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
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Breakpoint } from '../model/Breakpoint';
import { SAMPLE_VAULT_ID, VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { AgentMemoryStore } from '../model/AgentMemoryStore';
import { AgentRuntime } from '../model/AgentRuntime';
import { NotePathMutationResult, NoteService } from '../model/NoteService';
import { WorkspaceEditGuard } from '../model/WorkspaceEditGuard';
import { FileTree } from '../model/FileTree';
import { WikiLinkCandidate, WikiLinkParser, WikiLinkResolution } from '../model/WikiLinkParser';
import { WikiLinkService, WikiLinkUpdateReport } from '../model/WikiLinkService';
import { ChapterEntry, VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerView } from '../components/VaultManagerView';
import { SettingsView } from '../components/SettingsView';
import { ReleaseHistoryView } from '../components/ReleaseHistoryView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';
import { CreateNoteDialog, DeletePathDialog, RenamePathDialog, MovePathDialog } from '../components/NoteDialogs';
import { QuickSwitcher } from '../components/QuickSwitcher';
import { TrashService, UndoSnap } from '../model/TrashService';
import { RecentOpenStore } from '../model/RecentOpenStore';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { EditorWebView, EditorBridge } from '../components/EditorWebView';
import { PreviewWebView, PreviewBridge, PreviewCaptureResult } from '../components/PreviewWebView';
import { AgentWorkspace } from '../components/AgentWorkspace';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size, Motion } from '../common/Tokens';
import { SplitLayoutStore } from '../model/SplitLayoutStore';
import { EditorPreferenceStore } from '../model/EditorPreferenceStore';
import { PreviewFollowAnchor, PreviewFollowPair, resolvePreviewFollowPair } from '../model/PreviewFollowPolicy';
import { WorkspaceSession, WorkspaceSessionStore, restoreWorkspacePane, workspaceSessionPaths } from '../model/WorkspaceSessionStore';
import {
  DEFAULT_CONTENT_RATIO, clampContentRatio, clampNavigationWidth,
  isSingleLandscapeWindow, navigationWidth
} from '../model/PaneLayout';
import { SplitHandle } from '../components/SplitHandle';
import { ShareNoteDialog, ShareFormatOption } from '../components/ShareNoteDialog';
import { ShareImagePreviewDialog, ShareImagePreviewPage } from '../components/ShareImagePreviewDialog';
import { ShareTextPreviewDialog } from '../components/ShareTextPreviewDialog';
import { NoteShareService } from '../model/NoteShareService';
import { NoteImageShareService } from '../model/NoteImageShareService';
import { NoteTextSharePreview, NoteTextShareService } from '../model/NoteTextShareService';
import { NoteImageService } from '../model/NoteImageService';
import { shouldShowSaveFeedback } from '../model/SaveFeedbackPolicy';
import { ShareArchiveService, ShareSnapshot } from '../model/ShareArchiveService';
import { ShareLinkService, ShareLinkScope } from '../model/ShareLinkService';
import { FullTextSearchService } from '../model/FullTextSearchService';
import { FullTextSearchResult } from '../model/SearchIndex';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

const DOMAIN: number = 0x0000;
const TAG: string = 'Index';

/** PaneHead 的按引用传参载体（@Builder 按值传参不随状态刷新，实测标题停在初始值） */
interface PaneHeadParam {
  pane: string;
}

/** 窗口宽度档位标签；不把断点直接解释成物理屏幕形态。 */
function formLabelOf(bp: string, widthVp: number, heightVp: number): string {
  if (isSingleLandscapeWindow(widthVp, heightVp)) {
    return '单屏横向窗口';
  }
  if (bp === Breakpoint.SM) {
    return '窄窗口';
  }
  if (bp === Breakpoint.MD) {
    return '中宽窗口';
  }
  return '宽窗口';
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
  /** 窗口当前高度 vp，Agent 矮窗口输入区按真实尺寸收敛。 */
  @StorageProp('windowHeightVp') windowHeightVp: number = 0;
  /** 系统软键盘底部避让高度（px，由 EntryAbility 发布）。 */
  @StorageProp('keyboardInsetPx') @Watch('onFormatKeyboardInsetChanged') keyboardInsetPx: number = 0;
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
  @State @Watch('onFormatContextChanged') currentVaultId: string = '';
  /** 当前库内 Markdown 笔记数量（随注册表和文件树刷新） */
  @State currentVaultNoteCount: number = 0;
  /** v0.4 快切面板及当前库候选/最近打开项 */
  @State quickSwitchOpen: boolean = false;
  @State quickSwitchFiles: string[] = [];
  @State recentOpenPaths: string[] = [];
  private recentOpenStore: RecentOpenStore | null = null;
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State @Watch('onFormatContextChanged') sidebarCollapsed: boolean = false;
  /** 次级视图（库管理 / 设置与关于）整体替换内容区；'note' = 笔记主视图（原型 setView 模型） */
  @State @Watch('onFormatContextChanged') topView: string = 'note';
  @State agentKitSlotBuilder: WrappedBuilder<[() => void]> | null = null;
  @State vaultManagerReturnView: string = 'note';
  @State settingsReturnView: string = 'note';
  @State settingsCategory: string = 'general';
  @State settingsDetail: boolean = false;
  @State agentTitle: string = '新对话';
  @State agentHamburgerSeq: number = 0;
  @State agentRenameSeq: number = 0;
  @State moreMenuOpen: boolean = false;
  @State formatMenuOpen: boolean = false;
  @State formatMenuPane: string = 'left';
  @State formatPopupPlacement: Placement = Placement.Top;
  @State formatPopupOffsetX: number = 0;
  @State formatPopupOffsetY: number = -Space.s2;
  @State formatMenuWidth: number = Size.formatMenuW;
  @State formatMenuMaxHeight: number = Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2;
  private leftFormatPaneArea: number[] = [0, 0, 0, 0];
  private rightFormatPaneArea: number[] = [0, 0, 0, 0];
  private leftFormatAnchorArea: number[] = [0, 0, 0, 0];
  private rightFormatAnchorArea: number[] = [0, 0, 0, 0];
  private formatWindowArea: number[] = [0, 0, 0, 0];
  private formatMenuSourceVaultId: string = '';
  private formatMenuSourcePath: string = '';
  @State navigationRatio: number = -1;
  @State contentRatio: number = DEFAULT_CONTENT_RATIO;
  @State sidebarProgress: number = 1;
  @State drawerProgress: number = 0;
  @State splitDragging: boolean = false;
  private layoutBreakpoint: string = '';
  private splitLayoutStore: SplitLayoutStore | null = null;
  private editorPreferenceStore: EditorPreferenceStore | null = null;
  private agentKitLoadStarted: boolean = false;
  private readonly agentKitUnavailableInSimulator: boolean =
    deviceInfo.productModel.toLowerCase().indexOf('emulator') >= 0;
  private readonly xiaoyiDialogClosed = (): void => {
    void this.refreshWorkspaceAfterXiaoyi();
  };
  private workspaceSessionStore: WorkspaceSessionStore | null = null;
  private pendingWorkspaceSession: WorkspaceSession | null = null;
  private workspaceSessionRestoreStarted: boolean = false;
  private workspaceSessionRestoring: boolean = false;
  private workspaceSessionSavingEnabled: boolean = false;
  private workspaceSessionSaveTimer: number = -1;
  private workspaceOpenRequests: number = 0;
  private committedLeftPath: string = '';
  private committedRightPath: string = '';
  private pendingRestoredChapterOffset: number = -1;
  @State sidebarTab: string = 'files';
  private leftEditorScrollTop: number = 0;
  private leftPreviewScrollTop: number = 0;
  private rightEditorScrollTop: number = 0;
  private rightPreviewScrollTop: number = 0;
  private navigationDragStart: number = 0;
  private contentDragStart: number = 0;
  /**
   * 当前打开文件的**库内相对路径**（如 `docs/架构.md`）。
   *
   * 为什么放在这里而不是放在文件树组件里（需求 1.4）：
   * 折叠父目录只改变「哪些行可见」，不应连带改变正在编辑的文件。
   * 若当前文件由树持有，折叠动作会导致它被清掉（或被迫写例外逻辑绕过清理）。
   * 放在总装页还有一个额外好处：侧栏选中态、编辑区标题、以后的预览来源共用同一份状态，
   * 不存在三处各记一份然后不同步的可能。
   */
  @State @Watch('onFormatContextChanged') currentFilePath: string = '';
  /** v2 的第二栏单独记住笔记；同篇双编辑仍通过现有 NoteService 保存到同一文件。 */
  @State @Watch('onFormatContextChanged') rightFilePath: string = '';
  @State @Watch('onFormatContextChanged') rightEditing: boolean = false;
  @State showLineNumbers: boolean = false;
  @State followPreviewEnabled: boolean = true;
  private previewFollowPairKey: string = '';
  private previewFollowPane: string = '';
  @State @Watch('onFormatContextChanged') activePane: string = 'left';
  @State @Watch('onFormatContextChanged') referenceVisible: boolean = true;
  @State @Watch('onFormatContextChanged') focused: boolean = false;
  @State paneMoreOpen: boolean = false;
  @State paneMorePane: string = 'left';
  @State leftPaneWidthVp: number = 0;
  @State rightPaneWidthVp: number = 0;
  @State leftComposing: boolean = false;
  @State rightComposing: boolean = false;
  @State rightEditorDirty: boolean = false;
  @State rightEditorLen: number = 0;
  @State leftCodeBlockActive: boolean = false;
  @State rightCodeBlockActive: boolean = false;
  @State rightImagePickerBusy: boolean = false;
  @State chapterEntries: ChapterEntry[] = [];
  @State selectedChapterIndex: number = -1;
  @State chapterPath: string = '';
  private rightEditorBridge: EditorBridge = new EditorBridge();
  private rightPreviewBridge: PreviewBridge = new PreviewBridge();
  private rightSaveTimer: number = -1;
  private rightLastSavedText: string = '';
  private rightLastPreviewText: string = '';
  @State backlinkPaths: string[] = [];
  @State backlinksExpanded: boolean = false;
  @State backlinksPane: string = 'left';
  @State backlinksLoading: boolean = false;
  @State backlinksFailed: boolean = false;
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
  @State @Watch('onFormatContextChanged') smMode: string = 'edit';

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
  @State editorDirty: boolean = false;
  @State imagePickerBusy: boolean = false;
  @State saveFeedbackMounted: boolean = false;
  @State saveFeedbackOpacity: number = 0;
  @State saveFeedbackWorkspaceBottomVp: number = 0;
  private saveFeedbackTimer: number = -1;
  private saveFeedbackFadeTimer: number = -1;
  private saveFeedbackRevision: number = 0;

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
  private shareNoteCtl: CustomDialogController | null = null;
  private shareImagePreviewCtl: CustomDialogController | null = null;
  private shareTextPreviewCtl: CustomDialogController | null = null;
  private shareCaptureBridge: PreviewBridge = new PreviewBridge();
  private readonly shareCaptureComponentId: string = 'note-image-share-capture';
  private shareCaptureReadyResolver: (() => void) | null = null;
  private shareCaptureReadyRejecter: ((error: Error) => void) | null = null;
  private shareCaptureReadyTimer: number = -1;
  private shareCaptureCancelled: boolean = false;
  private shareImagePreviewSessionId: string = '';
  private shareImagePreviewTitle: string = '';
  @State shareCaptureActive: boolean = false;
  @State shareCaptureStatus: string = '正在准备分享图片…';
  @State shareImagePreviewPages: ShareImagePreviewPage[] = [];

  aboutToAppear(): void {
    void this.loadAgentKitSlot();
    this.refreshFromRegistry();
    this.ensureEditorPreferenceStore();
    this.showLineNumbers = (this.editorPreferenceStore as EditorPreferenceStore).showLineNumbers();
    this.followPreviewEnabled = (this.editorPreferenceStore as EditorPreferenceStore).followPreview();
    this.synchronizePreviewFollowContext();
    this.ensureRecentOpenStore();
    this.ensureSplitLayoutStore();
    const splitState = (this.splitLayoutStore as SplitLayoutStore).load();
    this.navigationRatio = splitState.navigationRatio;
    this.contentRatio = splitState.contentRatio;
    this.syncNavigationForBreakpoint();
    this.ensureWorkspaceSessionStore();
    this.pendingWorkspaceSession = (this.workspaceSessionStore as WorkspaceSessionStore).load();
  }

  private async loadAgentKitSlot(): Promise<void> {
    if (this.agentKitUnavailableInSimulator || this.agentKitLoadStarted) {
      return;
    }
    this.agentKitLoadStarted = true;
    try {
      const agentModule: ESObject = await import('../components/AgentKitSlot');
      const getAgentKitSlotBuilder: () => WrappedBuilder<[() => void]> =
        agentModule.getAgentKitSlotBuilder as () => WrappedBuilder<[() => void]>;
      this.agentKitSlotBuilder = getAgentKitSlotBuilder();
    } catch (error) {
      this.agentKitLoadStarted = false;
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '加载 AgentKit 入口失败，错误码 %{public}d', err.code);
    }
  }

  private ensureSplitLayoutStore(): void {
    if (this.splitLayoutStore === null) {
      this.splitLayoutStore = new SplitLayoutStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureEditorPreferenceStore(): void {
    if (this.editorPreferenceStore === null) {
      this.editorPreferenceStore = new EditorPreferenceStore(VaultRegistry.get().abilityContext());
    }
  }

  private setShowLineNumbers(show: boolean): void {
    this.showLineNumbers = show;
    this.ensureEditorPreferenceStore();
    (this.editorPreferenceStore as EditorPreferenceStore).saveShowLineNumbers(show);
  }

  private currentPreviewFollowPair(): PreviewFollowPair | null {
    return resolvePreviewFollowPair({
      topView: this.topView,
      vaultId: this.currentVaultId,
      leftPath: this.currentFilePath,
      rightPath: this.rightFilePath,
      leftEditing: this.smMode === 'edit',
      rightEditing: this.rightEditing,
      bothPanesVisible: !this.isSingleScreenLayout() && this.isReferenceShown()
    });
  }

  private previewBridgeForPane(pane: string): PreviewBridge {
    return pane === 'right' ? this.rightPreviewBridge : this.previewBridge;
  }

  private editorBridgeForPane(pane: string): EditorBridge {
    return pane === 'right' ? this.rightEditorBridge : this.editorBridge;
  }

  private synchronizePreviewFollowContext(): PreviewFollowPair | null {
    const pair: PreviewFollowPair | null = this.currentPreviewFollowPair();
    if (!this.followPreviewEnabled || pair === null) {
      if (this.previewFollowPane.length > 0) {
        this.previewBridgeForPane(this.previewFollowPane).cancelSourceFollow();
      }
      this.previewFollowPairKey = '';
      this.previewFollowPane = '';
      return null;
    }
    if (pair.key !== this.previewFollowPairKey) {
      if (this.previewFollowPane.length > 0) {
        this.previewBridgeForPane(this.previewFollowPane).cancelSourceFollow();
      }
      this.previewBridgeForPane(pair.previewPane).cancelSourceFollow();
      this.previewFollowPairKey = pair.key;
      this.previewFollowPane = pair.previewPane;
      this.editorBridgeForPane(pair.sourcePane).reportVisibleSourceAnchor();
    }
    return pair;
  }

  private handlePreviewFollowSourceScroll(pane: string, anchor: PreviewFollowAnchor): void {
    const pair: PreviewFollowPair | null = this.synchronizePreviewFollowContext();
    if (pair === null || pair.sourcePane !== pane) {
      return;
    }
    this.previewBridgeForPane(pair.previewPane).scrollToSourceLine(anchor);
  }

  private setPreviewFollowEnabled(enabled: boolean): void {
    this.followPreviewEnabled = enabled;
    this.ensureEditorPreferenceStore();
    (this.editorPreferenceStore as EditorPreferenceStore).saveFollowPreview(enabled);
    this.synchronizePreviewFollowContext();
  }

  private shouldShowPreviewFollowToggle(pane: string): boolean {
    const pair: PreviewFollowPair | null = this.currentPreviewFollowPair();
    return pair !== null && pair.previewPane === pane;
  }

  private ensureWorkspaceSessionStore(): void {
    if (this.workspaceSessionStore === null) {
      this.workspaceSessionStore = new WorkspaceSessionStore(VaultRegistry.get().abilityContext());
    }
  }

  /** 首次编辑器桥接就绪后恢复；没有有效快照时沿用原有空工作区启动行为。 */
  private async initializeWorkspaceSession(): Promise<void> {
    if (this.workspaceSessionRestoreStarted) {
      return;
    }
    this.workspaceSessionRestoreStarted = true;
    const session: WorkspaceSession | null = this.pendingWorkspaceSession;
    if (session === null) {
      const registry: VaultRegistry = VaultRegistry.get();
      const initialNotePath: string = registry.firstInstallNotePath();
      if (initialNotePath.length > 0 && registry.currentId() === SAMPLE_VAULT_ID) {
        this.currentFilePath = initialNotePath;
        if (await this.readAndPush(initialNotePath)) {
          this.flushWorkspaceSessionSave();
          registry.markFirstInstallNoteOpened();
        } else {
          this.currentFilePath = '';
          await this.readAndPush('');
        }
        return;
      }
      await this.readAndPush(this.currentFilePath);
      return;
    }

    this.workspaceSessionRestoring = true;
    this.workspaceSessionSavingEnabled = false;
    let leftOpened: boolean = false;
    let rightOpened: boolean = false;
    try {
      const registry: VaultRegistry = VaultRegistry.get();
      const hasVault: boolean = registry.list().some((entry: VaultEntry): boolean => entry.id === session.vaultId);
      if (!hasVault) {
        leftOpened = await restoreWorkspacePane('', async (path: string): Promise<boolean> =>
          await this.readAndPush(path, false), async (): Promise<void> => {
            this.currentFilePath = '';
            await this.readAndPush('', false);
          });
        rightOpened = await restoreWorkspacePane('', async (path: string): Promise<boolean> =>
          await this.readRightAndPush(path), async (): Promise<void> => {
            this.rightFilePath = '';
            await this.readRightAndPush('');
          });
        return;
      }
      if (registry.currentId() !== session.vaultId) {
        registry.setCurrent(session.vaultId);
        this.refreshFromRegistry();
      }

      const validPaths: string[] = FileTree.allMarkdownFiles(registry.vaultDirOf(session.vaultId));
      const desiredPaths = workspaceSessionPaths(session, this.isSingleScreenLayout(), validPaths);
      const leftPath: string = desiredPaths.leftPath;
      const rightPath: string = desiredPaths.rightPath;

      this.referenceVisible = session.referenceVisible;
      this.focused = session.focused;
      this.setSidebarCollapsed(session.sidebarCollapsed);
      this.setDrawerOpen(this.breakpoint === Breakpoint.SM && session.drawerOpen);
      this.smMode = session.leftMode;
      this.rightEditing = session.rightEditing;
      this.activePane = session.activePane;
      this.sidebarTab = session.sidebarTab;
      this.selectedChapterIndex = -1;
      this.chapterPath = '';
      this.pendingRestoredChapterOffset = session.selectedChapterOffset;
      this.currentFilePath = leftPath;
      this.rightFilePath = rightPath;
      this.committedLeftPath = '';
      this.committedRightPath = '';
      this.leftEditorScrollTop = session.leftEditorScrollTop;
      this.leftPreviewScrollTop = session.leftPreviewScrollTop;
      this.rightEditorScrollTop = session.rightEditorScrollTop;
      this.rightPreviewScrollTop = session.rightPreviewScrollTop;
      if (this.isSingleScreenLayout()) {
        if (session.activePane === 'right') {
          this.leftEditorScrollTop = 0;
          this.leftPreviewScrollTop = 0;
        } else {
          this.rightEditorScrollTop = 0;
          this.rightPreviewScrollTop = 0;
        }
      }

      leftOpened = await restoreWorkspacePane(leftPath,
        async (path: string): Promise<boolean> => await this.readAndPush(path, false),
        async (): Promise<void> => {
          this.currentFilePath = '';
          await this.readAndPush('', false);
        });
      rightOpened = await restoreWorkspacePane(rightPath,
        async (path: string): Promise<boolean> => await this.readRightAndPush(path),
        async (): Promise<void> => {
          this.rightFilePath = '';
          await this.readRightAndPush('');
        });
      this.restoreWorkspaceScrollPositions();
      this.applyRestoredChapterSelection();
    } catch (error) {
      leftOpened = false;
      rightOpened = false;
      this.currentFilePath = '';
      this.rightFilePath = '';
      this.sidebarTab = 'files';
      this.pendingRestoredChapterOffset = -1;
      this.committedLeftPath = '';
      this.committedRightPath = '';
      await restoreWorkspacePane('', async (path: string): Promise<boolean> =>
        await this.readAndPush(path, false), async (): Promise<void> => {
          await this.readAndPush('', false);
        });
      await restoreWorkspacePane('', async (path: string): Promise<boolean> =>
        await this.readRightAndPush(path), async (): Promise<void> => {
          await this.readRightAndPush('');
        });
    } finally {
      this.workspaceSessionRestoring = false;
      this.workspaceSessionSavingEnabled = leftOpened || rightOpened;
      if (this.workspaceSessionSavingEnabled) {
        this.scheduleWorkspaceSessionSave();
      }
    }
  }

  private restoreWorkspaceScrollPositions(): void {
    try {
      this.editorBridge.restoreScrollTop(this.leftEditorScrollTop);
      this.previewBridge.restoreScrollTop(this.leftPreviewScrollTop);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '恢复左栏滚动位置失败');
    }
    try {
      this.rightEditorBridge.restoreScrollTop(this.rightEditorScrollTop);
      this.rightPreviewBridge.restoreScrollTop(this.rightPreviewScrollTop);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '恢复右栏滚动位置失败');
    }
  }

  private applyRestoredChapterSelection(): void {
    const path: string = this.activeFilePath();
    if (path.length === 0) {
      this.pendingRestoredChapterOffset = -1;
      this.selectedChapterIndex = -1;
      this.sidebarTab = 'files';
      return;
    }
    if (this.chapterPath !== path) {
      return;
    }
    if (this.pendingRestoredChapterOffset >= 0) {
      this.selectedChapterIndex = -1;
      for (let i: number = 0; i < this.chapterEntries.length; i++) {
        if (this.chapterEntries[i].offset === this.pendingRestoredChapterOffset) {
          this.selectedChapterIndex = this.chapterEntries[i].index;
          break;
        }
      }
      this.pendingRestoredChapterOffset = -1;
    }
    if (this.sidebarTab === 'chapters' && this.chapterEntries.length === 0) {
      this.sidebarTab = 'files';
    }
  }

  private updateWorkspaceScroll(pane: string, mode: string, top: number): void {
    if (this.workspaceSessionRestoring) {
      return;
    }
    const safeTop: number = Number.isFinite(top) ? Math.max(0, top) : 0;
    if (pane === 'right') {
      if (mode === 'edit') {
        this.rightEditorScrollTop = safeTop;
        this.rightEditorBridge.rememberScrollTop(safeTop);
      } else {
        this.rightPreviewScrollTop = safeTop;
        this.rightPreviewBridge.rememberScrollTop(safeTop);
      }
    } else if (mode === 'edit') {
      this.leftEditorScrollTop = safeTop;
      this.editorBridge.rememberScrollTop(safeTop);
    } else {
      this.leftPreviewScrollTop = safeTop;
      this.previewBridge.rememberScrollTop(safeTop);
    }
    this.scheduleWorkspaceSessionSave();
  }

  private scheduleWorkspaceSessionSave(): void {
    if (!this.workspaceSessionSavingEnabled || this.workspaceSessionRestoring || this.topView !== 'note' ||
      this.workspaceOpenRequests > 0 || this.currentVaultId.length === 0) {
      return;
    }
    if (this.workspaceSessionSaveTimer !== -1) {
      clearTimeout(this.workspaceSessionSaveTimer);
    }
    this.workspaceSessionSaveTimer = setTimeout((): void => {
      this.workspaceSessionSaveTimer = -1;
      this.saveWorkspaceSessionNow();
    }, 450);
  }

  private flushWorkspaceSessionSave(): void {
    if (this.workspaceSessionSaveTimer !== -1) {
      clearTimeout(this.workspaceSessionSaveTimer);
      this.workspaceSessionSaveTimer = -1;
    }
    this.saveWorkspaceSessionNow();
  }

  private stopWorkspaceSessionSaving(): void {
    this.workspaceSessionSavingEnabled = false;
    if (this.workspaceSessionSaveTimer !== -1) {
      clearTimeout(this.workspaceSessionSaveTimer);
      this.workspaceSessionSaveTimer = -1;
    }
  }

  private saveWorkspaceSessionNow(): void {
    if (!this.workspaceSessionSavingEnabled || this.workspaceSessionRestoring || this.topView !== 'note' ||
      this.workspaceOpenRequests > 0 || this.currentVaultId.length === 0) {
      return;
    }
    const chapterOffset: number = this.chapterPath === this.activeFilePath() && this.selectedChapterIndex >= 0 &&
      this.selectedChapterIndex < this.chapterEntries.length
      ? this.chapterEntries[this.selectedChapterIndex].offset : -1;
    const session: WorkspaceSession = {
      schemaVersion: 1,
      vaultId: this.currentVaultId,
      leftPath: this.committedLeftPath,
      rightPath: this.committedRightPath,
      leftMode: this.smMode,
      rightEditing: this.rightEditing,
      activePane: this.activePane,
      referenceVisible: this.referenceVisible,
      sidebarCollapsed: this.sidebarCollapsed,
      drawerOpen: this.drawerOpen,
      focused: this.focused,
      sidebarTab: this.sidebarTab,
      selectedChapterOffset: chapterOffset,
      leftEditorScrollTop: this.leftEditorScrollTop,
      leftPreviewScrollTop: this.leftPreviewScrollTop,
      rightEditorScrollTop: this.rightEditorScrollTop,
      rightPreviewScrollTop: this.rightPreviewScrollTop
    };
    this.ensureWorkspaceSessionStore();
    const saved: boolean = (this.workspaceSessionStore as WorkspaceSessionStore).save(session);
    if (!saved) {
      hilog.warn(DOMAIN, TAG, '工作区会话保存失败');
    }
  }

  private isSingleLandscape(): boolean {
    return isSingleLandscapeWindow(this.windowWidthVp, this.windowHeightVp);
  }

  private workspaceGutter(): number {
    if (this.breakpoint === Breakpoint.SM || (this.windowHeightVp > 0 && this.windowHeightVp < 480)) {
      return Space.s2;
    }
    return this.breakpoint === Breakpoint.MD ? Space.s3 : Space.s5;
  }

  private isSingleScreenLayout(): boolean {
    return this.breakpoint === Breakpoint.SM || this.isSingleLandscape();
  }

  private noteNavigationWidth(): number {
    const contentPanes: number = this.breakpoint === Breakpoint.LG && !this.isSingleLandscape() ? 2 : 1;
    const ratio: number = this.navigationRatio < 0 && this.breakpoint === Breakpoint.MD
      ? 0.38 : this.navigationRatio;
    return navigationWidth(this.windowWidthVp, ratio, contentPanes, 0);
  }

  private drawerNavigationWidth(): number {
    return Math.min(Size.drawerW, this.windowWidthVp);
  }

  private agentNavigationWidth(): number {
    return navigationWidth(this.windowWidthVp, this.navigationRatio, 1, 1);
  }

  private noteContentWidth(): number {
    const progress: number = this.focused ? 0 : this.sidebarProgress;
    const navWidth: number = this.noteNavigationWidth() * progress;
    return Math.max(0, this.windowWidthVp - navWidth);
  }

  private noteNavigationProgress(): number {
    return this.focused ? 0 : this.sidebarProgress;
  }

  private noteContentRatio(): number {
    return clampContentRatio(this.contentRatio, this.noteContentWidth());
  }

  private settingsPaneWidthSummary(): string {
    const totalWidth: number = this.windowWidthVp;
    if (totalWidth <= 0) {
      return '—';
    }
    const singleScreenLayout: boolean = this.isSingleScreenLayout();
    const navigationVisible: boolean = !singleScreenLayout &&
      !this.sidebarCollapsed && !this.focused;
    const sidebarWidth: number = navigationVisible
      ? this.noteNavigationWidth() * this.sidebarProgress : 0;
    const contentWidth: number = Math.max(0, totalWidth - sidebarWidth);
    let leftWidth: number = contentWidth;
    let rightWidth: number = 0;
    if (singleScreenLayout || this.focused) {
      leftWidth = this.activePane === 'left' ? totalWidth : 0;
      rightWidth = this.activePane === 'right' ? totalWidth : 0;
    } else if (this.breakpoint === Breakpoint.MD) {
      rightWidth = this.referenceVisible ? totalWidth * 0.5 * (1 - this.sidebarProgress) : 0;
      leftWidth = Math.max(0, contentWidth - rightWidth);
    } else if (this.breakpoint === Breakpoint.LG && this.referenceVisible) {
      leftWidth = contentWidth * this.noteContentRatio();
      rightWidth = contentWidth - leftWidth;
    }
    const percent = (width: number): string => (width / totalWidth * 100).toFixed(1) + '%';
    return '目录 ' + percent(sidebarWidth) + ' · 左栏 ' + percent(leftWidth) + ' · 右栏 ' + percent(rightWidth);
  }

  private notePaneWidth(pane: string): Length {
    if (this.isSingleScreenLayout() || this.focused) {
      return this.activePane === pane ? '100%' : 0;
    }
    if (this.breakpoint === Breakpoint.MD) {
      const rightWidth: number = this.referenceVisible
        ? this.windowWidthVp * 0.5 * (1 - this.sidebarProgress) : 0;
      if (pane === 'right') {
        return rightWidth;
      }
      return this.referenceVisible ? this.noteContentWidth() - rightWidth : this.noteContentWidth();
    }
    if (pane === 'right') {
      return this.referenceVisible ? this.noteContentWidth() * (1 - this.noteContentRatio()) : 0;
    }
    return this.referenceVisible
      ? this.noteContentWidth() * this.noteContentRatio() : '100%';
  }

  private notePaneVisible(pane: string): boolean {
    if (this.isSingleScreenLayout() || this.focused) {
      return this.activePane === pane;
    }
    if (this.breakpoint === Breakpoint.MD) {
      return pane === 'left' || this.referenceVisible;
    }
    return pane === 'left' || this.referenceVisible;
  }

  private startNavigationDrag(agent: boolean): void {
    this.splitDragging = true;
    this.navigationDragStart = agent ? this.agentNavigationWidth() : this.noteNavigationWidth();
  }

  private updateNavigationDrag(offsetX: number, agent: boolean): void {
    if (this.windowWidthVp <= 0 || (!agent && this.sidebarCollapsed)) {
      return;
    }
    const panes: number = !agent && this.breakpoint === Breakpoint.LG ? 2 : 1;
    const splitters: number = !agent && this.breakpoint === Breakpoint.LG ? 2 : 1;
    const width: number = clampNavigationWidth(
      this.navigationDragStart + offsetX, this.windowWidthVp, panes, splitters);
    this.navigationRatio = width / this.windowWidthVp;
  }

  private startContentDrag(): void {
    const width: number = this.noteContentWidth();
    this.contentDragStart = Math.max(0, width) * this.noteContentRatio();
  }

  private updateContentDrag(offsetX: number): void {
    const width: number = this.noteContentWidth();
    this.contentRatio = clampContentRatio((this.contentDragStart + offsetX) / Math.max(1, width), width);
  }

  private endSplitDrag(): void {
    this.splitDragging = false;
    this.saveSplitLayout();
    this.scheduleWorkspaceSessionSave();
  }

  private saveSplitLayout(): void {
    this.ensureSplitLayoutStore();
    (this.splitLayoutStore as SplitLayoutStore).save({
      navigationRatio: this.navigationRatio,
      contentRatio: this.contentRatio
    });
  }

  private resetSplitLayout(): void {
    this.navigationRatio = -1;
    this.contentRatio = DEFAULT_CONTENT_RATIO;
    this.ensureSplitLayoutStore();
    (this.splitLayoutStore as SplitLayoutStore).reset();
    this.scheduleWorkspaceSessionSave();
  }

  private setSidebarCollapsed(collapsed: boolean): void {
    this.sidebarCollapsed = collapsed;
    this.sidebarProgress = collapsed ? 0 : 1;
    this.scheduleWorkspaceSessionSave();
  }

  private setDrawerOpen(open: boolean): void {
    this.drawerOpen = open;
    this.drawerProgress = open ? 1 : 0;
    this.scheduleWorkspaceSessionSave();
  }

  private closeNoteNavigation(): void {
    if (this.breakpoint === Breakpoint.SM) {
      this.setDrawerOpen(false);
    } else if (this.isSingleLandscape()) {
      this.setSidebarCollapsed(true);
    }
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
    if (this.currentVaultId !== reg.currentId()) {
      this.resetSaveFeedback();
    }
    this.currentVaultId = reg.currentId();
    this.refreshCurrentVaultNoteCount();
  }

  private refreshCurrentVaultNoteCount(): void {
    this.currentVaultNoteCount = this.currentVaultId.length > 0
      ? FileTree.allMarkdownFiles(VaultRegistry.get().vaultDirOf(this.currentVaultId)).length
      : 0;
  }

  /** 文件树内容变化时同步更新计数，并通知侧栏重扫。 */
  private refreshFileTree(): void {
    this.refreshCurrentVaultNoteCount();
    this.treeSeq++;
    void this.refreshBacklinks();
    void this.refreshActiveChaptersFromBridge();
  }

  private async refreshBacklinks(): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const targetPath: string = this.activeFilePath();
    const targetPane: string = this.activePane;
    this.backlinkPaths = [];
    this.backlinksFailed = false;
    if (vaultId.length === 0 || targetPath.length === 0) {
      this.backlinksLoading = false;
      return;
    }
    this.backlinksLoading = true;
    try {
      const paths: string[] = await WikiLinkService.backlinks(VaultRegistry.get(), vaultId, targetPath);
      if (vaultId === this.currentVaultId && targetPane === this.activePane && targetPath === this.activeFilePath()) {
        this.backlinkPaths = paths;
        this.backlinksLoading = false;
      }
    } catch (error) {
      if (vaultId === this.currentVaultId && targetPane === this.activePane && targetPath === this.activeFilePath()) {
        this.backlinksLoading = false;
        this.backlinksFailed = true;
      }
    }
  }

  private toggleBacklinks(pane: string): void {
    this.setActivePane(pane);
    const samePaneExpanded: boolean = this.backlinksExpanded && this.backlinksPane === pane;
    this.backlinksPane = pane;
    this.backlinksExpanded = !samePaneExpanded;
  }

  /** 档位变化：抽屉语义只在 sm；切到 md/lg 强制收抽屉，防止回 sm 时意外打开 */
  private onBreakpointChanged(): void {
    this.moreMenuOpen = false;
    this.closeFormatMenu();
    if (this.breakpoint !== Breakpoint.SM) {
      this.setDrawerOpen(false);
    }
    this.syncNavigationForBreakpoint();
    this.synchronizePreviewFollowContext();
    if (this.topView === 'note' && this.currentFilePath.length > 0) {
      void this.refreshAfterBreakpointChange(this.currentFilePath, this.currentVaultId);
    }
  }

  private syncNavigationForBreakpoint(): void {
    const enteredBreakpoint: boolean = this.layoutBreakpoint !== this.breakpoint;
    this.layoutBreakpoint = this.breakpoint;
    if (enteredBreakpoint && this.breakpoint === Breakpoint.MD && this.referenceVisible && !this.focused) {
      this.setSidebarCollapsed(true);
    }
  }

  private async refreshAfterBreakpointChange(path: string, vaultId: string): Promise<void> {
    if (path !== this.currentFilePath || vaultId !== this.currentVaultId) {
      return;
    }
    await this.flushSave(path, vaultId);
  }

  /**
   * 系统返回键/侧滑返回拦截（需求 2.7b；api_notes I-1 / I3.1 已真机核实：侧滑同样触发）。
   * 按优先级依次消费：① 快切/抽屉；② 次级视图；③ 图片查看器；④ sm 预览态；
   * 都不是则返 false 走系统默认（退出应用）。
   */
  onBackPress(): boolean {
    if (this.moreMenuOpen) {
      this.moreMenuOpen = false;
      return true;
    }
    if (this.quickSwitchOpen) {
      this.quickSwitchOpen = false;
      return true;
    }
    if (this.drawerOpen) {
      this.setDrawerOpen(false);
      return true;
    }
    if (this.topView !== 'note') {
      this.leaveSecondaryView();
      return true;
    }
    const activePreview: PreviewBridge = this.activePane === 'right'
      ? this.rightPreviewBridge : this.previewBridge;
    if (activePreview.closeImageViewer()) {
      return true;
    }
    if (this.breakpoint === Breakpoint.SM && this.smMode === 'preview') {
      this.smMode = 'edit';
      this.scheduleWorkspaceSessionSave();
      return true;
    }
    return false;
  }

  /** 页面隐藏（应用退到后台）：立刻落盘，兜底「杀进程重进内容还在」（2.3） */
  onPageHide(): void {
    if (this.topView === 'note') {
      void this.flushWorkspaceSaves().then((): void => {
        this.resetSaveFeedback();
        this.flushWorkspaceSessionSave();
      });
    }
  }

  private leaveSecondaryView(): void {
    if (this.topView === 'history') {
      this.topView = 'settings';
    } else if (this.topView === 'settings') {
      if (this.isSingleScreenLayout() && this.settingsDetail) {
        this.settingsDetail = false;
        return;
      }
      this.topView = this.settingsReturnView;
    } else if (this.topView === 'vaults') {
      this.topView = this.vaultManagerReturnView;
    } else {
      this.topView = 'note';
    }
    this.scheduleWorkspaceSessionSave();
  }

  private returnFromSettings(): void {
    this.settingsDetail = false;
    this.topView = this.settingsReturnView;
    this.scheduleWorkspaceSessionSave();
  }

  private async openVaultManager(fromView: string): Promise<void> {
    if (fromView === 'note' && !await this.flushWorkspaceSaves()) {
      return;
    }
    this.vaultManagerReturnView = fromView;
    this.topView = 'vaults';
  }

  private currentVaultIsGit(): boolean {
    const entry: VaultEntry | null = VaultRegistry.get().currentEntry();
    return entry !== null && entry.type === 'git';
  }

  private async openGitSyncPage(): Promise<void> {
    if (!await this.flushWorkspaceSaves()) {
      promptAction.showToast({ message: '当前笔记未保存，暂不能打开 Git 同步' });
      return;
    }
    this.moreMenuOpen = false;
    router.pushUrl({ url: 'pages/SyncPage' });
  }

  private async openAgent(): Promise<void> {
    if (this.topView !== 'note' || !await this.flushWorkspaceSaves()) {
      return;
    }
    this.moreMenuOpen = false;
    this.topView = 'agent';
  }

  private openSettings(fromView: string, initialTab: string): void {
    this.moreMenuOpen = false;
    this.settingsReturnView = fromView;
    this.settingsCategory = initialTab;
    this.settingsDetail = this.isSingleScreenLayout() && fromView === 'agent';
    this.topView = 'settings';
  }

  private openAgentNote(path: string): void {
    void this.loadAgentNote(path);
  }

  private async loadAgentNote(path: string): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const text: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, path);
    if (text === null) {
      promptAction.showToast({ message: '打开笔记失败' });
      return;
    }
    // Agent 页打开期间 Web 编辑器已卸载；不能 flush 它持有的旧内容覆盖 Agent 写入。
    this.resetSaveFeedback();
    this.currentFilePath = path;
    this.lastSavedText = text;
    WorkspaceEditGuard.clear('left', this.currentVaultId, path);
    this.editorDirty = false;
    this.topView = 'note';
    await this.readAndPush(path);
    this.ensureRecentOpenStore();
    (this.recentOpenStore as RecentOpenStore).record(vaultId, path);
  }

  /**
   * 返回本页（router.back from 导入页等）：注册表的当前库可能已被外部切换
   * （v0.3 导入完成自动切库）—— 与本地 currentVaultId 不一致时对齐上下文。
   */
  onPageShow(): void {
    const regId: string = VaultRegistry.get().currentId();
    if (regId.length > 0 && regId !== this.currentVaultId) {
      void this.adoptExternalVaultSwitch();
    }
  }

  /** 外部入口切换了当前库：落盘旧库编辑后按 switchVault 的重置序列对齐本页状态。 */
  private async adoptExternalVaultSwitch(): Promise<void> {
    try {
      if (!await this.flushWorkspaceSaves()) {
        return;
      }
      this.stopWorkspaceSessionSaving();
      this.refreshFromRegistry();
      this.currentFilePath = '';
      this.rightFilePath = '';
      this.quickSwitchOpen = false;
      this.quickSwitchFiles = [];
      this.recentOpenPaths = [];
      this.drawerOpen = false;
      this.smMode = 'edit';
      await this.readAndPush('');
      await this.readRightAndPush('');
    } catch (error) {
      this.toastRegistryError('切换库失败', error);
    }
  }

  /** 当前库名（显示名 = 目录名 = id；注册表兜底） */
  private currentVaultName(): string {
    return this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）';
  }

  private currentFileName(): string {
    if (this.currentFilePath.length === 0) {
      return '';
    }
    return this.currentFilePath.substring(this.currentFilePath.lastIndexOf('/') + 1);
  }

  private currentNoteName(): string {
    const name: string = this.currentFileName();
    return name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
  }

  private activeFilePath(): string {
    return this.activePane === 'right' ? this.rightFilePath : this.currentFilePath;
  }

  private activeEditorBridge(): EditorBridge {
    return this.activePane === 'right' ? this.rightEditorBridge : this.editorBridge;
  }

  private sharedNoteEditor(): EditorBridge {
    if (this.leftComposing) {
      return this.editorBridge;
    }
    if (this.rightComposing || this.rightEditorDirty || (this.rightEditing && this.activePane === 'right')) {
      return this.rightEditorBridge;
    }
    return this.editorBridge;
  }

  private parseChapterEntries(text: string): ChapterEntry[] {
    const entries: ChapterEntry[] = [];
    const frontmatter = text.match(/^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
    const contentOffset: number = frontmatter !== null ? frontmatter[0].length : 0;
    const lines: string[] = text.substring(contentOffset).split('\n');
    let offset: number = contentOffset;
    let fenceChar: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const fence = line.match(/^ {0,3}(`{3,}|~{3,})/);
      if (fence) {
        const marker: string = fence[1].substring(0, 1);
        fenceChar = fenceChar.length === 0 ? marker : (fenceChar === marker ? '' : fenceChar);
        offset += line.length + 1;
        continue;
      }
      if (fenceChar.length === 0) {
        const heading = line.match(/^ {0,3}(#{1,6})[ \t]+(.+?)\s*#*\s*$/);
        const setext = i + 1 < lines.length ? lines[i + 1].match(/^ {0,3}(=+|-+)\s*$/) : null;
        if (heading) {
          const title: string = heading[2].replace(/\s+#+\s*$/, '').trim();
          if (title.length > 0) {
            entries.push({
              index: entries.length,
              level: heading[1].length,
              title: title,
              offset: offset
            });
          }
        } else if (setext && line.trim().length > 0) {
          entries.push({
            index: entries.length,
            level: setext[1].startsWith('=') ? 1 : 2,
            title: line.trim(),
            offset: offset
          });
        }
      }
      offset += line.length + 1;
    }
    return entries;
  }

  private updateChapterEntries(text: string, path: string): void {
    if (path.length === 0 || path !== this.activeFilePath()) {
      return;
    }
    if (path !== this.chapterPath) {
      this.selectedChapterIndex = -1;
      this.chapterPath = path;
    }
    this.chapterEntries = this.parseChapterEntries(text);
    if (this.selectedChapterIndex >= this.chapterEntries.length) {
      this.selectedChapterIndex = -1;
    }
  }

  private async refreshActiveChaptersFromBridge(): Promise<void> {
    const pane: string = this.activePane;
    const path: string = this.activeFilePath();
    if (path.length === 0) {
      this.chapterPath = '';
      this.chapterEntries = [];
      this.selectedChapterIndex = -1;
      return;
    }
    const bridge: EditorBridge = this.activeEditorBridge();
    if (!bridge.ready) {
      return;
    }
    try {
      const text: string = await bridge.getContent();
      if (pane === this.activePane && path === this.activeFilePath()) {
        this.updateChapterEntries(text, path);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '更新章节导航失败');
    }
  }

  private selectChapter(index: number): void {
    if (index < 0 || index >= this.chapterEntries.length) {
      return;
    }
    const chapter: ChapterEntry = this.chapterEntries[index];
    this.selectedChapterIndex = index;
    if (this.activePane === 'right') {
      if (this.rightEditing) {
        this.rightEditorBridge.scrollToOffset(chapter.offset);
      } else {
        this.rightPreviewBridge.scrollToHeading(index);
      }
    } else if (this.smMode === 'edit') {
      this.editorBridge.scrollToOffset(chapter.offset);
    } else {
      this.previewBridge.scrollToHeading(index);
    }
    this.closeNoteNavigation();
    this.scheduleWorkspaceSessionSave();
  }

  private setSidebarTab(tab: string): void {
    this.sidebarTab = tab === 'chapters' ? 'chapters' : 'files';
    this.scheduleWorkspaceSessionSave();
  }

  private editorBridgeForPath(path: string): EditorBridge {
    if (path.length > 0 && path === this.currentFilePath && path === this.rightFilePath) {
      return this.sharedNoteEditor();
    }
    if (path.length > 0 && path === this.currentFilePath) {
      return this.editorBridge;
    }
    if (path.length > 0 && path === this.rightFilePath) {
      return this.rightEditorBridge;
    }
    return this.activeEditorBridge();
  }

  private setActivePane(pane: string): void {
    this.activePane = pane === 'right' ? 'right' : 'left';
    this.scheduleWorkspaceSessionSave();
    void this.refreshSharedEditability();
    void this.refreshActiveChaptersFromBridge();
    void this.refreshBacklinks();
    if (this.activePane === 'right' && this.rightFilePath.length === 0 && this.currentFilePath.length > 0) {
      void this.loadRightFile(this.currentFilePath);
    }
  }

  private recordPaneWidth(pane: string, widthVp: number): void {
    if (pane === 'right') {
      if (Math.abs(this.rightPaneWidthVp - widthVp) >= 1) {
        this.rightPaneWidthVp = widthVp;
      }
    } else if (Math.abs(this.leftPaneWidthVp - widthVp) >= 1) {
      this.leftPaneWidthVp = widthVp;
    }
  }

  /** Same-note editing has one active caret; the other editor stays read-only and mirrors content. */
  private async refreshSharedEditability(): Promise<void> {
    const sharedNote: boolean = this.currentFilePath.length > 0 && this.currentFilePath === this.rightFilePath;
    const leftRequested: boolean = this.smMode === 'edit';
    const rightRequested: boolean = this.rightEditing;
    const leftEditable: boolean = this.leftComposing || (leftRequested &&
      (!sharedNote || (!this.rightComposing && this.activePane === 'left')));
    const rightEditable: boolean = this.rightComposing || (rightRequested &&
      (!sharedNote || (!this.leftComposing && this.activePane === 'right')));

    // Revoke the old editor first so a same-note pane switch never leaves two active carets.
    if (!leftEditable && this.editorBridge.ready) {
      await this.editorBridge.setEditable(false);
      this.editorBridge.blur();
    }
    if (!rightEditable && this.rightEditorBridge.ready) {
      await this.rightEditorBridge.setEditable(false);
      this.rightEditorBridge.blur();
    }
    if (leftEditable && this.editorBridge.ready) {
      await this.editorBridge.setEditable(true);
    }
    if (rightEditable && this.rightEditorBridge.ready) {
      await this.rightEditorBridge.setEditable(true);
    }
  }

  private toggleActivePane(): void {
    const nextPane: string = this.activePane === 'left' ? 'right' : 'left';
    if (nextPane === 'right') {
      this.referenceVisible = true;
      if (this.breakpoint === Breakpoint.MD) {
        this.setSidebarCollapsed(true);
      }
    }
    this.setActivePane(nextPane);
  }

  private toggleReference(): void {
    if (this.focused) {
      return;
    }
    const show: boolean = !this.isReferenceShown();
    this.referenceVisible = show;
    this.scheduleWorkspaceSessionSave();
    if (show && this.breakpoint === Breakpoint.MD) {
      this.setSidebarCollapsed(true);
    }
    if (show && this.breakpoint === Breakpoint.SM) {
      this.setActivePane('right');
    } else if (!show && this.activePane === 'right') {
      this.setActivePane('left');
    }
  }

  private isReferenceShown(): boolean {
    if (!this.referenceVisible || this.focused) {
      return false;
    }
    if (this.breakpoint === Breakpoint.SM) {
      return this.activePane === 'right';
    }
    if (this.breakpoint === Breakpoint.MD) {
      return this.sidebarCollapsed;
    }
    return true;
  }

  private toggleFocus(): void {
    this.focused = !this.focused;
    this.scheduleWorkspaceSessionSave();
    this.moreMenuOpen = false;
    this.paneMoreOpen = false;
  }

  private previewActiveNoteInOtherPane(pane: string): void {
    const sourcePath: string = pane === 'left' ? this.currentFilePath : this.rightFilePath;
    if (sourcePath.length === 0) {
      return;
    }
    if (pane === 'left') {
      this.rightEditing = false;
      this.referenceVisible = true;
      if (this.breakpoint === Breakpoint.MD) {
        this.setSidebarCollapsed(true);
      }
      this.setActivePane('right');
      void this.loadRightFile(sourcePath);
    } else {
      this.smMode = 'preview';
      this.setActivePane('left');
      void this.loadFile(sourcePath);
    }
  }

  private isPaneEditable(pane: string): boolean {
    const sharedNote: boolean = this.currentFilePath.length > 0 && this.currentFilePath === this.rightFilePath;
    if (pane === 'right') {
      return this.rightEditorBridge.ready && (this.rightComposing || (this.rightEditing &&
        (!sharedNote || (!this.leftComposing && this.activePane === 'right'))));
    }
    return this.editorBridge.ready && (this.leftComposing || (this.smMode === 'edit' &&
      (!sharedNote || (!this.rightComposing && this.activePane === 'left'))));
  }

  private isImagePickerBusy(pane: string): boolean {
    return pane === 'right' ? this.rightImagePickerBusy : this.imagePickerBusy;
  }

  private paneFilePath(pane: string): string {
    return pane === 'right' ? this.rightFilePath : this.currentFilePath;
  }

  private recordFormatArea(target: number[], area: Area): void {
    const x: number = typeof area.globalPosition.x === 'number' ? area.globalPosition.x : 0;
    const y: number = typeof area.globalPosition.y === 'number' ? area.globalPosition.y : 0;
    const width: number = typeof area.width === 'number' ? area.width : 0;
    const height: number = typeof area.height === 'number' ? area.height : 0;
    target[0] = x;
    target[1] = y;
    target[2] = width;
    target[3] = height;
  }

  private onFormatContextChanged(): void {
    if (this.topView !== 'note') {
      this.resetSaveFeedback();
    }
    this.synchronizePreviewFollowContext();
    if (this.formatMenuOpen) {
      this.updateFormatPopupLayout(this.formatMenuPane);
    }
  }

  private async refreshWorkspaceAfterXiaoyi(): Promise<void> {
    if (this.topView !== 'note' || this.currentVaultId.length === 0) {
      return;
    }
    const vaultId: string = this.currentVaultId;
    const leftPath: string = this.currentFilePath;
    const rightPath: string = this.rightFilePath;
    if (leftPath.length > 0 && !WorkspaceEditGuard.isUnsaved(vaultId, leftPath)) {
      const current: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, leftPath);
      if (current === null) {
        this.currentFilePath = '';
        await this.readAndPush('');
      } else if (current !== this.lastSavedText) {
        await this.readAndPush(leftPath);
      }
    }
    if (rightPath.length > 0 && rightPath === leftPath && leftPath.length > 0 &&
      !WorkspaceEditGuard.isUnsaved(vaultId, rightPath)) {
      const current: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, rightPath);
      if (current === null) {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      } else if (current !== this.rightLastSavedText) {
        await this.readRightAndPush(rightPath);
      }
    } else if (rightPath.length > 0 && rightPath !== leftPath &&
      !WorkspaceEditGuard.isUnsaved(vaultId, rightPath)) {
      const current: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, rightPath);
      if (current === null) {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      } else if (current !== this.rightLastSavedText) {
        await this.readRightAndPush(rightPath);
      }
    }
  }

  private resetSaveFeedback(): void {
    this.saveFeedbackRevision++;
    this.hideSaveFeedback();
  }

  private hideSaveFeedback(): void {
    if (this.saveFeedbackTimer !== -1) {
      clearTimeout(this.saveFeedbackTimer);
      this.saveFeedbackTimer = -1;
    }
    if (this.saveFeedbackFadeTimer !== -1) {
      clearTimeout(this.saveFeedbackFadeTimer);
      this.saveFeedbackFadeTimer = -1;
    }
    this.saveFeedbackOpacity = 0;
    this.saveFeedbackMounted = false;
  }

  private showSaveFeedback(): void {
    this.hideSaveFeedback();
    this.saveFeedbackMounted = true;
    this.saveFeedbackOpacity = 1;
    this.saveFeedbackTimer = setTimeout((): void => {
      this.saveFeedbackTimer = -1;
      this.saveFeedbackOpacity = 0;
      this.saveFeedbackFadeTimer = setTimeout((): void => {
        this.saveFeedbackFadeTimer = -1;
        this.saveFeedbackMounted = false;
      }, Motion.durBase);
    }, 3500);
  }

  private saveFeedbackBottomMargin(): number {
    const windowBottom: number = this.formatWindowArea[1] + this.formatWindowArea[3];
    const workspaceGap: number = Math.max(0, windowBottom - this.saveFeedbackWorkspaceBottomVp);
    return Space.s3 + Math.max(0, this.keyboardInsetVp() - workspaceGap);
  }

  private recordSaveFeedbackWorkspaceArea(area: Area): void {
    const y: number = typeof area.globalPosition.y === 'number' ? area.globalPosition.y : 0;
    const height: number = typeof area.height === 'number' ? area.height : 0;
    this.saveFeedbackWorkspaceBottomVp = y + height;
  }

  private onFormatKeyboardInsetChanged(): void {
    if (this.formatMenuOpen) {
      this.updateFormatPopupLayout(this.formatMenuPane);
    }
  }

  private keyboardInsetVp(): number {
    return px2vp(Math.max(0, this.keyboardInsetPx));
  }

  private recordFormatPaneArea(pane: string, area: Area): void {
    this.recordFormatArea(pane === 'right' ? this.rightFormatPaneArea : this.leftFormatPaneArea, area);
    if (this.formatMenuOpen && this.formatMenuPane === pane) {
      this.updateFormatPopupLayout(pane);
    }
  }

  private recordFormatAnchorArea(pane: string, area: Area): void {
    this.recordFormatArea(pane === 'right' ? this.rightFormatAnchorArea : this.leftFormatAnchorArea, area);
    if (this.formatMenuOpen && this.formatMenuPane === pane) {
      this.updateFormatPopupLayout(pane);
    }
  }

  private recordFormatWindowArea(area: Area): void {
    this.recordFormatArea(this.formatWindowArea, area);
    if (this.formatMenuOpen) {
      this.updateFormatPopupLayout(this.formatMenuPane);
    }
  }

  private closeFormatMenu(restoreEditor: boolean = false): void {
    const pane: string = this.formatMenuPane;
    this.formatMenuOpen = false;
    if (restoreEditor) {
      const bridge: EditorBridge = pane === 'right' ? this.rightEditorBridge : this.editorBridge;
      bridge.focus();
    }
  }

  private toggleFormatMenu(pane: string): void {
    if (this.formatMenuOpen && this.formatMenuPane === pane) {
      this.closeFormatMenu();
      return;
    }
    if (!this.isPaneEditable(pane)) {
      return;
    }
    this.setActivePane(pane);
    this.formatMenuPane = pane;
    this.formatMenuSourceVaultId = this.currentVaultId;
    this.formatMenuSourcePath = this.paneFilePath(pane);
    this.formatMenuWidth = Size.formatMenuW;
    this.formatMenuMaxHeight = Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2;
    this.formatMenuOpen = true;
    this.updateFormatPopupLayout(pane);
  }

  private onFormatMenuKey(pane: string, event: KeyEvent): void {
    if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.closeFormatMenu(true);
    }
  }

  private updateFormatPopupLayout(pane: string): void {
    if (!this.formatMenuOpen || pane !== this.formatMenuPane) {
      return;
    }
    if (this.topView !== 'note' || this.activePane !== pane ||
      this.currentVaultId !== this.formatMenuSourceVaultId ||
      this.paneFilePath(pane) !== this.formatMenuSourcePath || !this.isPaneEditable(pane) ||
      (pane === 'right' && (this.breakpoint === Breakpoint.SM || this.focused || !this.isReferenceShown()))) {
      this.closeFormatMenu();
      return;
    }

    const paneArea: number[] = pane === 'right' ? this.rightFormatPaneArea : this.leftFormatPaneArea;
    const anchorArea: number[] = pane === 'right' ? this.rightFormatAnchorArea : this.leftFormatAnchorArea;
    const paneX: number = paneArea[0];
    const paneY: number = paneArea[1];
    const paneWidth: number = paneArea[2];
    const paneHeight: number = paneArea[3];
    const anchorX: number = anchorArea[0];
    const anchorY: number = anchorArea[1];
    const anchorWidth: number = anchorArea[2];
    const anchorHeight: number = anchorArea[3];
    if (paneWidth <= 0 || paneHeight <= 0 || anchorWidth <= 0 || anchorHeight <= 0) {
      return;
    }

    const windowWidth: number = this.formatWindowArea[2];
    const windowHeight: number = this.formatWindowArea[3];
    const visibleLeft: number = Math.max(paneX, windowWidth > 0 ? this.formatWindowArea[0] : paneX);
    const visibleTop: number = Math.max(paneY, windowHeight > 0 ? this.formatWindowArea[1] : paneY);
    const visibleRight: number = Math.min(paneX + paneWidth,
      windowWidth > 0 ? this.formatWindowArea[0] + windowWidth : paneX + paneWidth);
    const visibleBottom: number = Math.min(paneY + paneHeight,
      windowHeight > 0 ? this.formatWindowArea[1] + windowHeight : paneY + paneHeight);
    const keyboardInset: number = this.keyboardInsetVp();
    const keyboardSafeBottom: number = Math.max(visibleTop, visibleBottom - keyboardInset);
    const gap: number = Space.s2;
    const safeAnchorTop: number = Math.max(visibleTop, Math.min(anchorY, keyboardSafeBottom));
    const safeAnchorBottom: number = Math.max(visibleTop,
      Math.min(anchorY + anchorHeight, keyboardSafeBottom));
    const width: number = Math.min(Size.formatMenuW, visibleRight - visibleLeft - gap * 2);
    const above: number = Math.max(0, safeAnchorTop - visibleTop - gap * 2);
    const below: number = Math.max(0, keyboardSafeBottom - safeAnchorBottom - gap * 2);
    const naturalHeight: number = Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2;
    const showAbove: boolean = above >= naturalHeight || above >= below;
    const availableHeight: number = showAbove ? above : below;
    if (width <= 0 || availableHeight <= 0) {
      this.closeFormatMenu();
      return;
    }

    const minLeft: number = visibleLeft + gap;
    const maxLeft: number = visibleRight - gap - width;
    const minCenterX: number = minLeft + width / 2;
    const maxCenterX: number = maxLeft + width / 2;
    const centerX: number = Math.max(minCenterX, Math.min(anchorX + anchorWidth / 2, maxCenterX));
    const left: number = centerX - width / 2;
    const defaultPopupLeft: number = pane === 'right' ? anchorX - anchorWidth + gap : anchorX;
    const windowLeft: number = windowWidth > 0 ? this.formatWindowArea[0] : paneX;
    const windowRight: number = windowWidth > 0 ? windowLeft + windowWidth : paneX + paneWidth;
    const defaultPopupLeftInWindow: number = Math.max(windowLeft + gap,
      Math.min(defaultPopupLeft, windowRight - gap - width));
    this.formatPopupPlacement = showAbove ? Placement.TopLeft : Placement.BottomLeft;
    this.formatPopupOffsetX = left - defaultPopupLeftInWindow;
    this.formatPopupOffsetY = showAbove
      ? safeAnchorTop - anchorY - gap
      : safeAnchorBottom - anchorY - anchorHeight + gap;
    if (Math.abs(this.formatMenuWidth - width) >= 0.5) {
      this.formatMenuWidth = width;
    }
    if (Math.abs(this.formatMenuMaxHeight - availableHeight) >= 0.5) {
      this.formatMenuMaxHeight = availableHeight;
    }
  }

  private applyEditorFormat(kind: string, pane: string): void {
    if (!this.isPaneEditable(pane)) {
      return;
    }
    const bridge: EditorBridge = pane === 'right' ? this.rightEditorBridge : this.editorBridge;
    bridge.applyFormat(kind);
  }

  private appBarTitle(): string {
    if (this.topView === 'note') {
      if (this.breakpoint === Breakpoint.SM && this.drawerOpen) {
        return '';
      }
      return this.breakpoint === Breakpoint.SM || this.sidebarCollapsed || this.focused
        ? this.currentVaultName() : '';
    }
    if (this.topView === 'vaults') {
      return '笔记库';
    }
    if (this.topView === 'history') {
      return '版本记录';
    }
    if (this.topView === 'agent') {
      return this.agentTitle;
    }
    return '设置与关于';
  }

  /**
   * 选中文件。
   * 单屏态额外做两件事：关抽屉 + 回编辑态 —— 在只有一个栏位的地方点了文件，
   * 默认意图是「看/改它」，而不是开抽屉也不看 preview。
   */
  private onSelectFile(relPath: string): void {
    hilog.info(DOMAIN, TAG, '选中文件 %{public}s', relPath);
    if (this.isSingleScreenLayout()) {
      this.setDrawerOpen(false);
      if (this.isSingleLandscape()) {
        this.setSidebarCollapsed(true);
      }
      this.smMode = 'edit';
    }
    if (this.activePane === 'right') {
      void this.loadRightFile(relPath);
    } else {
      void this.loadFile(relPath);
    }
  }

  private openFileInOtherPane(relPath: string): void {
    const targetPane: string = this.activePane === 'left' ? 'right' : 'left';
    this.activePane = targetPane;
    if (this.isSingleScreenLayout()) {
      this.setDrawerOpen(false);
      this.smMode = 'edit';
    }
    if (targetPane === 'right') {
      void this.loadRightFile(relPath);
    } else {
      void this.loadFile(relPath);
    }
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
  private async readAndPush(relPath: string, initializeRight: boolean = true): Promise<boolean> {
    let text: string | null = '';
    if (this.currentVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.tryReadNote(VaultRegistry.get(), this.currentVaultId, relPath);
      if (text === null) {
        return false;
      }
    }
    WorkspaceEditGuard.clear('left', this.currentVaultId, relPath);
    if (!this.workspaceSessionRestoring && this.committedLeftPath !== relPath) {
      this.leftEditorScrollTop = 0;
      this.leftPreviewScrollTop = 0;
    }
    this.lastSavedText = text;
    this.editorDirty = false;
    this.editorLen = text.length;
    await this.editorBridge.setContent(text);
    if (relPath.length > 0 && relPath === this.rightFilePath) {
      this.rightLastSavedText = text;
      this.rightEditorDirty = false;
    }
    // M3 联动：文件加载后预览同步本页内容 + 告知笔记目录（相对图片引用的解析基准）
    this.previewBridge.resetDocument();
    this.previewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushPreview(text, true);
    if (!this.workspaceSessionRestoring) {
      this.editorBridge.restoreScrollTop(this.leftEditorScrollTop);
      this.previewBridge.restoreScrollTop(this.leftPreviewScrollTop);
    }
    if (initializeRight && relPath.length > 0 && this.rightFilePath.length === 0) {
      this.rightFilePath = relPath;
      await this.readRightAndPush(relPath);
    } else if (initializeRight && this.rightFilePath === relPath && relPath.length > 0) {
      await this.readRightAndPush(relPath);
    }
    if (this.activePane === 'left') {
      this.updateChapterEntries(text, relPath);
    }
    await this.refreshSharedEditability();
    await this.refreshActiveChaptersFromBridge();
    this.committedLeftPath = relPath;
    this.applyRestoredChapterSelection();
    if (!this.workspaceSessionRestoring && relPath.length > 0 && this.topView === 'note') {
      this.workspaceSessionSavingEnabled = true;
    }
    this.scheduleWorkspaceSessionSave();
    void this.refreshBacklinks();
    return true;
  }

  private async readRightAndPush(relPath: string): Promise<boolean> {
    let text: string | null = '';
    if (this.currentVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.tryReadNote(VaultRegistry.get(), this.currentVaultId, relPath);
      if (text === null) {
        return false;
      }
    }
    if (!this.workspaceSessionRestoring && this.committedRightPath !== relPath) {
      this.rightEditorScrollTop = 0;
      this.rightPreviewScrollTop = 0;
    }
    this.rightLastSavedText = text;
    WorkspaceEditGuard.clear('right', this.currentVaultId, relPath);
    this.rightEditorDirty = false;
    this.rightEditorLen = text.length;
    await this.rightEditorBridge.setContent(text);
    this.rightPreviewBridge.resetDocument();
    this.rightPreviewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushRightPreview(text, true);
    if (!this.workspaceSessionRestoring) {
      this.rightEditorBridge.restoreScrollTop(this.rightEditorScrollTop);
      this.rightPreviewBridge.restoreScrollTop(this.rightPreviewScrollTop);
    }
    if (this.activePane === 'right') {
      this.updateChapterEntries(text, relPath);
    }
    await this.refreshSharedEditability();
    await this.refreshActiveChaptersFromBridge();
    this.committedRightPath = relPath;
    this.applyRestoredChapterSelection();
    if (!this.workspaceSessionRestoring && relPath.length > 0 && this.topView === 'note') {
      this.workspaceSessionSavingEnabled = true;
    }
    this.scheduleWorkspaceSessionSave();
    return true;
  }

  private async loadRightFile(relPath: string): Promise<void> {
    const previousPath: string = this.rightFilePath;
    const vaultId: string = this.currentVaultId;
    if (relPath === previousPath) {
      return;
    }
    this.workspaceOpenRequests++;
    try {
      this.resetSaveFeedback();
      if (!await this.flushRightSave(previousPath, vaultId, false)) {
        return;
      }
      this.resetSaveFeedback();
      const text: string | null = relPath.length > 0
        ? NoteService.tryReadNote(VaultRegistry.get(), vaultId, relPath) : '';
      if (text === null) {
        promptAction.showToast({ message: '打开笔记失败' });
        return;
      }
      this.rightFilePath = relPath;
      this.rightLastSavedText = text;
      this.rightEditorDirty = false;
      await this.readRightAndPush(relPath);
      if (relPath.length > 0) {
        this.ensureRecentOpenStore();
        (this.recentOpenStore as RecentOpenStore).record(vaultId, relPath);
      }
    } finally {
      this.workspaceOpenRequests = Math.max(0, this.workspaceOpenRequests - 1);
      this.scheduleWorkspaceSessionSave();
    }
  }

  private async flushRightSave(targetPath: string = this.rightFilePath,
    targetVaultId: string = this.currentVaultId, showFeedback: boolean = true): Promise<boolean> {
    if (this.rightSaveTimer !== -1) {
      clearTimeout(this.rightSaveTimer);
      this.rightSaveTimer = -1;
    }
    if (targetPath.length === 0 || targetVaultId.length === 0 || !this.rightEditorBridge.ready) {
      return true;
    }
    if (targetPath === this.currentFilePath && targetVaultId === this.currentVaultId) {
      return await this.flushSave(targetPath, targetVaultId, this.sharedNoteEditor(), showFeedback);
    }
    const feedbackRevision: number = this.saveFeedbackRevision;
    let text: string = '';
    try {
      text = await this.rightEditorBridge.getContent();
    } catch (error) {
      promptAction.showToast({ message: '保存失败，请稍后重试' });
      return false;
    }
    const savedText: string = targetPath === this.rightFilePath ? this.rightLastSavedText : '';
    if (text === savedText) {
      if (targetPath === this.rightFilePath && targetVaultId === this.currentVaultId) {
        WorkspaceEditGuard.clear('right', targetVaultId, targetPath);
        this.rightEditorDirty = false;
      }
      return true;
    }
    try {
      await NoteService.saveNote(VaultRegistry.get(), targetVaultId, targetPath, text);
      if (targetPath === this.rightFilePath && targetVaultId === this.currentVaultId) {
        this.rightLastSavedText = text;
        WorkspaceEditGuard.clear('right', targetVaultId, targetPath);
        this.rightEditorDirty = false;
      }
      if (targetPath === this.currentFilePath && targetVaultId === this.currentVaultId) {
        this.lastSavedText = text;
        this.editorDirty = false;
        void this.refreshBacklinks();
      }
      if (shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: showFeedback,
        saveRevisionCurrent: feedbackRevision === this.saveFeedbackRevision,
        noteViewActive: this.topView === 'note',
        targetCurrent: targetPath === this.rightFilePath && targetVaultId === this.currentVaultId
      })) {
        this.showSaveFeedback();
      }
      return true;
    } catch (error) {
      this.toastRegistryError('保存失败', error);
      return false;
    }
  }

  private scheduleRightSave(): void {
    if (this.rightFilePath.length === 0) {
      return;
    }
    if (this.rightFilePath === this.currentFilePath) {
      if (this.saveTimer !== -1) {
        clearTimeout(this.saveTimer);
      }
      this.saveTimer = setTimeout((): void => {
        this.saveTimer = -1;
        void this.flushRightSave();
      }, 800);
      return;
    }
    if (this.rightSaveTimer !== -1) {
      clearTimeout(this.rightSaveTimer);
    }
    this.rightSaveTimer = setTimeout((): void => {
      this.rightSaveTimer = -1;
      void this.flushRightSave();
    }, 800);
  }

  private pushRightPreview(text: string, force: boolean = false): void {
    if (!force && text === this.rightLastPreviewText) {
      return;
    }
    this.rightLastPreviewText = text;
    if (this.currentVaultId.length > 0 && this.rightFilePath.length > 0) {
      const files: string[] = WikiLinkService.files(VaultRegistry.get(), this.currentVaultId);
      this.rightPreviewBridge.setContent(WikiLinkParser.renderForPreview(text, this.rightFilePath, files));
    } else {
      this.rightPreviewBridge.setContent(text);
    }
  }

  private async syncLeftContentToRight(): Promise<void> {
    if (this.currentFilePath.length === 0 || this.rightFilePath !== this.currentFilePath ||
      !this.editorBridge.ready) {
      return;
    }
    try {
      const text: string = await this.editorBridge.getContent();
      this.pushRightPreview(text);
      if (this.activePane === 'left') {
        this.updateChapterEntries(text, this.currentFilePath);
      } else {
        this.updateChapterEntries(text, this.rightFilePath);
      }
      if (this.rightEditorBridge.ready && !this.rightComposing) {
        await this.rightEditorBridge.setContent(text);
        WorkspaceEditGuard.clear('right', this.currentVaultId, this.currentFilePath);
        this.rightEditorDirty = false;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '双栏同步右栏失败');
    }
  }

  private async syncRightContentToLeft(): Promise<void> {
    if (this.rightFilePath.length === 0 || this.rightFilePath !== this.currentFilePath ||
      !this.rightEditorBridge.ready) {
      return;
    }
    try {
      const text: string = await this.rightEditorBridge.getContent();
      this.pushPreview(text);
      if (this.rightFilePath === this.currentFilePath) {
        this.pushRightPreview(text);
      }
      if (this.editorBridge.ready && !this.leftComposing) {
        await this.editorBridge.setContent(text);
        WorkspaceEditGuard.mark('left', this.currentVaultId, this.currentFilePath);
        this.editorDirty = true;
      }
      WorkspaceEditGuard.clear('right', this.currentVaultId, this.rightFilePath);
      this.rightEditorDirty = false;
      if (this.activePane === 'right') {
        this.updateChapterEntries(text, this.rightFilePath);
      } else {
        this.updateChapterEntries(text, this.currentFilePath);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '双栏同步左栏失败');
    }
  }

  private onLeftCompositionChange(composing: boolean): void {
    this.leftComposing = composing;
    void this.refreshSharedEditability();
    if (!composing) {
      void this.syncLeftContentToRight();
    }
  }

  private onRightCompositionChange(composing: boolean): void {
    this.rightComposing = composing;
    void this.refreshSharedEditability();
    if (!composing) {
      void this.syncRightContentToLeft();
    }
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
    this.workspaceOpenRequests++;
    try {
      this.resetSaveFeedback();
      const prev: string = this.currentFilePath;
      const vaultId: string = this.currentVaultId;
      const rightSharesPrevious: boolean = this.rightFilePath === prev && prev.length > 0;
      const rightIsActiveEditor: boolean = rightSharesPrevious && !this.leftComposing &&
        (this.rightComposing || this.rightEditorDirty || (this.rightEditing && this.activePane === 'right'));
      this.currentFilePath = relPath;
      if (rightIsActiveEditor && !await this.flushRightSave(prev, vaultId)) {
        this.currentFilePath = prev;
        this.scheduleSave();
        return;
      }
      if (!rightIsActiveEditor && !await this.flushSave(prev, vaultId)) {
        this.currentFilePath = prev;
        this.scheduleSave();
        return;
      }
      if (!rightSharesPrevious && this.rightFilePath.length > 0 &&
        !await this.flushRightSave(this.rightFilePath, vaultId)) {
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
    } finally {
      this.workspaceOpenRequests = Math.max(0, this.workspaceOpenRequests - 1);
      this.scheduleWorkspaceSessionSave();
    }
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
  private async flushSave(targetPath: string | null = null, targetVaultId: string = '',
    sourceBridge: EditorBridge | null = null, showFeedback: boolean = true): Promise<boolean> {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    const path: string = targetPath === null ? this.currentFilePath : targetPath;
    const vaultId: string = targetVaultId.length > 0 ? targetVaultId : this.currentVaultId;
    const feedbackRevision: number = this.saveFeedbackRevision;
    const source: EditorBridge = sourceBridge === null ? this.editorBridge : sourceBridge;
    if (vaultId.length === 0 || path.length === 0) {
      return true;
    }
    // 编辑器未就绪时 getContent 返回 ''，此时落盘会把真实文件清空 —— 必须跳过
    if (!source.ready) {
      return true;
    }
    let text: string = '';
    try {
      text = await source.getContent();
    } catch (error) {
      // 拉不到内容：放弃这次保存（拿空串落盘会清空文件），但绝不让异常外泄挡住调用方
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'flushSave 拉取编辑器内容失败，跳过保存: %{public}s', err.message);
      promptAction.showToast({ message: '保存失败，请稍后重试' });
      return false;
    }
    if (text === this.lastSavedText) {
      WorkspaceEditGuard.clear('left', vaultId, path);
      if (path === this.currentFilePath && vaultId === this.currentVaultId) {
        this.editorDirty = false;
        if (path === this.rightFilePath) {
          WorkspaceEditGuard.clear('right', vaultId, path);
          this.rightEditorDirty = false;
        }
      }
      return true;
    }
    try {
      await NoteService.saveNote(VaultRegistry.get(), vaultId, path, text);
      this.lastSavedText = text;
      WorkspaceEditGuard.clear('left', vaultId, path);
      if (path === this.currentFilePath && vaultId === this.currentVaultId) {
        this.editorDirty = false;
        if (path === this.rightFilePath) {
          this.rightLastSavedText = text;
          WorkspaceEditGuard.clear('right', vaultId, path);
          this.rightEditorDirty = false;
          const mirror: EditorBridge = source === this.rightEditorBridge
            ? this.editorBridge : this.rightEditorBridge;
          if (mirror.ready && !this.leftComposing && !this.rightComposing) {
            await mirror.setContent(text);
          }
          this.pushPreview(text);
          this.pushRightPreview(text);
        }
        void this.refreshBacklinks();
      }
      if (shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: showFeedback,
        saveRevisionCurrent: feedbackRevision === this.saveFeedbackRevision,
        noteViewActive: this.topView === 'note',
        targetCurrent: path === this.currentFilePath && vaultId === this.currentVaultId
      })) {
        this.showSaveFeedback();
      }
      return true;
    } catch (error) {
      this.toastRegistryError('保存失败', error);
      return false;
    }
  }

  /** Persist visible workspace content without creating two writers for a shared note. */
  private async flushWorkspaceSaves(): Promise<boolean> {
    if (this.currentFilePath.length > 0 && this.currentFilePath === this.rightFilePath) {
      return await this.flushSave(this.currentFilePath, this.currentVaultId, this.sharedNoteEditor());
    }
    if (!await this.flushSave()) {
      return false;
    }
    return await this.flushRightSave();
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
  private pushPreview(text: string, force: boolean = false): void {
    if (!force && text === this.lastPreviewText) {
      return;
    }
    this.lastPreviewText = text;
    if (this.currentVaultId.length > 0 && this.currentFilePath.length > 0) {
      const files: string[] = WikiLinkService.files(VaultRegistry.get(), this.currentVaultId);
      this.previewBridge.setContent(WikiLinkParser.renderForPreview(text, this.currentFilePath, files));
    } else {
      this.previewBridge.setContent(text);
    }
  }

  private provideWikiLinkCompletions(id: number, query: string, pane: string = 'left'): void {
    let candidates: WikiLinkCandidate[] = [];
    if (this.currentVaultId.length > 0) {
      candidates = WikiLinkParser.completionCandidates(query,
        WikiLinkService.files(VaultRegistry.get(), this.currentVaultId));
    }
    const bridge: EditorBridge = pane === 'right' ? this.rightEditorBridge : this.editorBridge;
    bridge.setLinkCandidatesResult(id, JSON.stringify(candidates));
  }

  private provideRightWikiLinkCompletions(id: number, query: string): void {
    this.provideWikiLinkCompletions(id, query, 'right');
  }

  private async handleWikiLinkClick(target: string, pane: string = 'left'): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const sourcePath: string = pane === 'right' ? this.rightFilePath : this.currentFilePath;
    if (vaultId.length === 0 || sourcePath.length === 0) {
      return;
    }
    const registry: VaultRegistry = VaultRegistry.get();
    const resolution: WikiLinkResolution = WikiLinkParser.resolve(target, sourcePath,
      WikiLinkService.files(registry, vaultId));
    if (resolution.status === 'resolved') {
      if (pane === 'right') {
        void this.loadRightFile(resolution.path);
      } else {
        void this.loadFile(resolution.path);
      }
      return;
    }
    if (resolution.status === 'ambiguous') {
      promptAction.showToast({ message: '目标不唯一，请在链接中补全 .md 或 .markdown' });
      return;
    }
    if (resolution.status === 'invalid') {
      promptAction.showToast({ message: '链接路径无效' });
      return;
    }
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: '目标笔记尚未创建',
      message: '是否创建「' + resolution.path + '」？',
      buttons: [
        { text: '取消', color: $r('app.color.text_secondary') },
        { text: '创建笔记', color: $r('app.color.brand') }
      ]
    });
    if (result.index !== 1) {
      return;
    }
    const currentSourcePath: string = pane === 'right' ? this.rightFilePath : this.currentFilePath;
    if (vaultId !== this.currentVaultId || sourcePath !== currentSourcePath) {
      promptAction.showToast({ message: '当前笔记已变化，请重新打开链接' });
      return;
    }
    const latest: WikiLinkResolution = WikiLinkParser.resolve(target, sourcePath,
      WikiLinkService.files(registry, vaultId));
    if (latest.status === 'resolved') {
      if (pane === 'right') {
        void this.loadRightFile(latest.path);
      } else {
        void this.loadFile(latest.path);
      }
      return;
    }
    if (latest.status !== 'missing') {
      promptAction.showToast({ message: latest.status === 'ambiguous'
        ? '目标不唯一，请在链接中补全扩展名' : '链接路径无效' });
      return;
    }
    try {
      if (NoteService.normalizeRelPath(latest.path) !== latest.path) {
        promptAction.showToast({ message: '链接路径包含不支持的文件名' });
        return;
      }
      const createdPath: string = NoteService.createNote(registry, vaultId, latest.path);
      this.revealPath = createdPath;
      this.refreshFileTree();
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
        this.smMode = 'edit';
      }
      if (pane === 'right') {
        await this.loadRightFile(createdPath);
      } else {
        await this.loadFile(createdPath);
      }
    } catch (error) {
      this.toastRegistryError('创建链接目标失败', error);
    }
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
  private async updatePreviewFromEditor(force: boolean = false): Promise<void> {
    if (!this.editorBridge.ready) {
      this.pushPreview(this.lastSavedText, force);
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
    this.pushPreview(text, force);
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

  /** Select one Gallery image, copy it into the current vault, and insert its relative Markdown path. */
  private async pickImageForCurrentNote(pane: string = 'left'): Promise<void> {
    const isRight: boolean = pane === 'right';
    const notePath: string = isRight ? this.rightFilePath : this.currentFilePath;
    const bridge: EditorBridge = isRight ? this.rightEditorBridge : this.editorBridge;
    if (this.imagePickerBusy || this.rightImagePickerBusy) {
      return;
    }
    if (this.currentVaultId.length === 0 || notePath.length === 0) {
      promptAction.showToast({ message: '请先打开一篇笔记' });
      return;
    }
    if (!bridge.ready) {
      promptAction.showToast({ message: '编辑器尚未就绪，请稍后重试' });
      return;
    }

    if (isRight) {
      this.rightImagePickerBusy = true;
    } else {
      this.imagePickerBusy = true;
    }
    const vaultId: string = this.currentVaultId;
    const registry: VaultRegistry = VaultRegistry.get();
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      options.isPhotoTakingSupported = false;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      const uri: string = NoteImageService.selectedUri(result.photoUris);
      if (uri.length === 0) {
        return;
      }
      const currentPath: string = isRight ? this.rightFilePath : this.currentFilePath;
      if (vaultId !== this.currentVaultId || notePath !== currentPath) {
        promptAction.showToast({ message: '当前笔记已变化，未导入图片' });
        return;
      }

      const imported = await NoteImageService.importPickedImage(registry, registry.abilityContext(),
        vaultId, notePath, uri);
      const currentPathAfterImport: string = isRight ? this.rightFilePath : this.currentFilePath;
      if (vaultId !== this.currentVaultId || notePath !== currentPathAfterImport) {
        NoteImageService.removeImportedImage(registry, vaultId, imported.assetPath);
        promptAction.showToast({ message: '笔记已切换，图片未插入' });
        return;
      }
      bridge.insertText(imported.markdownReference);
    } catch (error) {
      const err = error as BusinessError;
      promptAction.showToast({ message: err.message.length > 0 ? '图片导入失败：' + err.message : '图片导入失败' });
    } finally {
      if (isRight) {
        this.rightImagePickerBusy = false;
      } else {
        this.imagePickerBusy = false;
      }
    }
  }

  /** 状态栏右侧读数：形态 · vp · FS:N（有折痕时追加 · C:x,y，px 在此换算成 vp） */
  private statusRightText(): string {
    let s: string = formLabelOf(this.breakpoint, this.windowWidthVp, this.windowHeightVp) +
      ' · ' + Math.round(this.windowWidthVp) + '×' + Math.round(this.windowHeightVp) + 'vp' +
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

  /** 顶栏汉堡只控制当前工作区导航。 */
  private onHamburger(): void {
    if (this.topView === 'agent') {
      this.agentHamburgerSeq++;
      return;
    }
    if (this.focused) {
      this.toggleFocus();
      if (this.breakpoint === Breakpoint.MD && this.activePane === 'right') {
        this.setActivePane('left');
      }
      this.setSidebarCollapsed(false);
      return;
    }
    if (this.breakpoint === Breakpoint.SM) {
      this.setDrawerOpen(!this.drawerOpen);
    } else {
      if (this.breakpoint === Breakpoint.MD && this.sidebarCollapsed && this.activePane === 'right') {
        this.setActivePane('left');
      }
      this.setSidebarCollapsed(!this.sidebarCollapsed);
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
      const editorMounted: boolean = this.topView === 'note';
      if (editorMounted && !await this.flushWorkspaceSaves()) {
        return;
      }
      this.stopWorkspaceSessionSaving();
      VaultRegistry.get().setCurrent(id);
      this.refreshFromRegistry();
      this.currentFilePath = '';
      this.rightFilePath = '';
      this.quickSwitchOpen = false;
      this.quickSwitchFiles = [];
      this.recentOpenPaths = [];
      this.drawerOpen = false;
      this.smMode = 'edit';
      await this.readAndPush('');
      await this.readRightAndPush('');
    } catch (error) {
      this.toastRegistryError('切换库失败', error);
    }
  }

  private doCreateVault(name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const entry: VaultEntry = reg.createLocal(name);
      // 原型行为：新建后自动切到新库（doCreate → switchVault）
      void this.switchVault(entry.id);
    } catch (error) {
      this.toastRegistryError('新建库失败', error);
    }
  }

  private doRenameVault(id: string, name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const before: VaultEntry | undefined = this.vaults.find((v: VaultEntry): boolean => v.id === id);
      const renamed: VaultEntry = reg.rename(id, name);
      // Git 库令牌按 alias `vault:<id>:token` 存（Asset Store Kit）——改名 = 换 id，迁移到新 alias
      if (before !== undefined && before.type === 'git') {
        try {
          GitCredentialStore.migrateToken(id, renamed.id);
        } catch (error) {
          const err = error as BusinessError;
          hilog.warn(DOMAIN, TAG, '令牌迁移失败 vault=%{public}s: %{public}s', id, err.message);
          promptAction.showToast({ message: '改名成功，但令牌迁移失败，下次同步需重新填写' });
        }
      }
      this.refreshFromRegistry();
      if (this.currentVaultId === renamed.id && id !== renamed.id) {
        this.scheduleWorkspaceSessionSave();
      }
    } catch (error) {
      this.toastRegistryError('改名失败', error);
    }
  }

  private async doDeleteVault(id: string): Promise<void> {
    const deletingCurrent: boolean = id === this.currentVaultId;
    const wasSessionSavingEnabled: boolean = this.workspaceSessionSavingEnabled;
    if (deletingCurrent) {
      this.stopWorkspaceSessionSaving();
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const target: VaultEntry | undefined = this.vaults.find((v: VaultEntry): boolean => v.id === id);
      const vaultKey: string = reg.vaultKeyOf(id);
      const removed: boolean = await AgentRuntime.deleteVaultWithCleanup(id,
        async (): Promise<void> => {
          await AgentMemoryStore.removeVaultData(id);
        },
        (): void => {
          AgentRuntime.forgetVault(id, reg);
          reg.remove(id);
          FullTextSearchService.discardVault(id);
          // 移除 Git 库：令牌随库清理（只删本地副本与凭据，远端仓库不受影响）
          if (target !== undefined && target.type === 'git') {
            GitCredentialStore.removeToken(id);
          }
          this.refreshFromRegistry();
        });
      if (!removed) {
        if (deletingCurrent && this.currentVaultId === id && wasSessionSavingEnabled) {
          this.workspaceSessionSavingEnabled = true;
        }
        promptAction.showToast({ message: '该库的 Agent 正在运行或删除；稍后再试。' });
      }
    } catch (error) {
      try {
        await AgentMemoryStore.flushVault(id);
      } catch (persistError) {
        // Keep the deletion error visible; a later user edit can retry the conversation save.
      }
      if (deletingCurrent && this.currentVaultId === id && wasSessionSavingEnabled) {
        this.workspaceSessionSavingEnabled = true;
      }
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
      this.refreshFileTree();
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
      this.refreshFileTree();
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
      const isRightCurrent: boolean = this.rightFilePath === relPath
        || this.rightFilePath.startsWith(relPath + '/');
      if (isCurrent || isRightCurrent) {
        if (!await this.flushWorkspaceSaves()) {
          return;
        }
        this.resetSaveFeedback();
      }
      if (isCurrent) {
        this.currentFilePath = '';
      }
      if (isRightCurrent) {
        this.rightFilePath = '';
      }
      await NoteService.deletePath(VaultRegistry.get(), this.currentVaultId, relPath);
      if (isCurrent) {
        await this.readAndPush('');
      }
      if (isRightCurrent) {
        await this.readRightAndPush('');
      }
      this.revealPath = '';
      this.refreshFileTree();
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
      const wasRight: boolean = this.rightFilePath === relPath;
      if (wasCurrent || wasRight) {
        if (!await this.flushWorkspaceSaves()) {
          return;
        }
        this.resetSaveFeedback();
      }
      const reg: VaultRegistry = VaultRegistry.get();
      const trashRel: string = TrashService.moveToTrash(reg, this.currentVaultId, relPath);
      if (wasCurrent) {
        this.currentFilePath = '';
      }
      if (wasRight) {
        this.rightFilePath = '';
      }
      if (wasCurrent) {
        await this.readAndPush('');
      }
      if (wasRight) {
        await this.readRightAndPush('');
      }
      this.refreshFileTree();
      this.trashSeq++;
      const name: string = relPath.substring(relPath.lastIndexOf('/') + 1);
      const snap: UndoSnap = {
        vaultId: this.currentVaultId, relPath: trashRel, wasCurrent: wasCurrent, wasRight: wasRight
      };
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
      this.refreshFileTree();
      this.trashSeq++;
      // 删的正是当时在编辑的那篇 → 撤销后重新加载（内容就是删除前 flush 落盘的那份）
      if (snap.vaultId === this.currentVaultId) {
        if (snap.wasCurrent) {
          void this.loadFile(snap.relPath);
        } else if (snap.wasRight) {
          void this.loadRightFile(snap.relPath);
        }
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
      this.refreshFileTree();
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
  private async doRenamePath(relPath: string, isDir: boolean, newName: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      if (!await this.flushWorkspaceSaves()) {
        return;
      }
      const previousCurrent: string = this.currentFilePath;
      const mutation: NotePathMutationResult = await NoteService.renamePath(VaultRegistry.get(),
        this.currentVaultId, relPath, newName, isDir);
      this.ensureRecentOpenStore();
      (this.recentOpenStore as RecentOpenStore).retarget(this.currentVaultId, relPath, mutation.path, isDir);
      this.retargetCurrent(relPath, mutation.path, isDir);
      this.retargetRight(relPath, mutation.path, isDir);
      this.refreshFileTree();
      let reloaded: boolean = false;
      if (this.currentFilePath !== previousCurrent ||
        mutation.referenceUpdates.updatedPaths.indexOf(this.currentFilePath) >= 0) {
        await this.readAndPush(this.currentFilePath);
        reloaded = true;
      }
      if (!reloaded) {
        await this.updatePreviewFromEditor(true);
      }
      this.showReferenceUpdateFailures(mutation.referenceUpdates);
    } catch (error) {
      this.toastRegistryError('重命名失败', error);
    }
  }

  /** 移动文件/目录到目标目录；revealPath 展开新位置的父目录，移完立刻看得见 */
  private async doMovePath(relPath: string, isDir: boolean, destDir: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      if (!await this.flushWorkspaceSaves()) {
        return;
      }
      const previousCurrent: string = this.currentFilePath;
      const mutation: NotePathMutationResult = await NoteService.movePath(VaultRegistry.get(),
        this.currentVaultId, relPath, destDir, isDir);
      this.ensureRecentOpenStore();
      (this.recentOpenStore as RecentOpenStore).retarget(this.currentVaultId, relPath, mutation.path, isDir);
      this.retargetCurrent(relPath, mutation.path, isDir);
      this.retargetRight(relPath, mutation.path, isDir);
      this.revealPath = mutation.path;
      this.refreshFileTree();
      let reloaded: boolean = false;
      if (this.currentFilePath !== previousCurrent ||
        mutation.referenceUpdates.updatedPaths.indexOf(this.currentFilePath) >= 0) {
        await this.readAndPush(this.currentFilePath);
        reloaded = true;
      }
      if (!reloaded) {
        await this.updatePreviewFromEditor(true);
      }
      this.showReferenceUpdateFailures(mutation.referenceUpdates);
    } catch (error) {
      this.toastRegistryError('移动失败', error);
    }
  }

  private showReferenceUpdateFailures(report: WikiLinkUpdateReport): void {
    if (!report.scanFailed && report.failedPaths.length === 0) {
      return;
    }
    void this.getUIContext().getPromptAction().showDialog({
      title: '目标已移动，双链需检查',
      message: report.scanFailed
        ? '无法读取当前库的 Markdown 文件列表，未能扫描双链；请检查与该目标相关的链接。'
        : '以下笔记需要检查：\n' + report.failedPaths.join('\n'),
      buttons: [{ text: '知道了', color: $r('app.color.text_primary') }]
    });
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
        this.resetSaveFeedback();
        this.currentFilePath = newRel;
      }
      return;
    }
    if (this.currentFilePath === oldRel || this.currentFilePath.startsWith(oldRel + '/')) {
      this.resetSaveFeedback();
      this.currentFilePath = newRel + this.currentFilePath.substring(oldRel.length);
    }
  }

  private retargetRight(oldRel: string, newRel: string, isDir: boolean): void {
    if (this.rightFilePath.length === 0 || oldRel === newRel) {
      return;
    }
    if (!isDir) {
      if (this.rightFilePath === oldRel) {
        this.resetSaveFeedback();
        this.rightFilePath = newRel;
      }
      return;
    }
    if (this.rightFilePath === oldRel || this.rightFilePath.startsWith(oldRel + '/')) {
      this.resetSaveFeedback();
      this.rightFilePath = newRel + this.rightFilePath.substring(oldRel.length);
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

  private openShareNoteDialog(): void {
    const path: string = this.activeFilePath();
    if (this.topView !== 'note' || path.length === 0) {
      promptAction.showToast({ message: '请先打开一篇笔记' });
      return;
    }
    this.openShareDialog('note', path);
  }

  private openSharePath(relPath: string, isDir: boolean): void {
    if (this.topView !== 'note' || !isDir) {
      return;
    }
    this.openShareDialog('folder', relPath);
  }

  private openShareVault(): void {
    if (this.topView !== 'note' || this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '当前没有可分享的知识库' });
      return;
    }
    this.openShareDialog('vault', '');
  }

  private openShareDialog(scope: ShareLinkScope, path: string): void {
    const registry: VaultRegistry = VaultRegistry.get();
    const entries: VaultEntry[] = registry.list();
    let vault: VaultEntry | null = null;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === this.currentVaultId) {
        vault = entries[i];
        break;
      }
    }
    if (vault === null) {
      promptAction.showToast({ message: '当前知识库不存在' });
      return;
    }
    const shareBridge: EditorBridge = this.editorBridgeForPath(path);
    if (scope === 'note' && !shareBridge.ready) {
      promptAction.showToast({ message: '编辑器尚未就绪，暂时无法分享' });
      return;
    }
    let title: string = '分享笔记';
    let itemName: string = path.substring(path.lastIndexOf('/') + 1);
    let description: string = '范围：当前编辑中的笔记及其引用的库内图片，不包含链接到的其他笔记。';
    let itemSummary: string = '';
    if (scope === 'folder') {
      title = '分享文件夹';
      itemName = path;
      description = '范围：递归包含此文件夹下的文件，并补齐这些笔记引用的库内图片。';
    } else if (scope === 'vault') {
      title = '分享知识库';
      itemName = this.currentVaultId;
      description = '范围：当前知识库中的文件；隐藏项、回收站、缓存、草稿、凭据及内部状态不会打包。';
    }

    const options: ShareFormatOption[] = [];
    if (scope === 'note') {
      options.push({ value: 'image', label: '排版图片', detail: '覆盖全文与本地图片；长文会分图并显示页数。' });
      options.push({ value: 'file', label: 'Markdown / ZIP', detail: '无本地图片分享 Markdown；有本地图片时自动打包 ZIP。' });
      options.push({ value: 'text', label: '文本', detail: '预览并编辑标题与正文；图片和复杂格式按提示降级。' });
    } else {
      const count = ShareArchiveService.countScope(registry, this.currentVaultId, path);
      itemSummary = '范围内 ' + count.noteCount.toString() + ' 篇 Markdown、' +
        count.fileCount.toString() + ' 个文件；打包时会补齐外部引用图片。';
      options.push({ value: 'zip', label: 'ZIP 文件', detail: '在本地生成，保留目录结构，不上传托管服务。' });
    }

    let notice: string = '';
    if (vault.type === 'git') {
      try {
        const link: ShareLinkScope = scope;
        const targetPath: string = path;
        const linkResult = ShareLinkService.build(vault, link, targetPath);
        options.push({ value: 'link', label: '远端网页链接', detail: '来自已配置的 Git 远端和跟踪分支。' });
        notice = linkResult.accessNotice;
      } catch (error) {
        const err = error as Error;
        notice = err.message + '；仍可分享本地文件。';
      }
    }

    this.shareNoteCtl = new CustomDialogController({
      builder: ShareNoteDialog({
        title: title,
        itemName: itemName,
        scopeDescription: description,
        itemSummary: itemSummary,
        notice: notice,
        options: options,
        onConfirm: (format: string): void => { void this.prepareShare(scope, path, format, itemName, vault as VaultEntry); }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.shareNoteCtl.open();
  }

  private async prepareShare(scope: ShareLinkScope, path: string, format: string, itemName: string,
    vault: VaultEntry): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    try {
      if (format === 'link') {
        const link: ShareLinkScope = scope;
        const targetPath: string = path;
        const result = ShareLinkService.build(vault, link, targetPath);
        await this.shareLink(result.url, itemName, registry);
        return;
      }
      if (format === 'image' && scope === 'note') {
        await this.prepareNoteImageShare(this.currentVaultId, path, itemName, this.editorBridgeForPath(path));
        return;
      }
      if (format === 'text' && scope === 'note') {
        const markdown: string = await this.editorBridgeForPath(path).getContent();
        const preview: NoteTextSharePreview = NoteTextShareService.createPreview(path, markdown);
        this.openShareTextPreview(preview, path);
        return;
      }
      if (scope === 'note') {
        const markdown: string = await this.editorBridgeForPath(path).getContent();
        const prepared = await NoteShareService.prepareNote(registry, this.currentVaultId, path, markdown);
        await this.shareFile(prepared.filePath, prepared.fileName, uniformTypeDescriptor.UniformDataType.FILE,
          registry);
        return;
      }
      let snapshot: ShareSnapshot | null = null;
      const activePath: string = this.activeFilePath();
      const activeBridge: EditorBridge = this.editorBridgeForPath(activePath);
      if (activeBridge.ready && activePath.length > 0 &&
        (scope === 'vault' || activePath.startsWith(path + '/') || activePath === path)) {
        snapshot = { path: activePath, markdown: await activeBridge.getContent() };
      }
      const prepared = await ShareArchiveService.prepareZip(registry, this.currentVaultId, path, snapshot);
      await this.shareFile(prepared.filePath, prepared.fileName, uniformTypeDescriptor.UniformDataType.FILE,
        registry);
    } catch (error) {
      if (this.shareCaptureCancelled) {
        return;
      }
      const err = error as Error;
      const message: string = err.message.length > 0 ? err.message : '系统分享面板无法打开，请重试';
      void this.getUIContext().getPromptAction().showDialog({
        title: '分享失败',
        message: message,
        buttons: [{ text: '知道了', color: $r('app.color.text_primary') }]
      });
    }
  }

  private async shareFile(filePath: string, title: string, utd: string, registry: VaultRegistry): Promise<void> {
    const shared = new systemShare.SharedData({
      utd: utd,
      uri: fileUri.getUriFromPath(filePath),
      title: title
    });
    await new systemShare.ShareController(shared).show(registry.abilityContext(), {});
  }

  private async shareLink(url: string, title: string, registry: VaultRegistry): Promise<void> {
    const shared = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
      content: url,
      title: title,
      label: 'HYPERLINK'
    });
    await new systemShare.ShareController(shared).show(registry.abilityContext(), {});
  }

  private openShareTextPreview(preview: NoteTextSharePreview, notePath: string): void {
    this.shareTextPreviewCtl = new CustomDialogController({
      builder: ShareTextPreviewDialog({
        itemName: preview.title,
        initialContent: preview.content,
        limitations: preview.limitations,
        onBack: (): void => { this.openShareDialog('note', notePath); },
        onConfirm: (content: string): void => { void this.shareTextContent(preview.title, content); }
      }),
      autoCancel: false,
      customStyle: true
    });
    this.shareTextPreviewCtl.open();
  }

  private async shareTextContent(title: string, content: string): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    try {
      if (!NoteTextShareService.isWithinShareLimit(title, content)) {
        throw new Error('文本超过系统分享 200 KB 限制，请删减内容后重试或改用 Markdown / ZIP。');
      }
      const shared = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.TEXT,
        content: content,
        title: title,
        label: 'TEXT'
      });
      await new systemShare.ShareController(shared).show(registry.abilityContext(), {});
    } catch (error) {
      const err = error as Error;
      void this.getUIContext().getPromptAction().showDialog({
        title: '分享失败',
        message: err.message.length > 0 ? err.message : '系统分享面板无法接收此文本，请改用 Markdown / ZIP。',
        buttons: [{ text: '知道了', color: $r('app.color.text_primary') }]
      });
    }
  }

  private waitForShareCaptureReady(): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      this.shareCaptureReadyResolver = resolve;
      this.shareCaptureReadyRejecter = reject;
      this.shareCaptureReadyTimer = setTimeout((): void => {
        this.rejectShareCaptureReady(new Error('分享预览加载超时，请重试'));
      }, 10000);
    });
  }

  private resolveShareCaptureReady(): void {
    if (this.shareCaptureReadyResolver === null) {
      return;
    }
    clearTimeout(this.shareCaptureReadyTimer);
    this.shareCaptureReadyTimer = -1;
    const resolve: () => void = this.shareCaptureReadyResolver;
    this.shareCaptureReadyResolver = null;
    this.shareCaptureReadyRejecter = null;
    resolve();
  }

  private rejectShareCaptureReady(error: Error): void {
    if (this.shareCaptureReadyRejecter === null) {
      return;
    }
    clearTimeout(this.shareCaptureReadyTimer);
    this.shareCaptureReadyTimer = -1;
    const reject: (error: Error) => void = this.shareCaptureReadyRejecter;
    this.shareCaptureReadyResolver = null;
    this.shareCaptureReadyRejecter = null;
    reject(error);
  }

  private cancelShareImageCapture(): void {
    this.shareCaptureCancelled = true;
    this.shareCaptureActive = false;
    this.shareCaptureBridge.cancelShareCaptureRequests('分享图片生成已取消');
    this.rejectShareCaptureReady(new Error('分享图片生成已取消'));
  }

  private async prepareNoteImageShare(vaultId: string, notePath: string, itemName: string,
    editor: EditorBridge): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    const markdown: string = await editor.getContent();
    const bridge: PreviewBridge = new PreviewBridge();
    bridge.setNoteDir(NoteShareService.parentOf(notePath));
    bridge.setContent(markdown);
    this.shareCaptureBridge = bridge;
    this.shareCaptureCancelled = false;
    this.shareCaptureStatus = '正在渲染笔记…';
    this.shareCaptureActive = true;
    let sessionId: string = '';
    try {
      const ready: Promise<void> = this.waitForShareCaptureReady();
      await ready;
      const initial: PreviewCaptureResult = await bridge.requestShareCaptureMetrics();
      const pageTops: number[] = NoteImageShareService.pageTops(initial.scrollHeight, initial.viewportHeight);
      const paged: PreviewCaptureResult = await bridge.prepareShareCapturePages(pageTops.length);
      if (paged.viewportHeight <= 0 || paged.viewportWidth <= 0 ||
        paged.scrollHeight < pageTops.length * paged.viewportHeight) {
        throw new Error('分享预览分页尺寸不足，无法覆盖全文');
      }
      sessionId = NoteImageShareService.createSession(registry);
      const pages: ShareImagePreviewPage[] = [];
      for (let i = 0; i < pageTops.length; i++) {
        if (this.shareCaptureCancelled) {
          throw new Error('分享图片生成已取消');
        }
        this.shareCaptureStatus = '正在生成图片 ' + (i + 1).toString() + ' / ' + pageTops.length.toString();
        const positioned: PreviewCaptureResult = await bridge.setShareCaptureScrollTop(pageTops[i]);
        if (Math.abs(positioned.scrollTop - pageTops[i]) > 1) {
          throw new Error('分享预览无法滚动到第 ' + (i + 1).toString() + ' 张图片的位置');
        }
        const pixelMap = await this.getUIContext().getComponentSnapshot().get(this.shareCaptureComponentId,
          { waitUntilRenderFinished: true });
        const imageInfo = await pixelMap.getImageInfo();
        const remainingHeight: number = Math.min(initial.viewportHeight, initial.scrollHeight - pageTops[i]);
        const cropHeight: number = Math.max(1,
          Math.min(imageInfo.size.height, Math.round(imageInfo.size.height * remainingHeight / initial.viewportHeight)));
        if (cropHeight < imageInfo.size.height) {
          await pixelMap.crop({
            x: 0,
            y: 0,
            size: { width: imageInfo.size.width, height: cropHeight }
          });
        }
        const croppedInfo = await pixelMap.getImageInfo();
        const filePath: string = NoteImageShareService.pagePath(registry, sessionId, i);
        await NoteImageShareService.writeJpeg(filePath, pixelMap);
        pages.push({
          uri: fileUri.getUriFromPath(filePath),
          aspectRatio: croppedInfo.size.width / croppedInfo.size.height,
          pageNumber: i + 1
        });
      }
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      this.shareCaptureActive = false;
      this.shareImagePreviewSessionId = sessionId;
      this.shareImagePreviewTitle = itemName;
      this.shareImagePreviewPages = pages;
      this.openShareImagePreview(itemName, pages, notePath);
    } catch (error) {
      this.shareCaptureActive = false;
      bridge.cancelShareCaptureRequests('分享图片生成已结束');
      if (sessionId.length > 0) {
        try {
          NoteShareService.removeTree(registry, sessionId);
        } catch (cleanupError) {
          // The cache directory is private to this failed preparation and expires after 24 hours.
        }
      }
      if (!this.shareCaptureCancelled) {
        const err = error as Error;
        throw new Error(err.message);
      }
    } finally {
      if (this.shareCaptureReadyTimer >= 0) {
        clearTimeout(this.shareCaptureReadyTimer);
        this.shareCaptureReadyTimer = -1;
      }
      this.shareCaptureReadyResolver = null;
      this.shareCaptureReadyRejecter = null;
    }
  }

  private openShareImagePreview(itemName: string, pages: ShareImagePreviewPage[], notePath: string): void {
    this.shareImagePreviewCtl = new CustomDialogController({
      builder: ShareImagePreviewDialog({
        itemName: itemName,
        pages: pages,
        onConfirm: (): void => {
          const sharePages: ShareImagePreviewPage[] = this.shareImagePreviewPages.slice();
          const title: string = this.shareImagePreviewTitle;
          this.shareImagePreviewSessionId = '';
          this.shareImagePreviewPages = [];
          void this.shareImagePages(sharePages, title, VaultRegistry.get());
        },
        onCancel: (): void => {
          this.cleanupShareImagePreview();
          this.openShareDialog('note', notePath);
        }
      }),
      autoCancel: false,
      customStyle: true
    });
    this.shareImagePreviewCtl.open();
  }

  private cleanupShareImagePreview(): void {
    const sessionId: string = this.shareImagePreviewSessionId;
    this.shareImagePreviewSessionId = '';
    this.shareImagePreviewPages = [];
    if (sessionId.length === 0) {
      return;
    }
    try {
      NoteShareService.removeTree(VaultRegistry.get(), sessionId);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '分享预览临时文件清理失败');
    }
  }

  private async shareImagePages(pages: ShareImagePreviewPage[], title: string, registry: VaultRegistry): Promise<void> {
    if (pages.length === 0 || pages.length > NoteImageShareService.MAX_PAGES) {
      promptAction.showToast({ message: '分享图片数量无效，请重新生成' });
      return;
    }
    const first: ShareImagePreviewPage = pages[0];
    const shared = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.JPEG,
      uri: first.uri,
      title: title,
      label: 'IMAGE'
    });
    for (let i = 1; i < pages.length; i++) {
      shared.addRecord({
        utd: uniformTypeDescriptor.UniformDataType.JPEG,
        uri: pages[i].uri,
        title: title + ' · ' + pages[i].pageNumber.toString(),
        label: 'IMAGE'
      });
    }
    try {
      await new systemShare.ShareController(shared).show(registry.abilityContext(), {});
    } catch (error) {
      const err = error as Error;
      void this.getUIContext().getPromptAction().showDialog({
        title: '分享失败',
        message: err.message.length > 0 ? err.message : '系统分享面板无法打开，请重试',
        buttons: [{ text: '知道了', color: $r('app.color.text_primary') }]
      });
    }
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
          void this.doDeleteVault(id);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deleteDialogCtl.open();
  }

  // ===== 视觉构件 =====

  /** 顶栏图标按钮：视觉 22，热区 48（4.x 修正 v0.1 的 32×32 不足）；bgColor 用于按下态底色（v2 #showRef[aria-pressed=true] 的 --blue-soft） */
  @Builder
  IconButton(name: string, color: ResourceColor, onTap: () => void, bgColor: ResourceColor = Color.Transparent) {
    Row() {
      Icon(name, Space.s5, color)
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(bgColor)
    .onClick(onTap)
  }

  private isPaneModeSelected(pane: string, label: string): boolean {
    const editing: boolean = pane === 'right' ? this.rightEditing : this.smMode === 'edit';
    return label === '编辑' ? editing : !editing;
  }

  @Builder
  PaneModeButton(pane: string, label: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.body2)
        .fontWeight(this.isPaneModeSelected(pane, label) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isPaneModeSelected(pane, label)
          ? $r('app.color.brand') : $r('app.color.text_secondary'))
    }
    .height(Space.s8)
    .padding({ left: Space.s3, right: Space.s3 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.full)
    .backgroundColor(this.isPaneModeSelected(pane, label)
      ? $r('app.color.brand_bg') : Color.Transparent)
    .border({
      width: 1,
      color: this.isPaneModeSelected(pane, label) ? $r('app.color.brand') : Color.Transparent
    })
    .focusable(true)
    .onClick((): void => {
      this.setActivePane(pane);
      const editing: boolean = label === '编辑';
      if (pane === 'right') {
        this.rightEditing = editing;
        if (editing) {
          void this.syncLeftContentToRight();
        } else {
          void this.syncRightContentToLeft();
        }
      } else {
        this.smMode = editing ? 'edit' : 'preview';
        if (!editing) {
          void this.updatePreviewFromEditor();
        }
      }
      this.scheduleWorkspaceSessionSave();
      void this.refreshSharedEditability();
    })
  }

  @Builder
  PaneMoreMenu(pane: string) {
    Column() {
      if (this.shouldShowPreviewFollowToggle(pane)) {
        Row() {
          Text('跟随编辑：' + (this.followPreviewEnabled ? '开' : '关'))
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .focusable(true)
        .onClick((): void => {
          this.paneMoreOpen = false;
          this.setPreviewFollowEnabled(!this.followPreviewEnabled);
        })
      }
      if (this.paneFilePath(pane).length > 0) {
        Row() {
          Text('在另一栏预览')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .focusable(true)
        .onClick((): void => {
          this.paneMoreOpen = false;
          this.previewActiveNoteInOtherPane(pane);
        })
      }
      Row() {
        Text(this.backlinksExpanded && this.backlinksPane === pane ? '隐藏反链' : '查看反链')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .onClick((): void => {
        this.paneMoreOpen = false;
        this.toggleBacklinks(pane);
      })
    }
    .width(Size.sidebarW)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 20, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 8 })
  }

  @Builder
  PaneMoreButton(pane: string) {
    Row() {
      Icon('more', 20, $r('app.color.text_secondary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .onClick((): void => {
      this.paneMorePane = pane;
      this.paneMoreOpen = !this.paneMoreOpen;
    })
    .bindPopup(this.paneMoreOpen && this.paneMorePane === pane, {
      builder: this.PaneMoreMenu(pane),
      placement: Placement.BottomRight,
      enableArrow: false,
      offset: { x: 0, y: Space.s1 },
      mask: false,
      autoCancel: true,
      popupColor: Color.Transparent,
      onWillDismiss: (action: DismissPopupAction): void => {
        action.dismiss();
        this.paneMoreOpen = false;
      }
    })
  }

  /** 与 v2 一致：每栏显示模式切换和栏内更多操作。 */
  @Builder
  PaneHead($$: PaneHeadParam) {
    Row({ space: Space.s1 }) {
      Row({ space: Space.s1 }) {
        this.PaneModeButton($$.pane, '编辑')
        this.PaneModeButton($$.pane, '预览')
      }
      .padding(Space.s1)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.line') })

      if (this.breakpoint !== Breakpoint.SM) {
        this.PaneMoreButton($$.pane)
      }
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: this.workspaceGutter(), right: this.workspaceGutter() })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 2 }, color: this.activePane === $$.pane
      ? $r('app.color.brand') : $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  PaneTitle($$: PaneHeadParam) {
    Text(this.paneFilePath($$.pane).length > 0 ? this.paneFilePath($$.pane) : '未选择笔记')
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_tertiary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4, top: Space.s1, bottom: Space.s1 })
      .border({ width: { bottom: 1 }, color: $r('app.color.line') })
  }

  @Builder
  EmptyPane() {
    Column({ space: Space.s2 }) {
      Icon('doc', 28, $r('app.color.text_tertiary'))
      Text('未选择笔记')
        .fontSize(FontSize.body1)
        .fontColor($r('app.color.text_secondary'))
      Text('先打开一篇笔记')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  NoteWorkspaceContent() {
    Column() {
      this.Appbar()
      Stack({ alignContent: Alignment.BottomStart }) {
        this.NoteBody()
        this.SaveFeedback()
      }
      .layoutWeight(1)
      .width('100%')
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.recordSaveFeedbackWorkspaceArea(newArea);
      })
      this.Statusbar()
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  NoteWorkspaceShell() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.isSingleScreenLayout()) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            this.NoteNavigation(this.breakpoint === Breakpoint.SM)
          }
          .width(this.drawerNavigationWidth())
          .height('100%')
          .backgroundColor($r('app.color.bg_navigation'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
          .translate({ x: -this.drawerNavigationWidth() *
            (1 - (this.breakpoint === Breakpoint.SM ? this.drawerProgress : this.noteNavigationProgress())) })
          .enabled(this.breakpoint === Breakpoint.SM ? this.drawerOpen : !this.sidebarCollapsed)
          .animation({ duration: Motion.durNav, curve: Motion.navCurve })

          Column() {
            this.NoteWorkspaceContent()
          }
          .width('100%')
          .height('100%')
          .translate({ x: this.drawerNavigationWidth() *
            (this.breakpoint === Breakpoint.SM ? this.drawerProgress : this.noteNavigationProgress()) })
          .animation({ duration: Motion.durNav, curve: Motion.navCurve })
        }
        .width('100%')
        .height('100%')
        .clip(true)
      } else {
        Row() {
          Column() {
            this.NoteNavigation(false)
          }
          .width(this.noteNavigationWidth())
          .height('100%')
          .backgroundColor($r('app.color.bg_navigation'))
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
          .margin({ left: -this.noteNavigationWidth() * (1 - this.noteNavigationProgress()) })
          .enabled(!this.sidebarCollapsed && !this.focused)
          .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

          SplitHandle({
            dragStarted: (): void => { this.startNavigationDrag(false); },
            dragUpdated: (offsetX: number): void => { this.updateNavigationDrag(offsetX, false); },
            dragEnded: (): void => { this.endSplitDrag(); },
            resetRequested: (): void => { this.resetSplitLayout(); }
          })
            .width(Space.s4 * this.noteNavigationProgress())
            .margin({ left: -Space.s2 * this.noteNavigationProgress(),
              right: -Space.s2 * this.noteNavigationProgress() })
            .enabled(!this.sidebarCollapsed && !this.focused)
            .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

          Column() {
            this.NoteWorkspaceContent()
          }
          .width(this.noteContentWidth())
          .height('100%')
          .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })
        }
        .width('100%')
        .height('100%')
        .clip(true)
      }

      if (this.undoVisible) {
        this.UndoBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  NoteBody() {
    Row() {
      Column() {
        this.LeftWorkspacePane(false)
      }
      .width(this.notePaneWidth('left'))
      .height('100%')
      .visibility(this.notePaneVisible('left') ? Visibility.Visible : Visibility.Hidden)

      SplitHandle({
        dragStarted: (): void => { this.startContentDrag(); this.splitDragging = true; },
        dragUpdated: (offsetX: number): void => { this.updateContentDrag(offsetX); },
        dragEnded: (): void => { this.endSplitDrag(); },
        resetRequested: (): void => { this.resetSplitLayout(); }
      })
        .width(this.breakpoint === Breakpoint.LG && !this.focused && this.referenceVisible ? Space.s4 : 0)
        .margin(this.breakpoint === Breakpoint.LG && !this.focused && this.referenceVisible
          ? { left: -Space.s2, right: -Space.s2 } : { left: 0, right: 0 })
        .enabled(this.breakpoint === Breakpoint.LG && !this.focused && this.referenceVisible)
        .visibility(this.breakpoint === Breakpoint.LG && !this.focused && this.referenceVisible
          ? Visibility.Visible : Visibility.Hidden)

      Column() {
        this.RightWorkspacePane()
      }
      .width(this.notePaneWidth('right'))
      .height('100%')
      .enabled(this.notePaneWidth('right') !== 0)
      .visibility(this.notePaneVisible('right') ? Visibility.Visible : Visibility.Hidden)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.NoteWorkspaceShell()
      }
        .width('100%')
        .height('100%')
        .visibility(this.topView === 'note' ? Visibility.Visible : Visibility.Hidden)

      if (this.topView !== 'note') {
        Column() {
          this.Appbar()
          // 次级页面覆盖在工作区上方，工作区 Web 编辑器保持挂载。
          Stack({ alignContent: Alignment.Bottom }) {
            if (this.topView === 'vaults') {
              this.ManagerView()
            } else if (this.topView === 'history') {
              ReleaseHistoryView()
            } else if (this.topView === 'settings') {
              this.SettingsPane()
            } else if (this.topView === 'agent') {
              this.AgentPane()
            }
            if (this.undoVisible) {
              this.UndoBar()
            }
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_page'))
      }
      if (this.quickSwitchOpen && this.topView === 'note') {
        QuickSwitcher({
          filePaths: this.quickSwitchFiles,
          recentPaths: this.recentOpenPaths,
          searchContent: (query: string,
            onProgress: (completed: number, total: number) => void): Promise<FullTextSearchResult[]> => {
            return FullTextSearchService.search(
              VaultRegistry.get(), this.currentVaultId, query, onProgress);
          },
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
      if (this.shareCaptureActive) {
        this.ShareImageCaptureLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    // 页面底色延伸到系统底部手势安全区；交互控件仍按原窗口安全区排版。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.recordFormatWindowArea(newArea);
    })
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
    .shadow({ radius: 30, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 10 })
    .margin({ bottom: Space.s6 })
  }

  @Builder
  ShareImageCaptureLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      PreviewWebView({
        bridge: this.shareCaptureBridge,
        componentId: this.shareCaptureComponentId,
        onReadAsset: (relPath: string): string => {
          return this.readVaultAsset(relPath);
        },
        onReady: (): void => {
          this.resolveShareCaptureReady();
        },
        onError: (msg: string): void => {
          hilog.error(DOMAIN, TAG, '分享预览加载错误: %{public}s', msg);
          this.rejectShareCaptureReady(new Error('分享预览加载失败，请重试'));
        }
      })
        .width('100%')
        .height('100%')
      Row({ space: Space.s3 }) {
        Text(this.shareCaptureStatus)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('取消')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .onClick((): void => {
            this.cancelShareImageCapture();
          })
      }
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /**
   * 顶栏（需求 2.7，贴合设计稿）：
   *  - 笔记视图 = 汉堡（sm 抽屉 / md+lg 收起唤回）+ 形态对应标题 + 右上「同步 + 设置」图标；
   *  - 次级视图（库管理 / 设置与关于）= 左上角换返回箭头 + 标题「笔记库」/「设置与关于」，
   *    右上图标收敛（设计稿：同步图标仅在笔记视图显示、设置图标在设置视图隐藏）；
   *  - 库管理入口不放在顶栏（侧栏下拉「管理库…」+ 底部「管理库」已覆盖，避免重复）。
   * v0.2 §3.5：高度 56vp、标题 20fp/700、图标热区 48、颜色走 token。
   */
  @Builder
  Appbar() {
    Row() {
      if (this.topView !== 'note' && this.topView !== 'agent') {
        // 次级视图顶栏返回是硬要求（api_notes I3），不依赖系统返回可否拦截
        this.IconButton('back', $r('app.color.text_primary'), (): void => {
          if (this.topView === 'settings') {
            this.returnFromSettings();
          } else {
            this.leaveSecondaryView();
          }
        })
      } else {
        this.IconButton('menu', $r('app.color.text_secondary'), (): void => {
          this.onHamburger();
        })
        if (this.topView === 'agent') {
          this.IconButton('doc', $r('app.color.text_secondary'), (): void => {
            this.moreMenuOpen = false;
            this.topView = 'note';
          })
        }
      }
      // v2 的顶栏只显示当前库名；目录可见时留出标题空间但不重复显示库名。
      Text(this.appBarTitle())
        .fontSize(this.topView === 'note' ? FontSize.caption : FontSize.body1)
        .fontWeight(this.topView === 'note' ? FontWeight.Normal : FontWeight.Medium)
        .fontColor(this.topView === 'note' ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({
          left: this.isSingleScreenLayout() ? Space.s1 : Space.s2,
          right: this.isSingleScreenLayout() ? Space.s1 : Space.s2
        })
        .gesture(TapGesture({ count: 2 }).onAction((): void => {
          if (this.topView === 'agent') {
            this.agentRenameSeq++;
          }
        }))
      if (this.topView === 'note') {
        if (this.agentKitSlotBuilder !== null) {
          Row() {
            this.agentKitSlotBuilder.builder(this.xiaoyiDialogClosed)
          }
          .margin({ left: Space.s1, right: Space.s1 })
        }
        if (this.isSingleScreenLayout()) {
          this.MoreMenuButton()
        } else {
          if (this.currentVaultIsGit()) {
            this.IconButton('sync', $r('app.color.text_secondary'), (): void => {
              void this.openGitSyncPage();
            })
          }
          this.IconButton('columns', this.isReferenceShown()
            ? $r('app.color.brand') : $r('app.color.text_secondary'), (): void => {
            this.toggleReference();
          }, this.isReferenceShown()
            ? $r('app.color.brand_bg') : Color.Transparent)
          this.IconButton('share', $r('app.color.text_secondary'), (): void => {
            this.openShareNoteDialog();
          })
          this.IconButton('settings', $r('app.color.text_secondary'), (): void => {
            this.openSettings('note', 'general');
          })
          this.IconButton('focus', this.focused
            ? $r('app.color.brand') : $r('app.color.text_secondary'), (): void => {
            this.toggleFocus();
          })
        }
      } else if (this.topView === 'agent') {
        this.IconButton('settings', $r('app.color.text_secondary'), (): void => {
          this.openSettings('agent', 'agent');
        })
      }
    }
    .width('100%')
    .height(this.breakpoint === Breakpoint.SM || (this.windowHeightVp > 0 && this.windowHeightVp < 480)
      ? Size.appbarH : Size.appbarWideH)
    .padding({ left: this.workspaceGutter(), right: this.workspaceGutter() })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  MoreMenuButton() {
    Row() {
      Icon('more', Space.s5, $r('app.color.text_secondary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .onClick(() => { this.moreMenuOpen = !this.moreMenuOpen; })
    .bindPopup(this.moreMenuOpen, {
      builder: this.MoreMenu(),
      placement: Placement.BottomRight,
      enableArrow: false,
      offset: { x: 0, y: Space.s2 },
      mask: false,
      autoCancel: true,
      popupColor: Color.Transparent,
      onWillDismiss: (action: DismissPopupAction): void => {
        action.dismiss();
        this.moreMenuOpen = false;
      }
    })
  }

  @Builder
  MoreMenu() {
    Column() {
      if (this.currentVaultIsGit()) {
        Row() {
          Text('同步到 Git')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .onClick((): void => {
          void this.openGitSyncPage();
        })
      }
      Row() {
        Text('分享笔记')
          .fontSize(FontSize.body2)
          .fontColor(this.activeFilePath().length > 0
            ? $r('app.color.text_primary') : $r('app.color.text_disabled'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .enabled(this.activeFilePath().length > 0)
      .onClick(() => {
        this.moreMenuOpen = false;
        this.openShareNoteDialog();
      })
      Row() {
        Text('设置与关于')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .onClick(() => {
        this.moreMenuOpen = false;
        this.openSettings('note', 'general');
      })
      Row() {
        Text(this.activeFilePath().length > 0 && this.backlinksExpanded &&
          this.backlinksPane === this.activePane ? '隐藏反链' : '查看反链')
          .fontSize(FontSize.body2)
          .fontColor(this.activeFilePath().length > 0
            ? $r('app.color.text_primary') : $r('app.color.text_disabled'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .enabled(this.activeFilePath().length > 0)
      .onClick((): void => {
        this.moreMenuOpen = false;
        this.toggleBacklinks(this.activePane);
      })
      if (this.currentFilePath.length > 0 && this.rightFilePath.length > 0 &&
        this.currentFilePath !== this.rightFilePath) {
        Row() {
          Text('切换到 ' + (this.activePane === 'left'
            ? this.rightFilePath.substring(this.rightFilePath.lastIndexOf('/') + 1)
            : this.currentFilePath.substring(this.currentFilePath.lastIndexOf('/') + 1)))
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .onClick((): void => {
          this.moreMenuOpen = false;
          this.toggleActivePane();
        })
      }
    }
    .width(Size.sidebarW)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 30, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 10 })
  }

  @Builder
  NoteNavigation(asDrawer: boolean) {
    VaultSidebar({
      asDrawer: asDrawer,
      compact: this.isSingleLandscape(),
      vaults: this.vaults,
      currentVaultId: this.currentVaultId,
      noteCount: this.currentVaultNoteCount,
      sidebarTab: this.sidebarTab,
      currentFilePath: this.activeFilePath(),
      chapters: this.chapterEntries,
      selectedChapterIndex: this.selectedChapterIndex,
      refreshSeq: this.treeSeq,
      trashRefreshSeq: this.trashSeq,
      revealPath: this.revealPath,
      onCollapse: (): void => {
        if (asDrawer) {
          this.setDrawerOpen(false);
        } else {
          this.setSidebarCollapsed(true);
        }
      },
      onSwitchVault: (id: string): void => {
        this.closeNoteNavigation();
        this.doSwitchVault(id);
      },
      onManageVaults: (): void => {
        this.closeNoteNavigation();
        void this.openVaultManager('note');
      },
      onOpenSearch: (): void => {
        this.closeNoteNavigation();
        this.openQuickSwitcher();
      },
      onShareVault: (): void => {
        this.closeNoteNavigation();
        this.openShareVault();
      },
      onImportGit: (): void => {
        this.closeNoteNavigation();
        void this.openGitSyncPage();
      },
      onCreateNote: (): void => {
        this.closeNoteNavigation();
        this.openCreateNoteDialog();
      },
      onCreateInDir: (dirRelPath: string): void => {
        this.closeNoteNavigation();
        this.openCreateNoteDialog(dirRelPath);
      },
      onRenamePath: (relPath: string, isDir: boolean): void => {
        this.closeNoteNavigation();
        this.openRenamePathDialog(relPath, isDir);
      },
      onMovePath: (relPath: string, isDir: boolean): void => {
        this.closeNoteNavigation();
        this.openMovePathDialog(relPath, isDir);
      },
      onDeletePath: (relPath: string, isDir: boolean): void => {
        this.closeNoteNavigation();
        this.openDeletePathDialog(relPath, isDir);
      },
      onSharePath: (relPath: string, isDir: boolean): void => {
        this.closeNoteNavigation();
        this.openSharePath(relPath, isDir);
      },
      onSwipeDelete: (relPath: string): void => {
        this.closeNoteNavigation();
        void this.doTrashFile(relPath);
      },
      onRestoreTrash: (relPath: string): void => {
        this.doRestoreFromTrash(relPath);
      },
      onSelectFile: (relPath: string): void => { this.onSelectFile(relPath); },
      onSidebarTabChange: (tab: string): void => { this.setSidebarTab(tab); },
      onSelectChapter: (index: number): void => { this.selectChapter(index); },
      onOpenOtherPane: (relPath: string): void => { this.openFileInOtherPane(relPath); }
    })
  }

  /** Single-screen note navigation pushes the full-width editor/preview rail. */
  @Builder
  SmContent() {
    Row() {
      Column() {
        this.NoteNavigation(true)
      }
      .width(Size.drawerW)
      .height('100%')
      .margin({ left: -Size.drawerW * (1 - this.drawerProgress) })
      .enabled(this.drawerOpen)
      .animation({ duration: Motion.durNav, curve: Motion.navCurve })

      Stack({ alignContent: Alignment.Start }) {
        Column() {
          this.LeftWorkspacePane(false)
        }
        .width('100%')
        .height('100%')
        .visibility(this.activePane === 'left' ? Visibility.Visible : Visibility.Hidden)
        Column() {
          this.RightWorkspacePane()
        }
        .width('100%')
        .height('100%')
        .visibility(this.activePane === 'right' ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%')
      .height('100%')
      .translate({ x: Size.drawerW * this.drawerProgress })
      .animation({ duration: Motion.durNav, curve: Motion.navCurve })
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }

  @Builder
  SingleLandscapeContent() {
    Row() {
      Column() {
        this.NoteNavigation(false)
      }
      .width(this.noteNavigationWidth())
      .height('100%')
      .margin({ left: -this.noteNavigationWidth() * (1 - this.sidebarProgress) })
      .enabled(!this.sidebarCollapsed)
      .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

      SplitHandle({
        dragStarted: (): void => { this.startNavigationDrag(false); },
        dragUpdated: (offsetX: number): void => { this.updateNavigationDrag(offsetX, false); },
        dragEnded: (): void => { this.endSplitDrag(); },
        resetRequested: (): void => { this.resetSplitLayout(); }
      })
        .width(Space.s4 * this.sidebarProgress)
        .margin({ left: -Space.s2 * this.sidebarProgress,
          right: -Space.s2 * this.sidebarProgress })
        .enabled(!this.sidebarCollapsed)
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

      Stack({ alignContent: Alignment.Start }) {
        Column() {
          this.LeftWorkspacePane(false)
        }
        .width('100%')
        .height('100%')
        .visibility(this.activePane === 'left' ? Visibility.Visible : Visibility.Hidden)
        Column() {
          this.RightWorkspacePane()
        }
        .width('100%')
        .height('100%')
        .visibility(this.activePane === 'right' ? Visibility.Visible : Visibility.Hidden)
      }
      .width(Math.max(0, this.windowWidthVp - this.noteNavigationWidth() * this.sidebarProgress))
      .height('100%')
      .clip(true)
    }
    .width('100%')
    .height('100%')
  }

  /** md/lg：物理双屏保留等屏布局，lg 使用共享导航和内容分隔条。 */
  @Builder
  WideContent() {
    Row() {
      if (this.breakpoint === Breakpoint.MD) {
        Column() {
          this.NoteNavigation(false)
        }
        .width('50%')
        .height('100%')
        .margin({ left: -this.windowWidthVp * 0.5 * (1 - this.sidebarProgress) })
        .enabled(!this.sidebarCollapsed)
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

        Column() {
          this.LeftWorkspacePane(false)
        }
        .width(this.windowWidthVp * 0.5)
        .height('100%')

        Column() {
          this.RightWorkspacePane()
        }
        .width(this.windowWidthVp * 0.5 * (1 - this.sidebarProgress))
        .height('100%')
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })
      } else {
        Column() {
          this.NoteNavigation(false)
        }
        .width(this.noteNavigationWidth())
        .height('100%')
        .margin({ left: -this.noteNavigationWidth() * (1 - this.sidebarProgress) })
        .enabled(!this.sidebarCollapsed)
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

        SplitHandle({
          dragStarted: (): void => { this.startNavigationDrag(false); },
          dragUpdated: (offsetX: number): void => { this.updateNavigationDrag(offsetX, false); },
          dragEnded: (): void => { this.endSplitDrag(); },
          resetRequested: (): void => { this.resetSplitLayout(); }
        })
          .width(Space.s4 * this.sidebarProgress)
          .margin({ left: -Space.s2 * this.sidebarProgress,
            right: -Space.s2 * this.sidebarProgress })
          .enabled(!this.sidebarCollapsed)
          .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

        Column() {
          this.LeftWorkspacePane(false)
        }
        .width(this.noteContentWidth() * this.noteContentRatio())
        .height('100%')
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

        SplitHandle({
          dragStarted: (): void => { this.startContentDrag(); this.splitDragging = true; },
          dragUpdated: (offsetX: number): void => { this.updateContentDrag(offsetX); },
          dragEnded: (): void => { this.endSplitDrag(); },
          resetRequested: (): void => { this.resetSplitLayout(); }
        })
          .width(Space.s4)
          .margin({ left: -Space.s2, right: -Space.s2 })
          .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })

        Column() {
          this.RightWorkspacePane()
        }
        .width(this.noteContentWidth() * (1 - this.noteContentRatio()))
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
        .animation({ duration: this.splitDragging ? 0 : Motion.durNav, curve: Motion.navCurve })
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }

  @Builder
  LeftWorkspacePane(showHingeWarning: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.EditorPane(showHingeWarning)
      }
      .width('100%')
      .height('100%')
      .visibility(this.smMode === 'edit' ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.PreviewPane()
      }
      .width('100%')
      .height('100%')
      .visibility(this.smMode === 'preview' ? Visibility.Visible : Visibility.Hidden)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    .onClick((): void => { this.setActivePane('left'); })
  }

  @Builder
  FormatAction(label: string, kind: string, pane: string) {
    Row() {
      if (kind === 'task') {
        Icon('task', Space.s5, $r('app.color.text_primary'))
      } else {
        Text(label)
          .fontSize(FontSize.s3)
          .fontWeight(kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane))
    .onClick((): void => { this.applyEditorFormat(kind, pane); })
  }

  @Builder
  ImageFormatAction(pane: string) {
    Row() {
      Icon('image', Space.s5, this.isImagePickerBusy(pane)
        ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane) && !this.isImagePickerBusy(pane))
    .onClick((): void => { void this.pickImageForCurrentNote(pane); })
  }

  @Builder
  FormatCell(glyph: string, caption: string, kind: string) {
    Column({ space: Space.s1 }) {
      Text(glyph)
        .fontSize(FontSize.s2)
        .fontColor(kind === 'code' && (this.formatMenuPane === 'right'
          ? this.rightCodeBlockActive : this.leftCodeBlockActive)
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
      Text(caption)
        .fontSize(FontSize.caption)
        .fontColor(kind === 'code' && (this.formatMenuPane === 'right'
          ? this.rightCodeBlockActive : this.leftCodeBlockActive)
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
    }
    .width('100%')
    .constraintSize({ minHeight: Size.touch })
    .padding({ top: Space.s2, bottom: Space.s2 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(kind === 'code' && (this.formatMenuPane === 'right'
      ? this.rightCodeBlockActive : this.leftCodeBlockActive)
      ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
    .enabled(this.isPaneEditable(this.formatMenuPane))
    .onClick((): void => {
      this.formatMenuOpen = false;
      this.applyEditorFormat(kind, this.formatMenuPane);
    })
  }

  @Builder
  FormatMenu() {
    Column() {
      Row() {
        Text('文字与段落')
          .fontSize(FontSize.s2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('完成')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .focusable(true)
          .onClick((): void => { this.closeFormatMenu(true); })
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s5, right: Space.s5 })
      .alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: Space.s4 }) {
          Column() {
            Text('段落')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('Aa', '正文', 'paragraph') }
              GridCol() { this.FormatCell('H1', '1 级标题', 'h1') }
              GridCol() { this.FormatCell('H2', '2 级标题', 'h2') }
              GridCol() { this.FormatCell('H3', '3 级标题', 'h3') }
              GridCol() { this.FormatCell('H4', '4 级标题', 'h4') }
              GridCol() { this.FormatCell('H5', '5 级标题', 'h5') }
              GridCol() { this.FormatCell('H6', '6 级标题', 'h6') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          Column() {
            Text('文字')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('B', '加粗', 'bold') }
              GridCol() { this.FormatCell('I', '斜体', 'italic') }
              GridCol() { this.FormatCell('</>', '行内代码', 'inlineCode') }
              GridCol() { this.FormatCell('```', '代码块', 'code') }
              GridCol() { this.FormatCell('↗', '链接', 'link') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4 })
          Column() {
            Text('列表与引用')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('≡', '无序列表', 'list') }
              GridCol() { this.FormatCell('1.', '有序列表', 'ordered') }
              GridCol() { this.FormatCell('☑', '待办', 'task') }
              GridCol() { this.FormatCell('❞', '引用', 'quote') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4 })
        }
        .width('100%')
        .margin({ top: Space.s4 })
        .padding({ left: Space.s5, right: Space.s5, bottom: Space.s5 })
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(0, this.formatMenuMaxHeight - Size.touch - Space.s5) })
      .scrollBar(BarState.Auto)
    }
    .width(this.formatMenuWidth)
    .constraintSize({ maxHeight: this.formatMenuMaxHeight })
    .padding({ top: Space.s5 })
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
    .onKeyEvent((event: KeyEvent): void => { this.onFormatMenuKey(this.formatMenuPane, event); })
  }

  @Builder
  FormatToolbar(pane: string) {
    Row() {
      Blank()
      Row() {
        Row() {
          Text('Aa')
            .fontSize(FontSize.s3)
            .fontColor($r('app.color.text_primary'))
        }
        .width(Size.touch)
        .height(Size.touch)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Radius.full)
        .enabled(this.isPaneEditable(pane))
        .onClick((): void => {
          this.toggleFormatMenu(pane);
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.recordFormatAnchorArea(pane, newArea);
        })
        .onKeyEvent((event: KeyEvent): void => { this.onFormatMenuKey(pane, event); })
        .bindPopup(this.formatMenuOpen && this.formatMenuPane === pane, {
          builder: this.FormatMenu(),
          placement: this.formatPopupPlacement,
          enableArrow: false,
          offset: { x: this.formatPopupOffsetX, y: this.formatPopupOffsetY },
          mask: false,
          autoCancel: true,
          popupColor: Color.Transparent,
          onWillDismiss: (action: DismissPopupAction): void => {
            action.dismiss();
            this.formatMenuOpen = false;
          }
        })
        this.FormatAction('B', 'bold', pane)
        if ((pane === 'right' ? this.rightPaneWidthVp : this.leftPaneWidthVp) >= 280) {
          this.FormatAction('I', 'italic', pane)
        }
        this.FormatAction('☐', 'task', pane)
        if (this.paneFilePath(pane).length > 0) {
          this.ImageFormatAction(pane)
        }
      }
      .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
      .alignItems(VerticalAlign.Center)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.line') })
      .shadow({ radius: 20, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 8 })
      Blank()
    }
    .width('100%')
    .height(Size.touch + Space.s5)
    .padding({ bottom: Space.s5 })
    .margin({ bottom: this.keyboardInsetVp() })
    .alignItems(VerticalAlign.Bottom)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.recordPaneWidth(pane, newArea.width);
      }
    })
  }

  @Builder
  RightWorkspacePane() {
    Column() {
      this.PaneHead({ pane: 'right' })
      this.PaneTitle({ pane: 'right' })
      if (!this.rightEditing && this.backlinksExpanded && this.backlinksPane === 'right') {
        this.BacklinkPanel()
      }
      Stack({ alignContent: Alignment.Bottom }) {
        Stack() {
          EditorWebView({
            bridge: this.rightEditorBridge,
            showLineNumbers: this.showLineNumbers,
            onChange: (len: number): void => {
              this.resetSaveFeedback();
              WorkspaceEditGuard.mark('right', this.currentVaultId, this.rightFilePath);
              this.rightEditorDirty = true;
              this.rightEditorLen = len;
              this.scheduleRightSave();
              void this.syncRightContentToLeft();
              if (this.activePane === 'right') {
                void this.refreshActiveChaptersFromBridge();
              }
            },
            onScrollPositionChange: (top: number): void => {
              this.updateWorkspaceScroll('right', 'edit', top);
            },
            onSourceScrollChange: (anchor: PreviewFollowAnchor): void => {
              this.handlePreviewFollowSourceScroll('right', anchor);
            },
            onCompositionChange: (composing: boolean): void => {
              this.onRightCompositionChange(composing);
            },
            onCodeBlockStateChange: (active: boolean): void => {
              this.rightCodeBlockActive = active;
            },
            onLinkCompletion: (id: number, query: string): void => {
              this.provideRightWikiLinkCompletions(id, query);
            },
            onReady: (): void => {
              void this.readRightAndPush(this.rightFilePath);
            },
            onError: (msg: string): void => {
              hilog.error(DOMAIN, TAG, '右栏编辑器 Web: %{public}s', msg);
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.rightEditing ? Visibility.Visible : Visibility.Hidden)
          PreviewWebView({
            bridge: this.rightPreviewBridge,
            onReadAsset: (relPath: string): string => { return this.readVaultAsset(relPath); },
            onScrollPositionChange: (top: number): void => {
              this.updateWorkspaceScroll('right', 'preview', top);
            },
            onWikiLinkClick: (target: string): void => { void this.handleWikiLinkClick(target, 'right'); },
            onError: (msg: string): void => {
              hilog.error(DOMAIN, TAG, '右栏预览 Web: %{public}s', msg);
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.rightEditing ? Visibility.Hidden : Visibility.Visible)
          if (this.rightFilePath.length === 0) {
            this.EmptyPane()
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
        if (this.rightEditing && this.rightFilePath.length > 0) {
          this.FormatToolbar('right')
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.recordFormatPaneArea('right', newArea);
    })
    .onClick((): void => { this.setActivePane('right'); })
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
      this.PaneHead({ pane: 'left' })
      this.PaneTitle({ pane: 'left' })

      Stack({ alignContent: Alignment.Bottom }) {
        Stack() {
        // M0.5 spike：CodeMirror 6 跑在 Web 组件里（web/mdeditor → rawfile/mdeditor/index.html）。
        // 内容由本页在「选中文件 / 切库」时读好下发；组件本身不碰文件 IO（硬约束 14）。
        EditorWebView({
          bridge: this.editorBridge,
          showLineNumbers: this.showLineNumbers,
          onChange: (len: number): void => {
            // 编辑中：记长度（观察击键是否过桥正常）+ 触发防抖自动保存（M2 2.3）
            this.resetSaveFeedback();
            WorkspaceEditGuard.mark('left', this.currentVaultId, this.currentFilePath);
            this.editorDirty = true;
            if (len !== this.editorLen) {
              this.editorLen = len;
            }
            this.scheduleSave();
            this.schedulePreviewUpdate();
            void this.syncLeftContentToRight();
            if (this.activePane === 'left') {
              void this.refreshActiveChaptersFromBridge();
            }
          },
          onScrollPositionChange: (top: number): void => {
            this.updateWorkspaceScroll('left', 'edit', top);
          },
          onSourceScrollChange: (anchor: PreviewFollowAnchor): void => {
            this.handlePreviewFollowSourceScroll('left', anchor);
          },
          onCompositionChange: (composing: boolean): void => {
            this.onLeftCompositionChange(composing);
          },
          onCodeBlockStateChange: (active: boolean): void => {
            this.leftCodeBlockActive = active;
          },
          onLinkCompletion: (id: number, query: string): void => {
            this.provideWikiLinkCompletions(id, query);
          },
          onReady: (): void => {
            // 页面就绪后补一次内容加载：EditorWebView 的指令队列保证此前收到的
            // setContent 不丢。Web 容器因窗口尺寸变化重建时只重读，不先 flush 空 WebView，
            // 避免把当前笔记覆盖为空文件。
            if (!this.workspaceSessionRestoreStarted) {
              void this.initializeWorkspaceSession();
            } else {
              void this.readAndPush(this.currentFilePath, false);
            }
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
        if (this.currentFilePath.length === 0) {
          this.EmptyPane()
        }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
        if (this.smMode === 'edit' && this.currentFilePath.length > 0) {
          this.FormatToolbar('left')
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.recordFormatPaneArea('left', newArea);
    })
  }

  /**
   * 预览区（M3 3.1/3.2）：marked 渲染器跑在 Web 组件里（web/mdpreview → rawfile）。
   * 内容由本页在「加载文件 / 编辑器变化（500ms 防抖）/ 切预览」时推送；
   * 本地图片经 readVaultAsset 桥换 data URI。组件不碰文件 IO（硬约束 14）。
   */
  @Builder
  PreviewPane() {
    Column() {
      this.PaneHead({ pane: 'left' })
      this.PaneTitle({ pane: 'left' })
      if (this.backlinksExpanded && this.backlinksPane === 'left') {
        this.BacklinkPanel()
      }
      Stack() {
        PreviewWebView({
          bridge: this.previewBridge,
          onReadAsset: (relPath: string): string => {
            return this.readVaultAsset(relPath);
          },
          onScrollPositionChange: (top: number): void => {
            this.updateWorkspaceScroll('left', 'preview', top);
          },
          onWikiLinkClick: (target: string): void => {
            void this.handleWikiLinkClick(target);
          },
          onError: (msg: string): void => {
            hilog.error(DOMAIN, TAG, '预览 Web: %{public}s', msg);
          }
        })
          .width('100%')
          .height('100%')
        if (this.currentFilePath.length === 0) {
          this.EmptyPane()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  BacklinkPanel() {
    Column() {
      Row({ space: Space.s2 }) {
        Text('反链')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
        Text(this.backlinkPaths.length.toString())
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Text(this.backlinksExpanded ? '收起' : '展开')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .height(Size.buttonH)
      .padding({ left: Space.s4, right: Space.s4 })
      .onClick((): void => { this.backlinksExpanded = false; })

      if (this.backlinksExpanded) {
        if (this.backlinksLoading) {
          Text('正在读取反链…')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: Space.s4, right: Space.s4, bottom: Space.s3 })
        } else if (this.backlinksFailed) {
          Text('反链读取失败')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: Space.s4, right: Space.s4, bottom: Space.s3 })
        } else if (this.backlinkPaths.length === 0) {
          Text(this.activeFilePath().length === 0 ? '选择笔记后可查看反链' : '暂无来源笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: Space.s4, right: Space.s4, bottom: Space.s3 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.backlinkPaths, (path: string): void => {
                Row() {
                  Text(path)
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .height(Space.s8)
                .padding({ left: Space.s4, right: Space.s4 })
                .onClick((): void => {
                  this.onSelectFile(path);
                })
              }, (path: string): string => path)
            }
            .width('100%')
          }
          .height(Size.itemH * 2)
        }
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
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
      singleScreenLayout: this.isSingleScreenLayout(),
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      paneWidthSummary: this.settingsPaneWidthSummary(),
      currentVaultId: this.currentVaultId,
      vaults: this.vaults,
      showLineNumbers: this.showLineNumbers,
      selectedCategory: this.settingsCategory,
      showCategoryList: this.isSingleScreenLayout() && !this.settingsDetail,
      showCategoryBack: this.isSingleScreenLayout() && this.settingsDetail && this.settingsReturnView !== 'agent',
      onSelectCategory: (category: string): void => {
        this.settingsCategory = category;
        if (this.isSingleScreenLayout()) {
          this.settingsDetail = true;
        }
      },
      onBackToCategories: (): void => { this.settingsDetail = false; },
      onOpenHistory: (): void => { this.topView = 'history'; },
      onResetSplit: (): void => { this.resetSplitLayout(); },
      onShowLineNumbersChange: (show: boolean): void => { this.setShowLineNumbers(show); }
    })
  }

  @Builder
  AgentPane() {
    AgentWorkspace({
      vaultId: this.currentVaultId,
      vaults: this.vaults,
      noteCount: this.currentVaultNoteCount,
      breakpoint: this.breakpoint,
      singleLandscape: this.isSingleLandscape(),
      navToggleSeq: this.agentHamburgerSeq,
      renameCurrentSeq: this.agentRenameSeq,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      navigationWidthVp: this.agentNavigationWidth(),
      splitDragging: this.splitDragging,
      refreshSeq: this.treeSeq,
      onTitleChanged: (title: string): void => { this.agentTitle = title; },
      isUnsaved: (path: string): boolean => path === this.currentFilePath && this.editorDirty,
      onOpenNote: (path: string): void => { this.openAgentNote(path); },
      onSwitchVault: (id: string): void => { this.doSwitchVault(id); },
      onManageVaults: (): void => { void this.openVaultManager('agent'); },
      onImportGit: (): void => { void this.openGitSyncPage(); },
      onNavigationDragStart: (): void => { this.startNavigationDrag(true); },
      onNavigationDrag: (offsetX: number): void => { this.updateNavigationDrag(offsetX, true); },
      onSplitDragEnd: (): void => { this.endSplitDrag(); },
      onSplitReset: (): void => { this.resetSplitLayout(); },
      onNotesChanged: (): void => { this.refreshFileTree(); }
    })
  }

  /** 状态栏：当前库 + 档位 + vp 宽度（spec FR：状态栏联动断点） */
  @Builder
  Statusbar() {
    Row() {
      Blank()
      Text((this.activePane === 'right' ? this.rightEditorLen : Math.max(0, this.editorLen)).toString() + ' 字')
        .fontSize(FontSize.caption)
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

  @Builder
  SaveFeedback() {
    if (this.saveFeedbackMounted) {
      Row({ space: Space.s2 }) {
        Row()
          .width(Space.s2)
          .height(Space.s2)
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.success'))
        Text('更改已保存在本地')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
      .border({ width: 1, color: $r('app.color.line') })
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_card'))
      .opacity(this.saveFeedbackOpacity)
      .animation({ duration: Motion.durBase, curve: Curve.EaseInOut })
      .margin({ left: Space.s5, bottom: this.saveFeedbackBottomMargin() })
      .hitTestBehavior(HitTestMode.None)
    }
  }
}
