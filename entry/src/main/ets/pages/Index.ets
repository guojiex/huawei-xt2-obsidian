/**
 * Index.ets —— 三形态布局总装 + 库模型接线（v0.1 骨架 / v0.2 视觉基线）
 *
 * 为什么三栏自绘而不用 FoldSplitContainer（api_notes.md A2-bis）：
 * ① 它的「三分栏」不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」，横排列只有 2 个；
 * ② 分栏比例只有预设枚举 LAYOUT_1V1 / LAYOUT_3V2 / LAYOUT_2V3，无 1:1:1；
 * ③ 它为双折叠悬停态设计，三折叠三屏态不在其模型内。
 * （2026-10-18 官方答复亦确认：布局适配优先基于响应式断点，精确对齐折痕非官方要求）
 *
 * 断点只用 windowSizeChange + px2vp（api_notes.md A3 ✅），不用 getFoldDisplayMode 做分支。
 * 布局矩阵：
 *   sm：单栏（编辑 / 预览二选一，顶部分段控件切换）+ 抽屉侧栏
 *   md：侧栏 | 编辑 各 50%；收起 → 编辑 | 预览 各 50%
 *   lg：侧栏 | 编辑 | 预览 各 1/3；收起 → 编辑 2/3（跨第一条折痕，红警示）| 预览 1/3
 *
 * v0.2 §3.5：本文件视觉全部走 token —— 颜色 `$r('app.color.*')`（深色自动切另一套）、
 * 数值 `Space/Radius/FontSize/Size/Motion`（common/Tokens.ets）、图标 `Icon()`（common/Icons.ets）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Breakpoint } from '../model/Breakpoint';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { NoteService } from '../model/NoteService';
import { FileTree } from '../model/FileTree';
import { VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerView } from '../components/VaultManagerView';
import { SettingsView } from '../components/SettingsView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';
import { CreateNoteDialog, DeletePathDialog, RenamePathDialog, MovePathDialog } from '../components/NoteDialogs';
import { TrashView } from '../components/TrashView';
import { QuickSwitcher } from '../components/QuickSwitcher';
import { TrashService, UndoSnap } from '../model/TrashService';
import { RecentOpenStore } from '../model/RecentOpenStore';
import { EditorWebView, EditorBridge } from '../components/EditorWebView';
import { PreviewWebView, PreviewBridge } from '../components/PreviewWebView';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size, Motion } from '../common/Tokens';

const DOMAIN: number = 0x0000;
const TAG: string = 'Index';

/** PaneHead 的按引用传参载体（@Builder 按值传参不随状态刷新，实测标题停在初始值） */
interface PaneHeadParam {
  title: string;
}

/** 状态栏形态标签（与原型 FORMS 一致） */
function formLabelOf(bp: string): string {
  if (bp === Breakpoint.SM) {
    return '外屏合起';
  }
  if (bp === Breakpoint.MD) {
    return '展开双屏';
  }
  return '三屏展开';
}

/** 单屏态分段控件的单个按钮 */
@Extend(Text)
function segItem(active: boolean) {
  .fontSize(FontSize.body3)
  .fontColor(active ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
  .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
  .height(28)
  .padding({ left: Space.s3, right: Space.s3 })
  .textAlign(TextAlign.Center)
  .borderRadius(Radius.full)
  .backgroundColor(active ? $r('app.color.bg_card') : Color.Transparent)
}

@Entry
@Component
struct Index {
  /** 断点档位（EntryAbility 写入 AppStorage；@Watch 在档位变化时收敛抽屉态） */
  @StorageProp('breakpoint') @Watch('onBreakpointChanged') breakpoint: string = Breakpoint.SM;
  /** 窗口宽度 vp（状态栏显示用） */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
  /** display.getFoldStatus() 读数（调试用，-1 = 没取到；api_notes A1） */
  @StorageProp('foldStatus') foldStatus: number = -1;
  /**
   * 折痕中心 x（**px**，多条逗号分隔；'-' = 没取到。api_notes A2 采集通道，不参与布局）。
   * 存 px 而不是 vp：官方提醒 px2vp 应在 UI 上下文换算，故在页面侧 statusRightText() 里转。
   */
  @StorageProp('creasePx') creasePx: string = '-';
  /** 库列表（单一数据源 VaultRegistry；CRUD 后 refreshFromRegistry） */
  @State vaults: VaultEntry[] = [];
  /** 当前库 id */
  @State currentVaultId: string = '';
  /** v0.4 快切面板及当前库候选/最近打开项 */
  @State quickSwitchOpen: boolean = false;
  @State quickSwitchFiles: string[] = [];
  @State recentOpenPaths: string[] = [];
  private recentOpenStore: RecentOpenStore | null = null;
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State sidebarCollapsed: boolean = false;
  /** 次级视图（库管理 / 设置与关于）整体替换内容区；'note' = 笔记主视图（原型 setView 模型） */
  @State topView: string = 'note';
  /**
   * 当前打开文件的**库内相对路径**（如 `docs/架构.md`）。
   *
   * 为什么放在这里而不是放在文件树组件里（需求 1.4）：
   * 折叠父目录只改变「哪些行可见」，不应连带改变正在编辑的文件。
   * 若当前文件由树持有，折叠动作会导致它被清掉（或被迫写例外逻辑绕过清理）。
   * 放在总装页还有一个额外好处：侧栏选中态、编辑区标题、以后的预览来源共用同一份状态，
   * 不存在三处各记一份然后不同步的可能。
   */
  @State currentFilePath: string = '';
  /**
   * M0.5 spike：Web 编辑器（CodeMirror 6）的桥接句柄与「最近一次内容长度」。
   * bridge 由本页创建并传给 EditorWebView（对象引用共享，页面 ready 时内部 bind）。
   * editorLen 只用于观察击键是否过桥，-1 表示尚未有过编辑。
   */
  @State editorLen: number = -1;
  private editorBridge: EditorBridge = new EditorBridge();
  /**
   * 文件树重扫信号（每次 +1 触发一次 rescan）。
   * 为什么不用「更聪明」的方案：树组件自己不知道外部什么时候改了磁盘
   * （没有文件监听），用显式信号换确定性和简单性。
   */
  @State treeSeq: number = 0;
  /**
   * 需要树展开到可见的目标路径。建完笔记置位 → 树展开它的父目录 → 立刻看得见。
   */
  @State revealPath: string = '';
  /** 回收站视图重扫信号（删除 / 恢复 / 撤销后 +1，TrashView 重 list） */
  @State trashSeq: number = 0;
  /**
   * 5 秒撤销条（1.7）：滑到底 / 确认删除把文件移入回收站后弹出。
   * - undoVisible / undoMsg 驱动 UI；undoSnap 是恢复快照（非 @State：不驱动渲染）；
   * - undoTimer 5 秒自动消失（原型 showToast 的 toastTimer）；
   * - 撤销执行 TrashService.restore；失败（原位置重名）toast 原因，条照样收起。
   */
  @State undoVisible: boolean = false;
  @State undoMsg: string = '';
  private undoSnap: UndoSnap | null = null;
  private undoTimer: number = -1;
  /** 单屏态「编辑 / 预览」二选一（v0.2 §3.4-3.3）。
   * 只有一块屏放不下两栏；md/lg 两栏同时可见，这个状态不参与布局。
   */
  @State smMode: string = 'edit';

  /**
   * M2 自动保存（2.3）：编辑器 onChange → 防抖落盘。
   * - `saveTimer`：-1 表示无待触发计时器；切换/后台时清零并立刻 flush。
   * - `lastSavedText`：当前文件「已落盘或已加载」的内容镜像，用于跳过无变化的冗余写，
   *   也防止 Web 的 setContent 回灌 change 事件被误判成新编辑而重写一遍。
   * ⚠️ 切文件 / 新建 / 删除当前文件前必须先 flush 旧文件 —— 否则防抖触发时编辑器已是
   * 新文件内容，却写进旧路径，造成数据损坏（实现见 loadFile / doCreateNote / doDeletePath）。
   */
  private saveTimer: number = -1;
  private lastSavedText: string = '';

  /**
   * M3 预览（3.1/3.2）：marked 渲染器跑在 PreviewWebView 里，本页做「编辑 → 预览」联动。
   * - `previewBridge`：内容 / 笔记目录 / 主题下发句柄（就绪前进队列不丢）；
   * - `lastPreviewText`：已推给预览的内容镜像，跳过无变化的重复渲染；
   * - `previewTimer`：联动防抖 500ms —— 编辑器 change 事件（Web 侧已 300ms 防抖）
   *   到达后不立刻拉全量内容过桥，攒 500ms 再一次，避免连续击键反复渲染。
   */
  private previewBridge: PreviewBridge = new PreviewBridge();
  private lastPreviewText: string = '';
  private previewTimer: number = -1;

  /** 对话框控制器：每次拉起重建（传新鲜目标参数），不复用旧实例防参数过期 */
  private createDialogCtl: CustomDialogController | null = null;
  private renameDialogCtl: CustomDialogController | null = null;
  private deleteDialogCtl: CustomDialogController | null = null;
  private createNoteCtl: CustomDialogController | null = null;
  /** 删除确认（文件/目录）对话框 controller（2026-10-18 方案 A 配套） */
  private deletePathCtl: CustomDialogController | null = null;
  /** 重命名 / 移动对话框 controller（1.6 左滑操作条） */
  private renamePathCtl: CustomDialogController | null = null;
  private movePathCtl: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.refreshFromRegistry();
    this.ensureRecentOpenStore();
  }

  private ensureRecentOpenStore(): void {
    if (this.recentOpenStore === null) {
      this.recentOpenStore = new RecentOpenStore(VaultRegistry.get().abilityContext());
    }
  }

  /** 从注册表刷新库列表与当前库（切库/新建/改名/删除后调用） */
  private refreshFromRegistry(): void {
    const reg: VaultRegistry = VaultRegistry.get();
    this.vaults = reg.list();
    this.currentVaultId = reg.currentId();
  }

  /** 档位变化：抽屉语义只在 sm；切到 md/lg 强制收抽屉，防止回 sm 时意外打开 */
  private onBreakpointChanged(): void {
    if (this.breakpoint !== Breakpoint.SM) {
      this.drawerOpen = false;
    }
  }

  /**
   * 系统返回键/侧滑返回拦截（需求 2.7b；api_notes I-1 / I3.1 已真机核实：侧滑同样触发）。
   * 按优先级依次消费：① sm 抽屉打开 → 关抽屉；② 库管理视图 → 回笔记视图；
   * ③ sm 预览态 → 回编辑态；④ 都不是 → 返 false 走系统默认（退出应用）。
   */
  onBackPress(): boolean {
    if (this.quickSwitchOpen) {
      this.quickSwitchOpen = false;
      return true;
    }
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.topView !== 'note') {
      this.topView = 'note';
      return true;
    }
    if (this.breakpoint === Breakpoint.SM && this.smMode === 'preview') {
      this.smMode = 'edit';
      return true;
    }
    return false;
  }

  /** 页面隐藏（应用退到后台）：立刻落盘，兜底「杀进程重进内容还在」（2.3） */
  onPageHide(): void {
    void this.flushSave();
  }

  /** 当前库名（显示名 = 目录名 = id；注册表兜底） */
  private currentVaultName(): string {
    return this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）';
  }

  /**
   * 选中文件。
   * 单屏态额外做两件事：关抽屉 + 回编辑态 —— 在只有一个栏位的地方点了文件，
   * 默认意图是「看/改它」，而不是开抽屉也不看 preview。
   */
  private onSelectFile(relPath: string): void {
    hilog.info(DOMAIN, TAG, '选中文件 %{public}s', relPath);
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = false;
      this.smMode = 'edit';
    }
    void this.loadFile(relPath);
  }

  /** 打开快切时重新扫描当前库，候选与目录展开状态无关。 */
  private openQuickSwitcher(): void {
    if (this.topView !== 'note' || this.currentVaultId.length === 0) {
      return;
    }
    const registry: VaultRegistry = VaultRegistry.get();
    const files: string[] = FileTree.allMarkdownFiles(registry.vaultDirOf(this.currentVaultId));
    this.ensureRecentOpenStore();
    const store: RecentOpenStore = this.recentOpenStore as RecentOpenStore;
    this.quickSwitchFiles = files;
    this.recentOpenPaths = store.load(this.currentVaultId, files);
    this.quickSwitchOpen = true;
  }

  private selectQuickSwitchFile(relPath: string): void {
    this.quickSwitchOpen = false;
    this.onSelectFile(relPath);
  }

  /**
   * 读取笔记全文并下发给 Web 编辑器（M0.5 spike 的加载路径）。
   * 读文件在 ArkTS 侧做（组件不碰 IO，硬约束 14）；读取失败返回 false，由切换方保留当前笔记并提示。
   * ⚠️ **先更新 `lastSavedText` 再下发给编辑器**：若 Web 的 setContent 回灌一个 change
   * 事件，guard 才能识别「内容没变」跳过冗余写（否则会被当成新编辑重写一遍）。
   */
  private async readAndPush(relPath: string): Promise<boolean> {
    let text: string | null = '';
    if (this.currentVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.tryReadNote(VaultRegistry.get(), this.currentVaultId, relPath);
      if (text === null) {
        return false;
      }
    }
    this.lastSavedText = text;
    await this.editorBridge.setContent(text);
    // M3 联动：文件加载后预览同步本页内容 + 告知笔记目录（相对图片引用的解析基准）
    this.previewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushPreview(text);
    return true;
  }

  /**
   * 切换当前打开的文件（M2 协同 2.3）。
   *
   * ⚠️ **顺序（2026-10-18 修 bug 后定案）**：先把 `currentFilePath` 指向新文件，
   * 再去 flush 旧文件（用捕获的 `prev` 作写入目标），最后加载新内容。
   * 之前写成「先 await flushSave() 再赋值」有两个错：
   *  1. flush 是跨进程 Web 调用（getContent → runJavaScript），一抛错/卡住，
   *     `currentFilePath` 和 readAndPush 就永远不执行 —— 用户表现是「点了文件没反应、
   *     左下角文件名一直停在第一篇」（loadFile 是 void 调用，异常被静默吞掉）。
   *  2. UI（侧栏选中态 / 底部状态栏 / 编辑区标题）都被一次异步 IO 拖住才更新。
   * 改成先切指针后 flush，UI 立刻跟上；flush 用捕获的 prev 写旧内容，**不会串到新路径**。
   */
  private async loadFile(relPath: string): Promise<void> {
    const prev: string = this.currentFilePath;
    const vaultId: string = this.currentVaultId;
    this.currentFilePath = relPath;
    if (!await this.flushSave(prev, vaultId)) {
      this.currentFilePath = prev;
      this.scheduleSave();
      return;
    }
    if (!await this.readAndPush(relPath)) {
      this.currentFilePath = prev;
      promptAction.showToast({ message: '打开笔记失败' });
      return;
    }
    this.ensureRecentOpenStore();
    (this.recentOpenStore as RecentOpenStore).record(vaultId, relPath);
  }

  /**
   * 立刻把编辑器当前内容落盘（防抖到点 / 切文件前 / 后台时调用）。
   *
   * @param targetPath 写入目标，缺省为 `currentFilePath`。切文件时由 loadFile 传入**旧路径**：
   *   那时指针已经指向新文件，但编辑器里还是旧内容，必须写回旧路径。
   *
   * ⚠️ **本函数约定「永不抛错」**：它是尽力而为的保存，调用方（loadFile 切文件、
   *   doDeletePath 删除、onPageHide 后台兜底）都排在关键动作之前，一旦抛出就会
   *   连带把「打开文件 / 删除」整个动作吞掉（void 调用 + 静默 rejection）。
   *   所以 getContent 与 saveNote 两处 IO 都各自包 try/catch。
   */
  private async flushSave(targetPath: string | null = null, targetVaultId: string = ''): Promise<boolean> {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    const path: string = targetPath === null ? this.currentFilePath : targetPath;
    const vaultId: string = targetVaultId.length > 0 ? targetVaultId : this.currentVaultId;
    if (vaultId.length === 0 || path.length === 0) {
      return true;
    }
    // 编辑器未就绪时 getContent 返回 ''，此时落盘会把真实文件清空 —— 必须跳过
    if (!this.editorBridge.ready) {
      return true;
    }
    let text: string = '';
    try {
      text = await this.editorBridge.getContent();
    } catch (error) {
      // 拉不到内容：放弃这次保存（拿空串落盘会清空文件），但绝不让异常外泄挡住调用方
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'flushSave 拉取编辑器内容失败，跳过保存: %{public}s', err.message);
      promptAction.showToast({ message: '保存失败，请稍后重试' });
      return false;
    }
    if (text === this.lastSavedText) {
      return true;
    }
    try {
      await NoteService.saveNote(VaultRegistry.get(), vaultId, path, text);
      this.lastSavedText = text;
      return true;
    } catch (error) {
      this.toastRegistryError('保存失败', error);
      return false;
    }
  }

  /** 编辑器有改动：防抖 800ms 后再落盘，避免每次击键都写盘 */
  private scheduleSave(): void {
    if (this.currentFilePath.length === 0) {
      return;
    }
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      void this.flushSave();
    }, 800);
  }

  // ===== M3 预览联动（3.2 编辑/预览实时联动） =====

  /** 把文本推给预览渲染（相同内容跳过；预览未就绪时进其内部队列不丢） */
  private pushPreview(text: string): void {
    if (text === this.lastPreviewText) {
      return;
    }
    this.lastPreviewText = text;
    this.previewBridge.setContent(text);
  }

  /** 编辑器有改动：防抖 500ms 后从编辑器拉全量内容渲染预览 */
  private schedulePreviewUpdate(): void {
    if (this.previewTimer !== -1) {
      clearTimeout(this.previewTimer);
    }
    this.previewTimer = setTimeout((): void => {
      this.previewTimer = -1;
      void this.updatePreviewFromEditor();
    }, 500);
  }

  /**
   * 从编辑器拉当前内容 → 推给预览。编辑器未就绪时退回 `lastSavedText`
   * （已加载内容的镜像），保证预览永远有东西可渲染而不是空白。
   */
  private async updatePreviewFromEditor(): Promise<void> {
    if (!this.editorBridge.ready) {
      this.pushPreview(this.lastSavedText);
      return;
    }
    let text: string = '';
    try {
      text = await this.editorBridge.getContent();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '预览拉取编辑器内容失败: %{public}s', err.message);
      return;
    }
    this.pushPreview(text);
  }

  /**
   * 读库内图片 → data URI（PreviewWebView 的 readAsset 桥回调，M3 预览「图片」项）。
   * 返回空串 = 图片不存在/不支持，Web 侧显示「图片不存在」。
   */
  private readVaultAsset(relPath: string): string {
    if (this.currentVaultId.length === 0 || relPath.length === 0) {
      return '';
    }
    try {
      return NoteService.readAssetDataUri(VaultRegistry.get(), this.currentVaultId, relPath);
    } catch (error) {
      return '';
    }
  }

  /** 状态栏右侧读数：形态 · vp · FS:N（有折痕时追加 · C:x,y，px 在此换算成 vp） */
  private statusRightText(): string {
    let s: string = formLabelOf(this.breakpoint) + ' · ' + Math.round(this.windowWidthVp) + 'vp' +
      ' · FS:' + this.foldStatus;
    if (this.creasePx !== '-') {
      s += ' · C:' + this.creaseVpText();
    }
    return s;
  }

  /** 折痕 px 串 → vp 串（页面侧换算，UI 上下文里 px2vp 才可靠） */
  private creaseVpText(): string {
    const parts: string[] = this.creasePx.split(',');
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      const px: number = parseInt(parts[i], 10);
      out += (i === 0 ? '' : ',') + (isNaN(px) ? '?' : Math.round(px2vp(px)).toString());
    }
    return out;
  }

  /** 顶栏汉堡：sm = 抽屉开关；md/lg = 收起/唤回切换（toggle） */
  private onHamburger(): void {
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = !this.drawerOpen;
    } else {
      this.sidebarCollapsed = !this.sidebarCollapsed;
    }
  }

  // ===== 库操作（对话框确认后执行；失败 toast + 日志，注册表不落半状态） =====

  private doSwitchVault(id: string): void {
    void this.switchVault(id);
  }

  private async switchVault(id: string): Promise<void> {
    try {
      if (id === this.currentVaultId) {
        return;
      }
      const previousVaultId: string = this.currentVaultId;
      const previousPath: string = this.currentFilePath;
      if (!await this.flushSave(previousPath, previousVaultId)) {
        return;
      }
      VaultRegistry.get().setCurrent(id);
      this.refreshFromRegistry();
      this.currentFilePath = '';
      this.quickSwitchOpen = false;
      this.quickSwitchFiles = [];
      this.recentOpenPaths = [];
      this.drawerOpen = false;
      this.smMode = 'edit';
      await this.readAndPush('');
    } catch (error) {
      this.toastRegistryError('切换库失败', error);
    }
  }

  private doCreateVault(name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const entry: VaultEntry = reg.createLocal(name);
      // 原型行为：新建后自动切到新库（doCreate → switchVault）
      reg.setCurrent(entry.id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('新建库失败', error);
    }
  }

  private doRenameVault(id: string, name: string): void {
    try {
      VaultRegistry.get().rename(id, name);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('改名失败', error);
    }
  }

  private doDeleteVault(id: string): void {
    try {
      VaultRegistry.get().remove(id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /**
   * 新建笔记（顺序不能乱）：
   * 1. `normalizeRelPath` —— 消毒 + 补 `.md`（非法输入在这一步就抛错，不会落到磁盘）；
   * 2. `createNote` —— 逐级补建父目录 + 写空文件，重名自动加后缀；
   * 3. 置 currentFilePath / revealPath / treeSeq —— 让用户立刻看到刚建的那篇。
   * 失败一律 toast，且**不改动任何 UI 状态**（笔记没建成就不该「选中」它）。
   */
  private doCreateNote(rawName: string): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeRelPath(rawName);
      const actual: string = NoteService.createNote(reg, this.currentVaultId, rel);
      // 新笔记是空文件：先 flush 旧文件编辑，再指向新文件并加载空内容（loadFile 内部处理）
      void this.loadFile(actual);
      this.revealPath = actual;
      this.treeSeq++;
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
        this.smMode = 'edit';
      }
    } catch (error) {
      this.toastRegistryError('新建笔记失败', error);
    }
  }

  /**
   * 新建空文件夹（2026-10-18 方案 A：显式「新建文件夹」类型）。
   * 顺序：normalizeDirPath（消毒、不补 .md）→ createFolder（逐级补建父目录、
   * 重名加后缀）→ 记住新文件夹（下次新建默认进里面，与原型 lastDir 同策略）。
   * 不动 currentFilePath：建文件夹不该抢走用户正在编辑的笔记。
   */
  private doCreateFolder(rawName: string): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeDirPath(rawName);
      const actual: string = NoteService.createFolder(reg, this.currentVaultId, rel);
      // （2026-10-18 用户拍板：头部「＋」= 根目录入口，不再记忆上次目录）
      this.revealPath = actual;
      this.treeSeq++;
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
      }
    } catch (error) {
      this.toastRegistryError('新建文件夹失败', error);
    }
  }

  /**
   * 删除文件或整棵目录（1.6 起**只用于目录**：文件删除走 doTrashFile 进回收站）。
   * ⚠️ 不可恢复（目录整棵子树不进回收站，原型语义）—— 调用方必须先过确认框。
   * 删的是正在编辑的文件（或其子孙）时清空编辑器：留着已不存在文件的标题比空着更坏。
   */
  private async doDeletePath(relPath: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      // 删的是当前打开的文件（或其父目录）时：先落盘编辑，再删（删完文件就不复存在，
      // 且必须在 deletePath 之前 await 完，否则 flushSave 的 getContent 在文件已删后
      // 写回会 recreate 一个本该消失的文件）。
      const isCurrent: boolean = this.currentFilePath === relPath
        || this.currentFilePath.startsWith(relPath + '/');
      if (isCurrent) {
        await this.flushSave();
        this.currentFilePath = '';
      }
      NoteService.deletePath(VaultRegistry.get(), this.currentVaultId, relPath);
      this.revealPath = '';
      this.treeSeq++;
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /** 注册表操作失败：固定文案 toast + 详细原因进 hilog（不把异常原文弹给用户） */
  private toastRegistryError(prefix: string, error: Object): void {
    const err = error as Error;
    hilog.warn(DOMAIN, TAG, '%{public}s: %{public}s', prefix, err.message ?? JSON.stringify(error));
    promptAction.showToast({ message: prefix });
  }

  // ===== 1.7 回收站：删除入站 + 5 秒撤销条 =====

  /**
   * 把文件移入回收站（滑到底直接删 / 删除确认框的「确认删除」，文件分支）。
   * 顺序：删的是当前文件 → 先 flush 落盘再移（与 doDeletePath 同一条铁律）；
   * 然后 TrashService.moveToTrash（renameSync 原子移动）→ 刷树/回收站 → 弹 5 秒撤销条。
   * 快照记 wasCurrent：撤销后若是「删的正是这篇」就重新加载它（原型 snap.wasCurrent）。
   */
  private async doTrashFile(relPath: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      const wasCurrent: boolean = this.currentFilePath === relPath;
      if (wasCurrent) {
        await this.flushSave();
      }
      const reg: VaultRegistry = VaultRegistry.get();
      const trashRel: string = TrashService.moveToTrash(reg, this.currentVaultId, relPath);
      if (wasCurrent) {
        this.currentFilePath = '';
      }
      this.treeSeq++;
      this.trashSeq++;
      const name: string = relPath.substring(relPath.lastIndexOf('/') + 1);
      const snap: UndoSnap = { vaultId: this.currentVaultId, relPath: trashRel, wasCurrent: wasCurrent };
      this.showUndo('已移入回收站：「' + name + '」', snap);
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /** 撤销条：弹出（snap 为 null = 无按钮的纯提示条，原型 showToast 的无 undoFn 分支） */
  private showUndo(msg: string, snap: UndoSnap | null): void {
    this.undoMsg = msg;
    this.undoSnap = snap;
    this.undoVisible = true;
    if (this.undoTimer !== -1) {
      clearTimeout(this.undoTimer);
    }
    this.undoTimer = setTimeout((): void => {
      this.undoTimer = -1;
      this.undoVisible = false;
    }, Motion.snack);
  }

  /** 撤销条：收起（点撤销 / 5 秒到点 / 新条覆盖旧条前） */
  private hideUndo(): void {
    if (this.undoTimer !== -1) {
      clearTimeout(this.undoTimer);
      this.undoTimer = -1;
    }
    this.undoVisible = false;
  }

  /** 撤销条「撤销」：从回收站恢复；原位置重名 → 换一条无按钮提示条告知原因（原型同款） */
  private undoTrashRestore(): void {
    const snap: UndoSnap | null = this.undoSnap;
    this.hideUndo();
    if (snap === null) {
      return;
    }
    try {
      TrashService.restore(VaultRegistry.get(), snap.vaultId, snap.relPath);
      this.treeSeq++;
      this.trashSeq++;
      // 删的正是当时在编辑的那篇 → 撤销后重新加载（内容就是删除前 flush 落盘的那份）
      if (snap.wasCurrent && snap.vaultId === this.currentVaultId) {
        void this.loadFile(snap.relPath);
      }
    } catch (error) {
      this.showUndo('原位置已有同名文件，请先处理重名', null);
    }
  }

  /** 回收站视图「恢复」（1.8）：与撤销共用 TrashService.restore；重名 toast 原因 */
  private doRestoreFromTrash(relPath: string): void {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      TrashService.restore(VaultRegistry.get(), this.currentVaultId, relPath);
      this.treeSeq++;
      this.trashSeq++;
    } catch (error) {
      promptAction.showToast({ message: '原位置已有同名文件，请先处理重名' });
    }
  }

  // ===== 1.6 左滑三档：重命名 / 移动 =====

  /**
   * 重命名文件/目录（只改最后一段）。正在编辑的文件被改名 → 指针跟着走
   * （内容不动、只换标题；后续自动保存写到新路径）；父目录被改名 → 前缀替换。
   */
  private doRenamePath(relPath: string, isDir: boolean, newName: string): void {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      const newRel: string = NoteService.renamePath(VaultRegistry.get(),
        this.currentVaultId, relPath, newName, isDir);
      this.ensureRecentOpenStore();
      (this.recentOpenStore as RecentOpenStore).retarget(this.currentVaultId, relPath, newRel, isDir);
      this.retargetCurrent(relPath, newRel, isDir);
      this.treeSeq++;
    } catch (error) {
      this.toastRegistryError('重命名失败', error);
    }
  }

  /** 移动文件/目录到目标目录；revealPath 展开新位置的父目录，移完立刻看得见 */
  private doMovePath(relPath: string, isDir: boolean, destDir: string): void {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      const newRel: string = NoteService.movePath(VaultRegistry.get(),
        this.currentVaultId, relPath, destDir, isDir);
      this.ensureRecentOpenStore();
      (this.recentOpenStore as RecentOpenStore).retarget(this.currentVaultId, relPath, newRel, isDir);
      this.retargetCurrent(relPath, newRel, isDir);
      this.revealPath = newRel;
      this.treeSeq++;
    } catch (error) {
      this.toastRegistryError('移动失败', error);
    }
  }

  /**
   * 改名/移动后把 currentFilePath 指到新路径（文件 = 等值替换；目录 = 前缀替换）。
   * 只处理「正在编辑的正是被改的文件或其子孙」的情况，其他不动。
   */
  private retargetCurrent(oldRel: string, newRel: string, isDir: boolean): void {
    if (this.currentFilePath.length === 0 || oldRel === newRel) {
      return;
    }
    if (!isDir) {
      if (this.currentFilePath === oldRel) {
        this.currentFilePath = newRel;
      }
      return;
    }
    if (this.currentFilePath === oldRel || this.currentFilePath.startsWith(oldRel + '/')) {
      this.currentFilePath = newRel + this.currentFilePath.substring(oldRel.length);
    }
  }

  // ===== 对话框拉起（每次新建 controller 传新鲜参数） =====

  private openCreateDialog(): void {
    this.createDialogCtl = new CustomDialogController({
      builder: CreateVaultDialog({
        onConfirm: (name: string): void => {
          this.doCreateVault(name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createDialogCtl.open();
  }

  /**
   * 打开新建（笔记 / 文件夹）对话框。
   * @param initialDir 预选目录：目录行 + 按钮入口传点击的目录；空串 = 目录树头部「＋」入口，
   *        **固定为 vault 根目录**（2026-10-18 用户拍板：移除底部「新建笔记」按钮，头部「＋」
   *        作为根目录创建入口，与文件夹行尾「＋」（指定目录）两级入口一致，不再记忆上次目录）。
   */
  private openCreateNoteDialog(initialDir: string = ''): void {
    // 目录选择器的候选：全量目录（不受展开状态影响）
    let dirs: string[] = [];
    try {
      dirs = FileTree.allDirs(VaultRegistry.get().vaultDirOf(this.currentVaultId));
    } catch (error) {
      const err = error as Error;
      hilog.warn(0x0001, 'Index', '列目录失败：%{public}s', err.message);
      dirs = [];
    }
    this.createNoteCtl = new CustomDialogController({
      builder: CreateNoteDialog({
        vaultId: this.currentVaultId,
        dirs: dirs,
        initialDir: initialDir,
        onConfirm: (rawName: string, createType: string): void => {
          // 2026-10-18 方案 A：对话框内「笔记 / 文件夹」切换，落到不同的创建方法
          if (createType === 'folder') {
            this.doCreateFolder(rawName);
          } else {
            this.doCreateNote(rawName);
          }
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createNoteCtl.open();
  }

  /**
   * 打开删除确认框（1.6 左滑操作条的「删除」按钮；2026-10-18 方案 A 起目录/文件共用）。
   * 语义分流（原型 note-del 文案）：文件 → 移入回收站 + 5 秒撤销；目录 → 永久删除确认。
   */
  private openDeletePathDialog(relPath: string, isDir: boolean): void {
    this.deletePathCtl = new CustomDialogController({
      builder: DeletePathDialog({
        relPath: relPath,
        isDir: isDir,
        onConfirm: (): void => {
          if (isDir) {
            void this.doDeletePath(relPath);
          } else {
            void this.doTrashFile(relPath);
          }
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deletePathCtl.open();
  }

  /**
   * 打开重命名对话框（1.6 左滑操作条的「重命名」；原型 note-rename / dir-rename）。
   * 文件预填去掉 .md 的名字（确认时 NoteService.renamePath 自动补回）。
   */
  private openRenamePathDialog(relPath: string, isDir: boolean): void {
    const name: string = relPath.substring(relPath.lastIndexOf('/') + 1);
    let initial: string = name;
    if (!isDir) {
      const lower: string = name.toLowerCase();
      if (lower.endsWith(NoteService.EXT)) {
        initial = name.substring(0, name.length - NoteService.EXT.length);
      } else if (lower.endsWith('.markdown')) {
        initial = name.substring(0, name.length - '.markdown'.length);
      }
    }
    this.renamePathCtl = new CustomDialogController({
      builder: RenamePathDialog({
        relPath: relPath,
        isDir: isDir,
        initialName: initial,
        onConfirm: (newName: string): void => {
          this.doRenamePath(relPath, isDir, newName);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.renamePathCtl.open();
  }

  /**
   * 打开移动对话框（1.6 左滑操作条的「移动」；原型 note-move / dir-move）。
   * 目录目标：候选目录剔除自身与子孙（移进自己内部 = 目录消失）；文件目标：全量目录。
   */
  private openMovePathDialog(relPath: string, isDir: boolean): void {
    let dirs: string[] = [];
    try {
      const all: string[] = FileTree.allDirs(VaultRegistry.get().vaultDirOf(this.currentVaultId));
      if (isDir) {
        for (let i = 0; i < all.length; i++) {
          const d: string = all[i];
          if (d !== relPath && !d.startsWith(relPath + '/')) {
            dirs.push(d);
          }
        }
      } else {
        dirs = all;
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(DOMAIN, TAG, '列目录失败：%{public}s', err.message);
      dirs = [];
    }
    this.movePathCtl = new CustomDialogController({
      builder: MovePathDialog({
        relPath: relPath,
        isDir: isDir,
        dirs: dirs,
        onConfirm: (destDir: string): void => {
          this.doMovePath(relPath, isDir, destDir);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.movePathCtl.open();
  }

  private openRenameDialog(id: string): void {
    this.renameDialogCtl = new CustomDialogController({
      builder: RenameVaultDialog({
        initialName: id,
        onConfirm: (name: string): void => {
          this.doRenameVault(id, name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.renameDialogCtl.open();
  }

  private openDeleteDialog(id: string): void {
    this.deleteDialogCtl = new CustomDialogController({
      builder: DeleteVaultDialog({
        vaultId: id,
        onConfirm: (): void => {
          this.doDeleteVault(id);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deleteDialogCtl.open();
  }

  // ===== 视觉构件 =====

  /** 顶栏图标按钮：视觉 22，热区 48（4.x 修正 v0.1 的 32×32 不足） */
  @Builder
  IconButton(name: string, color: ResourceColor, onTap: () => void) {
    Row() {
      Icon(name, 22, color)
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .onClick(onTap)
  }

  /** 单屏态「编辑 / 预览」分段控件（SegmentedButton 观感） */
  @Builder
  SegToggle() {
    Row({ space: 2 }) {
      Text('编辑')
        .segItem(this.smMode === 'edit')
        .onClick(() => {
          this.smMode = 'edit';
        })
      Text('预览')
        .segItem(this.smMode === 'preview')
        .onClick(() => {
          this.smMode = 'preview';
          // 切到预览立刻拉一次编辑器当前内容：Web 侧 change 事件有 300ms 防抖，
          // 点击前刚敲的字可能还没报上来，直接 getContent 才是最新
          void this.updatePreviewFromEditor();
        })
    }
    .padding(2)
    .borderRadius(Radius.full)
    .backgroundColor($r('app.color.bg_secondary'))
  }

  /** 栏头：标题 + （单屏态才有的）编辑/预览切换。⚠️ $$ 按引用传参：按值传参时
   *  @Builder 不随状态刷新（实测：编辑区标题永远停在「源模式」，currentFilePath 变了不动） */
  @Builder
  PaneHead($$: PaneHeadParam) {
    Row() {
      Text($$.title)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.breakpoint === Breakpoint.SM) {
        this.SegToggle()
      }
    }
    .width('100%')
    .height(Size.paneHeadH)
    .padding({ left: Space.s4, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  build() {
    Column() {
      this.Appbar()
      // alignContent = Bottom：给撤销条（自动宽高的子节点）一个「底部居中」的落点；
      // 其余视图都显式铺满 100%×100%，对齐方式对它们没有影响。
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.topView === 'vaults') {
          this.ManagerView()
        } else if (this.topView === 'trash') {
          this.TrashPane()
        } else if (this.topView === 'settings') {
          this.SettingsPane()
        } else if (this.breakpoint === Breakpoint.SM) {
          this.SmContent()
        } else {
          this.WideContent()
        }
        // 5 秒撤销条（1.7）：覆盖在内容之上，底部居中、离底 --sp-6（原型 .undo-bar）
        if (this.undoVisible) {
          this.UndoBar()
        }
        if (this.quickSwitchOpen && this.topView === 'note') {
          QuickSwitcher({
            filePaths: this.quickSwitchFiles,
            recentPaths: this.recentOpenPaths,
            onSelect: (relPath: string): void => {
              this.selectQuickSwitchFile(relPath);
            },
            onClose: (): void => {
              this.quickSwitchOpen = false;
            }
          })
            .width('100%')
            .height('100%')
        }
      }
      .layoutWeight(1)
      .width('100%')
      this.Statusbar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /**
   * 撤销条（1.7，照原型 .undo-bar / HdsSnackBar 观感）：
   * 深底 snack_bg + snack_text 文案 + snack_action 色「撤销」按钮，圆角 --r-snack。
   * 快照为 null 时只显示文案不显示按钮（纯提示条，原型 showToast 无 undoFn 分支）。
   */
  @Builder
  UndoBar() {
    Row({ space: Space.s4 }) {
      Text(this.undoMsg)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.snack_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.undoSnap !== null) {
        Text('撤销')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.snack_action'))
          .onClick(() => {
            this.undoTrashRestore();
          })
      }
    }
    .constraintSize({ maxWidth: '86%' })
    .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
    .borderRadius(Radius.snack)
    .backgroundColor($r('app.color.snack_bg'))
    // 原型 --elev-3 的单层近似（与 VaultMenu 同款）
    .shadow({ radius: 30, color: '#2E000000', offsetX: 0, offsetY: 10 })
    .margin({ bottom: Space.s6 })
  }

  /** 回收站视图（1.8）：整体替换内容区；返回走顶栏 ‹ 与 onBackPress（2.7c 同级） */
  @Builder
  TrashPane() {
    TrashView({
      vaultId: this.currentVaultId,
      refreshSeq: this.trashSeq,
      onRestore: (relPath: string): void => {
        this.doRestoreFromTrash(relPath);
      }
    })
  }

  /**
   * 顶栏（需求 2.7，贴合设计稿）：
   *  - 笔记视图 = 汉堡（sm 抽屉 / md+lg 收起唤回）+ 标题（当前库名）+ 右上「同步 + 设置」图标；
   *  - 次级视图（库管理 / 设置与关于）= 左上角换返回箭头 + 标题「笔记库」/「设置与关于」，
   *    右上图标收敛（设计稿：同步图标仅在笔记视图显示、设置图标在设置视图隐藏）；
   *  - 库管理入口不放在顶栏（侧栏下拉「管理库…」+ 底部「管理库」已覆盖，避免重复）。
   * v0.2 §3.5：高度 56vp、标题 20fp/700、图标热区 48、颜色走 token。
   */
  @Builder
  Appbar() {
    Row() {
      if (this.topView !== 'note') {
        // 次级视图顶栏返回是硬要求（api_notes I3），不依赖系统返回可否拦截
        this.IconButton('back', $r('app.color.text_primary'), (): void => {
          this.topView = 'note';
        })
      } else {
        this.IconButton('menu', $r('app.color.text_secondary'), (): void => {
          this.onHamburger();
        })
      }
      // 原型 VIEW_TITLE：次级视图标题固定为视图名，不显示当前库名
      Text(this.topView === 'note' ? this.currentVaultName()
        : (this.topView === 'vaults' ? '笔记库'
          : (this.topView === 'trash' ? '回收站' : '设置与关于')))
        .fontSize(FontSize.s2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Space.s2, right: Space.s2 })
      if (this.topView === 'note') {
        // 设计稿顶栏右上 = 快切、同步、设置图标
        this.IconButton('search', $r('app.color.text_secondary'), (): void => {
          this.openQuickSwitcher();
        })
        this.IconButton('sync', $r('app.color.text_secondary'), (): void => {
          // 同步（Git 同步是 v0.3 能力）：跳独立「导入仓库」页
          router.pushUrl({ url: 'pages/SyncPage' });
        })
        this.IconButton('settings', $r('app.color.text_secondary'), (): void => {
          this.topView = 'settings';
        })
      }
    }
    .width('100%')
    .height(Size.appbarH)
    .padding({ left: Space.s1, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  /**
   * sm：单栏内容（编辑 / 预览二选一）+ 抽屉侧栏覆盖层（Stack，汉堡开关，点遮罩关闭）。
   * ⚠️ 编辑器**常驻**（Visibility 切换而非 if 卸载，同 git 容器的常驻铁律精神）：
   * 卸载会销毁 Web 实例 —— 800ms 防抖窗口内未落盘的编辑、光标、撤销栈全丢。
   * 预览是纯展示，可随用随挂（内容由 pushPreview 保证一致）。
   */
  @Builder
  SmContent() {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        this.EditorPane(false)
      }
      .width('100%')
      .height('100%')
      .visibility(this.smMode === 'edit' ? Visibility.Visible : Visibility.Hidden)
      if (this.smMode === 'preview') {
        this.PreviewPane()
      }
      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.mask'))
          .onClick(() => {
            this.drawerOpen = false;
          })
        VaultSidebar({
          asDrawer: true,
          vaults: this.vaults,
          currentVaultId: this.currentVaultId,
          currentFilePath: this.currentFilePath,
          refreshSeq: this.treeSeq,
          revealPath: this.revealPath,
          onSwitchVault: (id: string): void => {
            this.doSwitchVault(id);
          },
          onManageVaults: (): void => {
            this.drawerOpen = false;
            this.topView = 'vaults';
          },
          onImportGit: (): void => {
            // 原型 vault-menu 的「导入 Git 仓库…」→ 独立「导入仓库」页（Git 同步属 v0.3）
            this.drawerOpen = false;
            router.pushUrl({ url: 'pages/SyncPage' });
          },
          onCreateNote: (): void => {
            this.drawerOpen = false;
            this.openCreateNoteDialog();
          },
          onCreateInDir: (dirRelPath: string): void => {
            // 抽屉形态先关抽屉：对话框是窗口级弹层，但抽屉+遮罩叠着容易误触
            this.drawerOpen = false;
            this.openCreateNoteDialog(dirRelPath);
          },
          onRenamePath: (relPath: string, isDir: boolean): void => {
            this.drawerOpen = false;
            this.openRenamePathDialog(relPath, isDir);
          },
          onMovePath: (relPath: string, isDir: boolean): void => {
            this.drawerOpen = false;
            this.openMovePathDialog(relPath, isDir);
          },
          onDeletePath: (relPath: string, isDir: boolean): void => {
            this.drawerOpen = false;
            this.openDeletePathDialog(relPath, isDir);
          },
          onSwipeDelete: (relPath: string): void => {
            this.drawerOpen = false;
            void this.doTrashFile(relPath);
          },
          onOpenTrash: (): void => {
            this.drawerOpen = false;
            this.topView = 'trash';
          },
          onSelectFile: (relPath: string): void => {
            this.onSelectFile(relPath);
          }
        })
          .width(Size.drawerW)
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** md/lg：Row 等分（layoutWeight 精确等分，栏边界压折痕） */
  @Builder
  WideContent() {
    Row() {
      if (!this.sidebarCollapsed) {
        // 侧栏（嵌入形态）
        Column() {
          VaultSidebar({
            asDrawer: false,
            vaults: this.vaults,
            currentVaultId: this.currentVaultId,
            currentFilePath: this.currentFilePath,
            refreshSeq: this.treeSeq,
            revealPath: this.revealPath,
            onCollapse: (): void => {
              this.sidebarCollapsed = true;
            },
            onSwitchVault: (id: string): void => {
              this.doSwitchVault(id);
            },
            onManageVaults: (): void => {
              this.topView = 'vaults';
            },
            onImportGit: (): void => {
              // 原型 vault-menu 的「导入 Git 仓库…」→ 独立「导入仓库」页（Git 同步属 v0.3）
              router.pushUrl({ url: 'pages/SyncPage' });
            },
            onCreateNote: (): void => {
              this.openCreateNoteDialog();
            },
            onCreateInDir: (dirRelPath: string): void => {
              this.openCreateNoteDialog(dirRelPath);
            },
            onRenamePath: (relPath: string, isDir: boolean): void => {
              this.openRenamePathDialog(relPath, isDir);
            },
            onMovePath: (relPath: string, isDir: boolean): void => {
              this.openMovePathDialog(relPath, isDir);
            },
            onDeletePath: (relPath: string, isDir: boolean): void => {
              this.openDeletePathDialog(relPath, isDir);
            },
            onSwipeDelete: (relPath: string): void => {
              void this.doTrashFile(relPath);
            },
            onOpenTrash: (): void => {
              this.topView = 'trash';
            },
            onSelectFile: (relPath: string): void => {
              this.onSelectFile(relPath);
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { right: 1 }, color: $r('app.color.line') })

        if (this.breakpoint === Breakpoint.MD) {
          // md 展开：侧栏 | 编辑 各 50%（预览隐藏，原型 applyForm）
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          // lg 展开：侧栏 | 编辑 | 预览 各 1/3
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
          Column() {
            this.PreviewPane()
          }
          .layoutWeight(1)
          .height('100%')
          .border({ width: { left: 1 }, color: $r('app.color.line') })
        }
      } else if (this.breakpoint === Breakpoint.MD) {
        // md 收起：腾出的那一栏给预览 → 编辑 | 预览 各一整块屏
        Column() {
          this.EditorPane(false)
        }
        .layoutWeight(1)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      } else {
        // lg 收起：编辑扩 2/3 —— 会跨越第一条折痕，这是物理限制非 bug；
        // 编辑区内渲染红色虚线折痕警示 + 预览 1/3
        Column() {
          this.EditorPane(true)
        }
        .layoutWeight(2)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 编辑区占位（真实编辑器 v0.2 M2 接入）。
   * showHingeWarning：lg 收起态专用——编辑区扩到 2/3 会跨第一条折痕。
   * 警示线位置 = 编辑区宽的 50%：第一条折痕在整体 1/3 处，编辑区占 2/3，1/3 ÷ 2/3 = 50%。
   * 折痕实际坐标只做读数（api_notes A2：真机返回不可用 / 模拟器可用），**不进布局算式**。
   */
  @Builder
  EditorPane(showHingeWarning: boolean) {
    Column() {
      this.PaneHead({ title: this.currentFilePath.length > 0 ? this.currentFilePath : '源模式' })

      Stack() {
        // M0.5 spike：CodeMirror 6 跑在 Web 组件里（web/mdeditor → rawfile/mdeditor/index.html）。
        // 内容由本页在「选中文件 / 切库」时读好下发；组件本身不碰文件 IO（硬约束 14）。
        EditorWebView({
          bridge: this.editorBridge,
          onChange: (len: number): void => {
            // 编辑中：记长度（观察击键是否过桥正常）+ 触发防抖自动保存（M2 2.3）
            if (len !== this.editorLen) {
              this.editorLen = len;
            }
            this.scheduleSave();
            this.schedulePreviewUpdate();
          },
          onReady: (): void => {
            // 页面就绪后补一次内容加载：EditorWebView 的指令队列保证此前收到的
            // setContent 不丢，但首帧若在选中文件之前就绪，这里再同步一次更稳
            void this.loadFile(this.currentFilePath);
          },
          onError: (msg: string): void => {
            hilog.error(DOMAIN, TAG, '编辑器 Web: %{public}s', msg);
          }
        })

        if (showHingeWarning) {
          // 被内容横跨的折痕：红色虚线竖标（零宽 Column + 左边框）
          Column()
            .width(0)
            .height('100%')
            .border({ width: { left: 2 }, color: $r('app.color.danger'), style: BorderStyle.Dashed })
            .position({ x: '50%' })
          Text('被内容横跨')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .position({ x: '50%', y: Space.s3 })
            .translate({ x: Space.s1 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 预览区（M3 3.1/3.2）：marked 渲染器跑在 Web 组件里（web/mdpreview → rawfile）。
   * 内容由本页在「加载文件 / 编辑器变化（500ms 防抖）/ 切预览」时推送；
   * 本地图片经 readVaultAsset 桥换 data URI。组件不碰文件 IO（硬约束 14）。
   */
  @Builder
  PreviewPane() {
    Column() {
      this.PaneHead({ title: '预览' })
      PreviewWebView({
        bridge: this.previewBridge,
        onReadAsset: (relPath: string): string => {
          return this.readVaultAsset(relPath);
        },
        onError: (msg: string): void => {
          hilog.error(DOMAIN, TAG, '预览 Web: %{public}s', msg);
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 库管理视图：整体替换内容区；返回走顶栏 ‹ 与 onBackPress，组件不自带（2.7c） */
  @Builder
  ManagerView() {
    VaultManagerView({
      vaults: this.vaults,
      currentVaultId: this.currentVaultId,
      onSetCurrent: (id: string): void => {
        this.doSwitchVault(id);
      },
      onRename: (id: string): void => {
        this.openRenameDialog(id);
      },
      onDelete: (id: string): void => {
        this.openDeleteDialog(id);
      },
      onCreate: (): void => {
        this.openCreateDialog();
      }
    })
  }

  /** 设置与关于视图：整体替换内容区；返回走顶栏 ‹ 与 onBackPress（2.7c 同级） */
  @Builder
  SettingsPane() {
    SettingsView({
      breakpoint: this.breakpoint,
      currentVaultId: this.currentVaultId
    })
  }

  /** 状态栏：当前库 + 档位 + vp 宽度（spec FR：状态栏联动断点） */
  @Builder
  Statusbar() {
    Row() {
      // TEMP-MARKER：验证选中链路用，验证完删掉的第三行
      Text(this.currentVaultName() + ' | ' + this.currentFilePath)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
      Blank()
      Text(this.statusRightText())
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Size.statusbarH)
    .padding({ left: Space.s3, right: Space.s3 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }
}
