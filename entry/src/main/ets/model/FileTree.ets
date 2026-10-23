/**
 * FileTree.ets —— 真实目录的文件树（v0.2 M1，需求 1.1–1.5）
 *
 * 设计要点：
 * 1. **扁平化输出**：递归扫描后返回「当前可见」的节点数组（父目录折叠 → 子树整体不出现），
 *    渲染层只按数组画，不做递归组件（ArkUI 里递归组件容易踩状态复用的坑）。
 * 2. **只显示目录与 .md**：隐藏文件/隐藏目录（以 `.` 开头）与其它扩展名一律不显示 ——
 *    这是笔记库，不是文件管理器，混进 .DS_Store / 图片会让树变得不可读。
 * 3. **有上限**：深度 ≤ 8、节点 ≤ 1000，防止超大目录把 UI 线程卡死（真机上的实际目录很少这么深）。
 * 4. **展开状态持久化**：按库分别记忆（需求 1.3），存 preferences，切库回来还是原样。
 * 5. 路径解析不在这里做：库根绝对路径由 `VaultRegistry.vaultDirAbs()` 给出（硬约束 #14）。
 */
import { fileIo } from '@kit.CoreFileKit';
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

interface ScanCount {
  value: number;
}

/** 扫描 + 排序 */
export class FileTree {
  static readonly MAX_DEPTH: number = 8;
  static readonly MAX_NODES: number = 1000;

  /** 目录判定：statSync 失败（权限/竞态导致文件消失）按「不是目录」处理，不当错误抛出 */
  private static isDir(parentAbs: string, name: string): boolean {
    try {
      const info: fileIo.Stat = fileIo.statSync(parentAbs + '/' + name);
      return info.isDirectory();
    } catch (error) {
      return false;
    }
  }

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
   * 扫描库目录，返回当前可见的扁平节点列表。
   * @param rootAbs 库根绝对路径
   * @param expanded 已展开目录的 relPath 列表
   */
  static scan(rootAbs: string, expanded: string[]): TreeNode[] {
    const out: TreeNode[] = [];
    FileTree.walk(rootAbs, '', 0, expanded, out);
    return out;
  }

  /**
   * 列出库内所有有效 Markdown 文件，不读取目录展开状态。
   * 隐藏项、扩展名、深度和节点上限与文件树保持一致，供 v0.4 快速切换使用。
   */
  static allMarkdownFiles(rootAbs: string): string[] {
    const out: string[] = [];
    const count: ScanCount = { value: 0 };
    FileTree.walkMarkdown(rootAbs, '', 0, out, count);
    return out;
  }

  /**
   * 列出库里**所有**目录的 relPath（不受展开状态影响，只要目录不要文件）——
   * 新建笔记对话框的「目录选择器」用（2026-10-18 用户拍板：对话框里选目录，
   * 默认上次点过的目录，根目录作为一个选项）。
   * 与 scan 的分工：scan 给可见行；这个给全量目录候选。
   */
  static allDirs(rootAbs: string): string[] {
    const out: string[] = [];
    FileTree.walkDirs(rootAbs, '', 0, out);
    return out;
  }

  private static walkDirs(absDir: string, relDir: string, depth: number, out: string[]): void {
    if (depth >= FileTree.MAX_DEPTH || out.length >= FileTree.MAX_NODES) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(absDir);
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '列目录失败 %{public}s: %{public}s', relDir, err.message);
      return;
    }
    const dirNames: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const nm: string = names[i];
      if (nm.length > 0 && !nm.startsWith('.') && FileTree.isDir(absDir, nm)) {
        dirNames.push(nm);
      }
    }
    dirNames.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    for (let i = 0; i < dirNames.length; i++) {
      if (out.length >= FileTree.MAX_NODES) {
        return;
      }
      const rel: string = relDir.length === 0 ? dirNames[i] : relDir + '/' + dirNames[i];
      out.push(rel);
      FileTree.walkDirs(absDir + '/' + dirNames[i], rel, depth + 1, out);
    }
  }

  private static walkMarkdown(absDir: string, relDir: string, depth: number,
    out: string[], count: ScanCount): void {
    if (depth >= FileTree.MAX_DEPTH || count.value >= FileTree.MAX_NODES) {
      return;
    }
    const dirNames: string[] = [];
    const fileNames: string[] = [];
    try {
      const names: string[] = fileIo.listFileSync(absDir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name.length === 0 || name.startsWith('.')) {
          continue;
        }
        if (FileTree.isDir(absDir, name)) {
          dirNames.push(name);
        } else if (name.endsWith('.md') || name.endsWith('.markdown')) {
          fileNames.push(name);
        }
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '读取目录失败 %{public}s: %{public}s', relDir, err.message);
      return;
    }
    dirNames.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    fileNames.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    for (let i = 0; i < dirNames.length; i++) {
      if (count.value >= FileTree.MAX_NODES) {
        return;
      }
      const dirName: string = dirNames[i];
      count.value++;
      const dirRel: string = relDir.length === 0 ? dirName : relDir + '/' + dirName;
      FileTree.walkMarkdown(absDir + '/' + dirName, dirRel, depth + 1, out, count);
    }
    for (let i = 0; i < fileNames.length; i++) {
      if (count.value >= FileTree.MAX_NODES) {
        return;
      }
      count.value++;
      out.push(relDir.length === 0 ? fileNames[i] : relDir + '/' + fileNames[i]);
    }
  }

  /** 库内相对路径的父目录（`a/b/c.md` → `a/b`；根下文件 → 空串） */
  static parentOf(relPath: string): string {
    const i: number = relPath.lastIndexOf('/');
    return i > 0 ? relPath.substring(0, i) : '';
  }

  private static walk(absDir: string, relDir: string, depth: number,
    expanded: string[], out: TreeNode[]): void {
    if (depth >= FileTree.MAX_DEPTH || out.length >= FileTree.MAX_NODES) {
      return;
    }
    const dirNames: string[] = [];
    const fileNames: string[] = [];
    try {
      // ⚠️ 不用 opendirSync/Dir/Dirent：那是 @ohos.fileio（旧版）的成员，早已废弃，
      // 最新版 @ohos.file.fs / CoreFileKit 的 fileIo **不导出**它们（编译已实测：
      // Namespace 'fileIo' has no exported member 'Dir'）。官方明示替代者是 listFileSync。
      // listFileSync 返回的是**名字数组**，是否目录要再 statSync —— 一次 stat 换稳定，值。
      const names: string[] = fileIo.listFileSync(absDir);
      for (let i = 0; i < names.length; i++) {
        const nm: string = names[i];
        // 隐藏项一律不显示（.trash / .git / 系统垃圾文件）
        if (nm.length > 0 && !nm.startsWith('.')) {
          if (FileTree.isDir(absDir, nm)) {
            dirNames.push(nm);
          } else if (nm.endsWith('.md') || nm.endsWith('.markdown')) {
            fileNames.push(nm);
          }
        }
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '读取目录失败 %{public}s: %{public}s', relDir, err.message);
      return;
    }

    dirNames.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    fileNames.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));

    // 目录在前、文件在后（原型顺序）
    for (let i = 0; i < dirNames.length; i++) {
      if (out.length >= FileTree.MAX_NODES) {
        return;
      }
      const rel: string = relDir.length === 0 ? dirNames[i] : relDir + '/' + dirNames[i];
      const node: TreeNode = { name: dirNames[i], relPath: rel, isDir: true, depth: depth };
      out.push(node);
      if (expanded.indexOf(rel) >= 0) {
        FileTree.walk(absDir + '/' + dirNames[i], rel, depth + 1, expanded, out);
      }
    }
    for (let i = 0; i < fileNames.length; i++) {
      if (out.length >= FileTree.MAX_NODES) {
        return;
      }
      const rel: string = relDir.length === 0 ? fileNames[i] : relDir + '/' + fileNames[i];
      const node: TreeNode = { name: fileNames[i], relPath: rel, isDir: false, depth: depth };
      out.push(node);
    }
  }
}

/**
 * 展开状态的持久化（需求 1.3：按库分别记忆）。
 * 存储键 = `expand_<vaultId>`，值 = JSON 数组字符串（不能直接用逗号拼：路径里可能含逗号）。
 *
 * 同文件还存 **lastdir_<vaultId>**（2026-10-18 用户拍板）：上次在树里点过的目录
 * —— 点目录行记该目录、点文件行记它的父目录。新建笔记对话框默认建在那里，
 * 想建根目录就在对话框的目录选择器里显式选「根目录」。
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
