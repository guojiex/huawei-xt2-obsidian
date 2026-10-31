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

declare const nativeVaultDir: {
  /** 只列当前一层。 */
  listDirByFd(fd: number): VaultDirListResult;
  /** 递归列出所有层级。 */
  listDirRecursiveByFd(fd: number): VaultDirListResult;
};

export default nativeVaultDir;
