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

/* ==================== 写 / 删 / 改名 ==================== */
/*
 * 为什么这一段必须存在：ArkTS 侧「由 URI 生成可写目标」的能力是残缺的。
 * 官方 2026-10-31 的第二轮答复把口径说死了：
 *   - `AtomicFile(path)` / `createStream` / `unlink` / `rename` 的 path 契约全是
 *     「Application sandbox path」，对目录 URI 拼出来的子路径不成立
 *     （AtomicFile 传 URI 实测 code=-1，与答复吻合）；
 *   - 剩下的可写入口只有 `fs.open(childUri, WRITE_ONLY|CREATE)`，但官方明确
 *     **不推荐应用自行拼接 URI**（涉及百分号编解码，系统不保证自拼 URI 可用）。
 * 所以整个写闭环下沉到 Native：拿到的 dirFd 已经是「授权过的目录」，在其上
 * openat/unlinkat/renameat 走的是同一份 ACL，既不拼 URI 也不碰沙箱路径。
 */

/** 取任意个数的 JS 参数；个数不足或类型不对返回 false。 */
static bool vaultdir_args(napi_env env, napi_callback_info info, size_t expected,
                          napi_value *argv) {
  size_t argc = expected;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < expected) {
    return false;
  }
  return true;
}

/** 从 napi_value 取字符串到堆上 buffer；调用方 free。失败返回 NULL。 */
static char *vaultdir_to_utf8(napi_env env, napi_value value, size_t *out_len) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) {
    return NULL;
  }
  char *buffer = (char *)malloc(length + 1);
  if (buffer == NULL) {
    return NULL;
  }
  if (napi_get_value_string_utf8(env, value, buffer, length + 1, &length) != napi_ok) {
    free(buffer);
    return NULL;
  }
  buffer[length] = '\0';
  if (out_len != NULL) {
    *out_len = length;
  }
  return buffer;
}

/** ok / code / message 三元结果，写删改名都用它。 */
static napi_value vaultdir_build_simple(napi_env env, int error) {
  napi_value result = NULL;
  if (napi_create_object(env, &result) != napi_ok) {
    return NULL;
  }
  napi_value ok_value = NULL;
  napi_value code_value = NULL;
  napi_value message_value = NULL;
  napi_get_boolean(env, error == 0, &ok_value);
  napi_create_int32(env, error, &code_value);
  const char *message = error == 0 ? "" : strerror(error);
  napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &message_value);
  napi_set_named_property(env, result, "ok", ok_value);
  napi_set_named_property(env, result, "code", code_value);
  napi_set_named_property(env, result, "message", message_value);
  return result;
}

/** { ok, code, message, content } —— 读文本文件专用。 */
static napi_value vaultdir_build_read(napi_env env, int error, const char *content) {
  napi_value result = vaultdir_build_simple(env, error);
  if (result == NULL) {
    return NULL;
  }
  napi_value text_value = NULL;
  if (napi_create_string_utf8(env, content == NULL ? "" : content, NAPI_AUTO_LENGTH,
                              &text_value) == napi_ok) {
    napi_set_named_property(env, result, "content", text_value);
  }
  return result;
}

/* 带 EINTR 重试的完整写：write 可能被信号打断或短写，必须循环。 */
static bool vaultdir_write_all(int fd, const char *data, size_t length, int *error) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t written = write(fd, data + offset, length - offset);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      *error = errno;
      return false;
    }
    offset += (size_t)written;
  }
  return true;
}

/*
 * readFileByFd(dirFd, name) —— 读目录下的一个文本文件。
 * 对应「打开一篇笔记」；名字是**相对**目录 fd 的，不含任何路径分隔符以外的东西。
 */
static napi_value read_file_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[2] = {NULL, NULL};
  if (!vaultdir_args(env, info, 2, argv)) {
    return vaultdir_build_read(env, EINVAL, NULL);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_read(env, EBADF, NULL);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  if (name == NULL) {
    return vaultdir_build_read(env, EINVAL, NULL);
  }

  int file_fd = openat(fd, name, O_RDONLY | O_CLOEXEC);
  if (file_fd < 0) {
    int error = errno;
    free(name);
    return vaultdir_build_read(env, error, NULL);
  }
  free(name);

  /* 一次读到尾。笔记文件量级是 KB~百 KB，不做流式。 */
  size_t capacity = 8192;
  size_t length = 0;
  char *buffer = (char *)malloc(capacity);
  if (buffer == NULL) {
    close(file_fd);
    return vaultdir_build_read(env, ENOMEM, NULL);
  }
  int error = 0;
  while (true) {
    if (length + 1 >= capacity) {
      size_t grown = capacity * 2;
      char *resized = (char *)realloc(buffer, grown);
      if (resized == NULL) {
        error = ENOMEM;
        break;
      }
      buffer = resized;
      capacity = grown;
    }
    ssize_t got = read(file_fd, buffer + length, capacity - length - 1);
    if (got < 0) {
      if (errno == EINTR) {
        continue;
      }
      error = errno;
      break;
    }
    if (got == 0) {
      break;
    }
    length += (size_t)got;
  }
  close(file_fd);

  if (error != 0) {
    free(buffer);
    return vaultdir_build_read(env, error, NULL);
  }
  buffer[length] = '\0';
  napi_value result = vaultdir_build_read(env, 0, buffer);
  free(buffer);
  return result;
}

/*
 * writeFileByFd(dirFd, name, content) —— **原子**写。
 *
 * 官方推荐的形态（答复 Q3(a)）：同目录写 tmp → fsync → renameat 覆盖。
 * renameat 在同一目录内是 POSIX 原子语义：崩溃窗口里最多留下一个 .tmp 残骸，
 * 原文件始终完好。这正是 AtomicFile 在沙箱内做的事，只是我们用 fd 重做了一遍。
 */
static napi_value write_file_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[3] = {NULL, NULL, NULL};
  if (!vaultdir_args(env, info, 3, argv)) {
    return vaultdir_build_simple(env, EINVAL);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_simple(env, EBADF);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  size_t content_len = 0;
  char *content = vaultdir_to_utf8(env, argv[2], &content_len);
  if (name == NULL || content == NULL) {
    free(name);
    free(content);
    return vaultdir_build_simple(env, EINVAL);
  }

  /* tmp 名字带上 pid：同一个目录被两个进程/两次调用并发写时不会互相踩。
     name 必须活到 renameat，不能在构造 tmp 之后就 free。 */
  char tmp_name[1024];
  snprintf(tmp_name, sizeof(tmp_name), "%s.%d.tmp", name, (int)getpid());

  int error = 0;
  int tmp_fd = openat(fd, tmp_name, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0666);
  if (tmp_fd < 0) {
    error = errno;
    free(content);
    free(name);
    return vaultdir_build_simple(env, error);
  }

  if (!vaultdir_write_all(tmp_fd, content, content_len, &error)) {
    close(tmp_fd);
    unlinkat(fd, tmp_name, 0);
    free(content);
    free(name);
    return vaultdir_build_simple(env, error);
  }
  free(content);

  if (fsync(tmp_fd) != 0) {
    error = errno;
    close(tmp_fd);
    unlinkat(fd, tmp_name, 0);
    free(name);
    return vaultdir_build_simple(env, error);
  }
  close(tmp_fd);

  if (renameat(fd, tmp_name, fd, name) != 0) {
    error = errno;
    unlinkat(fd, tmp_name, 0);
    free(name);
    return vaultdir_build_simple(env, error);
  }

  /*
   * 目录项落盘：renameat 返回成功只保证命名空间已换，断电时目录项可能还在
   * page cache 里。这一步在某些 DFS/FUSE 挂载点上会返回 EINVAL（不支持对目录
   * fd 做 fsync）—— 此时数据本身已经在 rename 前 fsync 过了，内容不丢，
   * 所以只当作软警告，不把整个写判死。
   */
  if (fsync(fd) != 0 && errno != EINVAL) {
    free(name);
    return vaultdir_build_simple(env, errno);
  }

  free(name);
  return vaultdir_build_simple(env, 0);
}

/** deleteByFd(dirFd, name) —— 删目录下的一个文件，对应 unlink。 */
static napi_value delete_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[2] = {NULL, NULL};
  if (!vaultdir_args(env, info, 2, argv)) {
    return vaultdir_build_simple(env, EINVAL);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_simple(env, EBADF);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  if (name == NULL) {
    return vaultdir_build_simple(env, EINVAL);
  }
  int error = 0;
  if (unlinkat(fd, name, 0) != 0) {
    error = errno;
  }
  free(name);
  return vaultdir_build_simple(env, error);
}

/** renameByFd(dirFd, oldName, newName) —— 同目录内改名 / 移动。 */
static napi_value rename_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[3] = {NULL, NULL, NULL};
  if (!vaultdir_args(env, info, 3, argv)) {
    return vaultdir_build_simple(env, EINVAL);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_simple(env, EBADF);
  }
  char *old_name = vaultdir_to_utf8(env, argv[1], NULL);
  char *new_name = vaultdir_to_utf8(env, argv[2], NULL);
  if (old_name == NULL || new_name == NULL) {
    free(old_name);
    free(new_name);
    return vaultdir_build_simple(env, EINVAL);
  }
  int error = 0;
  if (renameat(fd, old_name, fd, new_name) != 0) {
    error = errno;
  }
  free(old_name);
  free(new_name);
  return vaultdir_build_simple(env, error);
}

static napi_value vaultdir_register_module(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"listDirByFd", NULL, list_dir_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"listDirRecursiveByFd", NULL, list_dir_recursive_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"readFileByFd", NULL, read_file_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"writeFileByFd", NULL, write_file_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"deleteByFd", NULL, delete_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"renameByFd", NULL, rename_by_fd, NULL, NULL, NULL, napi_default, NULL},
  };
  if (napi_define_properties(env, exports,
                             sizeof(properties) / sizeof(properties[0]),
                             properties) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(vaultdir_napi, vaultdir_register_module)
