/**
 * FileTreeView.ets —— 真实文件树（v0.2 M1 需求 1.1 / 1.2 / 1.3 / 1.4 / 1.5）
 *
 * 渲染约定（照原型 tree-row）：
 *  - **缩进即引导线**：每一级不是「加个 padding」，而是一个 24vp 宽的格子，格子画左边框
 *    —— 既产生 24vp 缩进，又产生一条竖向线；相邻行首尾相接，视觉上跨行连续（需求 1.5）。
 *    这么写是为了不引入第二套几何（避免 padding 与线条各算一次、以后改一处忘另一处）。
 *  - **目录 vs 文件**：目录 = 主色图标 + 500 字重 + 折叠箭头；文件 = 中性图标 + 400 字重。
 *  - **扁平渲染**：FileTree.scan 已经把「父目录折叠 → 子树不出现」处理掉，
 *    这里只按数组逐行画，不做递归组件（ArkUI 递归组件容易踩 status 复用）。
 *
 * 状态归属：
 *  - 展开状态 = 组件内 @State + ExpandStore 按库持久化（需求 1.3）；
 *  - **当前文件提给父级**（Index），理由见需求 1.4：折叠父目录不应改变正在编辑的文件，
 *    而「正在编辑什么」属于跨栏共享状态（侧栏选中态 + 编辑区标题 + 预览区来源同源），
 *    放在树里会让折叠动作连带改到它。这里只**回传选择**，不自己决定是否关闭。
 *
 * 后续 1.6（左滑三档）已落在本文件 ListItem.swipeAction（API 24 已核实，
 * sdk/default/openharmony/ets/component/list_item.d.ts:563），故本文件从一开始就用 List/ListItem。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { FileTree, ExpandStore, PinStore, FavoriteStore, TreeNode, PinnedNote } from '../model/FileTree';
import { VaultAccess, VaultDirChild, VaultFileStat } from '../model/VaultAccess';
import { VaultRegistry } from '../model/VaultRegistry';
import { Icon, symbolGlyphOf } from '../common/Icons';
import { noteDisplayName, noteDisplayNameOfPath } from '../common/NoteDisplayName';
import { FocusRequest } from '../common/FocusRequest';
import { Space, Radius, FontSize, Size, Weight } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { unifiedDataChannel } from '@kit.ArkData';
import { TrashView } from './TrashView';

const TREE_DOMAIN: number = 0x0002;
const TREE_TAG: string = 'FileTreeView';
// v1.71 修复（API26 模拟器实测 2026-11-16）：UDMF 应用自定义拖拽类型的匹配事实——
// 1) ApplicationDefinedRecord 的 summary 键恒为 'ApplicationDefinedType'（实测
//    "require summary: ApplicationDefinedType-<size>"，applicationDefinedType 写什么
//    都不改变它），框架 allowDrop 按 summary 键比对，所以 allowDrop 必须写
//    'ApplicationDefinedType'（= UDMF 文档 ApplicationDefinedRecord 示例的赋值）；
// 2) 任意「私有 MIME 串」allowDrop（旧 'application/x-yaoshi-note-ref'）永不匹配，
//    实测 "DragDropManager onDragEnd, target data is not allowed to fall into"。
// 细分过滤不放类型层：树内 / 栏落点靠拖拽会话状态（dragSourcePath / treeDragPath，
// 外来拖拽为空串自然被拒），Agent 靠 payload JSON 的 vaultId 校验。
const NOTE_REF_MIME: string = 'ApplicationDefinedType';

/**
 * LazyForEach 数据源（v1.0 需求 2「大目录懒加载」）。
 * 文件树的每次变化都是整树重扫（FileTree.scan 返回全新数组），
 * 所以这里只走 onDataReloaded 整体通知，不做按索引的增量维护——
 * 避开 LazyForEach 增删不同步的经典 bug（faqs-arkui-1355）。
 * dataSource 实例只创建一次，禁止重新赋值，只能通过 reload() 通知更新。
 */
class TreeRowDataSource implements IDataSource {
  private nodes: TreeNode[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.nodes.length;
  }

  getData(index: number): TreeNode {
    return this.nodes[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  reload(nodes: TreeNode[]): void {
    this.nodes = nodes;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

/**
 * 置顶区 / 收藏区数据源（v1.62 · v1.97 共用）：与树行**完全独立**的列表段，
 * LazyForEach 键以 `pin-` / `fav-` 开头，不会和树行键撞复用。行数少
 * （区内滚动上限 5.5 行），但仍走懒加载保持口径一致。
 */
class SectionRowDataSource implements IDataSource {
  private rows: PinnedNote[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): PinnedNote {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  reload(rows: PinnedNote[]): void {
    this.rows = rows;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

@Component
export struct FileTreeView {
  /** 当前库 id（切库由 @Watch 触发重扫） */
  @Prop @Watch('onVaultChanged') vaultId: string = '';
  /** 当前打开文件的库内相对路径（父级持有；这里只用于画选中态） */
  @Prop currentFilePath: string = '';
  /** 重扫信号：父级 +1 → onRefresh → reload */
  @Prop @Watch('onRefresh') refreshSeq: number = 0;
  /** 文件树排序模式（v1.49）：父级切换 → onSortChanged → rescan 重排。 */
  @Prop @Watch('onSortChanged') sortMode: string = 'name';
  /** 回收站重扫信号，与文件树扫描状态分开。 */
  @Prop trashRefreshSeq: number = 0;
  /** 需要展开到可见的目标路径（父级新建笔记后置位） */
  @Prop @Watch('onReveal') revealPath: string = '';
  /** Agent 引用模式：沿用同一棵树，但隐藏改名/移动/删除动作。 */
  @Prop referenceOnly: boolean = false;
  /** 单屏工作区不显示跨栏打开入口。 */
  @Prop hideOtherPane: boolean = false;
  /**
   * 57.7：钉底簇（左滑提示 + 回收站）整体下移量（vp），父级 VaultSidebar 算好传入：
   * 嵌入形态 = 避让高度 − 连写条高 − s1（簇底与连写条顶相接，可为负）、
   * 单屏抽屉 = 全额避让高度（无连写条）、Agent 引用侧栏 = 0。
   * ArkUI 布局不进安全区（api_notes AE4），固定内容压进条带只能靠 offset 渲染位移。
   */
  @Prop clusterOffsetVp: number = 0;
  /** 选中文件回调（把相对路径交给父级，由父级决定编辑器要做什么） */
  onSelectFile: (relPath: string) => void = (relPath: string) => {};
  /** 从行尾按钮在另一栏打开笔记。 */
  onOpenOtherPane: (relPath: string) => void = (relPath: string) => {};
  /** 仅引用模式下点击文件行；不打开编辑器。 */
  onReferenceNote: (relPath: string, vaultId: string) => void = (relPath: string, vaultId: string) => {};
  /**
   * 「在这个目录下新建笔记」回调（目录行尾的 + 按钮，2026-10-18 方案 A 用户拍板）。
   * 为什么要有它：侧栏底部「新建笔记」永远从根开始，想在目录里建必须手打完整路径；
   * 设计稿（原型）在这一块是空白（footer 的「新建」是个没绑行为的死按钮），
   * 所以入口形态是我们自己补的 —— 目录行 + 预填路径的对话框。
   */
  onCreateInDir: (dirRelPath: string) => void = (dirRelPath: string) => {};
  /**
   * 左滑操作条（1.6 三档）的三个按钮回调。侧栏只透传，对话框与执行都在父级（Index）：
   * - onRenamePath / onMovePath：拉起 RenamePathDialog / MovePathDialog；
   * - onDeletePath：拉起 DeletePathDialog（文件 → 移入回收站，目录 → 永久删除确认）。
   */
  onRenamePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onMovePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onDeletePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  /** 文件 / 文件夹分享回调，入口放在左滑操作菜单。 */
  onSharePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  /**
   * 「滑到底直接删除」回调（1.6 第三档 → 1.7）：越过操作条 + DEL_EXTRA 后松手触发。
   * 只有文件行接（原型同款：目录不给滑到底删除，误删一棵子树的代价不该这么轻）；
   * 走 TrashService 移入回收站 + 5 秒撤销条，**不弹确认框**（原型 deleteWithUndo 同语义）。
   */
  onSwipeDelete: (relPath: string) => void = (relPath: string) => {};
  /** 从内嵌回收站恢复笔记，由父级复用现有 TrashService 处理。 */
  onRestoreTrash: (relPath: string) => void = (relPath: string) => {};
  onPurgeTrash: (relPath: string) => void = (relPath: string) => {};
  /** 清空回收站（55.1）：父级拉清空确认弹窗，确认后 TrashService.purgeAll。 */
  onPurgeAllTrash: () => void = () => {};

  /** 回收站条目预览（74.3：点行主体弹只读预览） */
  onPreviewTrash: (relPath: string) => void = (relPath: string) => {};
  /**
   * v1.71 树内拖拽移动（71.1 / 71.3）：drop 到目录行 / 树根空白时请求父级执行
   * 既有移动全链（Index.doMovePath：flush → movePath → retarget → reveal → 刷新树）。
   * destDir 为空串 = 库根，与「移动」对话框的「库根目录」语义一致。
   */
  onDragMovePath: (relPath: string, isDir: boolean, destDir: string) => void =
    (relPath: string, isDir: boolean, destDir: string) => {};
  /**
   * v1.71 拖拽会话开始 / 结束（71.2）：父级（Index）据此启用正文栏「拖进打开」落点。
   * 会话源存父级本地状态而非 event.getData()——onDragEnter 阶段读数据可能抛
   * 「Data not found」（拖拽框架只在 drop 前保证数据可见），高亮判断不能依赖它。
   */
  onTreeDragStart: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onTreeDragEnd: () => void = () => {};

  @State nodes: TreeNode[] = [];
  @State expanded: string[] = [];
  @State pinned: string[] = [];
  /** v1.97 收藏路径数组（数组顺序即收藏先后，渲染层逆序 = 最新在前）。 */
  @State favorites: string[] = [];
  /** 置顶区可见行（v1.62）：由 PinStore 数组 ∩ 当前库全量笔记解析，陈旧条目自动不显示。 */
  @State pinRows: PinnedNote[] = [];
  /** 收藏区可见行（v1.97）：解析复用 pinnedNotes（收藏行与置顶行同构，不写两套）。 */
  @State favRows: PinnedNote[] = [];
  /** 置顶区折叠状态，按库持久化（PinStore.loadSectionOpen / saveSectionOpen）。 */
  @State pinSectionOpen: boolean = true;
  /** 收藏区折叠状态，按库持久化（FavoriteStore.loadSectionOpen / saveSectionOpen）。 */
  @State favSectionOpen: boolean = true;
  /** v2.5 闭环（方案 A）：树 List 实测宽（onAreaChange 回填，vp），驱动 isNarrowNav()。 */
  @State treeWidthVp: number = 0;
  @State pinHoverPath: string = '';
  @State pinFocusPath: string = '';
  @State favHoverPath: string = '';
  @State favFocusPath: string = '';
  @State pathMenuPath: string = '';
  @State helpHintOpen: boolean = false;
  /** 57.7：导航条避让高度（px，EntryAbility 发布；px2vp 后即下移量）。 */
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 57.7：钉底簇（左滑提示 + 回收站）实测高（onAreaChange 的 Area.height，单位 vp），用于文件树末条让位。 */
  @State clusterH: number = 0;
  /** v1.71：目录行拖拽悬停高亮路径（必须进 LazyForEach 键，见树行键值踩坑注释）。 */
  @State dropOverDir: string = '';
  private pathMenuReturnFocusId: string = '';
  private store: ExpandStore | null = null;
  private pinStore: PinStore | null = null;
  private favStore: FavoriteStore | null = null;
  private treeSource: TreeRowDataSource = new TreeRowDataSource();
  private pinSource: SectionRowDataSource = new SectionRowDataSource();
  private favSource: SectionRowDataSource = new SectionRowDataSource();
  /** v1.71 拖拽会话源：onDragStart 记录、onDragEnd 清空；只在事件回调里读，不进渲染绑定。 */
  private dragSourcePath: string = '';
  private dragSourceIsDir: boolean = false;
  /**
   * v1.71 同一次 drop 的多个 onDrop 合并（行 → List 的触发顺序与冒泡不可知，以实测为准
   * 不押注）：目录行(3) > 笔记行拦截(2) > 树根空白(1)，rank 高者胜；setTimeout(0)
   * 等全部 onDrop 到齐后只执行一次移动。
   */
  private pendingMoveDest: string = '';
  private pendingMoveRank: number = 0;
  private pendingMoveTimer: number = -1;

  /** 57.7：导航条避让高度（vp）；布局区不进安全区（AE4），固定内容压条带靠 offset。 */
  private navClearanceVp(): number {
    return px2vp(Math.max(0, this.navIndicatorHeightPx));
  }

  /**
   * 57.7：文件树末条让位（vp）。expandSafeArea 只延伸渲染边界，滚动内容底仍止于
   * 布局区下沿（2152px，2026-11-14 实测：末条底 = 2152 − 本值），末条让到簇顶
   * 上方一格（s1）。clusterH 来自 onAreaChange 的 Area.height，单位 vp，不得再
   * px2vp（二次换算回归）。referenceOnly（Agent 引用树）不渲染钉底簇，保持现状。
   */
  private treeBottomClearanceVp(): number {
    if (this.referenceOnly) {
      return 0;
    }
    return Math.max(Space.s1,
      -this.clusterOffsetVp + Math.max(0, this.clusterH) + Space.s1);
  }

  aboutToAppear(): void {
    this.ensureStore();
    this.ensurePinStore();
    this.reload();
  }

  private ensureStore(): void {
    if (this.store === null) {
      this.store = new ExpandStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensurePinStore(): void {
    if (this.pinStore === null) {
      this.pinStore = new PinStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureFavStore(): void {
    if (this.favStore === null) {
      this.favStore = new FavoriteStore(VaultRegistry.get().abilityContext());
    }
  }

  private onVaultChanged(): void {
    this.closePathMenu(false);
    this.reload();
  }

  private onRefresh(): void {
    this.closePathMenu(false);
    this.reload();
  }

  /** 排序模式切换（v1.49）：同一份可见行按新模式重排，不重新读展开状态。 */
  private onSortChanged(): void {
    this.rescan();
  }

  /**
   * 展开目标笔记的所有父目录并重扫（reveal）。
   * 例如 `工程/流式系统/笔记.md` → 祖先目录是 `工程`、`工程/流式系统`。
   */
  private onReveal(): void {
    if (this.revealPath.length === 0) {
      return;
    }
    this.ensureStore();
    const segs: string[] = this.revealPath.split('/');
    const next: string[] = [];
    for (let i = 0; i < this.expanded.length; i++) {
      next.push(this.expanded[i]);
    }
    let acc: string = '';
    for (let i = 0; i < segs.length - 1; i++) {
      acc = i === 0 ? segs[0] : acc + '/' + segs[i];
      if (next.indexOf(acc) < 0) {
        next.push(acc);
      }
    }
    this.expanded = next;
    const store: ExpandStore = this.store as ExpandStore;
    store.save(this.vaultId, next);
    this.rescan();
  }

  /** 唯一写入口：@State（空态判断用）与 LazyForEach 数据源必须同批更新 */
  private applyNodes(nodes: TreeNode[]): void {
    this.nodes = nodes;
    this.treeSource.reload(nodes);
  }

  /** 置顶区同理：显隐判断用的 @State 与独立数据源必须同批更新。 */
  private applyPinRows(rows: PinnedNote[]): void {
    this.pinRows = rows;
    this.pinSource.reload(rows);
  }

  /** 收藏区同理（v1.97）：显隐 @State 与独立数据源同批更新。 */
  private applyFavRows(rows: PinnedNote[]): void {
    this.favRows = rows;
    this.favSource.reload(rows);
  }

  /** 重扫：读出该库的展开状态 → scan → 刷新可见行 */
  private reload(): void {
    this.ensureStore();
    this.ensurePinStore();
    this.ensureFavStore();
    if (this.vaultId.length === 0) {
      this.applyNodes([]);
      this.applyPinRows([]);
      this.applyFavRows([]);
      return;
    }
    const store: ExpandStore = this.store as ExpandStore;
    this.expanded = store.load(this.vaultId);
    const pins: PinStore = this.pinStore as PinStore;
    this.pinned = pins.load(this.vaultId);
    this.pinSectionOpen = pins.loadSectionOpen(this.vaultId);
    this.pinHoverPath = '';
    this.pinFocusPath = '';
    const favs: FavoriteStore = this.favStore as FavoriteStore;
    this.favorites = favs.load(this.vaultId);
    this.favSectionOpen = favs.loadSectionOpen(this.vaultId);
    this.favHoverPath = '';
    this.favFocusPath = '';
    hilog.info(TREE_DOMAIN, TREE_TAG, '文件树扫描开始');
    this.rescan();
  }

  /** 按当前 expanded 重新扫描库目录，并同源解析置顶区与收藏区（一次 snapshot 三处用）。 */
  private rescan(): void {
    if (this.vaultId.length === 0) {
      this.applyNodes([]);
      this.applyPinRows([]);
      this.applyFavRows([]);
      return;
    }
    // v1.5：不再拿绝对路径自己递归 —— 外部授权库给不出绝对路径。
    // VaultAccess 负责遍历（沙箱 fileIo / 外部 Native POSIX），这里只做剪枝与排版。
    const access: VaultAccess = VaultRegistry.get().accessFor(this.vaultId);
    const entries: VaultDirChild[] = access.snapshot();
    let nodes: TreeNode[] = FileTree.scanEntries(entries, this.expanded);
    // v1.49 排序（v1.62 恢复纯规则）：mtime 按修改时间重排，stat 拿不到按最旧；
    // 置顶已在 62.2 从树内排序中移除，两种模式都不受置顶影响。
    nodes = FileTree.resort(nodes, this.sortMode === 'mtime' ? 'mtime' : 'name',
      (relPath: string): number => {
        const meta: VaultFileStat | null = access.stat(relPath);
        return meta === null ? -1 : meta.mtimeSec;
      });
    // 折叠文件夹里的置顶笔记也要显示（62.1 核心价值），故置顶区取**全量**笔记而非可见行；
    // 收藏区同款（97.1）：同一份全量笔记解析收藏行，收藏行与置顶行同构（不写两套）。
    this.applyPinRows(FileTree.pinnedNotes(FileTree.notesOfEntries(entries), this.pinned));
    this.applyFavRows(FileTree.pinnedNotes(FileTree.notesOfEntries(entries), this.favorites));
    this.applyNodes(nodes);
    hilog.info(TREE_DOMAIN, TREE_TAG, '文件树扫描完成');
  }

  private isExpanded(relPath: string): boolean {
    return this.expanded.indexOf(relPath) >= 0;
  }

  private onDirectoryKey(node: TreeNode, event: KeyEvent): boolean {
    if (!node.isDir || event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT && !this.isExpanded(node.relPath)) {
      this.toggleDir(node.relPath);
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT && this.isExpanded(node.relPath)) {
      this.toggleDir(node.relPath);
      return true;
    }
    return false;
  }

  private treeRowFocusId(node: TreeNode): string {
    return 'file-tree-row-' + this.vaultId + ':' + node.relPath;
  }

  private pathMenuFocusId(node: TreeNode, action: string): string {
    return this.treeRowFocusId(node) + ':menu:' + action;
  }

  private openPathMenu(node: TreeNode): void {
    this.pathMenuReturnFocusId = this.treeRowFocusId(node);
    this.pathMenuPath = node.relPath;
  }

  private closePathMenu(restoreFocus: boolean): void {
    const focusId: string = this.pathMenuReturnFocusId;
    this.pathMenuPath = '';
    this.pathMenuReturnFocusId = '';
    if (restoreFocus && focusId.length > 0) {
      FocusRequest.safely(this.getUIContext(), focusId);
    }
  }

  private onPathMenuDismiss(action: DismissPopupAction): void {
    action.dismiss();
    this.closePathMenu(action.reason === DismissReason.PRESS_BACK);
  }

  private onTreeRowKey(node: TreeNode, event: KeyEvent): boolean {
    if (this.onDirectoryKey(node, event)) {
      return true;
    }
    if (event.type !== KeyType.Down || this.referenceOnly) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_MENU) {
      this.openPathMenu(node);
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_F10) {
      let shiftPressed: boolean = false;
      if (event.getModifierKeyState !== undefined) {
        shiftPressed = event.getModifierKeyState(['Shift']);
      }
      if (shiftPressed) {
        this.openPathMenu(node);
        return true;
      }
    }
    return false;
  }

  private runPathMenuAction(node: TreeNode, action: string): void {
    this.closePathMenu(false);
    if (action === 'favorite' && !node.isDir) {
      // v2.5 闭环（方案 A）：星标按钮移除后，树内收藏切换入口收进 ⋯ 菜单。
      this.toggleFavoritePath(node.relPath);
    } else if (action === 'pin') {
      this.togglePin(node);
    } else if (action === 'share' && node.isDir) {
      this.onSharePath(node.relPath, true);
    } else if (action === 'rename') {
      this.onRenamePath(node.relPath, node.isDir);
    } else if (action === 'move') {
      this.onMovePath(node.relPath, node.isDir);
    } else if (action === 'delete') {
      this.onDeletePath(node.relPath, node.isDir);
    }
  }

  /** v2 的文件树主标题隐藏 Markdown 扩展名，文件操作仍使用完整相对路径。 */
  private displayName(node: TreeNode): string {
    if (node.isDir) {
      return node.name;
    }
    return noteDisplayName(node.name);
  }

  /** 展开/折叠：换整个数组触发刷新，并立刻落盘（需求 1.3） */
  private toggleDir(relPath: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.expanded.length; i++) {
      if (this.expanded[i] === relPath) {
        found = true;
      } else {
        next.push(this.expanded[i]);
      }
    }
    if (!found) {
      next.push(relPath);
    }
    this.expanded = next;
    const store: ExpandStore = this.store as ExpandStore;
    store.save(this.vaultId, next);
    this.rescan();
  }

  /** v1.71 目录行能否作为移动落点：拖到自身 / 子孙行不允许（与 NoteService.movePath 兜底同口径）。 */
  private canDropIntoDir(node: TreeNode): boolean {
    if (this.referenceOnly || !node.isDir || this.dragSourcePath.length === 0) {
      return false;
    }
    if (this.dragSourcePath === node.relPath) {
      return false;
    }
    if (this.dragSourceIsDir && node.relPath.startsWith(this.dragSourcePath + '/')) {
      return false;
    }
    return true;
  }

  /** v1.71 记录一次 drop 的候选落点（rank 高者胜），合并后一次执行，见 pendingMoveRank 注释。 */
  private requestDragMove(destDir: string, rank: number): void {
    if (rank >= this.pendingMoveRank) {
      this.pendingMoveRank = rank;
      this.pendingMoveDest = destDir;
    }
    if (this.pendingMoveTimer < 0) {
      this.pendingMoveTimer = setTimeout((): void => { this.flushPendingDragMove(); }, 0);
    }
  }

  private flushPendingDragMove(): void {
    this.pendingMoveTimer = -1;
    const destDir: string = this.pendingMoveDest;
    const rank: number = this.pendingMoveRank;
    this.pendingMoveRank = 0;
    this.pendingMoveDest = '';
    if (this.dragSourcePath.length === 0) {
      return;
    }
    if (rank === 3) {
      this.onDragMovePath(this.dragSourcePath, this.dragSourceIsDir, destDir);
    } else if (rank === 1) {
      // 树根空白 = 移到库根（对齐移动对话框「库根目录」）。
      this.onDragMovePath(this.dragSourcePath, this.dragSourceIsDir, '');
    }
    // rank === 2：笔记行上的 drop 只做拦截（无操作），防止被 List 兜底解释成「移到库根」。
  }

  /** 缩进格子数 = 层级数，超过封顶层级（v2.5 Size.treeDepthCap）后不再增长，深层级不侵占笔记名空间 */
  private levelsOf(depth: number): number[] {
    const capped: number = Math.min(depth, Size.treeDepthCap);
    const out: number[] = [];
    for (let i = 0; i < capped; i++) {
      out.push(i);
    }
    return out;
  }

  /** 该文件行是否置顶（v1.50 · 50.1：仅笔记文件行，目录恒 false） */
  private isPinned(relPath: string): boolean {
    return this.pinned.indexOf(relPath) >= 0;
  }

  /**
   * 置顶 / 取消置顶（v1.50 · 50.2 入口，v1.62 语义）：切换后立即落盘、toast 反馈、
   * 置顶区即时增删行。改名 / 移动后旧路径留存为陈旧条目（50.4：不自动清理，无副作用），
   * 由 pinnedNotes 与全量笔记的交集自然不显示。
   */
  private togglePin(node: TreeNode): void {
    if (node.isDir) {
      return;
    }
    this.togglePinPath(node.relPath);
  }

  /** 树内入口与置顶区取消入口共用的唯一写入口。 */
  private togglePinPath(relPath: string): void {
    if (this.vaultId.length === 0 || relPath.length === 0) {
      return;
    }
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.pinned.length; i++) {
      if (this.pinned[i] === relPath) {
        found = true;
      } else {
        next.push(this.pinned[i]);
      }
    }
    if (!found) {
      next.push(relPath);
    }
    this.pinned = next;
    this.ensurePinStore();
    const pins: PinStore = this.pinStore as PinStore;
    pins.save(this.vaultId, next);
    // 62.3：v1.50 无反馈，用户抱怨的核心就是「置顶了看不出来」。
    // toast 是本地 UI 反馈，不是埋点（62.5 红线只禁标题 / 路径进埋点）。
    promptAction.showToast({
      message: (found ? '已取消置顶：' : '已置顶：') + noteDisplayNameOfPath(relPath)
    });
    hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：置顶切换');
    this.rescan();
  }

  /** 置顶区折叠：按库记忆，默认展开。 */
  private togglePinSection(): void {
    const next: boolean = !this.pinSectionOpen;
    this.pinSectionOpen = next;
    this.ensurePinStore();
    const pins: PinStore = this.pinStore as PinStore;
    pins.saveSectionOpen(this.vaultId, next);
  }

  /** 区内滚动：最多约 5.5 行，不推挤目录树。 */
  private pinListHeight(): number {
    const rows: number = this.pinRows.length < Size.pinListMaxRows
      ? this.pinRows.length : Size.pinListMaxRows;
    return rows * (Size.pinRowH + Size.pinRowGap);
  }

  /** 指针设备悬停 / 键盘焦点时，行尾文件夹名换成「取消置顶」按钮。 */
  private pinRowActive(relPath: string): boolean {
    return this.pinHoverPath === relPath || this.pinFocusPath === relPath;
  }

  private pinLocation(row: PinnedNote): string {
    return row.folderPath.length === 0 ? '根目录' : row.folderPath;
  }

  /** 该文件行是否已收藏（v1.97 · 97.2：仅笔记文件行，目录恒 false）。 */
  private isFavorite(relPath: string): boolean {
    return this.favorites.indexOf(relPath) >= 0;
  }

  /**
   * v2.5 闭环（方案 A，2026-11-23）：窄侧栏 = 树实测宽 < Size.narrowNavW
   * （XT2 三栏 nav 200-248vp）时隐藏行尾跨栏按钮——拖笔记到栏内打开是既有
   * 替代路径；宽侧栏 / 桌面不受影响。未测得宽度（0）前按窄处理，避免首帧闪现。
   */
  private isNarrowNav(): boolean {
    return this.treeWidthVp < Size.narrowNavW;
  }

  /**
   * 收藏切换唯一写入口（97.2）：切换后立即落盘、toast 反馈、收藏区即时增删行；
   * 树行收藏星标（名字尾标记）靠行键 `|fav` 刷新（faqs-arkui-219）。删除进回收站关系保留（97.3），
   * 永久删除清理与改名 / 移动 retarget 在 Index 侧调 FavoriteStore。
   */
  private toggleFavoritePath(relPath: string): void {
    if (this.vaultId.length === 0 || relPath.length === 0) {
      return;
    }
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.favorites.length; i++) {
      if (this.favorites[i] === relPath) {
        found = true;
      } else {
        next.push(this.favorites[i]);
      }
    }
    if (!found) {
      next.push(relPath);
    }
    this.favorites = next;
    this.ensureFavStore();
    const favs: FavoriteStore = this.favStore as FavoriteStore;
    favs.save(this.vaultId, next);
    promptAction.showToast({
      message: (found ? '已取消收藏：' : '已收藏：') + noteDisplayNameOfPath(relPath)
    });
    hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：收藏切换');
    this.rescan();
  }

  /** 收藏区折叠：按库记忆，默认展开（97.1）。 */
  private toggleFavSection(): void {
    const next: boolean = !this.favSectionOpen;
    this.favSectionOpen = next;
    this.ensureFavStore();
    const favs: FavoriteStore = this.favStore as FavoriteStore;
    favs.saveSectionOpen(this.vaultId, next);
  }

  /** 收藏区行高：与置顶区同款（区内滚动上限 5.5 行，不推挤目录树）。 */
  private favListHeight(): number {
    const rows: number = this.favRows.length < Size.pinListMaxRows
      ? this.favRows.length : Size.pinListMaxRows;
    return rows * (Size.pinRowH + Size.pinRowGap);
  }

  private favRowActive(relPath: string): boolean {
    return this.favHoverPath === relPath || this.favFocusPath === relPath;
  }

  private favLocation(row: PinnedNote): string {
    return row.folderPath.length === 0 ? '根目录' : row.folderPath;
  }

  /** callout 色板（v1.54 §54.1 第三稿），颜色一律走资源 token，深色自动切换。 */
  private pinToneFg(tone: number): ResourceColor {
    if (tone === 1) {
      return $r('app.color.cb_tip');
    }
    if (tone === 2) {
      return $r('app.color.cb_warn');
    }
    if (tone === 3) {
      return $r('app.color.cb_purple');
    }
    if (tone === 4) {
      return $r('app.color.cb_gray');
    }
    return $r('app.color.cb_note');
  }

  private pinToneBg(tone: number): ResourceColor {
    if (tone === 1) {
      return $r('app.color.cb_tip_bg');
    }
    if (tone === 2) {
      return $r('app.color.cb_warn_bg');
    }
    if (tone === 3) {
      return $r('app.color.cb_purple_bg');
    }
    if (tone === 4) {
      return $r('app.color.cb_gray_bg');
    }
    return $r('app.color.cb_note_bg');
  }

  build() {
    // 57.7：根改 Bottom Stack——滚动列铺满，钉底簇（左滑提示+回收站）offset 压进
    // 底部手势条条带（布局不进安全区 AE4；offset 渲染+命中同步位移）。
    // 根节点仍是**唯一**容器：空态与列表走 if/else，不能提前 return（10905210）。
    Stack({ alignContent: Alignment.Bottom }) {
      // v1.62：置顶区在计数头之下、目录树之上；仅当前库至少有一篇置顶时显示。
      // v1.97：收藏区在置顶区之下、目录树之上（97.1 四段：置顶 → 收藏 → 全部笔记 → 树）；
      // referenceOnly（Agent 引用侧栏）保持纯树，「章节」页签由父级整树隐藏。
      Column() {
        if (!this.referenceOnly && this.pinRows.length > 0) {
          this.PinSection()
        }
        if (!this.referenceOnly && this.favRows.length > 0) {
          this.FavSection()
        }
        if (!this.referenceOnly && (this.pinRows.length > 0 || this.favRows.length > 0)) {
          this.AllNotesLabel()
        }
        if (this.nodes.length === 0) {
          this.EmptyHint()
        } else {
          this.TreeList()
        }
      }
      .width('100%')
      .height('100%')

      if (!this.referenceOnly) {
        Column() {
          Text('左滑操作 · 拖动移动或打开')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: Space.s2, left: Space.s2, right: Space.s2, bottom: Space.s1 })
            .onHover((isHover: boolean): void => {
              this.helpHintOpen = isHover;
            })
            .accessibilityText('左滑文件可操作；长按拖动笔记或文件夹移动，拖笔记到任一栏打开')
            .bindPopup(this.helpHintOpen, {
              builder: this.HelpHint(),
              placement: Placement.Top,
              enableArrow: false,
              mask: false,
              autoCancel: false,
              popupColor: Color.Transparent
            })

          TrashView({
            vaultId: this.vaultId,
            refreshSeq: this.trashRefreshSeq,
            onRestore: (relPath: string): void => { this.onRestoreTrash(relPath); },
            onPurge: (relPath: string): void => { this.onPurgeTrash(relPath); },
            onPurgeAll: (): void => { this.onPurgeAllTrash(); },
            onPreview: (relPath: string): void => { this.onPreviewTrash(relPath); }
          })
        }
        .width('100%')
        // 遮住穿小白条滚上来的树行（树 List 已 extend 到物理下沿）。
        .backgroundColor($r('app.color.bg_navigation'))
        .offset({ y: this.clusterOffsetVp })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          if (typeof newArea.height === 'number') {
            this.clusterH = newArea.height;
          }
        })
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  /**
   * 置顶区（v1.62 · 62.1）：分区标签 + 独立行列表，视觉规格沿用 v1.54 §54.1 第三稿。
   * 区头箭头常显（原生不做指针类型判断，触屏与键盘都要能发现折叠入口）。
   */
  @Builder
  PinSection() {
    Column() {
      Row({ space: Space.s2 }) {
        Text('置顶')
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Medium)
          .letterSpacing(Size.pinLabelTracking)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.pinRows.length.toString())
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.text_tertiary'))
          .opacity(0.8)
        Row() {
          // 全局 @Builder 按值实参会首帧固化（api_notes Z2/L-7）：图标名不能写
          // this.xxx ? 'a' : 'b'，必须拆成字面量分支，否则箭头方向不刷新。
          if (this.pinSectionOpen) {
            Icon('chevronDown', Size.treeChevron, $r('app.color.text_tertiary'))
          } else {
            Icon('chevronRight', Size.treeChevron, $r('app.color.text_tertiary'))
          }
        }
        .width(Size.touch)
        .height(Space.s6)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s4, right: Space.s1 })
      .alignItems(VerticalAlign.Center)
      .borderRadius(Radius.control)
      .onClick((): void => { this.togglePinSection(); })
      .focusable(true)
      .accessibilityText('置顶，' + this.pinRows.length.toString() + ' 篇笔记，点按展开 / 收起')

      if (this.pinSectionOpen) {
        List() {
          LazyForEach(this.pinSource, (row: PinnedNote) => {
            ListItem() {
              this.SectionRow(row, true)
            }
            .width('100%')
            .padding({ right: Space.s2 })
            // 62.3：置顶区左滑是独立手势，滑到底 = 取消置顶，
            // 绝不复用树行的三档删除语义（滑一下把笔记删进回收站是不可接受的）。
            .swipeAction({
              end: {
                builder: (): void => { this.PinSwipeBar(row); },
                actionAreaDistance: Size.swipeDelExtra,
                onAction: (): void => { this.togglePinPath(row.relPath); }
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          }, (row: PinnedNote): string => {
            // 独立键空间；当前态 / 悬停态进键，避免 faqs-arkui-219 行子树复用不刷新。
            return 'pin-' + row.relPath +
              (row.relPath === this.currentFilePath ? '|cur' : '|u') +
              (this.pinRowActive(row.relPath) ? '|act' : '');
          })
        }
        .width('100%')
        .height(this.pinListHeight())
        .padding({ left: Space.s4 })
        .scrollBar(BarState.Auto)
        .cachedCount(10)
        .backgroundColor($r('app.color.bg_navigation'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 收藏区（v1.97 · 97.1）：与置顶区同款分区标签 + 共用行组件（SectionRow），
   * 置顶之下、目录树之上；最新收藏在前（数组逆序渲染）。区头箭头常显（同 v1.62）。
   */
  @Builder
  FavSection() {
    Column() {
      Row({ space: Space.s2 }) {
        Text('收藏')
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Medium)
          .letterSpacing(Size.pinLabelTracking)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.favRows.length.toString())
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.text_tertiary'))
          .opacity(0.8)
        Row() {
          if (this.favSectionOpen) {
            Icon('chevronDown', Size.treeChevron, $r('app.color.text_tertiary'))
          } else {
            Icon('chevronRight', Size.treeChevron, $r('app.color.text_tertiary'))
          }
        }
        .width(Size.touch)
        .height(Space.s6)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s4, right: Space.s1 })
      .alignItems(VerticalAlign.Center)
      .borderRadius(Radius.control)
      .onClick((): void => { this.toggleFavSection(); })
      .focusable(true)
      .accessibilityText('收藏，' + this.favRows.length.toString() + ' 篇笔记，点按展开 / 收起')

      if (this.favSectionOpen) {
        List() {
          LazyForEach(this.favSource, (row: PinnedNote) => {
            ListItem() {
              this.SectionRow(row, false)
            }
            .width('100%')
            .padding({ right: Space.s2 })
            // 97.1：收藏区左滑是独立手势（改名 + 移出收藏），滑到底 = 移出收藏，
            // 绝不复用树行的三档删除语义（与置顶区同款红线）。
            .swipeAction({
              end: {
                builder: (): void => { this.FavSwipeBar(row); },
                actionAreaDistance: Size.swipeDelExtra,
                onAction: (): void => { this.toggleFavoritePath(row.relPath); }
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          }, (row: PinnedNote): string => {
            // 独立键空间；当前态 / 悬停态进键，避免 faqs-arkui-219 行子树复用不刷新。
            return 'fav-' + row.relPath +
              (row.relPath === this.currentFilePath ? '|cur' : '|u') +
              (this.favRowActive(row.relPath) ? '|act' : '');
          })
        }
        .width('100%')
        .height(this.favListHeight())
        .padding({ left: Space.s4 })
        .scrollBar(BarState.Auto)
        .cachedCount(10)
        .backgroundColor($r('app.color.bg_navigation'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 置顶区可见时，目录树上方补同款分区标签（62.1）。 */
  @Builder
  AllNotesLabel() {
    Text('全部笔记')
      .fontSize(FontSize.caption)
      .fontWeight(FontWeight.Medium)
      .letterSpacing(Size.pinLabelTracking)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: Space.s4, right: Space.s2, top: Space.s2, bottom: Space.s1 })
  }

  /**
   * 置顶区 / 收藏区共用行（v1.62 落形，v1.97 兑现「共用行组件不写两套」）：
   * 首字色块 + 标题 + 所在文件夹；行尾文件夹名在悬停 / 焦点时原位换成取消按钮。
   * isPin 区分两区：取消入口（置顶 / 收藏）、读屏文案、行 id 前缀与悬停状态组。
   */
  @Builder
  SectionRow(row: PinnedNote, isPin: boolean) {
    Row() {
      Row({ space: Space.s2 }) {
        Row() {
          Text(row.initial)
            .fontSize(FontSize.caption)
            .fontWeight(Weight.semibold)
            .fontColor(this.pinToneFg(row.tone))
            .textAlign(TextAlign.Center)
        }
        .width(Size.pinMonogram)
        .height(Size.pinMonogram)
        .borderRadius(Size.pinMonogramRadius)
        .backgroundColor(this.pinToneBg(row.tone))
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        Text(row.title)
          .fontSize(FontSize.body2)
          .fontWeight(row.relPath === this.currentFilePath ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(row.relPath === this.currentFilePath
            ? $r('app.color.brand') : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      .padding({ left: Space.s2, right: Space.s3 })
      // 同树行坑：内容子树透明，点击统一冒泡到外层 Row；行尾按钮在子树之外才点得动。
      .hitTestBehavior(HitTestMode.None)

      if (isPin ? this.pinRowActive(row.relPath) : this.favRowActive(row.relPath)) {
        Row() {
          if (isPin) {
            Icon('pin', Space.s4, $r('app.color.text_tertiary'))
          } else {
            // 全局 @Builder 按值实参首帧固化（Z2/L-7）：图标名必须字面量分支。
            Icon('starFilled', Space.s4, $r('app.color.text_tertiary'))
          }
        }
        .width(Size.touch)
        .height(Size.touch)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.icon)
        .onClick((): void => {
          if (isPin) {
            this.togglePinPath(row.relPath);
          } else {
            this.toggleFavoritePath(row.relPath);
          }
        })
        .accessibilityText((isPin ? '取消置顶：' : '取消收藏：') + row.title)
      } else {
        Text(row.folder)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .width('40%')
      }
    }
    .width('100%')
    .height(Size.pinRowH)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.control)
    .onClick((): void => {
      if (row.relPath !== this.currentFilePath) {
        this.onSelectFile(row.relPath);
      }
    })
    .onHover((isHover: boolean): void => {
      if (isPin) {
        this.pinHoverPath = isHover ? row.relPath : '';
      } else {
        this.favHoverPath = isHover ? row.relPath : '';
      }
    })
    .onFocus((): void => {
      if (isPin) {
        this.pinFocusPath = row.relPath;
      } else {
        this.favFocusPath = row.relPath;
      }
    })
    .onBlur((): void => {
      if (isPin) {
        if (this.pinFocusPath === row.relPath) {
          this.pinFocusPath = '';
        }
      } else {
        if (this.favFocusPath === row.relPath) {
          this.favFocusPath = '';
        }
      }
    })
    .focusable(true)
    .id((isPin ? 'pin-row-' : 'fav-row-') + this.vaultId + ':' + row.relPath)
    .accessibilityText((isPin ? '打开置顶的笔记：' : '打开收藏的笔记：') + row.title +
      '，位于 ' + (isPin ? this.pinLocation(row) : this.favLocation(row)))
  }

  /** 置顶区左滑操作条：可点图标「取消置顶」，滑到底松手同样取消（不触发删除）。 */
  @Builder
  PinSwipeBar(row: PinnedNote) {
    Row() {
      Row() {
        // v2.3：取消置顶图标化（pinOff），无文字；读屏语义进 accessibilityText。
        Icon('pinOff', Space.s5, $r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
      .id('unpin-swipe-' + row.relPath)
      .accessibilityText('取消置顶：' + row.title)
      .onClick((): void => { this.togglePinPath(row.relPath); })
      Text('· 松手取消置顶')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.brand'))
        .maxLines(1)
        .padding({ right: Space.s2 })
    }
    .height('100%')
    .backgroundColor($r('app.color.brand_bg'))
  }

  /**
   * 收藏区左滑操作条（97.1 第三稿）：「改名 / 移出收藏」可点；
   * 滑到底松手 = 移出收藏（提示「· 松手移出」，非删除语义）。
   */
  @Builder
  FavSwipeBar(row: PinnedNote) {
    Row() {
      Row() {
        Text('改名')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
      .onClick((): void => { this.onRenamePath(row.relPath, false); })
      Row() {
        Text('移出收藏')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
      .onClick((): void => { this.toggleFavoritePath(row.relPath); })
      Text('· 松手移出')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.brand'))
        .maxLines(1)
        .padding({ right: Space.s2 })
    }
    .height('100%')
    .backgroundColor($r('app.color.brand_bg'))
  }

  @Builder
  HelpHint() {
    Text('左滑文件可操作；长按拖动笔记或文件夹移动，拖笔记到任一栏打开')
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_primary'))
      .padding(Space.s2)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(Radius.control)
      .border({ width: 1, color: $r('app.color.line') })
  }

  /** 空库提示（新建库、或库里全是别的文件类型时） */
  @Builder
  EmptyHint() {
    Column() {
      Icon('doc', 24, $r('app.color.text_tertiary'))
      Text('库里还没有笔记')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: Space.s2 })
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 左滑操作条（1.6 三档）：笔记按 v2 原型显示「置顶 / 改名 / 移动 / 删除」文字按钮，
   * 普通操作为浅蓝底蓝字，删除为红底白字。目录保留原有分享入口。
   * v1.50：文件行最前新增置顶切换（已置顶显示「已置顶」），点击切换并收回操作条。
   */
  @Builder
  SwipeBar(n: TreeNode) {
    Row() {
      if (n.isDir) {
        Row() {
          Text('分享')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.brand'))
        }
        .width(Size.touch)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.brand_bg'))
        .onClick(() => {
          this.onSharePath(n.relPath, true);
        })
      } else {
        // v2.3：置顶切换图标化——未置顶 pin / 已置顶 pinOff，无文字。
        // 全局 @Builder 按值实参首帧固化（Z2/L-7）：图标名必须字面量分支。
        Row() {
          if (this.isPinned(n.relPath)) {
            Icon('pinOff', Space.s5, $r('app.color.brand'))
          } else {
            Icon('pin', Space.s5, $r('app.color.brand'))
          }
        }
        .width(Size.touch)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.brand_bg'))
        .id('pin-swipe-' + n.relPath)
        .accessibilityText(this.isPinned(n.relPath) ? '取消置顶：' + n.name : '置顶：' + n.name)
        .onClick(() => {
          hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：置顶切换');
          this.togglePin(n);
        })
        // v2.5 闭环（方案 A）：星标按钮移除后，触屏的树内收藏切换入口——左滑操作条
        // 加收藏按钮（原型左滑条 --swipe-width 为固定行程，不跟随加宽，原型侧不加、
        // 走 ⋯ 菜单；原生 swipeAction builder 自适应，无此约束）。
        // 图标名字面量分支（Z2/L-7 首帧固化）。
        Row() {
          if (this.isFavorite(n.relPath)) {
            Icon('starFilled', Space.s5, $r('app.color.brand'))
          } else {
            Icon('star', Space.s5, $r('app.color.brand'))
          }
        }
        .width(Size.touch)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.brand_bg'))
        .accessibilityText(this.isFavorite(n.relPath) ? '取消收藏：' + n.name : '收藏：' + n.name)
        .onClick(() => {
          this.toggleFavoritePath(n.relPath);
        })
      }
      Row() {
        Text('改名')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
      .onClick(() => {
        hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：重命名');
        this.onRenamePath(n.relPath, n.isDir);
      })
      Row() {
        Text('移动')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
      .onClick(() => {
        hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：移动');
        this.onMovePath(n.relPath, n.isDir);
      })
      Row() {
        Text('删除')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.on_brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.danger'))
      .onClick(() => {
        hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：删除');
        this.onDeletePath(n.relPath, n.isDir);
      })
    }
    .height('100%')
  }

  @Builder
  PathMenuItem(n: TreeNode, action: string, label: string, icon: string,
    destructive: boolean, first: boolean) {
    Row({ space: Space.s2 }) {
      Icon(icon, Space.s4, destructive ? $r('app.color.danger') : $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor(destructive ? $r('app.color.danger') : $r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .focusable(true)
    .id(this.pathMenuFocusId(n, action))
    .accessibilityText(label)
    .onClick((): void => { this.runPathMenuAction(n, action); })
    .onAppear((): void => {
      if (first) {
        FocusRequest.safely(this.getUIContext(), this.pathMenuFocusId(n, action));
      }
    })
  }

  @Builder
  PathActionsMenu(n: TreeNode) {
    Column({ space: Space.s1 }) {
      if (n.isDir) {
        this.PathMenuItem(n, 'share', '分享', 'share', false, true)
        this.PathMenuItem(n, 'rename', '改名', 'rename', false, false)
      } else {
        // v2.5 闭环（方案 A）：星标按钮移除后，树内收藏切换入口收进长按 ⋯ 菜单。
        // 图标名字面量分支（Z2/L-7 首帧固化）。
        this.PathMenuItem(n, 'favorite', this.isFavorite(n.relPath) ? '取消收藏' : '收藏',
          this.isFavorite(n.relPath) ? 'starFilled' : 'star', false, true)
        this.PathMenuItem(n, 'pin', this.isPinned(n.relPath) ? '取消置顶' : '置顶',
          'pin', false, false)
        this.PathMenuItem(n, 'rename', '改名', 'rename', false, false)
      }
      this.PathMenuItem(n, 'move', '移动', 'move', false, false)
      this.PathMenuItem(n, 'delete', '删除', 'trash', true, false)
    }
    .width(Size.touch * 3)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
  }

  @Builder
  TreeList() {
    List() {
      LazyForEach(this.treeSource, (n: TreeNode) => {
        ListItem() {
          Row() {
            ForEach(this.levelsOf(n.depth), (lv: number) => {
              Column()
                .width(Size.treeIndent)
                .height('100%')
                .border({ width: { left: 1 }, color: $r('app.color.line') })
                // 整行只允许有一个命中目标：缩进格和文本都不参与命中，点击一律冒泡到外层 Row
                .hitTestBehavior(HitTestMode.None)
            }, (lv: number) => lv.toString())

            Row({ space: Space.s2 }) {
              if (n.isDir) {
                Icon(this.isExpanded(n.relPath) ? 'chevronDown' : 'chevronRight',
                  Size.treeChevron, $r('app.color.text_tertiary'))
              } else {
                // 占位：让文件名与目录名左对齐（文件没有箭头，用等宽空白顶替）
                Column()
                  .width(Size.treeChevron)
                  .height(Size.treeChevron)
              }
              // 图标颜色不能经全局 @Builder 按值实参传递（api_notes L-7/Z2：首帧固化，
              // 切换笔记后蓝图标停在旧笔记上）。内联 SymbolGlyph（v2.6 官方 Symbol）让
              // .fontColor 与行背景 / 标题色一样直接绑定 currentFilePath，走同一条局部更新通道。
              SymbolGlyph(symbolGlyphOf(n.isDir ? 'folder' : 'note'))
                .fontSize(Size.treeIcon)
                .fontColor([n.isDir ? $r('app.color.brand') : n.relPath === this.currentFilePath
                  ? $r('app.color.brand') : $r('app.color.text_secondary')])
            if (this.referenceOnly && !n.isDir) {
              Column() {
                Text(this.displayName(n))
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(n.relPath)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Center)
            } else {
              Text(this.displayName(n))
                .fontSize(FontSize.body2)
                .fontWeight(n.isDir ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(!n.isDir && n.relPath === this.currentFilePath
                  ? $r('app.color.brand') : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            // v1.50 置顶标记：文件行名字尾部小图钉（不可点，状态由左滑 / 菜单切换）
            if (!n.isDir && this.isPinned(n.relPath)) {
              Icon('pin', 12, $r('app.color.text_tertiary'))
            }
            // v2.5 闭环（方案 A，2026-11-23）：收藏降为名字尾 12vp 状态星标（同图钉
            // 口径：不可点，切换走左滑操作条 / 长按 ⋯ 菜单 / 收藏区行）。行尾 48vp
            // 星标按钮与跨栏按钮在窄侧栏（XT2 三栏 200-248vp）合计 ~96vp，深层笔记
            // 名宽直接归零——缩进封顶（v2.5）单独救不回来。已收藏才渲染
            // （starFilled 字面量，Z2/L-7 首帧固化），行键 |fav 驱动刷新。
            if (!n.isDir && this.isFavorite(n.relPath)) {
              Icon('starFilled', 12, $r('app.color.text_tertiary'))
            }
            }
            .layoutWeight(1)
            .height(Size.itemH)
            .padding({ left: Space.s2, right: Space.s3 })
            .alignItems(VerticalAlign.Center)
            // 见下方 onClick 的踩坑说明：不把子控件排除在命中之外，点文件名会「点不动」
            .hitTestBehavior(HitTestMode.None)

            // （v1.97 树行行尾 48vp 星标按钮已随 v2.5 闭环方案 A 移除：与跨栏按钮在
            // 窄侧栏合计 ~96vp，深层笔记名宽归零；收藏改名字尾 12vp 标记，见上方。）
            // 目录行尾的「+」：在该目录下新建笔记（仅目录行有）。
            // ⚠️ 位置有讲究：必须是内容 Row 的**兄弟**，不能塞进那个 Row 里 ——
            // 内容 Row 整体设了 HitTestMode.None（子树透明，让点击冒泡到外层行），
            // 塞进去的按钮也会变透明、点不动。放在外层行下，它自己吃点击，
            // 不会误触展开/折叠（ArkUI 点击不向祖先行冒泡，最近的处理者消费）。
            // （目录行尾的常驻 trash 按钮已移进 1.6 左滑操作条，见下方 swipeAction）
            if (n.isDir && !this.referenceOnly) {
              Row() {
                Icon('plus', 16, $r('app.color.text_secondary'))
              }
              .width(Size.touch)
              .height(Size.touch)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .onClick(() => {
              hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：新建子目录');
              this.onCreateInDir(n.relPath);
              })
              // v1.10 读屏：纯图标按钮没有可见文字，必须自带名称
              .accessibilityText('在「' + n.name + '」下新建')
            } else if (!n.isDir && !this.referenceOnly && !this.hideOtherPane &&
              !this.isNarrowNav()) {
              Row() {
                Icon('fileReference', Space.s5, $r('app.color.text_secondary'), 1.7)
              }
              .width(Size.touch)
              .height(Size.touch)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .onClick((): void => {
                this.onOpenOtherPane(n.relPath);
              })
              .accessibilityText('在参考栏打开「' + n.name + '」')
            }
          }
          .width('100%')
          .height(this.referenceOnly && !n.isDir ? Size.itemH + Space.s2 : Size.itemH)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.control)
          .backgroundColor(this.dropOverDir === n.relPath ? $r('app.color.brand_bg')
            : !n.isDir && n.relPath === this.currentFilePath
              ? $r('app.color.brand_bg_solid') : Color.Transparent)
          // ⚠️ 踩坑（模拟器实测 2026-10-18）：行内子控件（图标 / 文件名 Text）会**吃掉点击**，
          // 点文件名「点不动」，只有点行的空白处才响应 —— 而目录行因为箭头图标在左侧、
          // 早期测试点到了图标附近才看起来正常。修法是给行内的缩进格与内容 Row 都设
          // `HitTestMode.None`，让整行的点击统一冒泡到这个外层 Row 的 onClick 上。
          .onClick(() => {
            if (n.isDir) {
              this.toggleDir(n.relPath);
            } else if (this.referenceOnly) {
              this.onReferenceNote(n.relPath, this.vaultId);
            } else if (n.relPath !== this.currentFilePath) {
              this.onSelectFile(n.relPath);
            }
          })
          .focusable(true)
          .id(this.treeRowFocusId(n))
          .onKeyEvent((event: KeyEvent): boolean => { return this.onTreeRowKey(n, event); })
          .bindPopup(this.pathMenuPath === n.relPath && !this.referenceOnly, {
            builder: this.PathActionsMenu(n),
            placement: Placement.BottomLeft,
            enableArrow: false,
            offset: { x: 0, y: Space.s1 },
            mask: false,
            autoCancel: true,
            popupColor: Color.Transparent,
            onWillDismiss: (action: DismissPopupAction): void => { this.onPathMenuDismiss(action); }
          })
        }
        .width('100%')
        .padding({ right: Space.s2 })
        // v1.71（71.1）：主树笔记 / 文件夹整行可拖；referenceOnly（Agent 引用树）
        // 保持仅笔记行可拖，Agent 对话区拖放零回归。
        .draggable(!this.referenceOnly || !n.isDir)
        .onDragStart((event: DragEvent): DragItemInfo => {
          this.dragSourcePath = n.relPath;
          this.dragSourceIsDir = n.isDir;
          this.onTreeDragStart(n.relPath, n.isDir);
          // payload 加 isDir：语义由落点决定（目录行 = 移动，正文栏 = 打开）；
          // Agent 侧解析只读 vaultId / path，新增字段不影响旧解析。
          const payload: string = JSON.stringify({ vaultId: this.vaultId, path: n.relPath, isDir: n.isDir });
          // v1.71 修复：官方构造形态（UDMF 文档 ApplicationDefinedRecord 示例）——
          // 类型走 applicationDefinedType（带强制前缀），JSON 走 rawData（Uint8Array）。
          // Agent 侧读取同步改为 rawData 解码，见 AgentWorkspace.readNoteRefText。
          const record: unifiedDataChannel.ApplicationDefinedRecord =
            new unifiedDataChannel.ApplicationDefinedRecord();
          record.applicationDefinedType = NOTE_REF_MIME;
          record.rawData = new util.TextEncoder().encodeInto(payload);
          event.setData(new unifiedDataChannel.UnifiedData(record));
          return { extraInfo: this.referenceOnly ? '当前知识库笔记引用' : '拖动移动或打开' };
        })
        .onDragEnd((event: DragEvent): void => {
          this.dragSourcePath = '';
          this.dragSourceIsDir = false;
          this.dropOverDir = '';
          this.onTreeDragEnd();
        })
        // v1.71 树内移动落点（71.1 / 71.3）：行级 allowDrop + 事件回调里按 canDropIntoDir
        // 过滤。allowDrop 是渲染绑定，LazyForEach 键不变时不会重算（faqs-arkui-219 同机理），
        // 所以这里保持常量接收、把「自身 / 子孙行不允许」放到事件回调（读取实时字段）里拦。
        // referenceOnly 树不接受任何行内落点（Agent 行为零回归）。
        .allowDrop(this.referenceOnly ? null : [NOTE_REF_MIME])
        .onDragEnter((event: DragEvent): void => {
          if (this.canDropIntoDir(n)) {
            this.dropOverDir = n.relPath;
          }
        })
        .onDragLeave((event: DragEvent): void => {
          if (this.dropOverDir === n.relPath) {
            this.dropOverDir = '';
          }
        })
        .onDrop((event: DragEvent): void => {
          const wasOver: boolean = this.dropOverDir === n.relPath;
          if (wasOver) {
            this.dropOverDir = '';
          }
          if (this.referenceOnly || this.dragSourcePath.length === 0) {
            return;
          }
          if (n.isDir) {
            if (this.canDropIntoDir(n)) {
              this.requestDragMove(n.relPath, 3);
            } else if (wasOver || this.dragSourcePath === n.relPath ||
              (this.dragSourceIsDir && n.relPath.startsWith(this.dragSourcePath + '/'))) {
              // 自身 / 子孙行上的 drop = 无操作拦截，避免被 List 兜底解释成「移到库根」。
              this.requestDragMove('', 2);
            }
          } else {
            // 笔记行 drop = 拦截为无操作（71.3：落点语义只在目录行 / 树根 / 正文栏三种）。
            this.requestDragMove('', 2);
          }
        })
        // 左滑三档（1.6）：ListItem.swipeAction（API 24，list_item.d.ts:563 已核实）。
        // - 轻扫拖出操作条（SwipeBar：重命名 / 移动 / 删除）；
        // - 滑过操作条 + swipeDelExtra 再松手 → onAction（第三档）：
        //   文件行 = 移入回收站 + 5 秒撤销（不弹确认框）；目录行 = 空操作（原型不给目录滑到底删除）。
        // - edgeEffect.Spring：越过操作条后有阻尼回弹（原型 DAMP 的系统等价物）。
        .swipeAction({
          end: {
            builder: (): void => {
              if (!this.referenceOnly) {
                this.SwipeBar(n);
              }
            },
            actionAreaDistance: this.referenceOnly ? 0 : Size.swipeDelExtra,
            onAction: (): void => {
              if (!this.referenceOnly && !n.isDir) {
                hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：滑动删除');
                this.onSwipeDelete(n.relPath);
              }
            }
          },
          edgeEffect: SwipeEdgeEffect.Spring
        })
        }, (n: TreeNode) => {
        // ⚠️ 踩坑（2026-10-18 实测 + 官方键值复用规则 faqs-arkui-219，ForEach/LazyForEach 同理）：
        // 键值相同的项不会重新执行 itemGenerator，行子树整体复用 —— 只用 relPath 时，
        // 折叠/展开后 chevron 方向停在旧值（子行消失是因为键被移除，父行键没变）。
        // 选中高亮同机理：不进键值的话，点新文件旧高亮不掉、新高亮不上。
        if (n.isDir) {
          // v1.71：拖拽悬停高亮进键值——不进的话复用行子树背景不刷新（faqs-arkui-219 同机理，
          // 与折叠箭头 / 选中高亮同坑）。drop 结束键回落，行恢复复用。
          return n.relPath + (this.isExpanded(n.relPath) ? '|e' : '|c') +
            (this.dropOverDir === n.relPath ? '|drop' : '');
        }
        // v1.50：置顶态进键值——不进的话切换置顶后行顺序变了、行内 pin 标记不刷新
        // （faqs-arkui-219 官方键值复用规则，与选中高亮同机理）。
        // v1.97：收藏态进键值——星标切换后行子树（星 / 描边星）复用不刷新，同机理。
        return n.relPath + (this.isPinned(n.relPath) ? '|pin' : '') +
          (this.isFavorite(n.relPath) ? '|fav' : '') +
          (n.relPath === this.currentFilePath ? '|s' : '|u');
      })
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: Space.s4, bottom: this.treeBottomClearanceVp() })
    .scrollBar(BarState.Auto)
    .cachedCount(10)
    // v2.5 闭环（方案 A）：实测树宽回填（vp），驱动 isNarrowNav()（跨栏按钮显隐）。
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.treeWidthVp = newArea.width;
      }
    })
    .backgroundColor($r('app.color.bg_navigation'))
    // v1.71 树根空白兜底（71.1）：drop 到行外空白（左侧缩进区 / 末条让位区）= 移到库根，
    // 对齐「移动」对话框的「库根目录」语义；rank 1 会被任何行级 drop（rank 2/3）覆盖。
    .allowDrop(this.referenceOnly ? null : [NOTE_REF_MIME])
    .onDrop((event: DragEvent): void => {
      if (!this.referenceOnly) {
        this.requestDragMove('', 1);
      }
    })
    // 57.7：树 List 底边与安全区边界重合，extend 视口到物理下沿（api_notes AE3），
    // 穿小白条；末条按 treeBottomClearanceVp 让位钉底簇。referenceOnly（Agent 页）
    // 连写条仍在流内 → 底边不与安全区重合 → 天然 no-op，Agent 页零变化。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
