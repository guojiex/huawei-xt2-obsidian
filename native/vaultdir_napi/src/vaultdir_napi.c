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
 * 把一个已打开的 fd 一次读到尾（带 EINTR 重试，末尾留 '\0'）。
 * 笔记与附件量级是 KB~几 MB，不做流式；抽出来自 `.md` 与二进制两处共用，
 * 免得「文本读」和「附件读」各自演进、哪天行为分叉。
 */
static bool vaultdir_read_all(int file_fd, char **out_buffer, size_t *out_length, int *error) {
  size_t capacity = 8192;
  size_t length = 0;
  char *buffer = (char *)malloc(capacity);
  if (buffer == NULL) {
    *error = ENOMEM;
    return false;
  }
  while (true) {
    if (length + 1 >= capacity) {
      size_t grown = capacity * 2;
      char *resized = (char *)realloc(buffer, grown);
      if (resized == NULL) {
        free(buffer);
        *error = ENOMEM;
        return false;
      }
      buffer = resized;
      capacity = grown;
    }
    ssize_t got = read(file_fd, buffer + length, capacity - length - 1);
    if (got < 0) {
      if (errno == EINTR) {
        continue;
      }
      *error = errno;
      free(buffer);
      return false;
    }
    if (got == 0) {
      break;
    }
    length += (size_t)got;
  }
  buffer[length] = '\0';
  *out_buffer = buffer;
  *out_length = length;
  *error = 0;
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

  char *buffer = NULL;
  size_t length = 0;
  int error = 0;
  if (!vaultdir_read_all(file_fd, &buffer, &length, &error)) {
    close(file_fd);
    return vaultdir_build_read(env, error, NULL);
  }
  close(file_fd);

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

/* ====================================================================== */
/* v1.5 15.3/15.4 追加的四项能力                                          */
/* ---------------------------------------------------------------------- */
/* 前面六个函数是「核实链路」用的，够证明技术可行；但要真正把 FileTree /    */
/* 编辑器接进来，还缺四件事：                                             */
/*   stat        —— 15.4 要靠 mtime 判断外部有没有改过，没有它只能瞎猜；   */
/*   mkdir       —— 新建笔记放到新目录时，父目录必须先存在；               */
/*   递归删目录  —— 删除文件夹子树；                                      */
/*   二进制读    —— 附件（图片）走 UTF-8 字符串一定坏字节。                */
/* 四个都是 POSIX 标准调用（fstatat / mkdirat / unlinkat AT_REMOVEDIR /    */
/* read），不涉及任何鸿蒙私有 API，风险面只在文件 unusually 大时的内存。    */
/* ====================================================================== */

/** { ok, code, message, size, mtime, isDir } —— size/mtime 用 double 承载：
 *  ArkTS number 是 IEEE 754 双精度，53 位安全整数远大于任何单文件大小与秒级时间戳。 */
static napi_value vaultdir_build_stat(napi_env env, int error, const struct stat *info) {
  napi_value result = vaultdir_build_simple(env, error);
  if (result == NULL) {
    return NULL;
  }
  napi_value size_value = NULL;
  napi_value mtime_value = NULL;
  napi_value is_dir_value = NULL;
  napi_create_double(env, info == NULL ? 0.0 : (double)info->st_size, &size_value);
  napi_create_double(env, info == NULL ? 0.0 : (double)info->st_mtime, &mtime_value);
  napi_get_boolean(env, info != NULL && S_ISDIR(info->st_mode), &is_dir_value);
  napi_set_named_property(env, result, "size", size_value);
  napi_set_named_property(env, result, "mtime", mtime_value);
  napi_set_named_property(env, result, "isDir", is_dir_value);
  return result;
}

/*
 * statByFd(dirFd, name) —— 取一个子项的元信息。
 *
 * name 为空串时表示「问目录 fd 自己」，走 fstat(fd)：
 * 这正是 15.4 探测「持久化授权还活不活」的第一道关 —— 目录被挪走了 here 会先失败。
 */
static napi_value stat_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[2] = {NULL, NULL};
  if (!vaultdir_args(env, info, 2, argv)) {
    return vaultdir_build_stat(env, EINVAL, NULL);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_stat(env, EBADF, NULL);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  if (name == NULL) {
    return vaultdir_build_stat(env, EINVAL, NULL);
  }
  /* 局部变量不能叫 info —— 与 napi_callback_info 入参同名会触发
     "redefinition with a different type"（CI 上是 -Werror 的错）。 */
  struct stat meta;
  int error = 0;
  if (name[0] == '\0') {
    if (fstat(fd, &meta) != 0) {
      error = errno;
    }
  } else if (fstatat(fd, name, &meta, 0) != 0) {
    error = errno;
  }
  free(name);
  return vaultdir_build_stat(env, error, error == 0 ? &meta : NULL);
}

/*
 * mkdirByFd(dirFd, name) —— 等价于 mkdir -p。
 *
 * 逐段 mkdirat 后再 openat 进入下一段，全程相对父 fd：既支持多级一次性创建，
 * 也不用关心这棵树挂在哪。已存在的段允许 EEXIST；若已存在的同名物是文件，
 * 下一步 openat 带 O_DIRECTORY 会报 ENOTDIR，不会悄悄干掉用户文件。
 */
static int vaultdir_mkdir_all(int root_fd, const char *rel, int *error) {
  char *rest = vaultdir_dup(rel);
  if (rest == NULL) {
    *error = ENOMEM;
    return 0;
  }
  size_t len = strlen(rest);
  size_t pos = 0;
  int current = root_fd;
  int ok = 1;
  while (pos < len) {
    while (pos < len && rest[pos] == '/') {
      pos++;
    }
    if (pos >= len) {
      break;
    }
    size_t start = pos;
    while (pos < len && rest[pos] != '/') {
      pos++;
    }
    char slash = rest[pos];
    rest[pos] = '\0';
    const char *seg = rest + start;

    if (mkdirat(current, seg, 0777) != 0 && errno != EEXIST) {
      *error = errno;
      ok = 0;
      rest[pos] = slash;
      break;
    }
    int next = openat(current, seg, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (next < 0) {
      *error = errno;
      ok = 0;
      rest[pos] = slash;
      break;
    }
    if (current != root_fd) {
      close(current);
    }
    current = next;
    rest[pos] = slash;
  }
  if (current != root_fd) {
    close(current);
  }
  free(rest);
  return ok;
}

static napi_value mkdir_by_fd(napi_env env, napi_callback_info info) {
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
  if (name[0] == '\0') {
    error = EINVAL;
  } else if (!vaultdir_mkdir_all(fd, name, &error)) {
    if (error == 0) {
      error = EIO;
    }
  }
  free(name);
  return vaultdir_build_simple(env, error);
}

/* 前向声明：清空目录与删子项互相递归，必须先把其中一个的签名露出来。 */
static bool vaultdir_rm_all(int parent_fd, const char *name, int *error);

/* 清空一个目录 fd 的全部内容（不删目录自身）。 */
static bool vaultdir_clear_dir(int dir_fd, int *error) {
  /* 同 scan 的结论：fdopendir 接管 fd 所有权，必须先 dup。 */
  int owned_fd = dup(dir_fd);
  if (owned_fd < 0) {
    *error = errno;
    return false;
  }
  DIR *stream = fdopendir(owned_fd);
  if (stream == NULL) {
    *error = errno;
    close(owned_fd);
    return false;
  }
  struct dirent *entry = NULL;
  bool ok = true;
  while ((entry = readdir(stream)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (!vaultdir_rm_all(dir_fd, entry->d_name, error)) {
      ok = false;
      break;
    }
  }
  closedir(stream); /* 会一并关掉 owned_fd */
  return ok;
}

/* 删除 parent_fd 下的 name：目录递归清，普通文件直接 unlink。 */
static bool vaultdir_rm_all(int parent_fd, const char *name, int *error) {
  int child = openat(parent_fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (child < 0) {
    if (errno == ENOTDIR) {
      if (unlinkat(parent_fd, name, 0) != 0) {
        *error = errno;
        return false;
      }
      return true;
    }
    *error = errno;
    return false;
  }
  bool ok = vaultdir_clear_dir(child, error);
  close(child);
  if (!ok) {
    return false;
  }
  if (unlinkat(parent_fd, name, AT_REMOVEDIR) != 0) {
    *error = errno;
    return false;
  }
  return true;
}

/**
 * removeDirByFd(dirFd, name) —— 递归删子树。
 *
 * ⚠️ 这条一次调用就会抹掉磁盘上的真实文件，**没有回收站**：外部库不像沙箱库会把
 * 内容先挪进 `.trash`（15.6：App 私有数据一律不落外部目录）。所以调用方必须在
 * UI 层先做确认 —— 沙箱库删了还能从 .trash 捞回来，外部库删了就是真没了。
 */
static napi_value remove_dir_by_fd(napi_env env, napi_callback_info info) {
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
  if (name[0] == '\0') {
    error = EINVAL;
  } else if (!vaultdir_rm_all(fd, name, &error)) {
    if (error == 0) {
      error = EIO;
    }
  }
  free(name);
  return vaultdir_build_simple(env, error);
}

/** { ok, code, message, fd } —— openDirByFd 专用。失败时 fd 为 -1。 */
static napi_value vaultdir_build_fd(napi_env env, int error, int opened_fd) {
  napi_value result = vaultdir_build_simple(env, error);
  if (result == NULL) {
    return NULL;
  }
  napi_value fd_value = NULL;
  napi_create_int32(env, opened_fd, &fd_value);
  napi_set_named_property(env, result, "fd", fd_value);
  return result;
}

/*
 * openDirByFd(dirFd, name) —— 在父目录 fd 上打开一个**子目录**，返回它的 fd。
 *
 * 为什么要单列这个函数：readdir 需要先有一个目录 fd（listDirByFd 收的是 fd 而不
 * 是名字），而文件树要在任意深度列一层。文件级那些接口（read/write/delete/rename）
 * 本来就用 openat 吃相对路径 "a/b/c.md"，不缺这一层；只有列目录缺。
 *
 * ⚠️ 返回的是**新 fd，调用方负责关**。名字为空串不给 dup(dirFd) —— 那会让调用方
 * 容易忘关；需要根 fd 时调用方自己再去开根。
 */
static napi_value open_dir_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[2] = {NULL, NULL};
  if (!vaultdir_args(env, info, 2, argv)) {
    return vaultdir_build_fd(env, EINVAL, -1);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_fd(env, EBADF, -1);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  if (name == NULL) {
    return vaultdir_build_fd(env, EINVAL, -1);
  }
  int opened = -1;
  int error = 0;
  if (name[0] == '\0') {
    error = EINVAL;
  } else {
    opened = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (opened < 0) {
      error = errno;
    }
  }
  free(name);
  return vaultdir_build_fd(env, error, error == 0 ? opened : -1);
}

/** { ok, code, message, bytes: Uint8Array } —— 二进制读专用。 */
static napi_value vaultdir_build_binary(napi_env env, int error, const char *data, size_t length) {
  napi_value result = vaultdir_build_simple(env, error);
  if (result == NULL) {
    return NULL;
  }
  napi_value arraybuffer = NULL;
  void *payload = NULL;
  bool made = false;
  if (data != NULL && napi_create_arraybuffer(env, length, &payload, &arraybuffer) == napi_ok) {
    memcpy(payload, data, length);
    napi_value typed = NULL;
    if (napi_create_typedarray(env, napi_uint8_array, length, arraybuffer, 0, &typed) == napi_ok) {
      napi_set_named_property(env, result, "bytes", typed);
      made = true;
    }
  }
  if (!made) {
    /* 失败或零长度也要给一个空的 Uint8Array，别让 ArkTS 侧拿到 undefined。 */
    napi_value empty_buffer = NULL;
    void *empty = NULL;
    if (napi_create_arraybuffer(env, 0, &empty, &empty_buffer) == napi_ok) {
      napi_value typed = NULL;
      if (napi_create_typedarray(env, napi_uint8_array, 0, empty_buffer, 0, &typed) == napi_ok) {
        napi_set_named_property(env, result, "bytes", typed);
      }
    }
  }
  return result;
}

/*
 * readBinaryByFd(dirFd, name) —— 按字节读一个文件。
 *
 * 存在的理由很直接：图片附件只要经过 UTF-8 字符串就必然坏字节（0x80 以上字节
 * 会被替换成 U+FFFD），readFileByFd 那条路对二进制是不可用的。
 */
static napi_value read_binary_by_fd(napi_env env, napi_callback_info info) {
  napi_value argv[2] = {NULL, NULL};
  if (!vaultdir_args(env, info, 2, argv)) {
    return vaultdir_build_binary(env, EINVAL, NULL, 0);
  }
  int32_t fd = 0;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return vaultdir_build_binary(env, EBADF, NULL, 0);
  }
  char *name = vaultdir_to_utf8(env, argv[1], NULL);
  if (name == NULL) {
    return vaultdir_build_binary(env, EINVAL, NULL, 0);
  }
  int file_fd = openat(fd, name, O_RDONLY | O_CLOEXEC);
  if (file_fd < 0) {
    int error = errno;
    free(name);
    return vaultdir_build_binary(env, error, NULL, 0);
  }
  free(name);

  char *buffer = NULL;
  size_t length = 0;
  int error = 0;
  if (!vaultdir_read_all(file_fd, &buffer, &length, &error)) {
    close(file_fd);
    return vaultdir_build_binary(env, error, NULL, 0);
  }
  close(file_fd);

  napi_value result = vaultdir_build_binary(env, 0, buffer, length);
  free(buffer);
  return result;
}

static napi_value vaultdir_register_module(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"listDirByFd", NULL, list_dir_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"listDirRecursiveByFd", NULL, list_dir_recursive_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"readFileByFd", NULL, read_file_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"writeFileByFd", NULL, write_file_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"deleteByFd", NULL, delete_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"renameByFd", NULL, rename_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"statByFd", NULL, stat_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"mkdirByFd", NULL, mkdir_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"removeDirByFd", NULL, remove_dir_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"readBinaryByFd", NULL, read_binary_by_fd, NULL, NULL, NULL, napi_default, NULL},
      {"openDirByFd", NULL, open_dir_by_fd, NULL, NULL, NULL, napi_default, NULL},
  };
  if (napi_define_properties(env, exports,
                             sizeof(properties) / sizeof(properties[0]),
                             properties) != napi_ok) {
    return NULL;
  }
  return exports;
}

NAPI_MODULE(vaultdir_napi, vaultdir_register_module)
