/*
 * VaultAccess.ets —— 库访问的统一抽象（v1.5 · 15.3）
 *
 * 为什么必须有这一层（2026-10-31 定案，证据见 docs/harmonyos/api_notes.md T3/T6/T7）：
 *   - 沙箱库有**绝对路径**可以到处传，外部授权库没有：
 *     Picker 只给 `file://docs/…` 目录 URI，而 `fs.listFile` / `AtomicFile` /
 *     `unlink` / `rename` 的 path 契约全是「应用沙箱路径」（d.ts L1548 / L4718 /
 *     L3455 / L3009），对外部目录分别报 13900002 与 code=-1；
 *   - 唯一收 URI 的入口是 `fs.open`（L2491），产物是一个 dirFd，之后只能走
 *     Native POSIX（fdopendir / openat / write+fsync+renameat / unlinkat）——
 *     官方答复确认这是三方唯一通路，且 ArkTS 侧没有补齐计划。
 *
 * 结论：**两类库的形状不同，但上层（FileTree / NoteService）不该关心**。
 * 统一成「对一个不透明根做相对路径 IO」的接口，各自实现：
 *   - SandboxVaultAccess：绝对路径仍由 VaultPathResolver 产出（硬约束 14 不变，
 *     本类只是调用者，不自己拼路径）；
 *   - ExternalVaultAccess：只在已授权的目录 fd 上做相对名字操作，
 *     既不拼 URI（官方不保证自拼 URI 可用）也不碰沙箱路径。
 *
 * 隐藏项的过滤规则也统一在这里 —— 否则「沙箱能列出的」和「Native 能列出的」
 * 会差一批文件，这种差异最难查。
 *
 * 定位是**纯逻辑 + 依赖注入**（与 ExternalDirProbe / VaultDirNative 同套路）：
 * 真正的系统 IO 由调用方注入，工具侧单测可以在 Node 里裸跑。
 */

/** 库根的形态。上层只允许拿它做差异化**提示**，不允许据此分支 IO。 */
export type VaultAccessKind = 'sandbox' | 'external';

/** 某一层目录下的可见子节点（扁平，不带 relPath —— relPath 由调用方拼）。 */
export interface VaultDirChild {
  name: string;
  isDir: boolean;
}

/**
 * 全树快照 + 完整性标记（v1.40 · 40.8）：
 * - truncated：列举被深度 / 节点上限截断，未出现的路径**不许**当作已删除；
 * - failed：本次列举失败（如外部授权失效），entries 为空，同样不可下任何「消失」结论。
 */
export interface VaultSnapshotReport {
  entries: VaultDirChild[];
  truncated: boolean;
  failed: boolean;
}

/** collectTree 传递截断标记的可变持有者（沙箱实现内部用）。 */
interface VaultTruncationHolder {
  truncated: boolean;
}

/** 文件元信息。mtime 单位是**秒**（fileIo.Stat 与 POSIX st_mtime 都是秒）。 */
export interface VaultFileStat {
  size: number;
  mtimeSec: number;
  isDir: boolean;
  isSymbolicLink: boolean;
}

/** A picker-authorized binary source. Each adapter chooses the verified transfer path it supports. */
export interface VaultBinaryImportSource {
  byteLength: number;
  copyToPath(destinationPath: string): Promise<void>;
  readBytes(): Uint8Array;
}

/** 认作笔记的后缀，必须与 FileTree / VaultDirNative 同口径。 */
export const VAULT_NOTE_SUFFIXES: string[] = ['.md', '.markdown'];

/**
 * 扫描保护上限，沿用 FileTree 原值（深度 8 / 节点 1000）。
 * 放这里是为了避免两个地方各写一遍魔数，以后调上限只改一处。
 */
export const VAULT_SCAN_MAX_DEPTH: number = 8;
export const VAULT_SCAN_MAX_NODES: number = 1000;

/** 隐藏项：以点开头的一律不进树（.trash / .git / 系统垃圾文件）。 */
export function isVaultHiddenName(name: string): boolean {
  return name.length > 0 && name.charAt(0) === '.';
}

export function isVaultNoteName(name: string): boolean {
  const lower: string = name.toLowerCase();
  for (let i = 0; i < VAULT_NOTE_SUFFIXES.length; i++) {
    if (lower.endsWith(VAULT_NOTE_SUFFIXES[i])) {
      return true;
    }
  }
  return false;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) {
      return false;
    }
  }
  return true;
}

/** 排序口径保持与 FileTree 一致：字典序，目录排在文件之前。 */
export function compareVaultNames(a: string, b: string): number {
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

/**
 * 全树快照的规范化排序 —— **两类库必须产出同一种顺序**，否则同一个 flicking  amended
 * 说不通。
 *
 * 规则（与改造前 FileTree.walk 的产出完全等价）：一层里目录及其整棵子树在前，
 * 文件在后，同层内部字典序。实现方式是给路径每一段加一个类型权重再字典序比较：
 * 非末段必然是目录 → '0'，末段按自身 isDir 给 '0'/'1'。
 * 于是 `sub/deep.md` 的键是 ['0sub','1deep.md']，`root.md` 是 ['1root.md']，
 * 前者更小 —— 与原「先递归子目录、最后 push 本层文件」的顺序一致。
 */
export function sortVaultTree(entries: VaultDirChild[]): VaultDirChild[] {
  const decorated: string[][] = [];
  for (let i = 0; i < entries.length; i++) {
    decorated.push([vaultTreeKey(entries[i]), entries[i].name]);
  }
  // 排序键用 \u0000 连接：路径里不可能出现这个字符，不会错切。
  decorated.sort((a: string[], b: string[]): number => compareVaultNames(a[0], b[0]));
  const out: VaultDirChild[] = [];
  const lookup: Map<string, VaultDirChild> = new Map<string, VaultDirChild>();
  for (let i = 0; i < entries.length; i++) {
    lookup.set(entries[i].name, entries[i]);
  }
  for (let i = 0; i < decorated.length; i++) {
    const hit: VaultDirChild | undefined = lookup.get(decorated[i][1]);
    if (hit !== undefined) {
      out.push(hit);
    }
  }
  return out;
}

function vaultTreeKey(child: VaultDirChild): string {
  const segments: string[] = child.name.split('/');
  const parts: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    const last: boolean = i === segments.length - 1;
    const weight: string = (last && !child.isDir) ? '1' : '0';
    parts.push(weight + segments[i]);
  }
  return parts.join('\u0000');
}

/** 拼 relative 路径：空父段不产生前导斜杠（根目录用 '' 表示）。 */
export function joinVaultPath(relDir: string, name: string): string {
  if (relDir.length === 0) {
    return name;
  }
  return relDir + '/' + name;
}

/**
 * 库访问接口：全部以**库内相对路径**为参数。
 * 绝对路径、URI、fd 这些「根怎么表达」的细节留在实现里。
 */
/**
 * 全树快照：一次遍历拿到**全部**可见条目（相对路径 + 是否目录），已过滤隐藏项，
 * 顺序经 sortVaultTree 规范化（目录子树在前、文件在后、同层字典序）。
 *
 * 存在的直接理由：把 FileTree 从「自己拿着绝对路径递归」换成「对快照做过滤」，
 * 两类库就只剩**这一处**遍历实现，不可能再出现「沙箱能列出来的外部列不出来」。
 */
export interface VaultAccess {
  kind: VaultAccessKind;

  /** 一次遍历的全树快照（受 VAULT_SCAN_MAX_DEPTH / MAX_NODES 保护）。 */
  snapshot(): VaultDirChild[];

  /** 带完整性标记的全树快照（40.8）：truncated / failed 时不得据 entries 下「文件消失」结论。 */
  snapshotReport(): VaultSnapshotReport;

  /** List all non-hidden content in one directory, including attachments and other files. */
  /** List all non-hidden content; includeHidden is reserved for controlled migrations. */
  listAll(relDir: string, includeHidden?: boolean): VaultDirChild[];

  /** 列一层可见子节点（已过滤隐藏项；只保留目录与笔记文件），目录在前、字典序。 */
  listDir(relDir: string): VaultDirChild[];

  /** 全量目录 relPath（不受展开状态影响），供新建笔记对话框的目录选择器用。 */
  allDirs(): string[];

  /** 全量笔记 relPath，供快速切换 / 搜索用。 */
  allNotes(): string[];

  exists(relPath: string): boolean;

  /** 拿不到（文件不存在，或该形态不支持）返回 null，不抛。 */
  stat(relPath: string): VaultFileStat | null;

  readText(relPath: string): string;

  /** 读原始字节：附件转 base64 / dataUri 那条路要用。 */
  readBytes(relPath: string): Uint8Array;

  /** Import bytes into a newly named attachment; existing paths are rejected. */
  writeNewBinary(relPath: string, source: VaultBinaryImportSource): Promise<void>;

  /** 建一个空文件（新建笔记）。父目录由实现保证或由调用方先 ensureDir。 */
  createEmptyNote(relPath: string): void;

  ensureDir(relDir: string): void;

  /**
   * 原子写。**硬约束 15 的等价实现**：沙箱走 AtomicFile，外部走 Native
   * 「tmp → fsync → renameat」—— 后者正是 POSIX 语义上的原子替换，
   * 崩溃最多留一个 .tmp 残骸，原文件始终完好。
   */
  writeAtomic(relPath: string, content: string): Promise<void>;

  remove(relPath: string): void;

  /** 删目录。非空由调用方决定怎么提示，这里按实现能力处理（沙箱递归删）。 */
  removeDir(relPath: string): void;

  rename(from: string, to: string): void;
}

/* ------------------------------------------------------------------------- */
/* 沙箱实现                                                                   */
/* ------------------------------------------------------------------------- */

/**
 * 「给我相对路径，我还你绝对路径」的最小契约。
 * 实现方必须是 VaultPathResolver（硬约束 14 的唯一解析器），这里只约束形状
 * 是为了让本文件在 Node 单测里不依赖 AbilityKit。
 */
export interface VaultRootResolver {
  resolve(relativePath: string): string;
}

/** fileIo 里真正用到的那几个动作。抽成接口是为了 Node 单测能注入 fake。 */
export interface SandboxFsLike {
  listFileSync(abs: string): string[];
  accessSync(abs: string): boolean;
  mkdirSync(abs: string, recursive?: boolean): void;
  renameSync(from: string, to: string): void;
  unlinkSync(abs: string): void;
  rmdirSync(abs: string): void;
  readTextSync(abs: string): string;
  statSync(abs: string): SandboxStatLike;
  lstatSync(abs: string): SandboxStatLike;
  openSync(abs: string, mode: number): SandboxFileHandle;
  writeSync(fd: number, data: string): number;
  readSync(fd: number, buffer: Uint8Array): number;
  closeSync(fd: number): void;
  openAtomic(abs: string): SandboxAtomicFileLike;
}

export interface SandboxStatLike {
  size: number;
  mtime: number;
  isDirectory(): boolean;
  isSymbolicLink(): boolean;
}

export interface SandboxFileHandle {
  fd: number;
}

/** AtomicFile / WriteStream 的形状：落盘由回调式 end（flush 收尾）+ finishWrite 收尾。
 * 2026-11-07 API26 x86_64 模拟器探针实测：write 的回调先于落盘触发（end 回调才是写完点），
 * 故统一走 end。 */
export interface SandboxWriteStreamLike {
  end(content: string, encoding: string, callback: (err?: Error) => void): void;
}

export interface SandboxAtomicFileLike {
  startWrite(): SandboxWriteStreamLike;
  finishWrite(): void;
  failWrite(): void;
}

/** OpenMode 里本文件用得到的位；值取自 SDK d.ts 枚举。 */
export const VAULT_OPEN_READ_ONLY: number = 0o0;
export const VAULT_OPEN_WRITE_ONLY: number = 0o1;
export const VAULT_OPEN_CREATE: number = 0o100;

/**
 * 沙箱库的访问实现。
 *
 * 行为必须与今天的 FileTree / NoteService **完全一致** —— 这一的做法是把 IO 搬家，
 * 不是顺手改语义；回归只看得很隐蔽的差异（过滤规则、排序、写 errored 后的处理）。
 */
export class SandboxVaultAccess implements VaultAccess {
  readonly kind: VaultAccessKind = 'sandbox';

  private root: VaultRootResolver;
  private fsImpl: SandboxFsLike;

  constructor(root: VaultRootResolver, fsImpl: SandboxFsLike) {
    this.root = root;
    this.fsImpl = fsImpl;
  }

  private abs(relPath: string): string {
    return this.root.resolve(relPath);
  }

  /** Reject existing symlink parents before fileIo can follow them outside this library. */
  private assertNoSymlinkPath(relPath: string, includeFinal: boolean): void {
    if (relPath.length === 0) {
      return;
    }
    const segments: string[] = relPath.split('/');
    let current: string = '';
    const count: number = includeFinal ? segments.length : segments.length - 1;
    for (let i = 0; i < count; i++) {
      current = joinVaultPath(current, segments[i]);
      let meta: SandboxStatLike;
      try {
        meta = this.fsImpl.lstatSync(this.abs(current));
      } catch (error) {
        const failure: ErrorCodeCarrier = error as ErrorCodeCarrier;
        const code: number = failure !== undefined && failure !== null && typeof failure.code === 'number'
          ? failure.code : -1;
        if (code === 2 || code === 13900002) {
          return;
        }
        throw error instanceof Error ? error : new Error('检查库路径失败');
      }
      if (meta.isSymbolicLink()) {
        throw new Error('库路径不能经过符号链接');
      }
      if (i < count - 1 && !meta.isDirectory()) {
        throw new Error('库路径父级不是目录');
      }
      if (i === count - 1 && includeFinal && !meta.isDirectory()) {
        throw new Error('目标不是目录');
      }
    }
  }

  listDir(relDir: string): VaultDirChild[] {
    const all: VaultDirChild[] = this.listAll(relDir);
    const out: VaultDirChild[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].isDir || isVaultNoteName(all[i].name)) {
        out.push(all[i]);
      }
    }
    return out;
  }

  listAll(relDir: string, includeHidden: boolean = false): VaultDirChild[] {
    this.assertNoSymlinkPath(relDir, true);
    const names: string[] = this.rawChildNames(this.abs(relDir), includeHidden);
    const dirs: string[] = [];
    const files: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!includeHidden && isVaultHiddenName(name)) {
        continue;
      }
      const meta: VaultFileStat | null = this.stat(joinVaultPath(relDir, name));
      if (meta === null || meta.isSymbolicLink) {
        continue;
      }
      if (meta.isDir) {
        dirs.push(name);
      } else {
        files.push(name);
      }
    }
    dirs.sort(compareVaultNames);
    files.sort(compareVaultNames);

    const out: VaultDirChild[] = [];
    for (let i = 0; i < dirs.length; i++) {
      out.push({ name: dirs[i], isDir: true });
    }
    for (let i = 0; i < files.length; i++) {
      out.push({ name: files[i], isDir: false });
    }
    return out;
  }

  snapshot(): VaultDirChild[] {
    return this.snapshotReport().entries;
  }

  /**
   * 沙箱侧列举永不置 failed：rawChildNames 列不到时当空目录（既有语义，不把 UI 拖崩）；
   * 但深度 / 节点上限照常置 truncated（40.8）。
   */
  snapshotReport(): VaultSnapshotReport {
    const counted: CountHolder = { value: 0 };
    const holder: VaultTruncationHolder = { truncated: false };
    const out: VaultDirChild[] = [];
    this.collectTree('', 0, out, counted, holder);
    return { entries: sortVaultTree(out), truncated: holder.truncated, failed: false };
  }

  allDirs(): string[] {
    const all: VaultDirChild[] = this.snapshot();
    const out: string[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].isDir) {
        out.push(all[i].name);
      }
    }
    return out;
  }

  allNotes(): string[] {
    const all: VaultDirChild[] = this.snapshot();
    const out: string[] = [];
    for (let i = 0; i < all.length; i++) {
      const entry: VaultDirChild = all[i];
      if (!entry.isDir && isVaultNoteName(entry.name)) {
        out.push(entry.name);
      }
    }
    return out;
  }

  exists(relPath: string): boolean {
    return this.stat(relPath) !== null;
  }

  stat(relPath: string): VaultFileStat | null {
    this.assertNoSymlinkPath(relPath, false);
    try {
      const raw: SandboxStatLike = this.fsImpl.lstatSync(this.abs(relPath));
      return {
        size: raw.size,
        mtimeSec: raw.mtime,
        isDir: raw.isDirectory(),
        isSymbolicLink: raw.isSymbolicLink()
      };
    } catch (error) {
      return null;
    }
  }

  readText(relPath: string): string {
    const meta: VaultFileStat | null = this.stat(relPath);
    if (meta !== null && meta.isSymbolicLink) {
      throw new Error('不读取符号链接');
    }
    return this.fsImpl.readTextSync(this.abs(relPath));
  }

  readBytes(relPath: string): Uint8Array {
    const meta: VaultFileStat | null = this.stat(relPath);
    if (meta !== null && meta.isSymbolicLink) {
      throw new Error('不读取符号链接');
    }
    const abs: string = this.abs(relPath);
    const size: number = this.sizeOf(abs);
    const handle: SandboxFileHandle = this.fsImpl.openSync(abs, VAULT_OPEN_READ_ONLY);
    try {
      const buffer: Uint8Array = new Uint8Array(size);
      let offset: number = 0;
      while (offset < buffer.length) {
        const chunk: Uint8Array = new Uint8Array(buffer.length - offset);
        const count: number = this.fsImpl.readSync(handle.fd, chunk);
        const copied: number = Math.min(count, chunk.length);
        if (copied <= 0) {
          throw new Error('附件读取未完成');
        }
        buffer.set(chunk.subarray(0, copied), offset);
        offset += copied;
      }
      return buffer;
    } finally {
      this.fsImpl.closeSync(handle.fd);
    }
  }

  async writeNewBinary(relPath: string, source: VaultBinaryImportSource): Promise<void> {
    this.assertNoSymlinkPath(parentDirOf(relPath), true);
    if (this.exists(relPath)) {
      throw new Error('附件目标已存在');
    }
    this.ensureDir(parentDirOf(relPath));
    const abs: string = this.abs(relPath);
    try {
      const sourceBytes: Uint8Array = source.readBytes();
      if (sourceBytes.length !== source.byteLength || sourceBytes.length === 0) {
        throw new Error('所选图片读取不完整');
      }
      await source.copyToPath(abs);
      const copied: VaultFileStat | null = this.stat(relPath);
      if (copied === null || copied.isDir || copied.size !== source.byteLength ||
        !sameBytes(sourceBytes, this.readBytes(relPath))) {
        throw new Error('附件副本字节校验失败');
      }
    } catch (error) {
      try {
        if (this.exists(relPath)) {
          this.remove(relPath);
        }
      } catch (cleanupError) {
        // Preserve the transfer failure; callers report cleanup separately if needed.
      }
      throw error instanceof Error ? error : new Error('附件导入失败');
    }
  }

  createEmptyNote(relPath: string): void {
    this.ensureDir(parentDirOf(relPath));
    if (this.exists(relPath)) {
      throw new Error('目标已存在');
    }
    const abs: string = this.abs(relPath);
    const handle: SandboxFileHandle = this.fsImpl.openSync(abs, VAULT_OPEN_WRITE_ONLY | VAULT_OPEN_CREATE);
    try {
      this.fsImpl.writeSync(handle.fd, '');
    } finally {
      this.fsImpl.closeSync(handle.fd);
    }
  }

  ensureDir(relDir: string): void {
    if (relDir.length === 0) {
      return;
    }
    const abs: string = this.abs(relDir);
    this.assertNoSymlinkPath(relDir, true);
    const meta: VaultFileStat | null = this.stat(relDir);
    if (meta !== null && meta.isSymbolicLink) {
      throw new Error('不进入符号链接目录');
    }
    if (!this.fsImpl.accessSync(abs)) {
      this.fsImpl.mkdirSync(abs, true);
    }
  }

  writeAtomic(relPath: string, content: string): Promise<void> {
    this.assertNoSymlinkPath(parentDirOf(relPath), true);
    const existing: VaultFileStat | null = this.stat(relPath);
    if (existing !== null && existing.isSymbolicLink) {
      return Promise.reject(new Error('不覆盖符号链接'));
    }
    const atomicFile: SandboxAtomicFileLike = this.fsImpl.openAtomic(this.abs(relPath));
    return new Promise<void>((resolve: (v: void) => void, reject: (e: Error) => void): void => {
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (rollbackError) {
          // Preserve the original failure if rollback itself fails.
        }
        reject(error);
      };
      const finish = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
        } catch (error) {
          fail(error instanceof Error ? error : new Error('原子写提交失败'));
          return;
        }
        settled = true;
        resolve(undefined);
      };
      try {
        const stream: SandboxWriteStreamLike = atomicFile.startWrite();
        if (content.length === 0) {
          finish();
          return;
        }
        timerId = setTimeout((): void => {
          fail(new Error('write 回调 3s 未触发'));
        }, 3000);
        stream.end(content, 'utf-8', (writeError?: Error): void => {
          if (writeError !== undefined && writeError !== null) {
            fail(writeError);
          } else {
            finish();
          }
        });
      } catch (error) {
        fail(error instanceof Error ? error : new Error('原子写失败'));
      }
    });
  }

  remove(relPath: string): void {
    this.assertNoSymlinkPath(parentDirOf(relPath), true);
    this.fsImpl.unlinkSync(this.abs(relPath));
  }

  removeDir(relPath: string): void {
    this.assertNoSymlinkPath(relPath, true);
    const abs: string = this.abs(relPath);
    const names: string[] = this.rawChildNames(abs);
    for (let i = 0; i < names.length; i++) {
      const childAbs: string = this.abs(joinVaultPath(relPath, names[i]));
      if (this.isDirectory(relPath, names[i])) {
        this.removeDir(joinVaultPath(relPath, names[i]));
      } else {
        this.fsImpl.unlinkSync(childAbs);
      }
    }
    this.fsImpl.rmdirSync(abs);
  }

  rename(from: string, to: string): void {
    this.assertNoSymlinkPath(parentDirOf(from), true);
    this.assertNoSymlinkPath(parentDirOf(to), true);
    this.fsImpl.renameSync(this.abs(from), this.abs(to));
  }

  /* --- 内部 --- */

  /** 原始子项名（不做过滤）；列不到就当空目录，避免把 UI 拖崩。 */
  private rawChildNames(absDir: string, throwOnError: boolean = false): string[] {
    try {
      return this.fsImpl.listFileSync(absDir);
    } catch (error) {
      if (throwOnError) {
        const err = error as Error;
        throw new Error(err.message);
      }
      return [];
    }
  }

  private isDirectory(relDir: string, name: string): boolean {
    try {
      const meta: SandboxStatLike = this.fsImpl.lstatSync(this.abs(joinVaultPath(relDir, name)));
      return !meta.isSymbolicLink() && meta.isDirectory();
    } catch (error) {
      return false;
    }
  }

  private sizeOf(abs: string): number {
    try {
      const raw: SandboxStatLike = this.fsImpl.statSync(abs);
      return raw.size;
    } catch (error) {
      return 0;
    }
  }

  /** 全树收集（隐藏项与非笔记文件由 listDir 已滤掉）。可由 snapshotReport 派生 allDirs/allNotes。 */
  private collectTree(relDir: string, depth: number, out: VaultDirChild[], counted: CountHolder,
    holder: VaultTruncationHolder): void {
    if (counted.value >= VAULT_SCAN_MAX_NODES) {
      holder.truncated = true;
      return;
    }
    if (depth >= VAULT_SCAN_MAX_DEPTH) {
      holder.truncated = true;
      return;
    }
    const children: VaultDirChild[] = this.listDir(relDir);
    for (let i = 0; i < children.length; i++) {
      const child: VaultDirChild = children[i];
      if (counted.value >= VAULT_SCAN_MAX_NODES) {
        holder.truncated = true;
        return;
      }
      const rel: string = joinVaultPath(relDir, child.name);
      counted.value++;
      out.push({ name: rel, isDir: child.isDir });
      if (child.isDir) {
        this.collectTree(rel, depth + 1, out, counted, holder);
      }
    }
  }
}

export interface CountHolder {
  value: number;
}

/* ------------------------------------------------------------------------- */
/* 外部实现（授权目录 URI → dirFd → Native POSIX）                            */
/* ------------------------------------------------------------------------- */

/* Native 结果结构体必须与 cpp/types/vaultdir_napi/Index.d.ts 一一对应。
   这里重新声明而不是 import，是为了保住「model 层零系统依赖」——设备侧由调用方
   注入真实实现，Node 单测注入 fake。

   ⚠️ 为什么非要有一层 ExternalIoStatus：ArkTS **不支持结构化类型**
   （arkts-no-structural-typing），只认声明名。若把「字段一样但名字不同」的两个接口
   互传（例如 ExternalBinaryResult 当 ExternalIoResult 用），编译期直接报错，
   连 `as` 强转都不是长久之计。故把「只看 ok/code/message」的公共部分提成基接口，
   各结果接口 extends 它 —— 继承关系是 ArkTS 认可的兼容方式。 */
export interface ExternalIoStatus {
  ok: boolean;
  code: number;
  message: string;
}

export interface ExternalStringResult extends ExternalIoStatus {
  entries: string[];
}

export interface ExternalIoResult extends ExternalIoStatus {
}

export interface ExternalReadResult extends ExternalIoStatus {
  content: string;
}

export interface ExternalBinaryResult extends ExternalIoStatus {
  bytes: Uint8Array;
}

export interface ExternalStatResult extends ExternalIoStatus {
  size: number;
  mtime: number;
  isDir: boolean;
  isSymbolicLink: boolean;
}

export interface ExternalFdResult extends ExternalIoStatus {
  fd: number;
}

export interface ExternalNativeLike {
  listDirByFd(fd: number): ExternalStringResult;
  listDirRecursiveByFd(fd: number): ExternalStringResult;
  openDirByFd(fd: number, name: string): ExternalFdResult;
  readFileByFd(fd: number, name: string): ExternalReadResult;
  readBinaryByFd(fd: number, name: string): ExternalBinaryResult;
  writeFileByFd(fd: number, name: string, content: string): ExternalIoResult;
  writeBinaryByFd(fd: number, name: string, bytes: Uint8Array): ExternalIoResult;
  deleteByFd(fd: number, name: string): ExternalIoResult;
  renameByFd(fd: number, oldName: string, newName: string): ExternalIoResult;
  statByFd(fd: number, name: string): ExternalStatResult;
  mkdirByFd(fd: number, name: string): ExternalIoResult;
  removeDirByFd(fd: number, name: string): ExternalIoResult;
}

/**
 * 「外部库根目录怎么变成 fd」由调用方负责。
 *
 * 之所以要抽这一层：授权 URI 的打开前提很多（先 activatePermission，再
 * `fs.open(uri, READ_ONLY|DIR)`），而这些动作都属于设备侧实现。本文件只承诺
 * 「给我一个能用的目录 fd」。
 */
export interface ExternalFdSource {
  openRootFd(): number;
  closeFd(fd: number): void;
}

/**
 * 统一的访问错误。**带 errno**：页面要把「ENOENT（目录被挪走了）」和
 * 「EACCES（权限被撤了）」区分开提示用户，只给一个 Error 字符串做不到。
 */
export class VaultAccessError extends Error {
  readonly code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

/**
 * IO 结果 → 抛错。message 为空时补一句人话，避免页面上只显示一个 errno 数字。
 *
 * 形参只收 ExternalIoStatus（ok/code/message）：抛错这件事本来就**不关心载荷**，
 * 收窄到状态部分才能同时吃下文本读、二进制读、stat、开目录等所有结果。
 * message 是非可选字段，Native 侧保证永远返回字符串（napi 构造空串兜底），
 * 所以这里不需要额外的 typeof 守卫。
 */
function throwExternalFailure(result: ExternalIoStatus, action: string): void {
  const detail: string = result.message.length > 0 ? result.message : 'errno=' + result.code;
  throw new VaultAccessError(result.code, action + '失败：' + detail);
}

/** Native 约定：目录项字符串以 '/' 结尾。 */
function parseExternalEntry(raw: string): VaultDirChild {
  const isDir: boolean = raw.endsWith('/');
  return { name: isDir ? raw.slice(0, raw.length - 1) : raw, isDir: isDir };
}

/** 取父目录相对路径；没有父目录返回 ''（即库根）。 */
export function parentDirOf(relPath: string): string {
  const slash: number = relPath.lastIndexOf('/');
  if (slash <= 0) {
    return '';
  }
  return relPath.slice(0, slash);
}

/**
 * 外部授权库的访问实现。
 *
 * 与沙箱实现唯一的形状差异是**根的表达**：这里没有绝对路径，只有一个被授权的
 * 目录 fd。所有相对名字都喂给 Native 的 openat 系动作 —— 官方不保证自拼 URI
 * 可用（涉及百分号编解码），所以绝不拼 URI，也不伪造沙箱路径。
 *
 * fd 生命周期：每次公开方法自带「开根 → 用完关」，子目录 fd 由 withSubFd 成对管理。
 * 不做长驻 fd：跨应用重启后 fd 必然失效，长驻只会让「目录被挪走」这种错晚暴露。
 */
export class ExternalVaultAccess implements VaultAccess {
  readonly kind: VaultAccessKind = 'external';

  private nativeImpl: ExternalNativeLike;
  private fdSource: ExternalFdSource;

  constructor(nativeImpl: ExternalNativeLike, fdSource: ExternalFdSource) {
    this.nativeImpl = nativeImpl;
    this.fdSource = fdSource;
  }

  listDir(relDir: string): VaultDirChild[] {
    const all: VaultDirChild[] = this.listAll(relDir);
    const out: VaultDirChild[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].isDir || isVaultNoteName(all[i].name)) {
        out.push(all[i]);
      }
    }
    return out;
  }

  listAll(relDir: string, includeHidden: boolean = false): VaultDirChild[] {
    return this.withRoot<VaultDirChild[]>((fd: number): VaultDirChild[] =>
      this.listChildrenAt(fd, relDir, true, includeHidden));
  }

  allDirs(): string[] {
    const snapshot: VaultDirChild[] = this.snapshot();
    const out: string[] = [];
    for (let i = 0; i < snapshot.length; i++) {
      if (snapshot[i].isDir) {
        out.push(snapshot[i].name);
      }
    }
    out.sort(compareVaultNames);
    return out;
  }

  allNotes(): string[] {
    const snapshot: VaultDirChild[] = this.snapshot();
    const out: string[] = [];
    for (let i = 0; i < snapshot.length; i++) {
      const entry: VaultDirChild = snapshot[i];
      if (!entry.isDir && isVaultNoteName(entry.name)) {
        out.push(entry.name);
      }
    }
    return out;
  }

  exists(relPath: string): boolean {
    return this.stat(relPath) !== null;
  }

  stat(relPath: string): VaultFileStat | null {
    return this.withRoot<VaultFileStat | null>((fd: number): VaultFileStat | null => {
      const raw: ExternalStatResult = this.nativeImpl.statByFd(fd, relPath);
      if (!raw.ok) {
        if (raw.code === 2) {
          return null;
        }
        throwExternalFailure(raw, '检查文件');
      }
      return { size: raw.size, mtimeSec: raw.mtime, isDir: raw.isDir, isSymbolicLink: raw.isSymbolicLink };
    });
  }

  readText(relPath: string): string {
    return this.withRoot<string>((fd: number): string => {
      const raw: ExternalReadResult = this.nativeImpl.readFileByFd(fd, relPath);
      if (!raw.ok) {
        throwExternalFailure(raw, '读取笔记');
      }
      return raw.content;
    });
  }

  readBytes(relPath: string): Uint8Array {
    return this.withRoot<Uint8Array>((fd: number): Uint8Array => {
      const raw: ExternalBinaryResult = this.nativeImpl.readBinaryByFd(fd, relPath);
      if (!raw.ok) {
        throwExternalFailure(raw, '读取附件');
      }
      return raw.bytes;
    });
  }

  createEmptyNote(relPath: string): void {
    this.ensureDir(parentDirOf(relPath));
    if (this.exists(relPath)) {
      throw new Error('目标已存在');
    }
    this.writeAtomicSync(relPath, '');
  }

  ensureDir(relDir: string): void {
    if (relDir.length === 0) {
      return;
    }
    this.withRoot<void>((fd: number): void => {
      const raw: ExternalIoResult = this.nativeImpl.mkdirByFd(fd, relDir);
      if (!raw.ok) {
        throwExternalFailure(raw, '创建目录');
      }
    });
  }

  writeAtomic(relPath: string, content: string): Promise<void> {
    // Native 的 writeFileByFd 本身就是 tmp→fsync→renameat，同步返回已成事实；
    // 这里包一层 Promise 是为了让上层与沙箱实现（回调式 AtomicFile）写法一致。
    return new Promise<void>((resolve: (v: void) => void, reject: (e: Error) => void): void => {
      try {
        this.writeAtomicSync(relPath, content);
        resolve(undefined);
      } catch (error) {
        reject(error instanceof Error ? error : new VaultAccessError(-1, '原子写失败'));
      }
    });
  }

  async writeNewBinary(relPath: string, source: VaultBinaryImportSource): Promise<void> {
    if (this.exists(relPath)) {
      throw new Error('附件目标已存在');
    }
    this.ensureDir(parentDirOf(relPath));
    const bytes: Uint8Array = source.readBytes();
    if (bytes.length !== source.byteLength || bytes.length === 0) {
      throw new Error('所选图片读取不完整');
    }
    let createdByThisCall: boolean = false;
    try {
      this.withRoot<void>((fd: number): void => {
        const raw: ExternalIoResult = this.nativeImpl.writeBinaryByFd(fd, relPath, bytes);
        if (!raw.ok) {
          throwExternalFailure(raw, '写入附件');
        }
      });
      createdByThisCall = true;
      const copied: VaultFileStat | null = this.stat(relPath);
      if (copied === null || copied.isDir || copied.size !== source.byteLength ||
        !sameBytes(bytes, this.readBytes(relPath))) {
        throw new Error('附件副本字节校验失败');
      }
    } catch (error) {
      try {
        if (createdByThisCall && this.exists(relPath)) {
          this.remove(relPath);
        }
      } catch (cleanupError) {
        // Retain the transfer error; the unique target may remain as an unreferenced partial.
      }
      throw error instanceof Error ? error : new Error('附件导入失败');
    }
  }

  remove(relPath: string): void {
    this.withRoot<void>((fd: number): void => {
      const meta: ExternalStatResult = this.nativeImpl.statByFd(fd, relPath);
      const raw: ExternalIoResult = meta.ok && meta.isDir
        ? this.nativeImpl.removeDirByFd(fd, relPath)
        : this.nativeImpl.deleteByFd(fd, relPath);
      if (!raw.ok) {
        throwExternalFailure(raw, '删除');
      }
    });
  }

  removeDir(relPath: string): void {
    this.withRoot<void>((fd: number): void => {
      const raw: ExternalIoResult = this.nativeImpl.removeDirByFd(fd, relPath);
      if (!raw.ok) {
        throwExternalFailure(raw, '删除目录');
      }
    });
  }

  rename(from: string, to: string): void {
    this.ensureDir(parentDirOf(to));
    this.withRoot<void>((fd: number): void => {
      const raw: ExternalIoResult = this.nativeImpl.renameByFd(fd, from, to);
      if (!raw.ok) {
        throwExternalFailure(raw, '重命名');
      }
    });
  }

  /**
   * 授权还在不在的一次性探测：只 stat 根自己。
   * 15.1 的 UI 要在打开外部库前先问这一句 —— 目录被移动/授权被撤销都从这里先失效。
   */
  rootAlive(): boolean {
    try {
      return this.stat('') !== null;
    } catch (error) {
      return false;
    }
  }

  /* --- 内部 --- */

  private writeAtomicSync(relPath: string, content: string): void {
    this.withRoot<void>((fd: number): void => {
      const raw: ExternalIoResult = this.nativeImpl.writeFileByFd(fd, relPath, content);
      if (!raw.ok) {
        throwExternalFailure(raw, '保存笔记');
      }
    });
  }

  private withRoot<T>(action: (fd: number) => T): T {
    let fd: number = -1;
    try {
      fd = this.fdSource.openRootFd();
    } catch (error) {
      const code: number = ExternalVaultAccess.errorCodeOf(error);
      throw new VaultAccessError(code, ExternalVaultAccess.describe(code));
    }
    try {
      return action(fd);
    } finally {
      try {
        this.fdSource.closeFd(fd);
      } catch (error) {
        // 关失败不影响结果：fd 泄漏在下次操作会立刻以 EBADF 现形
      }
    }
  }

  private listChildrenAt(fd: number, relDir: string, includeAll: boolean = false,
    includeHidden: boolean = false): VaultDirChild[] {
    if (relDir.length === 0) {
      return this.collectChildren(fd, includeAll, includeHidden);
    }
    return this.withSub<VaultDirChild[]>(fd, relDir, (dirFd: number): VaultDirChild[] =>
      this.collectChildren(dirFd, includeAll, includeHidden));
  }

  private collectChildren(dirFd: number, includeAll: boolean, includeHidden: boolean = false): VaultDirChild[] {
    const raw: ExternalStringResult = this.nativeImpl.listDirByFd(dirFd);
    if (!raw.ok) {
      throwExternalFailure(raw, '列出目录');
    }
    const dirs: string[] = [];
    const files: string[] = [];
    for (let i = 0; i < raw.entries.length; i++) {
      const child: VaultDirChild = parseExternalEntry(raw.entries[i]);
      if (!includeHidden && isVaultHiddenName(child.name)) {
        continue;
      }
      if (child.isDir) {
        dirs.push(child.name);
      } else if (includeAll || isVaultNoteName(child.name)) {
        files.push(child.name);
      }
    }
    dirs.sort(compareVaultNames);
    files.sort(compareVaultNames);

    const out: VaultDirChild[] = [];
    for (let i = 0; i < dirs.length; i++) {
      out.push({ name: dirs[i], isDir: true });
    }
    for (let i = 0; i < files.length; i++) {
      out.push({ name: files[i], isDir: false });
    }
    return out;
  }

  /**
   * 一次递归扫描得到全树快照，allDirs / allNotes 都从这里派生。
   * 只扫一次是刻意的：每下拉刷新都走一遍 Native 递归对大库是实打实的开销。
   */
  snapshot(): VaultDirChild[] {
    // Native 的递归顺序与沙箱 walk 不同；统一过一遍规范化排序，两边才是同一棵树。
    return sortVaultTree(this.collectSnapshot());
  }

  /**
   * 带完整性标记的全树快照（40.8）：授权失效 / 目录被移走等列举失败置 failed，
   * 节点上限截断置 truncated；两种情况都禁止调用方把未出现路径当作已删除。
   */
  snapshotReport(): VaultSnapshotReport {
    let collected: VaultDirChild[] = [];
    try {
      collected = this.collectSnapshot();
    } catch (error) {
      return { entries: [], truncated: false, failed: true };
    }
    return {
      entries: sortVaultTree(collected),
      truncated: collected.length >= VAULT_SCAN_MAX_NODES,
      failed: false
    };
  }

  private collectSnapshot(): VaultDirChild[] {
    return this.withRoot<VaultDirChild[]>((fd: number): VaultDirChild[] => {
      const raw: ExternalStringResult = this.nativeImpl.listDirRecursiveByFd(fd);
      if (!raw.ok) {
        throwExternalFailure(raw, '扫描库');
      }
      const out: VaultDirChild[] = [];
      for (let i = 0; i < raw.entries.length && out.length < VAULT_SCAN_MAX_NODES; i++) {
        const child: VaultDirChild = parseExternalEntry(raw.entries[i]);
        if (this.visibleInSnapshot(child)) {
          out.push(child);
        }
      }
      return out;
    });
  }

  /** 快照保留：所有目录 + 所有笔记文件；隐藏层整条排除（子串 '…/.' 判别）。 */
  private visibleInSnapshot(child: VaultDirChild): boolean {
    const segments: string[] = child.name.split('/');
    for (let i = 0; i < segments.length; i++) {
      if (isVaultHiddenName(segments[i])) {
        return false;
      }
    }
    return child.isDir || isVaultNoteName(child.name);
  }

  private withSub<T>(fd: number, relDir: string, action: (dirFd: number) => T): T {
    const opened: ExternalFdResult = this.nativeImpl.openDirByFd(fd, relDir);
    if (!opened.ok || opened.fd < 0) {
      throwExternalFailure(opened, '打开子目录');
    }
    let dirFd: number = opened.fd;
    try {
      return action(dirFd);
    } finally {
      try {
        this.fdSource.closeFd(dirFd);
      } catch (error) {
        // 同上：忽略
      }
    }
  }

  static errorCodeOf(error: Object): number {
    const carry: ErrorCodeCarrier = error as ErrorCodeCarrier;
    if (carry !== undefined && carry !== null && typeof carry.code === 'number') {
      return carry.code;
    }
    return -1;
  }

  /** errno → 人话（15.1 的用户提示要走这一段）。 */
  static describe(code: number): string {
    if (code === 2) {
      return '目录不存在或已被移动（请重新关联该库）';
    }
    if (code === 13 || code === 1) {
      return '没有读写该目录的权限（授权可能已被撤销）';
    }
    if (code === 9) {
      return '目录句柄已失效，请重新打开该库';
    }
    if (code === 28) {
      return '存储空间不足';
    }
    if (code === 30) {
      return '该目录所在的存储处于只读状态';
    }
    return '无法访问所选目录（errno=' + code + '）';
  }
}

interface ErrorCodeCarrier {
  code?: number;
}
