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
    const entries: VaultDirChild[] = access.snapshot();
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
      hilog.error(DOMAIN, TAG, 'expand 状态库打开失败: %{public}s', JSON.stringify(err));
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
      hilog.error(DOMAIN, TAG, 'expand 状态写入失败: %{public}s', JSON.stringify(err));
    }
  }
}