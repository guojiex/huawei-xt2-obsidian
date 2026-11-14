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
import { FileTree, ExpandStore, PinStore, TreeNode, PinnedNote } from '../model/FileTree';
import { VaultAccess, VaultDirChild, VaultFileStat } from '../model/VaultAccess';
import { VaultRegistry } from '../model/VaultRegistry';
import { Icon } from '../common/Icons';
import { noteDisplayName, noteDisplayNameOfPath } from '../common/NoteDisplayName';
import { FocusRequest } from '../common/FocusRequest';
import { Space, Radius, FontSize, Size, Weight } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { unifiedDataChannel } from '@kit.ArkData';
import { TrashView } from './TrashView';

const TREE_DOMAIN: number = 0x0002;
const TREE_TAG: string = 'FileTreeView';
const NOTE_REF_MIME: string = 'application/x-yaoshi-note-ref';

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
 * 置顶区数据源（v1.62）：与树行**完全独立**的列表段，LazyForEach 键以 `pin-` 开头，
 * 不会和树行键撞复用。行数少（区内滚动上限 5.5 行），但仍走懒加载保持口径一致。
 */
class PinRowDataSource implements IDataSource {
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

  @State nodes: TreeNode[] = [];
  @State expanded: string[] = [];
  @State pinned: string[] = [];
  /** 置顶区可见行（v1.62）：由 PinStore 数组 ∩ 当前库全量笔记解析，陈旧条目自动不显示。 */
  @State pinRows: PinnedNote[] = [];
  /** 置顶区折叠状态，按库持久化（PinStore.loadSectionOpen / saveSectionOpen）。 */
  @State pinSectionOpen: boolean = true;
  @State pinHoverPath: string = '';
  @State pinFocusPath: string = '';
  @State pathMenuPath: string = '';
  @State helpHintOpen: boolean = false;
  /** 57.7：导航条避让高度（px，EntryAbility 发布；px2vp 后即下移量）。 */
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 57.7：钉底簇（左滑提示 + 回收站）实测高（onAreaChange 的 Area.height，单位 vp），用于文件树末条让位。 */
  @State clusterH: number = 0;
  private pathMenuReturnFocusId: string = '';
  private store: ExpandStore | null = null;
  private pinStore: PinStore | null = null;
  private treeSource: TreeRowDataSource = new TreeRowDataSource();
  private pinSource: PinRowDataSource = new PinRowDataSource();

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

  /** 重扫：读出该库的展开状态 → scan → 刷新可见行 */
  private reload(): void {
    this.ensureStore();
    this.ensurePinStore();
    if (this.vaultId.length === 0) {
      this.applyNodes([]);
      this.applyPinRows([]);
      return;
    }
    const store: ExpandStore = this.store as ExpandStore;
    this.expanded = store.load(this.vaultId);
    const pins: PinStore = this.pinStore as PinStore;
    this.pinned = pins.load(this.vaultId);
    this.pinSectionOpen = pins.loadSectionOpen(this.vaultId);
    this.pinHoverPath = '';
    this.pinFocusPath = '';
    hilog.info(TREE_DOMAIN, TREE_TAG, '文件树扫描开始');
    this.rescan();
  }

  /** 按当前 expanded 重新扫描库目录，并同源解析置顶区（v1.62：一次 snapshot 两处用）。 */
  private rescan(): void {
    if (this.vaultId.length === 0) {
      this.applyNodes([]);
      this.applyPinRows([]);
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
    // 折叠文件夹里的置顶笔记也要显示（62.1 核心价值），故置顶区取**全量**笔记而非可见行。
    this.applyPinRows(FileTree.pinnedNotes(FileTree.notesOfEntries(entries), this.pinned));
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
    if (action === 'pin') {
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

  /** 缩进格子数 = 层级数（depth=0 的行不长缩进、也没有引导线） */
  private levelsOf(depth: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < depth; i++) {
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
      // referenceOnly（Agent 引用侧栏）保持纯树，「章节」页签由父级整树隐藏。
      Column() {
        if (!this.referenceOnly && this.pinRows.length > 0) {
          this.PinSection()
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
          Text('左滑操作 · 拖图标到任一栏')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: Space.s2, left: Space.s2, right: Space.s2, bottom: Space.s1 })
            .onHover((isHover: boolean): void => {
              this.helpHintOpen = isHover;
            })
            .accessibilityText('左滑文件可操作；拖动行尾图标到任一栏打开')
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
            onPurge: (relPath: string): void => { this.onPurgeTrash(relPath); }
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
              this.PinRow(row)
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

  /** 置顶区行：首字色块 + 标题 + 所在文件夹 / 行尾取消置顶按钮。 */
  @Builder
  PinRow(row: PinnedNote) {
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

      if (this.pinRowActive(row.relPath)) {
        Row() {
          Icon('pin', Space.s4, $r('app.color.text_tertiary'))
        }
        .width(Size.touch)
        .height(Size.touch)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.icon)
        .onClick((): void => { this.togglePinPath(row.relPath); })
        .accessibilityText('取消置顶：' + row.title)
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
      this.pinHoverPath = isHover ? row.relPath : '';
    })
    .onFocus((): void => { this.pinFocusPath = row.relPath; })
    .onBlur((): void => {
      if (this.pinFocusPath === row.relPath) {
        this.pinFocusPath = '';
      }
    })
    .focusable(true)
    .id('pin-row-' + this.vaultId + ':' + row.relPath)
    .accessibilityText('打开置顶的笔记：' + row.title + '，位于 ' + this.pinLocation(row))
  }

  /** 置顶区左滑操作条：可点「取消置顶」，滑到底松手同样取消（不触发删除）。 */
  @Builder
  PinSwipeBar(row: PinnedNote) {
    Row() {
      Row() {
        Text('取消置顶')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width(Size.touch)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.brand_bg'))
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

  @Builder
  HelpHint() {
    Text('左滑文件可操作；拖动行尾图标到任一栏打开')
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
        Row() {
          Text(this.isPinned(n.relPath) ? '已置顶' : '置顶')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.brand'))
        }
        .width(Size.touch)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.brand_bg'))
        .onClick(() => {
          hilog.info(TREE_DOMAIN, TREE_TAG, '文件树操作：置顶切换');
          this.togglePin(n);
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
        this.PathMenuItem(n, 'pin', this.isPinned(n.relPath) ? '取消置顶' : '置顶',
          'pin', false, true)
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
              Icon(n.isDir ? 'folder' : 'note', Size.treeIcon,
                n.isDir ? $r('app.color.brand') : n.relPath === this.currentFilePath
                  ? $r('app.color.brand') : $r('app.color.text_secondary'), 1.7)
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
            }
            .layoutWeight(1)
            .height(Size.itemH)
            .padding({ left: Space.s2, right: Space.s3 })
            .alignItems(VerticalAlign.Center)
            // 见下方 onClick 的踩坑说明：不把子控件排除在命中之外，点文件名会「点不动」
            .hitTestBehavior(HitTestMode.None)

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
            } else if (!n.isDir && !this.referenceOnly && !this.hideOtherPane) {
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
          .backgroundColor(!n.isDir && n.relPath === this.currentFilePath
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
        .draggable(this.referenceOnly && !n.isDir)
        .onDragStart((event: DragEvent): DragItemInfo => {
          const payload: string = JSON.stringify({ vaultId: this.vaultId, path: n.relPath });
          const record: unifiedDataChannel.UnifiedRecord =
            new unifiedDataChannel.UnifiedRecord(NOTE_REF_MIME, payload);
          event.setData(new unifiedDataChannel.UnifiedData(record));
          return { extraInfo: '当前知识库笔记引用' };
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
          return n.relPath + (this.isExpanded(n.relPath) ? '|e' : '|c');
        }
        // v1.50：置顶态进键值——不进的话切换置顶后行顺序变了、行内 pin 标记不刷新
        // （faqs-arkui-219 官方键值复用规则，与选中高亮同机理）。
        return n.relPath + (this.isPinned(n.relPath) ? '|pin' : '') +
          (n.relPath === this.currentFilePath ? '|s' : '|u');
      })
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: Space.s4, bottom: this.treeBottomClearanceVp() })
    .scrollBar(BarState.Auto)
    .cachedCount(10)
    .backgroundColor($r('app.color.bg_navigation'))
    // 57.7：树 List 底边与安全区边界重合，extend 视口到物理下沿（api_notes AE3），
    // 穿小白条；末条按 treeBottomClearanceVp 让位钉底簇。referenceOnly（Agent 页）
    // 连写条仍在流内 → 底边不与安全区重合 → 天然 no-op，Agent 页零变化。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
