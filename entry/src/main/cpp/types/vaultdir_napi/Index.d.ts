/*
 * vaultdir_napi 的 ArkTS 类型声明。
 * 与 native/vaultdir_napi/src/vaultdir_napi.c 的导出一一对应。
 */

/**
 * 遍历结果。**失败不抛异常**，而是 ok:false + errno —— ArkTS 的 throw 只能带
 * Error 子类，会丢掉 errno，而 errno 正是核实阶段最需要的东西。
 */
export interface VaultDirListResult {
  ok: boolean;
  /** 0 表示成功；否则是 POSIX errno（如 EBADF=9、EACCES=13、ENOENT=2）。 */
  code: number;
  /** code 非 0 时的 strerror 文案。部分成功（命中无权进入的子目录）时也会带 code。 */
  message: string;
  /**
   * 相对路径数组，**不带前导斜杠**（与 fs.listFileSync 的 "以 / 开头" 不同）。
   * 目录项以 '/' 结尾，文件项不带 —— 按 endsWith('/') 区分，无需再 stat。
   */
  entries: string[];
}

/**
 * 写 / 删 / 改名的结果。**同样不抛异常**，成功与否看 ok，原因看 code(errno)。
 *
 * 为什么这些能力必须下沉 Native：ArkTS 侧 AtomicFile / createStream / unlink /
 * rename 的 path 契约全是「应用沙箱路径」，对目录 URI 拼出的子路径不成立；
 * 唯一收 URI 的 `fs.open` 又被官方明确不推荐用于自行拼接 URI（涉及百分号编解码，
 * 系统不保证自拼 URI 可用）。基于已授权的目录 fd 做 openat/unlinkat/renameat
 * 走的是同一份 ACL，既不拼 URI 也不碰沙箱路径。
 */
export interface VaultDirIoResult {
  ok: boolean;
  /** 0 成功；否则 POSIX errno（EBADF=9、EACCES=13、ENOENT=2、EROFS=30…）。 */
  code: number;
  message: string;
}

/** 读文件返回：内容与成功与否同体，省掉调用方一次 round-trip。 */
export interface VaultDirReadResult extends VaultDirIoResult {
  /** 失败时为 ''。 */
  content: string;
}

/** statByFd 的返回。mtime 是**秒**（POSIX st_mtime），用来做外部变更检测。 */
export interface VaultDirStatResult extends VaultDirIoResult {
  /** 字节数；失败为 0。 */
  size: number;
  /** 最后修改时间（Unix 秒）；失败为 0。 */
  mtime: number;
  /** 是否是目录；失败为 false。 */
  isDir: boolean;
}

/** readBinaryByFd 的返回。图片附件必须走这条，不能走 readFileByFd。 */
export interface VaultDirBinaryResult extends VaultDirIoResult {
  /** 失败或空文件时为零长数组，不会是 undefined。 */
  bytes: Uint8Array;
}

/** openDirByFd 的返回。失败时 fd 为 -1。 */
export interface VaultDirFdResult extends VaultDirIoResult {
  fd: number;
}

declare const nativeVaultDir: {
  /** 只列当前一层。 */
  listDirByFd(fd: number): VaultDirListResult;
  /** 递归列出所有层级。 */
  listDirRecursiveByFd(fd: number): VaultDirListResult;
  /** 读目录下的一个文本文件（名字相对 dirFd）。 */
  readFileByFd(fd: number, name: string): VaultDirReadResult;
  /**
   * **原子**写：同目录写 `name.<pid>.tmp` → fsync → renameat 覆盖。
   * 崩溃窗口最多留一个 .tmp 残骸，原文件始终完好。
   */
  writeFileByFd(fd: number, name: string, content: string): VaultDirIoResult;
  /** 删除目录下的一个文件（unlinkat）。无需系统二次授权，持久化 WRITE_MODE 已覆盖。 */
  deleteByFd(fd: number, name: string): VaultDirIoResult;
  /** 同目录内改名 / 移动（renameat）。 */
  renameByFd(fd: number, oldName: string, newName: string): VaultDirIoResult;

  /**
   * 取子项元信息（fstatat）。**name 为空串表示问目录 fd 自己** ——
   * 这是判断「持久化授权还活不活 / 目录有没有被挪走」的第一道探测。
   */
  statByFd(fd: number, name: string): VaultDirStatResult;
  /** 建多级目录（逐段 mkdirat，等价于 mkdir -p）。已存在的段不报错。 */
  mkdirByFd(fd: number, name: string): VaultDirIoResult;
  /**
   * 递归删子树（openat + unlinkat AT_REMOVEDIR）。
   * ⚠️ 外部库没有 `.trash`：这一下是真删，UI 层必须先确认再调。
   */
  removeDirByFd(fd: number, name: string): VaultDirIoResult;
  /** 打开子目录并返回它的 fd（⚠️ 新 fd，调用方负责关）。 */
  openDirByFd(fd: number, name: string): VaultDirFdResult;
  /**
   * 按字节读（图片附件专用）。
   * 为什么必须单列：二进制经 UTF-8 字符串必然坏字节，readFileByFd 对附件不可用。
   */
  readBinaryByFd(fd: number, name: string): VaultDirBinaryResult;
};

export default nativeVaultDir;
