/*
 * VaultDirNative —— 「目录 URI → fd → Native fdopendir」这条路的 ArkTS 封装。
 *
 * 由来（已由官方答复 + 本机 SDK 交叉验证，见 api_notes.md T5）：
 *   - DocumentViewPicker(DocumentSelectMode.FOLDER) 返回的目录 URI，
 *     经 persistPermission + activatePermission 后可长期读写；
 *   - 但 @ohos.file.fs.listFile* 的 path 契约是「应用沙箱路径」，传目录 URI 报
 *     13900002 —— 这不是用法错，是接口不支持；
 *   - 而 fs.open/openSync 的 path 契约是「沙箱路径 or URI」，同一 URI 能开出 fd；
 *   - ArkTS 侧没有任何基于 fd 的 readdir 语义接口，所以遍历交给 Native。
 *
 * 于是完整链路是：openSync(目录URI) → 拿 fd → Native fdopendir/readdir 遍历。
 * Native 侧用 openat(fd, 子项名) 递归，**全程不拼 URI、不碰沙箱路径**。
 *
 * 本文件的定位是**纯逻辑 + 依赖注入**：真正的 native 桥接由调用方传入，
 * 这样工具侧单测能在 Node 里跑（见 tools/tests/test_vault_dir_native.mjs）。
 */

/** native 桥接契约，对应 vaultdir_napi 的两个导出。 */
export interface VaultDirListResult {
  ok: boolean;
  code: number;
  message: string;
  entries: string[];
}

export interface VaultDirNativeLike {
  listDirByFd(fd: number): VaultDirListResult;
  listDirRecursiveByFd(fd: number): VaultDirListResult;
  readFileByFd(fd: number, name: string): VaultDirReadResult;
  writeFileByFd(fd: number, name: string, content: string): VaultDirIoResult;
  deleteByFd(fd: number, name: string): VaultDirIoResult;
  renameByFd(fd: number, oldName: string, newName: string): VaultDirIoResult;
}

/** Native 返回的 { ok, code, message }。失败统一走 struct 而不是 throw。 */
export interface VaultDirIoResult {
  ok: boolean;
  code: number;
  message: string;
}

/** readFileByFd 的返回：内容与成功与否同体。 */
export interface VaultDirReadResult {
  ok: boolean;
  code: number;
  message: string;
  content: string;
}

/** 只需要能开目录 fd 并关掉，其余交给 Native。 */
export interface VaultDirFsLike {
  openDirFd(uri: string): number;
  closeFd(fd: number): void;
}

/** 归一化后的条目（Native 返回的字符串在此转成结构）。 */
export interface VaultDirEntry {
  path: string;
  isDir: boolean;
}

export interface VaultDirScanResult {
  ok: boolean;
  code: number;
  message: string;
  entries: VaultDirEntry[];
}

/** Native 侧的约定：目录项以 '/' 结尾，文件项不带；路径一律不带前导斜杠。 */
export function splitVaultDirEntry(raw: string): VaultDirEntry {
  const isDir: boolean = raw.endsWith('/');
  return { path: isDir ? raw.slice(0, raw.length - 1) : raw, isDir: isDir };
}

/**
 * 认作笔记的后缀。**必须与 ExternalDirProbe.isMarkdownEntry 同口径**（ .md + .markdown ），
 * 否则「listFileSync 能列出的」和「Native 能列出的」会差一批文件，这种差最难查。
 * 这里没直接 import，是想让本文件保持零 IO 依赖、能在 Node 单测里裸跑。
 */
const VAULT_MARKDOWN_SUFFIXES: string[] = ['.md', '.markdown'];

function isVaultMarkdownName(path: string): boolean {
  const lower: string = path.toLowerCase();
  for (let i = 0; i < VAULT_MARKDOWN_SUFFIXES.length; i++) {
    if (lower.endsWith(VAULT_MARKDOWN_SUFFIXES[i])) {
      return true;
    }
  }
  return false;
}

/** 从遍历结果里挑 Markdown 文件（忽略大小写），保持遍历顺序。 */
export function selectVaultMarkdown(entries: VaultDirEntry[]): string[] {
  const picked: string[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry: VaultDirEntry = entries[i];
    if (entry.isDir) {
      continue;
    }
    if (isVaultMarkdownName(entry.path)) {
      picked.push(entry.path);
    }
  }
  return picked;
}

/** BusinessError 的 code 字段。ArkTS 不允许用对象字面量当类型，必须具名。 */
interface ErrorCodeCarrier {
  code?: number;
}

/** errno → 人话。只写核实过程中真见过的，其余原样带上数字。 */
const VAULT_DIR_ERROR_TEXT: Record<number, string> = {
  2: '目录不存在或已被移动（ENOENT）',
  9: 'fd 不可用，可能已被关闭（EBADF）',
  13: '权限不足，该 fd 上没有读授权（EACCES）',
  12: '内存不足（ENOMEM）',
  20: '目标不是目录（ENOTDIR）',
  40: '存在符号链接环路，超过最大递归深度（ELOOP）',
};

export function describeVaultDirError(code: number): string {
  const known: string = VAULT_DIR_ERROR_TEXT[code];
  if (known !== undefined && known.length > 0) {
    return known;
  }
  return '遍历失败（errno=' + code + '）';
}

/** 把 native 的原始返回收敛成本文件的结果结构。 */
function toScanResult(raw: VaultDirListResult): VaultDirScanResult {
  const entries: VaultDirEntry[] = [];
  for (let i = 0; i < raw.entries.length; i++) {
    entries.push(splitVaultDirEntry(raw.entries[i]));
  }
  return {
    ok: raw.ok,
    code: raw.code,
    message: raw.message,
    entries: entries,
  };
}

/**
 * 目录遍历器。**fd 的开关由自己负责**：caller 传 URI，scan 内部控制生命周期，
 * 避免 native 拿到的是被 dup 之后又被 ArkTS 侧提前关掉的描述符。
 */
export class VaultDirectoryScanner {
  private nativeImpl: VaultDirNativeLike;
  private fsImpl: VaultDirFsLike;

  constructor(nativeImpl: VaultDirNativeLike, fsImpl: VaultDirFsLike) {
    this.nativeImpl = nativeImpl;
    this.fsImpl = fsImpl;
  }

  /**
   * 对一个目录 URI 做遍历。失败时 `ok:false` 而不是抛异常 ——
   * 核实阶段要看 errno，抛出去会被 ArkTS 的 Error 包装吃干净。
   */
  scan(uri: string, recursive: boolean): VaultDirScanResult {
    let fd: number = -1;
    try {
      fd = this.fsImpl.openDirFd(uri);
    } catch (error) {
      const code: number = VaultDirectoryScanner.errorCodeOf(error);
      return { ok: false, code: code, message: describeVaultDirError(code), entries: [] };
    }

    try {
      const raw: VaultDirListResult = recursive
        ? this.nativeImpl.listDirRecursiveByFd(fd)
        : this.nativeImpl.listDirByFd(fd);
      return toScanResult(raw);
    } finally {
      // fd 一定还活着：Native 侧 fdopendir 用的是 dup 出来的描述符，
      // closedir 不会动原 fd。这里关原始那个。
      try {
        this.fsImpl.closeFd(fd);
      } catch (error) {
        // 关闭失败不影响遍历结果，核实阶段只需知道发生了什么
        hilogWarnOnce('vault dir fd close failed: ' + VaultDirectoryScanner.errorCodeOf(error));
      }
    }
  }

  /**
   * BusinessError / Error 都能掏出数字码；掏不到返回 -1（沿用 ExternalDirProbe 口径）。
   * 入参用 `Object` 而不是 `unknown`：ArkTS 禁 unknown/any（arkts-no-any-unknown），
   * 类型也不能用对象字面量现写（arkts-no-obj-literals-as-types），必须具名 interface。
   */
  static errorCodeOf(error: Object): number {
    const carry: ErrorCodeCarrier = error as ErrorCodeCarrier;
    if (carry !== undefined && carry !== null && typeof carry.code === 'number') {
      return carry.code;
    }
    return -1;
  }
}

/* --- hilog 只在设备侧有意义，Node 单测里会被替换；这里做一次轻量守卫 --- */
function hilogWarnOnce(text: string): void {
  // ArkTS 不允许在 import 之外动态 require；核实阶段直接用全局 hilog。
  // 单测注入的 fake fs 不会失败，所以这条分支在 Node 侧不会走到。
  console.warn('[VaultDirectoryScanner] ' + text);
}

/**
 * 目录 fd 的一次性借用：开 → 用 → 关。
 *
 * 所有文件级操作都复用这一层：上层永远传 URI 与「相对名字」，绝不碰 URI 拼接。
 * 官方明确说过系统不保证应用自拼 URI 的可用性（涉及百分号编解码），
 * 所以我们坚持「只在已授权的目录 fd 上做相对操作」这一条路。
 */
abstract class VaultDirSession {
  protected nativeImpl: VaultDirNativeLike;
  protected fsImpl: VaultDirFsLike;

  constructor(nativeImpl: VaultDirNativeLike, fsImpl: VaultDirFsLike) {
    this.nativeImpl = nativeImpl;
    this.fsImpl = fsImpl;
  }

  /** 在目录 fd 上跑一段逻辑。开 fd 失败时返回 code，而不是把异常抛给页面。 */
  protected withDirFd<T>(uri: string, action: (fd: number) => T, onOpenFailed: (code: number) => T): T {
    let fd: number = -1;
    try {
      fd = this.fsImpl.openDirFd(uri);
    } catch (error) {
      return onOpenFailed(VaultDirectoryScanner.errorCodeOf(error));
    }
    try {
      return action(fd);
    } finally {
      try {
        this.fsImpl.closeFd(fd);
      } catch (error) {
        hilogWarnOnce('vault dir fd close failed: ' + VaultDirectoryScanner.errorCodeOf(error));
      }
    }
  }

  protected ioFailure(code: number): VaultDirIoResult {
    return { ok: false, code: code, message: describeVaultDirError(code) };
  }
}

/**
 * 读写删改的对外入口。对应 v1.5 的四个业务动作：
 * 打开笔记 / 保存笔记 / 删除笔记 / 重命名笔记。
 *
 * 每个方法都返回 struct 而非抛异常 —— 页面要能把 errno 直接显示出来做核实，
 * 抛出去会被 ArkTS 的 Error 包装吃干净（这是之前 AtomicFile 报 code=-1 时
 * 我们完全无法定位的原因）。
 */
export class VaultDirFileStore extends VaultDirSession {
  /** 读一篇笔记。名字是**相对于被授权目录**的相对路径，可含子目录分隔符。 */
  read(uri: string, name: string): VaultDirReadResult {
    return this.withDirFd<VaultDirReadResult>(
      uri,
      (fd: number): VaultDirReadResult => this.nativeImpl.readFileByFd(fd, name),
      (code: number): VaultDirReadResult => {
        return { ok: false, code: code, message: describeVaultDirError(code), content: '' };
      }
    );
  }

  /**
   * 原子保存一篇笔记。Native 侧是「同目录 tmp → fsync → renameat」，
   * 崩溃时最多留一个 .tmp 残骸，原内容不会半截。
   */
  write(uri: string, name: string, content: string): VaultDirIoResult {
    return this.withDirFd<VaultDirIoResult>(
      uri,
      (fd: number): VaultDirIoResult => this.nativeImpl.writeFileByFd(fd, name, content),
      (code: number): VaultDirIoResult => this.ioFailure(code)
    );
  }

  /** 删除。持久化授权里的 WRITE_MODE 已覆盖子树删除，系统不再逐次确认。 */
  remove(uri: string, name: string): VaultDirIoResult {
    return this.withDirFd<VaultDirIoResult>(
      uri,
      (fd: number): VaultDirIoResult => this.nativeImpl.deleteByFd(fd, name),
      (code: number): VaultDirIoResult => this.ioFailure(code)
    );
  }

  /** 同目录内改名 / 移动。 */
  rename(uri: string, oldName: string, newName: string): VaultDirIoResult {
    return this.withDirFd<VaultDirIoResult>(
      uri,
      (fd: number): VaultDirIoResult => this.nativeImpl.renameByFd(fd, oldName, newName),
      (code: number): VaultDirIoResult => this.ioFailure(code)
    );
  }
}
