/**
 * FileTree.ets —— 真实目录的文件树（v0.2 M1，需求 1.1–1.5；v1.5 改走 VaultAccess）
 *
 * 设计要点：
 * 1. **扁平化输出**：返回「当前可见」的节点数组（父目录折叠 → 子树整体不出现），
 *    渲染层只按数组画，不做递归组件（ArkUI 里递归组件容易踩状态复用的坑）。
 * 2. **只显示目录与 .md**：隐藏文件/隐藏目录（以 `.` 开头）与其它扩展名一律不显示 ——
 *    这是笔记库，不是文件管理器，混进 .DS_Store / 图片会让树变得不可读。
 *    过滤不在这里做，由 VaultAccess 的两 Implementer 各自保证（并有用例锁住）。
 * 3. **有上限**：深度 ≤ 8、节点 ≤ 1000，防止超大目录把 UI 线程卡死。
 * 4. **展开状态持久化**：按库分别记忆（需求 1.3），存 preferences，切库回来还是原样。
 * 5. **这一层不再碰 IO**（v1.5 的关键改动）：之前 `scan(rootAbs, …)` 拿着绝对路径自己
 *    `listFileSync` + `statSync` 递归，而外部授权库只有目录 fd、给不出绝对路径
 *    （`listFileSync` 的 path 契约是沙箱路径，传 URI 报 13900002，见 api_notes T3）。
 *    现在输入是 `VaultAccess.snapshot()` —— 一次遍历产出的规范化全树；本类只负责
 *    「按展开状态剪枝 + 排版」，沙箱库与外部库共用这一份代码，不可能再出现
 *    「沙箱能列出来的外部列不出来」这类差异。副作用是它变成了纯逻辑，可以在 Node 里跑。
 */
import { VaultAccess, VaultDirChild } from './VaultAccess';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTree';

/** 文件树节点（扁平化后的一行） */
export interface TreeNode {
  /** 显示名（文件名或目录名） */
  name: string;
  /** 相对库根的路径，例如 `docs/架构.md`（目录则是 `docs`） */
  relPath: string;
  isDir: boolean;
  /** 层级：库根下第一层 = 0（需求 1.5：每级缩进 24vp，子文件比父目录深一级） */
  depth: number;
}

/** 置顶区一行（v1.62 · 62.1）：由 PinStore 数组 + 全量笔记路径解析，纯数据无 UI 依赖。 */
export interface PinnedNote {
  relPath: string;
  /** 剥掉 .md / .markdown 的显示标题 */
  title: string;
  /** 最近一级文件夹名；根目录显示「根目录」 */
  folder: string;
  /** 完整父路径（悬停提示与读屏用） */
  folderPath: string;
  /** 首字色块里的字符 */
  initial: string;
  /** callout 色板索引 0..4，按文件夹哈希 */
  tone: number;
}

/** 文件树排序模式（v1.49）：名称 = 现状默认；mtime = 按修改时间降序（新的在前）。 */
export type FileListSortMode = 'name' | 'mtime';

export class FileTree {
  static readonly MAX_DEPTH: number = 8;
  static readonly MAX_NODES: number = 1000;

  /**
   * 把可见行压成一行日志：`d0 DIR docs / d1 FILE 笔记.md`。
   * 存在的理由：模拟器/真机上验证文件树时**看不了截图**（图片在这类会话里不可用），
   * 只能靠 hilog 文本判断「扫到了什么、层级对不对、顺序对不对」。
   * 超长会自动截断，避免把日志打爆。
   */
  static describe(nodes: TreeNode[]): string {
    let s: string = '';
    const limit: number = nodes.length < 40 ? nodes.length : 40;
    for (let i = 0; i < limit; i++) {
      const n: TreeNode = nodes[i];
      s += (i === 0 ? '' : ' / ') + 'd' + n.depth + ' ' + (n.isDir ? 'DIR' : 'FILE') + ' ' + n.name;
    }
    if (s.length > 700) {
      s = s.substring(0, 700) + '…';
    }
    return s;
  }

  /**
   * 扫描库，返回当前可见的扁平节点列表。
   *
   * @param access 库访问（沙箱或外部授权目录，本层不关心是哪种）
   * @param expanded 已展开目录的 relPath 列表
   *
   * 快照已按「目录子树在前、文件在后、同层字典序」排好（见 VaultAccess.sortVaultTree），
   * 所以这里只要顺序过一遍、滤掉祖先没展开的分支，产出的行序就与原递归版完全一致。
   */
  static scan(access: VaultAccess, expanded: string[]): TreeNode[] {
    return FileTree.scanEntries(access.snapshot(), expanded);
  }

  /**
   * 从一次快照排版可见行（v1.62）：置顶区与目录树共用同一份 entries，
   * 避免同一帧里两处数据不一致，也省掉一次全库遍历。
   */
  static scanEntries(entries: VaultDirChild[], expanded: string[]): TreeNode[] {
    const out: TreeNode[] = [];
    for (let i = 0; i < entries.length; i++) {
      if (out.length >= FileTree.MAX_NODES) {
        break;
      }
      const entry: VaultDirChild = entries[i];
      const depth: number = FileTree.depthOf(entry.name);
      if (depth >= FileTree.MAX_DEPTH) {
        continue;
      }
      if (!FileTree.ancestorsExpanded(entry.name, expanded)) {
        continue;
      }
      out.push({
        name: FileTree.lastSegment(entry.name),
        relPath: entry.name,
        isDir: entry.isDir,
        depth: depth
      });
    }
    return out;
  }

  /**
   * 快照内的全量笔记路径（v1.62 置顶区用）：不受展开状态影响。
   * VaultAccess.listDir 已过滤隐藏项与非笔记文件，故这里只需排除目录；
   * `.trash` 属隐藏项，回收站里的笔记不在其中（62.4 删除隐藏 / 恢复回显）。
   */
  static notesOfEntries(entries: VaultDirChild[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      if (!entries[i].isDir) {
        out.push(entries[i].name);
      }
    }
    return out;
  }

  /**
   * 置顶区行（v1.62 · 62.1）：由 `pinned_<vaultId>` 数组与全量笔记路径解析。
   * - 数组顺序即置顶先后，逆序渲染 = 最近置顶在前；不存时间戳、不改数据结构；
   * - 路径不在当前库笔记里（陈旧条目 / 改名 / 移动 / 进回收站 / 永久删除）直接跳过，
   *   不自动清理偏好（50.4 口径），恢复后自然回到置顶区；
   * - 目录路径与重复路径同样由 allNotes 交集过滤；
   * - 标题、所在文件夹、首字与色板索引都在这里算好，渲染层只画，纯逻辑可单测。
   */
  static pinnedNotes(allNotes: string[], pinned: string[]): PinnedNote[] {
    const out: PinnedNote[] = [];
    const seen: Map<string, boolean> = new Map<string, boolean>();
    for (let i = pinned.length - 1; i >= 0; i--) {
      const relPath: string = pinned[i];
      if (relPath.length === 0 || seen.has(relPath) || allNotes.indexOf(relPath) < 0) {
        continue;
      }
      seen.set(relPath, true);
      const title: string = FileTree.noteTitleOf(FileTree.lastSegment(relPath));
      const folderPath: string = FileTree.parentOf(relPath);
      out.push({
        relPath: relPath,
        title: title,
        folder: folderPath.length === 0 ? '根目录' : FileTree.lastSegment(folderPath),
        folderPath: folderPath,
        initial: FileTree.initialOf(title),
        tone: FileTree.toneOf(folderPath)
      });
    }
    return out;
  }

  /** 与 NoteDisplayName 同口径：剥一层 .markdown / .md，大小写不敏感。 */
  private static noteTitleOf(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    if (lower.endsWith('.markdown')) {
      return fileName.substring(0, fileName.length - '.markdown'.length);
    }
    if (lower.endsWith('.md')) {
      return fileName.substring(0, fileName.length - '.md'.length);
    }
    return fileName;
  }

  /** 首字色块里的字符：标题首字（拉丁字母大写），空标题兜底中点。 */
  private static initialOf(title: string): string {
    const trimmed: string = title.trim();
    return trimmed.length === 0 ? '·' : trimmed.substring(0, 1).toUpperCase();
  }

  /** 按所在文件夹完整路径哈希取 callout 色板索引（同文件夹同色，v1.54 §54.1 第三稿）。 */
  private static toneOf(folderPath: string): number {
    let hash: number = 0;
    for (let i = 0; i < folderPath.length; i++) {
      hash = (hash * 31 + folderPath.charCodeAt(i)) % 1000003;
    }
    return hash % 5;
  }

  /**
   * 列出库内所有笔记文件，不读取目录展开状态（v0.4 快速切换 / 全文搜索用）。
   * 过滤与上限规则统一放在 VaultAccess 一侧，保证与文件树同源。
   */
  static allNotesOf(access: VaultAccess): string[] {
    return access.allNotes();
  }

  /**
   * 列出库里**所有**目录的 relPath（不受展开状态影响，只要目录不要文件）——
   * 新建笔记对话框的「目录选择器」用（2026-10-18 用户拍板：对话框里选目录，
   * 默认上次点过的目录，根目录作为一个选项）。
   * 与 scan 的分工：scan 给可见行；这个给全量目录候选。
   */
  static allDirsOf(access: VaultAccess): string[] {
    return access.allDirs();
  }

  /** 一个条目的层级：根下第一层 = 0。 */
  private static depthOf(relPath: string): number {
    let count: number = 0;
    for (let i = 0; i < relPath.length; i++) {
      if (relPath.charAt(i) === '/') {
        count++;
      }
    }
    return count;
  }

  private static lastSegment(relPath: string): string {
    const slash: number = relPath.lastIndexOf('/');
    return slash < 0 ? relPath : relPath.substring(slash + 1);
  }

  /** 所有祖先目录都展开，这一条才可见。 */
  private static ancestorsExpanded(relPath: string, expanded: string[]): boolean {
    const slash: number = relPath.lastIndexOf('/');
    if (slash < 0) {
      return true;
    }
    const parentPath: string = relPath.substring(0, slash);
    if (expanded.indexOf(parentPath) < 0) {
      return false;
    }
    return FileTree.ancestorsExpanded(parentPath, expanded);
  }

  /** 库内相对路径的父目录（`a/b/c.md` → `a/b`；根下文件 → 空串） */
  static parentOf(relPath: string): string {
    const i: number = relPath.lastIndexOf('/');
    return i > 0 ? relPath.substring(0, i) : '';
  }

  /**
   * 按排序模式重排可见行（v1.49 · 49.1；v1.62 废弃 v1.50 置顶权重）。
   *
   * 约定：输入是 scan 产出的可见行（已按展开状态剪枝），输出保持
   * 「父目录在子项之前」的扁平 DFS 结构；每层内部目录在前、文件在后，
   * 同组按模式排序——name = 字典序升序，mtime = mtimeOf(relPath) 降序
   * （新的在前），相同或拿不到按名称升序稳定。stat 失败（返回负值）按最旧
   * 处理，排序不崩。纯逻辑：mtimeOf 由调用方注入（沙箱 / 外部都从
   * VaultAccess.stat 拿），两类库共用，不按 rootKind 分叉。
   *
   * v1.62：置顶不再参与树内排序（置顶的唯一可见效果在顶部独立置顶区），
   * 因此去掉 pinned 参数，name 模式恢复 v1.49 的快路径原样返回。
   */
  static resort(nodes: TreeNode[], mode: FileListSortMode,
    mtimeOf: (relPath: string) => number): TreeNode[] {
    if (mode !== 'mtime') {
      return nodes;
    }
    const byParent: Map<string, TreeNode[]> = new Map<string, TreeNode[]>();
    for (let i = 0; i < nodes.length; i++) {
      const parent: string = FileTree.parentOf(nodes[i].relPath);
      const group: TreeNode[] | undefined = byParent.get(parent);
      if (group === undefined) {
        byParent.set(parent, [nodes[i]]);
      } else {
        group.push(nodes[i]);
      }
    }
    const parents: string[] = [];
    byParent.forEach((_group: TreeNode[], key: string): void => {
      parents.push(key);
    });
    for (let p = 0; p < parents.length; p++) {
      const group: TreeNode[] | undefined = byParent.get(parents[p]);
      if (group !== undefined) {
        group.sort((a: TreeNode, b: TreeNode): number =>
          FileTree.compareSiblings(a, b, mode, mtimeOf));
      }
    }
    const out: TreeNode[] = [];
    FileTree.emitChildren('', byParent, out);
    return out;
  }

  /**
   * 同层比较（v1.49 纯规则，v1.62 恢复）：目录在前、文件在后 →
   * 同组按模式（name 字典序 / mtime 降序），平局按名称升序稳定。
   */
  private static compareSiblings(a: TreeNode, b: TreeNode, mode: FileListSortMode,
    mtimeOf: (relPath: string) => number): number {
    if (a.isDir !== b.isDir) {
      return a.isDir ? -1 : 1;
    }
    if (mode === 'mtime') {
      const at: number = mtimeOf(a.relPath);
      const bt: number = mtimeOf(b.relPath);
      if (at !== bt) {
        return at > bt ? -1 : 1;
      }
    }
    if (a.name < b.name) {
      return -1;
    }
    if (a.name > b.name) {
      return 1;
    }
    return 0;
  }

  /** DFS 输出某父目录下的已排序子行；目录行后紧跟其子树（父先于子的不变式）。 */
  private static emitChildren(parent: string, byParent: Map<string, TreeNode[]>, out: TreeNode[]): void {
    const group: TreeNode[] | undefined = byParent.get(parent);
    if (group === undefined) {
      return;
    }
    for (let i = 0; i < group.length; i++) {
      const node: TreeNode = group[i];
      out.push(node);
      if (node.isDir) {
        FileTree.emitChildren(node.relPath, byParent, out);
      }
    }
  }
}

/**
 * ExpandStore —— 展开状态持久化（需求 1.3：按库分别记忆）
 *
 * 这里碰 preferences / UIAbilityContext，所以**不属于**上面那层纯逻辑：
 * FileTree 类本身已经可以不依赖任何 @kit 包，能在 Node 单测里跑（见 test_file_tree_snapshot）。
 */
export class ExpandStore {
  private static readonly PREF_NAME: string = 'file_tree_state';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: ExpandStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'expand 状态库打开失败 code=%{public}d', err.code);
      this.store = null;
    }
  }

  load(vaultId: string): string[] {
    if (this.store === null || vaultId.length === 0) {
      return [];
    }
    const raw: string = this.store.getSync('expand_' + vaultId, '[]') as string;
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) {
      return [];
    }
  }

  save(vaultId: string, expanded: string[]): void {
    if (this.store === null || vaultId.length === 0) {
      return;
    }
    try {
      this.store.putSync('expand_' + vaultId, JSON.stringify(expanded));
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'expand 状态写入失败 code=%{public}d', err.code);
    }
  }
}

/**
 * FileListSortStore —— 文件树排序偏好持久化（v1.49 · 49.3）。
 *
 * 与 ExpandStore 不同：排序是 App 级单一偏好（不分库），存同一个
 * preferences 文件的 `sort_mode` 键；默认 name，坏值回退 name。
 */
export class FileListSortStore {
  private static readonly PREF_NAME: string = 'file_tree_state';
  private static readonly KEY: string = 'sort_mode';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: FileListSortStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '排序偏好库打开失败 code=%{public}d', err.code);
      this.store = null;
    }
  }

  load(): FileListSortMode {
    if (this.store === null) {
      return 'name';
    }
    const raw: string = this.store.getSync(FileListSortStore.KEY, 'name') as string;
    return raw === 'mtime' ? 'mtime' : 'name';
  }

  save(mode: FileListSortMode): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(FileListSortStore.KEY, mode);
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '排序偏好写入失败 code=%{public}d', err.code);
    }
  }
}

/**
 * PinStore —— 置顶状态持久化（v1.50 · 50.3）。
 *
 * 与 ExpandStore 同库不同键：置顶是库内容组织，**按库**分别记忆，
 * 存 `file_tree_state` preferences 的 `pinned_<vaultId>` 键（JSON 字符串
 * 数组）；坏值回退空数组。改名 / 移动后旧路径留存为陈旧条目，不再匹配
 * 任何行、无副作用（50.4：不做自动清理）。
 */
export class PinStore {
  private static readonly PREF_NAME: string = 'file_tree_state';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: PinStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '置顶状态库打开失败 code=%{public}d', err.code);
      this.store = null;
    }
  }

  load(vaultId: string): string[] {
    if (this.store === null || vaultId.length === 0) {
      return [];
    }
    const raw: string = this.store.getSync('pinned_' + vaultId, '[]') as string;
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) {
      return [];
    }
  }

  save(vaultId: string, pinned: string[]): void {
    if (this.store === null || vaultId.length === 0) {
      return;
    }
    try {
      this.store.putSync('pinned_' + vaultId, JSON.stringify(pinned));
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '置顶状态写入失败 code=%{public}d', err.code);
    }
  }

  /**
   * 置顶区展开 / 收起（v1.62 · 62.4）：`pinSectionOpen_<vaultId>`，按库记忆，
   * 默认展开——置顶是主动行为，有置顶就该看到。坏值 / 读失败回退展开。
   */
  loadSectionOpen(vaultId: string): boolean {
    if (this.store === null || vaultId.length === 0) {
      return true;
    }
    try {
      const raw: boolean = this.store.getSync('pinSectionOpen_' + vaultId, true) as boolean;
      return typeof raw === 'boolean' ? raw : true;
    } catch (error) {
      return true;
    }
  }

  saveSectionOpen(vaultId: string, open: boolean): void {
    if (this.store === null || vaultId.length === 0) {
      return;
    }
    try {
      this.store.putSync('pinSectionOpen_' + vaultId, open);
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '置顶区状态写入失败 code=%{public}d', err.code);
    }
  }
}
