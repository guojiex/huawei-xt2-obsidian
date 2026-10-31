/*
 * vaultdir_napi —— 基于 fd 的目录遍历（ArkTS 侧缺失的能力，Native 补齐）。
 *
 * 背景：三方应用通过 DocumentViewPicker(DocumentSelectMode.FOLDER) 拿到的目录 URI 形如
 *   file://docs/storage/Users/currentUser/Download/xxx
 * 该 URI 经 fileShare.persistPermission + activatePermission 后可长期读写，但
 * @ohos.file.fs 的 listFile/listFileSync 的 path 参数官方契约是「应用沙箱路径」，
 * 不支持 URI（传目录 URI 报 13900002）；而 fs.open/openSync 的 path 契约是
 * 「沙箱路径 or URI」，能对目录 URI 成功拿到 fd。ArkTS 侧又没有基于 fd 的
 * readdir 语义接口（旧的 @ohos.fileio opendir/Dir 已废弃）。
 *
 * 所以本模块做的事就一件：**收一个 fd，用 POSIX fdopendir/readdir 把它遍历出来**。
 * 递归时不用拼 URI、不用知道沙箱路径，直接在目录 fd 上 openat 子项 —— 这也是
 * 它比「拼子路径再 open」更稳的地方：只要父目录 fd 上有授权，子路径就走同一 ACL。
 *
 * 约定：
 *   - 返回的相对路径**不带前导斜杠**（与 fs.listFileSync 的 "以 / 开头" 不同）。
 *   - 目录项以 '/' 结尾，文件项不带。调用方按 endsWith('/') 区分，无需额外 stat。
 *   - 失败时**返回 ok:false + errno**，不抛异常。ArkTS 侧 throw 只能带 Error 子类，
 *     会丢掉 errno，而 errno 正是核实阶段最需要的东西。
 */

#include <node_api.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* 递归深度上限：防御符号链接成环。真正常规笔记库远低于此。 */
#define VAULTDIR_MAX_DEPTH 32
/* 条目上限：防止遍历失控把内存吃光。 */
#define VAULTDIR_MAX_ENTRIES 200000

typedef struct {
  char **items;
  size_t count;
  size_t capacity;
} vaultdir_vec;

/*
 * 自带 strdup：strdup 属 POSIX 而非 C99，在 `c_std_99` 下可能被 <string.h>
 * 的可见性宏裁掉（换 NDK 版本最容易踩），所以不依赖它。
 */
static char *vaultdir_dup(const char *text) {
  size_t length = strlen(text) + 1;
  char *copy = (char *)malloc(length);
  if (copy != NULL) {
    memcpy(copy, text, length);
  }
  return copy;
}

static void vaultdir_vec_free(vaultdir_vec *vec) {
  if (vec == NULL) {
    return;
  }
  for (size_t i = 0; i < vec->count; i++) {
    free(vec->items[i]);
  }
  free(vec->items);
  vec->items = NULL;
  vec->count = 0;
  vec->capacity = 0;
}

static bool vaultdir_vec_push(vaultdir_vec *vec, const char *text, int *error) {
  if (vec->count >= VAULTDIR_MAX_ENTRIES) {
    *error = ENOMEM;
    return false;
  }
  if (vec->count == vec->capacity) {
    size_t next = vec->capacity == 0 ? 64 : vec->capacity * 2;
    char **grown = (char **)realloc(vec->items, next * sizeof(char *));
    if (grown == NULL) {
      *error = ENOMEM;
      return false;
    }
    vec->items = grown;
    vec->capacity = next;
  }
  char *copy = vaultdir_dup(text);
  if (copy == NULL) {
    *error = ENOMEM;
    return false;
  }
  vec->items[vec->count++] = copy;
  return true;
}

/**
 * 判断 dir_fd 目录下 name 是否为目录。
 * dirent.d_type 在部分文件系统上是 DT_UNKNOWN，所以统一用 fstatat 兜底，
 * 且在传进来的父 fd 上做（相对路径语义，不依赖任何绝对路径）。
 */
static bool vaultdir_is_dirat(int parent_fd, const char *name, int *error) {
  struct stat info;
  if (fstatat(parent_fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0) {
    *error = errno;
    return false;
  }
  return S_ISDIR(info.st_mode);
}

/*
 * 遍历一个目录 fd。
 *
 * @param dir_fd 目录 fd（**调用方持有所有权**，本函数只 dup，不关闭入参 fd）
 * @param prefix 当前层级前缀：顶层为 ""，子层为 "sub/"（非空必以 '/' 结尾）
 */
static void vaultdir_scan(int dir_fd, const char *prefix, int depth,
                          bool recursive, vaultdir_vec *out, int *error) {
  if (*error != 0 || depth > VAULTDIR_MAX_DEPTH) {
    return;
  }

  /* fdopendir 会接管传入 fd 的所有权 —— 必须先 dup，否则 ArkTS 侧随后
     fs.closeSync(fd) 会操作一个已被 closedir 关掉的 fd（double close）。 */
  int owned_fd = dup(dir_fd);
  if (owned_fd < 0) {
    *error = errno;
    return;
  }
  DIR *stream = fdopendir(owned_fd);
  if (stream == NULL) {
    *error = errno;
    close(owned_fd);
    return;
  }

  struct dirent *entry = NULL;
  while ((entry = readdir(stream)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }

    size_t relative_len = strlen(prefix) + strlen(entry->d_name) + 2;
    char *relative = (char *)malloc(relative_len);
    if (relative == NULL) {
      *error = ENOMEM;
      break;
    }
    snprintf(relative, relative_len, "%s%s", prefix, entry->d_name);

    if (vaultdir_is_dirat(dir_fd, entry->d_name, error)) {
      size_t marked_len = strlen(relative) + 2;
      char *marked = (char *)malloc(marked_len);
      if (marked == NULL) {
        *error = ENOMEM;
        free(relative);
        break;
      }
      snprintf(marked, marked_len, "%s/", relative);
      if (!vaultdir_vec_push(out, marked, error)) {
        free(marked);
        free(relative);
        break;
      }
      free(marked);

      if (recursive) {
        size_t child_prefix_len = strlen(relative) + 2;
        char *child_prefix = (char *)malloc(child_prefix_len);
        if (child_prefix == NULL) {
          *error = ENOMEM;
          free(relative);
          break;
        }
        snprintf(child_prefix, child_prefix_len, "%s/", relative);

        int child_fd = openat(dir_fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (child_fd >= 0) {
          vaultdir_scan(child_fd, child_prefix, depth + 1, recursive, out, error);
          close(child_fd);
        } else if (errno != EACCES) {
          /* EACCES 只表示这一个子目录进不去，其他兄弟继续；别的错误停下报原因 */
          *error = errno;
        }
        free(child_prefix);
      }
      free(relative);
      if (*error != 0) {
        break;
      }
      continue;
    }

    if (*error != 0) {
      free(relative);
      break;
    }
    if (!vaultdir_vec_push(out, relative, error)) {
      free(relative);
      break;
    }
    free(relative);
  }

  closedir(stream); /* 同时关闭 owned_fd */
}

static napi_value vaultdir_build_result(napi_env env, int error, vaultdir_vec *out) {
  napi_value result = NULL;
  if (napi_create_object(env, &result) != napi_ok) {
    return NULL;
  }

  napi_value ok_value = NULL;
  napi_value code_value = NULL;
  napi_value message_value = NULL;
  napi_value entries_value = NULL;

  napi_get_boolean(env, error == 0, &ok_value);
  napi_create_int32(env, error, &code_value);

  const char *message = error == 0 ? "" : strerror(error);
  napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &message_value);

  size_t count = out == NULL ? 0 : out->count;
  if (napi_create_array_with_length(env, count, &entries_value) != napi_ok) {
    return NULL;
  }
  for (size_t i = 0; i < count; i++) {
    napi_value item = NULL;
    if (napi_create_string_utf8(env, out->items[i], NAPI_AUTO_LENGTH, &item) == napi_ok) {
      napi_set_element(env, entries_value, (uint32_t)i, item);
    }
  }

  napi_set_named_property(env, result, "ok", ok_value);
  napi_set_named_property(env, result, "code", code_value);
  napi_set_named_property(env, result, "message", message_value);
  napi_set_named_property(env, result, "entries", entries_value);
  return result;
}

/** 从 JS 取一个 int32 参数；失败返回 false。 */
static bool vaultdir_arg_fd(napi_env env, napi_callback_info info, int *out_fd) {
  size_t argc = 1;
  napi_value argv[1] = {NULL};
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) {
    return false;
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok) {
    return false;
  }
  *out_fd = (int)fd;
  return true;
}

static napi_value vaultdir_list_common(napi_env env, napi_callback_info info, bool recursive) {
  int fd = -1;
  if (!vaultdir_arg_fd(env, info, &fd)) {
    return vaultdir_build_result(env, EINVAL, NULL);
  }
  if (fd < 0) {
    return vaultdir_build_result(env, EBADF, NULL);
  }

  vaultdir_vec collected = {NULL, 0, 0};
  int error = 0;
  vaultdir_scan(fd, "", 0, recursive, &collected, &error);

  /* 只要拿到了东西，就把遍历中途的软错误降级：宁可返回部分结果 + code，
     也不要让一个 EACCES 子目录把整次列目录判死。 */
  napi_value result = vaultdir_build_result(env, error, &collected);
  vaultdir_vec_free(&collected);
  return result;
}

/** listDirByFd(fd: number): VaultDirListResult —— 只列当前一层。 */
static napi_value list_dir_by_fd(napi_env env, napi_callback_info info) {
  return vaultdir_list_common(env, info, false);
}

/** listDirRecursiveByFd(fd: number): VaultDirListResult —— 递归全部层级。 */
static napi_value list_dir_recursive_by_fd(napi_env env, napi_callback_info info) {
  return vaultdir_list_common(env, info, true);
}

static napi_value vaultdir_register_module(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"listDirByFd", NULL, list_dir_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"listDirRecursiveByFd", NULL, list_dir_recursive_by_fd, NULL, NULL, NULL, napi_default, NULL},
  };
  if (napi_define_properties(env, exports,
                             sizeof(properties) / sizeof(properties[0]),
                             properties) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(vaultdir_napi, vaultdir_register_module)
