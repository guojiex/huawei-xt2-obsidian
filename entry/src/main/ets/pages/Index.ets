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
import { ColorMetrics, KeyboardAvoidMode, LengthMetrics, promptAction, router } from '@kit.ArkUI';
import { BusinessError, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { Breakpoint } from '../model/Breakpoint';
import { FocusRequest } from '../common/FocusRequest';
import { SAMPLE_VAULT_ID, sanitizeVaultName, VaultEntry } from '../model/Vault';
import { GIT_IMPORTING_SUFFIX, VaultRegistry } from '../model/VaultRegistry';
import { VaultDirChild } from '../model/VaultAccess';
import { AgentMemoryStore } from '../model/AgentMemoryStore';
import { AgentRuntime } from '../model/AgentRuntime';
import { NotePathMutationResult, NoteService } from '../model/NoteService';
import { WorkspaceEditGuard } from '../model/WorkspaceEditGuard';
import { FileTree } from '../model/FileTree';
import { WikiLinkCandidate, WikiLinkParser, WikiLinkResolution } from '../model/WikiLinkParser';
import { WikiLinkService, WikiLinkUpdateReport } from '../model/WikiLinkService';
import { MarkdownImageParts, MarkdownInlineParser } from '../model/MarkdownInlineParser';
import { ChapterEntry, VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerShareSummary, VaultManagerView } from '../components/VaultManagerView';
import {
  currentWeekFlagsOf,
  emptyStatsModel,
  VaultStatsModel,
  VaultStatsScanOutcome,
  VaultStatsService
} from '../model/VaultStatsService';
import { VaultStatsDialog } from '../components/VaultStatsDialog';
import { SettingsView } from '../components/SettingsView';
import { ReleaseHistoryView } from '../components/ReleaseHistoryView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';
import { ImportVaultDialog } from '../components/ImportVaultDialog';
import { GitSyncDialog } from '../components/GitSyncDialog';
import {
  CreateNoteDialog,
  DeletePathDialog,
  MovePathDialog,
  PurgeTrashDialog,
  RenamePathDialog
} from '../components/NoteDialogs';
import { QuickSwitcher } from '../components/QuickSwitcher';
import { TrashService, UndoSnap } from '../model/TrashService';
import { RecentOpenStore } from '../model/RecentOpenStore';
import {
  formatRecentErrorFeedback,
  RecentErrorCategory,
  RecentErrorNextStep,
  RecentErrorOperation,
  RecentErrorOutcome,
  RecentErrorPhase,
  RecentErrorStore
} from '../model/RecentErrorStore';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitNativeService } from '../git/GitNativeService';
import { EditorBridge, EditorSnapshot, EditorWebView } from '../components/EditorWebView';
import { EditorNoteSession } from '../model/EditorNoteSession';
import {
  isSameBlockPanelTarget,
  PreviewBlockAnchor,
  PreviewBridge,
  PreviewCaptureResult,
  PreviewCodeEditRequest,
  PreviewEditHistoryAction,
  PreviewWebView
} from '../components/PreviewWebView';
import { AgentWorkspace } from '../components/AgentWorkspace';
import { StartupMask } from '../components/StartupMask';
import { Icon } from '../common/Icons';
import { noteDisplayName, noteDisplayNameOfPath } from '../common/NoteDisplayName';
import { FontSize, Motion, Radius, ScreenSaver, Shadow, Size, Space, Weight } from '../common/Tokens';
import { SplitLayoutStore } from '../model/SplitLayoutStore';
import { EditorPreferenceStore } from '../model/EditorPreferenceStore';
import { VaultStatsPreferenceStore } from '../model/VaultStatsPreferenceStore';
import { ScreenSaverPreferenceStore } from '../model/ScreenSaverPreferenceStore';
import { XiaoyiEntryPreferenceStore } from '../model/XiaoyiEntryPreferenceStore';
import { DEFAULT_EDITOR_EXPERIENCE, EditorExperienceMode } from '../model/EditorExperiencePolicy';
import { EditorExperienceStore } from '../model/EditorExperienceStore';
import { ShareImagePreferenceStore } from '../model/ShareImagePreferenceStore';
import { PreviewFollowAnchor, PreviewFollowPair, resolvePreviewFollowPair } from '../model/PreviewFollowPolicy';
import {
  restoreWorkspacePane,
  WorkspaceSession,
  workspaceSessionPaths,
  WorkspaceSessionStore
} from '../model/WorkspaceSessionStore';
import {
  clampContentRatio,
  clampNavigationWidth,
  contentMinVp,
  DEFAULT_CONTENT_RATIO,
  DEFAULT_NAV_RATIO,
  isSingleLandscapeWindow,
  MAX_NAV_RATIO,
  MdPaneWidths,
  mdPaneWidths,
  MIN_NAV_RATIO,
  navigationWidth,
  navMinVp
} from '../model/PaneLayout';
import { SplitHandle } from '../components/SplitHandle';
import { ShareFormatOption, ShareNoteDialog, ShareScopeOption } from '../components/ShareNoteDialog';
import { ShareImagePreviewDialog, ShareImagePreviewImage } from '../components/ShareImagePreviewDialog';
import { ShareFilePreviewDialog } from '../components/ShareFilePreviewDialog';
import { ShareTextPreviewDialog } from '../components/ShareTextPreviewDialog';
import { SaveShareDialog } from '../components/SaveShareDialog';
import { ShareIngestDraft, ShareIngestPayload, ShareIngestService } from '../model/ShareIngestService';
import { SharePdfPreviewFlow, SharePdfPreviewRequest } from '../model/SharePdfPreviewFlow';
import { NoteShareService, PreparedNoteShare } from '../model/NoteShareService';
import { NoteImageShareGeometry, NoteImageShareService } from '../model/NoteImageShareService';
import { NotePdfDocumentService } from '../model/NotePdfDocumentService';
import { NoteTextSharePreview, NoteTextShareService } from '../model/NoteTextShareService';
import { NoteImageService } from '../model/NoteImageService';
import { NoteDraftRecovery, NoteDraftService } from '../model/NoteDraftService';
import { shouldShowSaveFeedback } from '../model/SaveFeedbackPolicy';
import { PreparedArchiveShare, ShareArchiveService, ShareSnapshot } from '../model/ShareArchiveService';
import { ShareLinkScope, ShareLinkService } from '../model/ShareLinkService';
import { FullTextSearchService } from '../model/FullTextSearchService';
import { SearchOutcome } from '../model/SearchStore';
import { CrossVaultSearchOutcome, CrossVaultSearchService } from '../model/CrossVaultSearchService';
import {
  ExternalDirectoryGrant,
  ExternalDirectorySelection,
  ExternalVaultAuthorizationService
} from '../model/ExternalVaultAuthorization';
import { createExternalVaultAuthorization } from '../model/ExternalVaultAuthorizationDevice';
import { GitImportDraft, GitImportDraftStore } from '../model/GitImportDraftStore';
import { VaultPathResolver } from '../model/VaultPathResolver';
import {
  ZipChooseOutcome,
  ZipImportError,
  ZipImportErrorKind,
  ZipImportOutcome,
  ZipImportResult,
  ZipImportService,
  ZipParsed,
  ZipPickResult
} from '../model/ZipImportService';
import {
  copyPickerZipToStaging,
  DeviceZipPicker,
  freeBytesUnder,
  removeStagingFile,
  StagingZipReader,
  TempVaultZipWriter,
  ZlibRawInflate
} from '../model/ZipImportDevice';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { blockPanelTitleFor, BlockPropertyPanel, PanelImageReplaceContext } from '../components/BlockPropertyPanel';

const DOMAIN: number = 0x0000;
const TAG: string = 'Index';
const EXTERNAL_VAULT_POLL_MS: number = 5000;
/** 控制 Git 导入与同步入口；远端链接分享保持可用。 */
const GIT_ENTRY_UI_ENABLED: boolean = true;

/** PaneHead 的按引用传参载体（@Builder 按值传参不随状态刷新，实测标题停在初始值） */
interface PaneHeadParam {
  pane: string;
}

interface AnchoredPopupLayout {
  placement: Placement;
  offsetX: number;
  offsetY: number;
  width: number;
  maxHeight: number;
}

interface BlockToolbarAction {
  id: string;
  icon: string;
  accessibilityText: string;
  onActivate: () => void;
}

interface TableEditUndoState {
  pane: string;
  vaultId: string;
  path: string;
  requestId: number;
  documentRevision: number;
  expectedContent: string;
}

/** 53.10：带旧帧校验的分段快照结果（快照本体 + 用于下一段比对的像素缓冲）。 */
interface ShareSegmentCapture {
  snapshot: image.PixelMap;
  buffer: ArrayBuffer;
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
  .height(Size.segItemH)
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
  /**
   * 系统字号缩放系数（EntryAbility 启动与 onFontSizeScaleUpdated 回调发布，api_notes AA1/AA2）。
   * v1.39 39.2/39.7：分栏下限按 k=clamp(值,1,1.45) 放大；只钳制布局，不改写已保存比例（39.3）。
   */
  @StorageProp('fontSizeScale') fontSizeScale: number = 1;
  /**
   * v1.56 56.2/56.4：接收系统分享的载荷通道。EntryAbility 在 onCreate / onNewWant
   * 解析 sendData want 后把 JSON 写进 `incomingShare`（receivedAt 时间戳保证同内容
   * 重复分享也触发 @Watch）；aboutToAppear 兜「早到」（冷启动解析先于页面挂载完成），
   * @Watch 兜「晚到」，消费后清空键防重复弹层。
   */
  @StorageProp('incomingShare') @Watch('onIncomingShareChanged') incomingShareJson: string = '';
  /** 57.7：底部导航条避让高度（px，EntryAbility 随 avoidAreaChange 动态发布）；状态条 offset 进条带用。 */
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 库列表（单一数据源 VaultRegistry；CRUD 后 refreshFromRegistry） */
  @State vaults: VaultEntry[] = [];
  @State vaultManagerShareSummaries: VaultManagerShareSummary[] = [];
  /** 当前库 id */
  @State @Watch('onFormatContextChanged') currentVaultId: string = '';
  @State private vaultSwitchInProgress: boolean = false;
  /** 当前库内 Markdown 笔记数量（随注册表和文件树刷新） */
  @State currentVaultNoteCount: number = 0;
  /** 当前 Git 库相对 origin/xt2 的本地超前提交数（仅前台查询，不触发网络）。 */
  @State gitAheadCommitCount: number = 0;
  /** v0.4 快切面板及当前库候选/最近打开项 */
  @State quickSwitchOpen: boolean = false;
  @State quickSwitchFiles: string[] = [];
  @State recentOpenPaths: string[] = [];
  @State leftLastClosedPath: string = '';
  @State rightLastClosedPath: string = '';
  @State private quickSwitchTargetPane: string = 'left';
  @State paneCloseHovered: string = '';
  private recentOpenStore: RecentOpenStore | null = null;
  private recentErrorStore: RecentErrorStore | null = null;
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State @Watch('onFormatContextChanged') sidebarCollapsed: boolean = false;
  /** 次级视图（库管理 / 设置与关于）整体替换内容区；'note' = 笔记主视图（原型 setView 模型） */
  @State @Watch('onFormatContextChanged') topView: string = 'note';
  @State agentKitSlotBuilder: WrappedBuilder<[() => void, string]> | null = null;
  @State showXiaoyiDialogEntry: boolean = false;
  @State vaultManagerReturnView: string = 'note';
  /** v1.58：统计缓存（侧栏连写条只读这里）；打开弹窗时重算并回写，不落盘。 */
  @State vaultStatsModel: VaultStatsModel = emptyStatsModel();
  @State vaultStatsScanning: boolean = true;
  @State vaultStatsFailed: boolean = false;
  @State settingsReturnView: string = 'note';
  @State settingsCategory: string = 'general';
  @State settingsDetail: boolean = false;
  @State settingsPrivacyPolicyOpen: boolean = false;
  @State agentTitle: string = '新对话';
  @State agentHamburgerSeq: number = 0;
  @State agentRenameSeq: number = 0;
  @State moreMenuOpen: boolean = false;
  /** v1.65 65.2：屏保 / 台历覆盖层开关；false 时不挂载，工作区状态完全不变。 */
  @State screenSaverOpen: boolean = false;
  @State focusMoreMenuOnAppear: boolean = false;
  /** v1.31 31.2：单屏更多菜单当前悬停项（hover 高亮 --nav 底） */
  @State mobileMoreHoveredAction: string = '';
  @State formatMenuOpen: boolean = false;
  @State formatMenuPane: string = 'left';
  @State tableGridOpen: boolean = false;
  @State tableGridPane: string = 'left';
  @State tableGridFocusedRows: number = 1;
  @State tableGridFocusedColumns: number = 1;
  @State formatPopupPlacement: Placement = Placement.Top;
  @State formatPopupOffsetX: number = 0;
  @State formatPopupOffsetY: number = -Space.s2;
  @State formatMenuWidth: number = Size.formatMenuW;
  @State formatMenuMaxHeight: number =
    Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2 + Size.touch + Space.s2;
  /** Aa 面板打开时被压制的选区所在栏位与模式（pane 为空 = 未压制）；关面板按此还原选区 UI */
  private formatSelectionSuppressedPane: string = '';
  private formatSelectionSuppressedMode: string = '';
  private leftFormatPaneArea: number[] = [0, 0, 0, 0];
  private rightFormatPaneArea: number[] = [0, 0, 0, 0];
  private leftFormatAnchorArea: number[] = [0, 0, 0, 0];
  private rightFormatAnchorArea: number[] = [0, 0, 0, 0];
  private formatWindowArea: number[] = [0, 0, 0, 0];
  private readonly tableGridRowOptions: number[] = [1, 2, 3, 4, 5, 6, 7, 8];
  private readonly tableGridColumnOptions: number[] = [1, 2, 3, 4, 5, 6];
  @State blockToolbarOpen: boolean = false;
  @State blockToolbarPane: string = 'left';
  @State blockToolbarPlacement: Placement = Placement.BottomLeft;
  @State blockToolbarOffsetX: number = 0;
  @State blockToolbarOffsetY: number = Space.s2;
  @State blockToolbarWidth: number = 0;
  @State blockToolbarMaxHeight: number = 0;
  private leftBlockToolbarPaneArea: number[] = [0, 0, 0, 0];
  private rightBlockToolbarPaneArea: number[] = [0, 0, 0, 0];
  private blockToolbarActions: BlockToolbarAction[] = [];
  @State leftBlockPanelOpen: boolean = false;
  @State rightBlockPanelOpen: boolean = false;
  @State blockPanelPane: string = 'left';
  @State blockPanelTitle: string = '当前块';
  @State blockPanelAnchor: PreviewBlockAnchor | null = null;
  @State pushedAnchor: PreviewBlockAnchor | null = null;
  @State pushedAnchorSeq: number = 0;
  @State pushedAnchorMode: string = 'open';
  @State blockPanelPlacement: Placement = Placement.Bottom;
  @State blockPanelWidth: number = Size.blockPanelW;
  @State blockPanelMaxHeight: number = Size.menuMaxH;
  @State blockPanelHostX: number = 0;
  @State blockPanelHostY: number = 0;
  @State blockPanelSourceVaultId: string = '';
  @State blockPanelSourcePath: string = '';
  private blockPanelRestoreFocus: boolean = false;
  private blockPanelPendingAction: boolean = false;
  private leftCodePreviewEditing: boolean = false;
  private rightCodePreviewEditing: boolean = false;
  private leftCodeEditPending: boolean = false;
  private rightCodeEditPending: boolean = false;
  @State blockSourceEditing: boolean = false;
  private formatMenuSourceVaultId: string = '';
  private formatMenuSourcePath: string = '';
  @State navigationRatio: number = -1;
  @State contentRatio: number = DEFAULT_CONTENT_RATIO;
  @State sidebarProgress: number = 1;
  @State drawerProgress: number = 0;
  @State splitDragging: boolean = false;
  /** 首次工作区快照完成前关闭隐式布局动画，避免冷启动先展开再收起。 */
  @State navigationAnimationsEnabled: boolean = false;
  /** 冷启动恢复期间先遮住默认工作区，待会话与当前可见内容就绪后一帧展示。 */
  @State workspaceInitialRenderReady: boolean = false;
  private layoutBreakpoint: string = '';
  private splitLayoutStore: SplitLayoutStore | null = null;
  private editorPreferenceStore: EditorPreferenceStore | null = null;
  private vaultStatsPreferenceStore: VaultStatsPreferenceStore | null = null;
  private screenSaverPreferenceStore: ScreenSaverPreferenceStore | null = null;
  private xiaoyiEntryPreferenceStore: XiaoyiEntryPreferenceStore | null = null;
  private editorExperienceStore: EditorExperienceStore | null = null;
  private shareImagePreferenceStore: ShareImagePreferenceStore | null = null;
  private agentKitLoadStarted: boolean = false;
  private readonly agentKitUnavailableInSimulator: boolean =
    deviceInfo.productModel.toLowerCase().indexOf('emulator') >= 0;
  private readonly xiaoyiDialogClosed = (): void => {
    void this.refreshWorkspaceAfterXiaoyi();
  };

  /** 小艺入口提示文案：当前打开笔记的说明（未打开笔记时为空串）。 */
  private xiaoyiNoteHint(): string {
    const active: string = this.activeFilePath();
    if (active.length === 0) {
      return '';
    }
    return `关于当前打开的笔记「${this.paneNoteTitle(active)}」（${active}）：`;
  }
  private workspaceSessionStore: WorkspaceSessionStore | null = null;
  private pendingWorkspaceSession: WorkspaceSession | null = null;
  private workspaceSessionRestoreStarted: boolean = false;
  private workspaceSessionRestoring: boolean = false;
  private workspaceSessionSavingEnabled: boolean = false;
  private workspaceSessionSaveTimer: number = -1;
  private workspaceSessionSaveFailureRecorded: boolean = false;
  private workspaceOpenRequests: number = 0;
  private paneCloseRequestSequence: number = 0;
  private leftCloseRequestId: number = 0;
  private rightCloseRequestId: number = 0;
  private leftOpenRequestId: number = 0;
  private rightOpenRequestId: number = 0;
  /** 空栏待聚焦栏位（L-20：目标行 onAppear 挂树后再请求，取代 setTimeout(0) 时序猜测，v1.46 46.5）。 */
  private pendingEmptyPaneFocus: string = '';
  /**
   * 「编辑器当前持有的文档」的配对账本（2026-11-08 跨笔记串写重构，见 EditorNoteSession）。
   * 会话在 setContent 完成后立刻创建，保存链校验 revision 一致才允许落盘；
   * 取代了旧的 committedXxxPath / committedXxxVaultId / lastSavedText / rightLastSavedText 六字段。
   */
  private leftSession: EditorNoteSession | null = null;
  private rightSession: EditorNoteSession | null = null;
  private sharedEditabilityGeneration: number = 0;
  private pendingRestoredChapterOffset: number = -1;
  @State sidebarTab: string = 'files';
  private leftEditorScrollTop: number = 0;
  private leftPreviewScrollTop: number = 0;
  private rightEditorScrollTop: number = 0;
  private rightPreviewScrollTop: number = 0;
  private navigationDragStart: number = 0;
  private contentDragStart: number = 0;
  private navigationRatioAtDragStart: number = -1;
  private contentRatioAtDragStart: number = DEFAULT_CONTENT_RATIO;
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
  @State rightPaneIntentionallyEmpty: boolean = false;
  @State @Watch('onFormatContextChanged') rightEditing: boolean = false;
  @State showLineNumbers: boolean = false;
  /** v1.58 开关：写作统计总开关（默认开）。关闭时隐藏入口、连写条并跳过后台重算。 */
  @State statsEnabled: boolean = false;
  /** v1.65 65.5：名言轮换间隔（应用级偏好，0 = 不轮换）。 */
  @State screenSaverIntervalMs: number = ScreenSaver.defaultIntervalMs;
  @State followPreviewEnabled: boolean = true;
  @State experienceMode: EditorExperienceMode = DEFAULT_EDITOR_EXPERIENCE;
  private leftSimplePreviewCommit: Promise<void> = Promise.resolve();
  private rightSimplePreviewCommit: Promise<void> = Promise.resolve();
  /**
   * 该栏预览里存在「还没回写进编辑器」的改动。预览可编辑时的每次编辑都会异步回写，
   * 回写完清标记；切换编辑模式时只有带标记的栏才必须同步成功，没有改动就不该拦住用户。
   */
  private leftSimplePreviewDirty: boolean = false;
  private rightSimplePreviewDirty: boolean = false;
  private previewFollowPairKey: string = '';
  private previewFollowPane: string = '';
  @State @Watch('onFormatContextChanged') activePane: string = 'left';
  @State @Watch('onFormatContextChanged') referenceVisible: boolean = true;
  @State @Watch('onFormatContextChanged') focused: boolean = false;
  /** 专注模式下临时展开的文件导航（汉堡切换）；退出专注即重置，不进会话快照 */
  @State focusNavigationOpen: boolean = false;
  @State leftPaneWidthVp: number = 0;
  @State rightPaneWidthVp: number = 0;
  @State leftComposing: boolean = false;
  @State rightComposing: boolean = false;
  /** v1.30 30.1：简单模式各栏正文编辑焦点（web 侧可编辑块聚焦/失焦跟踪） */
  @State leftSimpleTextFocus: boolean = false;
  @State rightSimpleTextFocus: boolean = false;
  /** v1.30 30.1：停靠格式栏失焦隐藏去抖定时器（组合输入期间不收起） */
  private leftSimpleFocusHideTimer: number = -1;
  private rightSimpleFocusHideTimer: number = -1;
  @State rightEditorDirty: boolean = false;
  @State rightEditorLen: number = 0;
  @State leftCodeBlockActive: boolean = false;
  @State rightCodeBlockActive: boolean = false;
  @State leftBlockAnchor: PreviewBlockAnchor | null = null;
  @State rightBlockAnchor: PreviewBlockAnchor | null = null;
  @State rightImagePickerBusy: boolean = false;
  @State chapterEntries: ChapterEntry[] = [];
  @State selectedChapterIndex: number = -1;
  @State chapterPath: string = '';
  private rightEditorBridge: EditorBridge = new EditorBridge();
  private rightPreviewBridge: PreviewBridge = new PreviewBridge();
  private rightSaveTimer: number = -1;
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
  private tableEditUndoState: TableEditUndoState | null = null;
  private undoTimer: number = -1;
  /** 单屏态「编辑 / 预览」二选一（v0.2 §3.4-3.3）。
   * 只有一块屏放不下两栏；md/lg 两栏同时可见，这个状态不参与布局。
   */
  @State @Watch('onFormatContextChanged') smMode: string = 'edit';

  /**
   * M2 自动保存（2.3）：编辑器 onChange → 防抖落盘。
   * - `saveTimer`：-1 表示无待触发计时器；切换/后台时清零并立刻 flush。
   * - 「已落盘或已加载」的内容镜像在 EditorNoteSession.baseline 里（跳过无变化的冗余写，
   *   也防止 Web 的 setContent 回灌 change 事件被误判成新编辑而重写一遍）。
   * ⚠️ 切文件 / 新建 / 删除当前文件前必须先 flush 旧文件 —— 否则防抖触发时编辑器已是
   * 新文件内容，却写进旧路径，造成数据损坏（实现见 loadFile / doCreateNote / doDeletePath）。
   */
  private saveTimer: number = -1;
  @State editorDirty: boolean = false;
  @State imagePickerBusy: boolean = false;
  @State saveFeedbackMounted: boolean = false;
  @State saveFeedbackOpacity: number = 0;
  private saveFeedbackTimer: number = -1;
  private saveFeedbackFadeTimer: number = -1;
  private saveFeedbackRevision: number = 0;
  private externalVaultPollTimer: number = -1;
  private externalVaultPolling: boolean = false;
  private externalVaultSnapshotId: string = '';
  private externalVaultSnapshotKey: string = '';
  private externalVaultAccessErrorShown: boolean = false;
  private externalVaultNoteReadErrorKeys: string[] = [];
  private staleSaveNoticeKeys: string[] = [];
  private editorMismatchDialogOpen: boolean = false;
  private lastDraftRecoveryNoticeKey: string = '';

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
  /** v1.58 58.4：写作统计弹窗 controller（每次拉起重建，避免参数过期）。 */
  private statsDialogCtl: CustomDialogController | null = null;
  private statsDialogOpen: boolean = false;
  /** 冷启动 / 切库后的空闲扫描定时器：统计不进首帧关键路径。 */
  private statsIdleTimer: number = -1;
  private importVaultCtl: CustomDialogController | null = null;
  private restoreImportTriggerFocus: () => void = () => {};
  @State private importVaultDialogBusy: boolean = false;
  private gitSyncCtl: CustomDialogController | null = null;
  private gitSyncBusy: boolean = false;
  private pendingExternalDirectory: ExternalDirectorySelection | null = null;
  /** v1.36 ZIP 导入：弹窗侧暂存的解析结果与暂存文件路径（关闭弹窗时清理，36.6）。 */
  private pendingZipParse: ZipParsed | null = null;
  private pendingZipStagingPath: string = '';
  private renameDialogCtl: CustomDialogController | null = null;
  private deleteDialogCtl: CustomDialogController | null = null;
  private createNoteCtl: CustomDialogController | null = null;
  /** 删除确认（文件/目录）对话框 controller（2026-10-18 方案 A 配套） */
  private deletePathCtl: CustomDialogController | null = null;
  /** 回收站永久删除确认 controller（47.3） */
  private purgeTrashCtl: CustomDialogController | null = null;
  /** 重命名 / 移动对话框 controller（1.6 左滑操作条） */
  private renamePathCtl: CustomDialogController | null = null;
  private movePathCtl: CustomDialogController | null = null;
  private shareNoteCtl: CustomDialogController | null = null;
  private shareImagePreviewCtl: CustomDialogController | null = null;
  private shareFilePreviewCtl: CustomDialogController | null = null;
  private shareTextPreviewCtl: CustomDialogController | null = null;
  /** v1.56 56.3：接收系统分享的保存确认层 controller（每次拉起重建） */
  private saveShareCtl: CustomDialogController | null = null;
  /** 53.7：PDF 分页预览流程（会话状态与弹窗编排拆至 model/SharePdfPreviewFlow） */
  private sharePdfPreviewFlow: SharePdfPreviewFlow = new SharePdfPreviewFlow();
  private shareCaptureBridge: PreviewBridge = new PreviewBridge();
  private readonly shareCaptureComponentId: string = 'note-image-share-capture';
  private shareCaptureReadyResolver: (() => void) | null = null;
  private shareCaptureReadyRejecter: ((error: Error) => void) | null = null;
  private shareCaptureReadyTimer: number = -1;
  private shareCaptureCancelled: boolean = false;
  private shareImagePreviewSessionId: string = '';
  private shareImagePreviewTitle: string = '';
  @State shareCaptureActive: boolean = false;
  @State shareCaptureTheme: string = 'light';
  @State shareCaptureWidthVp: number = 0;
  private shareCapturePaneWidthVp: number = 0;
  @State shareCaptureWidthId: string = 'phone';
  /** v1.53 PDF 模式：捕获层按 A4 比例 + 浅色主题渲染（53.3）。 */
  @State shareCapturePdfMode: boolean = false;
  /**
   * PDF 捕获页尺寸（2026-11-11 修复）：不再固定 700×990.59vp——窗口高不足 990.59vp
   * （模拟器 776vp、XT2 折叠 / 展开横屏均如此）时捕获层超出布局边界，#content 实际
   * 视口被压矮，分页要求 scrollHeight ≥ 末页顶 + 990.59 永远补不齐（PDF 分页高度
   * 不足）。现按当前窗口自适应：比例恒 A4 竖版，宽度 ≤ 700vp 且不超窗口宽高，
   * 高度取整（scrollHeight / clientHeight 均为取整值，整数页高消除 ±0.5px 歧义）。
   * prepareNotePdfShare 挂捕获层前调 updatePdfPageSize() 重算。
   */
  private pdfPageWidthVp: number = 700;
  private pdfPageHeightVp: number = 700 * NotePdfDocumentService.A4_HEIGHT_PT /
    NotePdfDocumentService.A4_WIDTH_PT;
  @State shareImagePreviewImage: ShareImagePreviewImage = {
    uri: '', aspectRatio: 1, width: 0, height: 0, theme: 'light', scaled: false, widthId: 'phone'
  };

  aboutToAppear(): void {
    // v1.46 46.6 修复真机双重避让时固定了 RESIZE，但 RESIZE 把键盘起落变成一次
    // 全窗口 resize：三栏 + 两个 Web 每次全部重排（中文输入法弹起整页「刷新弹一遍」）。
    // 改 OFFSET_WITH_CARET（since 14 ≤ 24）：窗口尺寸不动、无全页重排，页面上抬由
    // 系统动画完成，且光标变化时系统持续把光标行调整到可见区（真机效果待验收）。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET_WITH_CARET);
      hilog.info(DOMAIN, TAG, '键盘避让模式固定为 OFFSET_WITH_CARET');
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '设置键盘避让模式失败，错误码 %{public}d %{public}s', err.code, err.message);
    }
    this.previewBridge.onBlockAnchorChange = (anchor: PreviewBlockAnchor | null): void => {
      this.onBlockAnchorChange('left', anchor);
    };
    this.rightPreviewBridge.onBlockAnchorChange = (anchor: PreviewBlockAnchor | null): void => {
      this.onBlockAnchorChange('right', anchor);
    };
    this.previewBridge.onContentReplacing = (): void => {
      this.onPreviewContentReplacing('left');
    };
    this.rightPreviewBridge.onContentReplacing = (): void => {
      this.onPreviewContentReplacing('right');
    };
    this.ensureXiaoyiEntryPreferenceStore();
    this.showXiaoyiDialogEntry = (this.xiaoyiEntryPreferenceStore as XiaoyiEntryPreferenceStore).load();
    if (this.showXiaoyiDialogEntry) {
      void this.loadAgentKitSlot();
    }
    this.refreshFromRegistry();
    this.ensureEditorPreferenceStore();
    this.showLineNumbers = (this.editorPreferenceStore as EditorPreferenceStore).showLineNumbers();
    this.followPreviewEnabled = (this.editorPreferenceStore as EditorPreferenceStore).followPreview();
    this.ensureVaultStatsPreferenceStore();
    this.statsEnabled = (this.vaultStatsPreferenceStore as VaultStatsPreferenceStore).statsEnabled();
    this.ensureScreenSaverPreferenceStore();
    this.screenSaverIntervalMs = (this.screenSaverPreferenceStore as ScreenSaverPreferenceStore).intervalMs();
    this.ensureShareImagePreferenceStore();
    this.shareCaptureTheme = (this.shareImagePreferenceStore as ShareImagePreferenceStore).loadTheme();
    this.shareCaptureWidthId = (this.shareImagePreferenceStore as ShareImagePreferenceStore).loadWidth();
    this.ensureEditorExperienceStore();
    this.experienceMode = (this.editorExperienceStore as EditorExperienceStore).load();
    this.synchronizePreviewFollowContext();
    this.ensureRecentOpenStore();
    this.refreshRecentOpenPaths();
    this.ensureSplitLayoutStore();
    const splitState = (this.splitLayoutStore as SplitLayoutStore).load();
    this.navigationRatio = splitState.navigationRatio;
    this.contentRatio = splitState.contentRatio;
    this.syncNavigationForBreakpoint();
    this.ensureWorkspaceSessionStore();
    this.pendingWorkspaceSession = (this.workspaceSessionStore as WorkspaceSessionStore).load();
    // Restore the session and read note files while ArkWeb initializes; bridges
    // retain the initial content in memory until their first page is ready.
    void this.initializeWorkspaceSession();
    this.startExternalVaultPolling();
    this.cleanupZipImportStaging();
    // v1.56 56.4：冷启动分享——EntryAbility 的载荷可能早于页面挂载就已写进 AppStorage
    //（@StorageProp 初始化同步了它但 @Watch 不触发），这里兜底消费一次。
    if (this.incomingShareJson.length > 0) {
      setTimeout((): void => {
        this.consumeIncomingShare();
      }, 0);
    }
    // v1.58 §5：连写条缓存的首次扫描排到空闲时机，不进入启动页首帧关键路径。
    this.scheduleIdleStatsRefresh();
  }

  private async loadAgentKitSlot(): Promise<void> {
    if (this.agentKitUnavailableInSimulator || this.agentKitLoadStarted) {
      return;
    }
    this.agentKitLoadStarted = true;
    try {
      const agentModule: ESObject = await import('../components/AgentKitSlot');
      const getAgentKitSlotBuilder: () => WrappedBuilder<[() => void, string]> =
        agentModule.getAgentKitSlotBuilder as () => WrappedBuilder<[() => void, string]>;
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

  private ensureVaultStatsPreferenceStore(): void {
    if (this.vaultStatsPreferenceStore === null) {
      this.vaultStatsPreferenceStore = new VaultStatsPreferenceStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureEditorExperienceStore(): void {
    if (this.editorExperienceStore === null) {
      this.editorExperienceStore = new EditorExperienceStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureShareImagePreferenceStore(): void {
    if (this.shareImagePreferenceStore === null) {
      this.shareImagePreferenceStore = new ShareImagePreferenceStore(VaultRegistry.get().abilityContext());
    }
  }

  private async selectEditorExperience(mode: EditorExperienceMode): Promise<void> {
    if (mode === this.experienceMode) {
      return;
    }
    if (this.workspaceOpenRequests > 0) {
      promptAction.showToast({ message: '笔记正在切换，请稍后再切换编辑模式' });
      return;
    }
    if (this.leftComposing || this.rightComposing) {
      promptAction.showToast({ message: '请先完成当前输入，再切换编辑模式' });
      return;
    }
    const targetVaultId: string = this.currentVaultId;
    const targetLeftPath: string = this.currentFilePath;
    const targetRightPath: string = this.rightFilePath;
    const targetLeftRequestId: number = this.leftOpenRequestId;
    const targetRightRequestId: number = this.rightOpenRequestId;
    if (this.experienceMode === 'simple') {
      const syncFailure: string = await this.flushSimplePreviewChanges();
      if (syncFailure.length > 0) {
        promptAction.showToast({ message: '简单模式的正文尚未同步：' + syncFailure + '，编辑模式未更改' });
        return;
      }
    }
    if (this.workspaceOpenRequests > 0 || targetVaultId !== this.currentVaultId ||
      targetLeftPath !== this.currentFilePath || targetRightPath !== this.rightFilePath ||
      targetLeftRequestId !== this.leftOpenRequestId || targetRightRequestId !== this.rightOpenRequestId) {
      promptAction.showToast({ message: '笔记正在切换，请稍后再切换编辑模式' });
      return;
    }
    if (!await this.flushWorkspaceSaves()) {
      if (this.leftComposing || this.rightComposing) {
        promptAction.showToast({ message: '请先完成当前输入，再切换编辑模式' });
      } else {
        promptAction.showToast({ message: '笔记状态尚未就绪，编辑模式未更改' });
      }
      return;
    }
    if (targetVaultId !== this.currentVaultId || targetLeftPath !== this.currentFilePath ||
      targetRightPath !== this.rightFilePath || targetLeftRequestId !== this.leftOpenRequestId ||
      targetRightRequestId !== this.rightOpenRequestId) {
      promptAction.showToast({ message: '笔记正在切换，请稍后再切换编辑模式' });
      return;
    }
    if (this.leftComposing || this.rightComposing) {
      promptAction.showToast({ message: '请先完成当前输入，再切换编辑模式' });
      return;
    }
    this.leftOpenRequestId++;
    this.rightOpenRequestId++;
    this.ensureEditorExperienceStore();
    this.experienceMode = mode;
    // 同步已经收尾（或确认无需同步），清掉标记，避免下次切回简单模式时拿旧标记拦人。
    this.setSimplePreviewDirty('left', false);
    this.setSimplePreviewDirty('right', false);
    void this.refreshPreviewsForExperienceMode();
    void this.refreshSharedEditability();
    if (!(this.editorExperienceStore as EditorExperienceStore).save(mode)) {
      promptAction.showToast({ message: '模式已切换，但偏好保存失败；重启后无法保证保留本次选择' });
    }
  }

  private isCurrentSimplePreviewTarget(pane: string, notePath: string, vaultId: string,
    requestId: number): boolean {
    return pane === 'right'
      ? this.isCurrentRightOpenTarget(notePath, vaultId, requestId)
      : this.isCurrentLeftOpenTarget(notePath, vaultId, requestId);
  }

  private async commitSimplePreviewContent(pane: string, content: string, vaultId: string,
    notePath: string, requestId: number): Promise<boolean> {
    if (this.experienceMode !== 'simple' || vaultId.length === 0 || notePath.length === 0 ||
      !this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
      return false;
    }
    const editor = this.editorBridgeForPane(pane);
    // 预览回写必须对着「本会话记录的那次加载」：会话缺失/路径不符 → 拒绝，
    // 防止预览内容被回写进另一篇笔记的编辑器正文（跨笔记串写防线，见 EditorNoteSession）。
    const session: EditorNoteSession | null = pane === 'right' ? this.rightSession : this.leftSession;
    if (session === null || !session.isFor(vaultId, notePath)) {
      return false;
    }
    // 编辑器当前内容只用于「内容没变就跳过回写」这一个优化：
    // 拿不到（页面不可见时 ArkWeb 可能不回内容）不该判成同步失败，直接按有差异走回写。
    let hasCurrent: boolean = false;
    let current: string = '';
    let currentRevision: number = -1;
    try {
      const snapshot: EditorSnapshot = await editor.getContentSnapshot();
      current = snapshot.text;
      currentRevision = snapshot.revision;
      hasCurrent = true;
    } catch {
      hilog.warn(DOMAIN, TAG, '读取编辑器内容失败，按有差异处理预览回写');
    }
    if (this.experienceMode !== 'simple' ||
      !this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
      return false;
    }
    if (hasCurrent && currentRevision !== session.revision) {
      // 编辑器持有的正文不属于会话记录的加载代次（加载被取代/撕裂）——拒绝回写。
      return false;
    }
    if (hasCurrent && current === content) {
      this.setSimplePreviewDirty(pane, false);
      return true;
    }
    await editor.replaceContentFromPreview(content);
    if (this.experienceMode !== 'simple' ||
      !this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
      return false;
    }
    this.setSimplePreviewDirty(pane, false);
    this.resetSaveFeedback();
    WorkspaceEditGuard.mark(pane, vaultId, notePath);
    if (pane === 'right') {
      this.rightEditorDirty = true;
      this.rightEditorLen = content.length;
      this.scheduleRightSave();
      void this.syncRightContentToLeft();
    } else {
      this.editorDirty = true;
      this.editorLen = content.length;
      this.scheduleSave();
      void this.syncLeftContentToRight();
    }
    return true;
  }

  private setSimplePreviewDirty(pane: string, dirty: boolean): void {
    if (pane === 'right') {
      this.rightSimplePreviewDirty = dirty;
    } else {
      this.leftSimplePreviewDirty = dirty;
    }
  }

  /** 等预览页就绪（上限 1.5s）：页面刚起来 / 后台刚回到前台时，同步前先给它一个就绪的机会。 */
  private waitForPreviewReady(preview: PreviewBridge, timeoutMs: number = 1500): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      let settled: boolean = false;
      const finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        resolve();
      };
      const timerId: number = setTimeout(finish, timeoutMs);
      preview.waitUntilReady().then((): void => {
        clearTimeout(timerId);
        finish();
      });
    });
  }

  private simplePreviewDirty(pane: string): boolean {
    return pane === 'right' ? this.rightSimplePreviewDirty : this.leftSimplePreviewDirty;
  }

  /**
   * 把预览里最后一次（可能还在防抖里没上报的）编辑回写进编辑器源码。
   * @returns 空串＝同步完成；非空＝失败原因，直接进 toast，用户能看出卡在哪一栏哪一步。
   */
  private async flushSimplePreviewPane(pane: string): Promise<string> {
    const label: string = pane === 'right' ? '右栏' : '左栏';
    const notePath: string = this.paneFilePath(pane);
    if (notePath.length === 0) {
      return '';
    }
    const vaultId: string = this.currentVaultId;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
      return label + '笔记目标已变化';
    }
    if (!this.simplePreviewEditable(pane)) {
      return '';
    }
    const preview: PreviewBridge = this.previewBridgeForPane(pane);
    if (!preview.ready) {
      await this.waitForPreviewReady(preview);
      if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
        return label + '笔记目标已变化';
      }
    }
    if (!preview.ready) {
      return this.simplePreviewDirty(pane) ? label + '预览尚未就绪，未能同步正文' : '';
    }
    const dirty: boolean = this.simplePreviewDirty(pane);
    try {
      await (pane === 'right' ? this.rightSimplePreviewCommit : this.leftSimplePreviewCommit);
      if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
        return label + '笔记目标已变化';
      }
      let content: string = '';
      try {
        content = await preview.requestEditableContent();
      } catch {
        if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
          return label + '笔记目标已变化';
        }
        hilog.warn(DOMAIN, TAG, '%{public}s预览未回传正文', label);
        return dirty ? label + '预览未回传正文（页面可能不可见）' : '';
      }
      if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
        return label + '笔记目标已变化';
      }
      if (!await this.commitSimplePreviewContent(pane, content, vaultId, notePath, requestId)) {
        return label + '正文回写编辑器失败';
      }
      return this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)
        ? '' : label + '笔记目标已变化';
    } catch (error) {
      if (!this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
        return label + '笔记目标已变化';
      }
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '%{public}s预览同步异常，错误码 %{public}d', label, err?.code ?? -1);
      return label + '预览同步异常（code=' + (err?.code ?? -1).toString() + '）';
    }
  }

  private async flushSimplePreviewChanges(): Promise<string> {
    for (const pane of ['left', 'right']) {
      const error: string = await this.flushSimplePreviewPane(pane);
      if (error.length > 0) {
        return error;
      }
    }
    return '';
  }

  private handleSimplePreviewEdit(pane: string, content: string): void {
    const vaultId: string = this.currentVaultId;
    const notePath: string = pane === 'right' ? this.rightFilePath : this.currentFilePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    if (this.experienceMode !== 'simple' || this.workspaceOpenRequests > 0 || notePath.length === 0 ||
      !this.isCurrentSimplePreviewTarget(pane, notePath, vaultId, requestId)) {
      return;
    }
    this.setSimplePreviewDirty(pane, true);
    const previous = pane === 'right' ? this.rightSimplePreviewCommit : this.leftSimplePreviewCommit;
    const next = previous.then(async (): Promise<void> => {
      await this.commitSimplePreviewContent(pane, content, vaultId, notePath, requestId);
    }).catch((): void => {
      hilog.warn(DOMAIN, TAG, '简单模式正文同步失败');
    });
    if (pane === 'right') {
      this.rightSimplePreviewCommit = next;
    } else {
      this.leftSimplePreviewCommit = next;
    }
  }

  private async refreshPreviewsForExperienceMode(): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const leftPath: string = this.currentFilePath;
    const rightPath: string = this.rightFilePath;
    const leftRequestId: number = this.leftOpenRequestId;
    const rightRequestId: number = this.rightOpenRequestId;
    if (leftPath.length > 0 && this.editorBridge.ready) {
      try {
        const content: string = await this.editorBridge.getContent();
        if (this.isCurrentLeftOpenTarget(leftPath, vaultId, leftRequestId)) {
          this.pushPreview(content, true);
        }
      } catch {
        hilog.warn(DOMAIN, TAG, '切换编辑模式后刷新左侧预览失败');
      }
    }
    if (rightPath.length > 0 && this.rightEditorBridge.ready) {
      try {
        const content: string = await this.rightEditorBridge.getContent();
        if (this.isCurrentRightOpenTarget(rightPath, vaultId, rightRequestId)) {
          this.pushRightPreview(content, true);
        }
      } catch {
        hilog.warn(DOMAIN, TAG, '切换编辑模式后刷新右侧预览失败');
      }
    }
  }

  private setShowLineNumbers(show: boolean): void {
    this.showLineNumbers = show;
    this.ensureEditorPreferenceStore();
    (this.editorPreferenceStore as EditorPreferenceStore).saveShowLineNumbers(show);
  }

  private setStatsEnabled(enabled: boolean): void {
    this.statsEnabled = enabled;
    this.ensureVaultStatsPreferenceStore();
    (this.vaultStatsPreferenceStore as VaultStatsPreferenceStore).saveStatsEnabled(enabled);
    if (!enabled) {
      // 关闭时丢弃进行中的连写数据，避免连写条/弹窗再引用过期结果。
      this.vaultStatsModel = emptyStatsModel();
      this.vaultStatsScanning = false;
      this.vaultStatsFailed = false;
    } else {
      // 开启时立即排一次空闲扫描，连写条/弹窗无需等冷启动或切库即有数。
      this.scheduleIdleStatsRefresh();
    }
  }

  private ensureScreenSaverPreferenceStore(): void {
    if (this.screenSaverPreferenceStore === null) {
      this.screenSaverPreferenceStore = new ScreenSaverPreferenceStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureXiaoyiEntryPreferenceStore(): void {
    if (this.xiaoyiEntryPreferenceStore === null) {
      this.xiaoyiEntryPreferenceStore = new XiaoyiEntryPreferenceStore(VaultRegistry.get().abilityContext());
    }
  }

  private setShowXiaoyiDialogEntry(show: boolean): void {
    this.ensureXiaoyiEntryPreferenceStore();
    if (!(this.xiaoyiEntryPreferenceStore as XiaoyiEntryPreferenceStore).save(show)) {
      promptAction.showToast({ message: '小艺入口设置保存失败，当前状态未更改。' });
      return;
    }
    this.showXiaoyiDialogEntry = show;
    if (show) {
      void this.loadAgentKitSlot();
    }
  }

  /** v1.65 65.1：右上角菜单进入屏保 / 台历；工作区保持挂载，只叠一层全屏覆盖。 */
  private openScreenSaver(): void {
    this.screenSaverOpen = true;
  }

  /** 组件淡出完成后回调：卸载覆盖层并回到笔记工作区。 */
  private closeScreenSaver(): void {
    this.screenSaverOpen = false;
    this.topView = 'note';
  }

  private setScreenSaverInterval(ms: number): void {
    if (!ScreenSaver.isValidInterval(ms)) {
      return;
    }
    this.screenSaverIntervalMs = ms;
    this.ensureScreenSaverPreferenceStore();
    (this.screenSaverPreferenceStore as ScreenSaverPreferenceStore).saveIntervalMs(ms);
  }

  private currentPreviewFollowPair(): PreviewFollowPair | null {
    return resolvePreviewFollowPair({
      topView: this.topView,
      vaultId: this.currentVaultId,
      leftPath: this.currentFilePath,
      rightPath: this.rightFilePath,
      leftEditing: this.smMode === 'edit',
      rightEditing: this.rightEditing,
      bothPanesVisible: this.experienceMode === 'professional' &&
        !this.isSingleScreenLayout() && this.isReferenceShown()
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

  /** 页面出现时先恢复会话与笔记；可见 Web 面板就绪后再揭示首屏。 */
  private async initializeWorkspaceSession(): Promise<void> {
    if (this.workspaceSessionRestoreStarted) {
      return;
    }
    this.workspaceSessionRestoreStarted = true;
    try {
      const session: WorkspaceSession | null = this.pendingWorkspaceSession;
      if (session === null) {
        const registry: VaultRegistry = VaultRegistry.get();
        const initialNotePath: string = registry.firstInstallNotePath();
        if (initialNotePath.length > 0 && registry.currentId() === SAMPLE_VAULT_ID) {
          this.currentFilePath = initialNotePath;
          if (await this.readAndPush(initialNotePath)) {
            if (this.flushWorkspaceSessionSave()) {
              registry.markFirstInstallNoteOpened();
            }
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
          this.rightPaneIntentionallyEmpty = false;
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

        const opened: boolean = await this.applyWorkspaceSession(session);
        leftOpened = opened;
        rightOpened = opened;
      } catch (error) {
        leftOpened = false;
        rightOpened = false;
        this.currentFilePath = '';
        this.rightFilePath = '';
        this.rightPaneIntentionallyEmpty = false;
        this.sidebarTab = 'files';
        this.pendingRestoredChapterOffset = -1;
        this.leftSession = null;
        this.rightSession = null;
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
    } finally {
      try {
        await this.waitForInitialWorkspaceSurfaces();
      } catch (error) {
        // 首屏恢复不能因某个可见 Web 面板异常而永久停在启动遮罩下。
      }
      this.navigationAnimationsEnabled = true;
      this.workspaceInitialRenderReady = true;
    }
  }

  /**
   * 会话恢复主体（冷启动与切库共用，v1.47 47.4 抽取）：按快照还原工作区状态与
   * 左右栏笔记，含单屏可见栏过滤、滚动位置与章节选择。调用方需置
   * workspaceSessionRestoring = true 包裹，结束后自行恢复保存开关。
   */
  private async applyWorkspaceSession(session: WorkspaceSession): Promise<boolean> {
    const registry: VaultRegistry = VaultRegistry.get();
    const validPaths: string[] = FileTree.allNotesOf(registry.accessFor(session.vaultId));
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
    this.rightPaneIntentionallyEmpty = session.rightPaneIntentionallyEmpty;
    this.sidebarTab = session.sidebarTab;
    this.selectedChapterIndex = -1;
    this.chapterPath = '';
    this.pendingRestoredChapterOffset = session.selectedChapterOffset;
    this.currentFilePath = leftPath;
    this.rightFilePath = rightPath;
    this.leftSession = null;
    this.rightSession = null;
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

    const leftOpened: boolean = await restoreWorkspacePane(leftPath,
      async (path: string): Promise<boolean> => await this.readAndPush(path, false),
      async (): Promise<void> => {
        this.currentFilePath = '';
        await this.readAndPush('', false);
      });
    const rightOpened: boolean = await restoreWorkspacePane(rightPath,
      async (path: string): Promise<boolean> => await this.readRightAndPush(path),
      async (): Promise<void> => {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      });
    this.restoreWorkspaceScrollPositions();
    this.applyRestoredChapterSelection();
    return leftOpened || rightOpened;
  }

  private async waitForInitialWorkspaceSurfaces(): Promise<void> {
    const waits: Array<Promise<void>> = [];
    if (this.notePaneVisible('left')) {
      waits.push(this.experienceMode === 'simple'
        ? this.previewBridge.waitUntilReady()
        : this.smMode === 'edit' ? this.editorBridge.waitUntilReady() : this.previewBridge.waitUntilReady());
    }
    if (this.notePaneVisible('right')) {
      waits.push(this.experienceMode === 'simple'
        ? this.rightPreviewBridge.waitUntilReady()
        : this.rightEditing ? this.rightEditorBridge.waitUntilReady() : this.rightPreviewBridge.waitUntilReady());
    }
    await Promise.all(waits);
  }

  private handleInitialWorkspaceSurfaceError(pane: string, surface: string): void {
    if (this.workspaceInitialRenderReady || !this.notePaneVisible(pane)) {
      return;
    }
    const expectedSurface: string = pane === 'right'
      ? (this.experienceMode === 'simple' || !this.rightEditing ? 'preview' : 'edit')
      : (this.experienceMode === 'simple' || this.smMode === 'preview' ? 'preview' : 'edit');
    if (surface !== expectedSurface) {
      return;
    }
    // A visible Web error also starts restoration so the normal gate can
    // resolve this failed surface and wait for any other visible pane.
    if (!this.workspaceSessionRestoreStarted) {
      void this.initializeWorkspaceSession();
    }
  }

  private restoreWorkspaceScrollPositions(): void {
    let restoreFailed: boolean = false;
    try {
      this.editorBridge.restoreScrollTop(this.leftEditorScrollTop);
      this.previewBridge.restoreScrollTop(this.leftPreviewScrollTop);
    } catch (error) {
      restoreFailed = true;
      hilog.warn(DOMAIN, TAG, '恢复左栏滚动位置失败');
    }
    try {
      this.rightEditorBridge.restoreScrollTop(this.rightEditorScrollTop);
      this.rightPreviewBridge.restoreScrollTop(this.rightPreviewScrollTop);
    } catch (error) {
      restoreFailed = true;
      hilog.warn(DOMAIN, TAG, '恢复右栏滚动位置失败');
    }
    if (restoreFailed) {
      this.recordBackgroundFailure('workspace', 'restore', 'unknown', 'completed_with_warning',
        'check_status');
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

  private flushWorkspaceSessionSave(force: boolean = false): boolean {
    if (this.workspaceSessionSaveTimer !== -1) {
      clearTimeout(this.workspaceSessionSaveTimer);
      this.workspaceSessionSaveTimer = -1;
    }
    return this.saveWorkspaceSessionNow(force);
  }

  private stopWorkspaceSessionSaving(): void {
    this.workspaceSessionSavingEnabled = false;
    if (this.workspaceSessionSaveTimer !== -1) {
      clearTimeout(this.workspaceSessionSaveTimer);
      this.workspaceSessionSaveTimer = -1;
    }
  }

  private saveWorkspaceSessionNow(force: boolean = false): boolean {
    if (!this.workspaceSessionSavingEnabled || this.workspaceSessionRestoring || (!force && this.topView !== 'note') ||
      this.workspaceOpenRequests > 0 || this.currentVaultId.length === 0) {
      return false;
    }
    const chapterOffset: number = this.chapterPath === this.activeFilePath() && this.selectedChapterIndex >= 0 &&
      this.selectedChapterIndex < this.chapterEntries.length
      ? this.chapterEntries[this.selectedChapterIndex].offset : -1;
    const session: WorkspaceSession = {
      schemaVersion: 1,
      vaultId: this.currentVaultId,
      leftPath: this.leftSession !== null ? this.leftSession.path : '',
      rightPath: this.rightSession !== null ? this.rightSession.path : '',
      leftMode: this.smMode,
      rightEditing: this.rightEditing,
      activePane: this.activePane,
      rightPaneIntentionallyEmpty: this.rightPaneIntentionallyEmpty,
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
    if (saved) {
      this.workspaceSessionSaveFailureRecorded = false;
    } else {
      hilog.warn(DOMAIN, TAG, '工作区会话保存失败');
      if (!this.workspaceSessionSaveFailureRecorded) {
        this.workspaceSessionSaveFailureRecorded = true;
        this.recordBackgroundFailure('workspace', 'save', 'storage_failure', 'not_completed', 'check_status');
      }
    }
    return saved;
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

  private appbarHeightVp(): number {
    return this.breakpoint === Breakpoint.SM || (this.windowHeightVp > 0 && this.windowHeightVp < 480)
      ? Size.appbarH : Size.appbarWideH;
  }

  private isSingleScreenLayout(): boolean {
    return this.breakpoint === Breakpoint.SM || this.isSingleLandscape();
  }

  private noteNavigationWidth(): number {
    const contentPanes: number = this.breakpoint === Breakpoint.LG && !this.isSingleLandscape() ? 2 : 1;
    const ratio: number = this.navigationRatio < 0 && this.breakpoint === Breakpoint.MD
      ? 0.38 : this.navigationRatio;
    return navigationWidth(this.windowWidthVp, ratio, contentPanes, 0,
      this.fontSizeScale, this.contentRatio);
  }

  private drawerNavigationWidth(): number {
    return Math.min(Size.drawerW, this.windowWidthVp);
  }

  private agentNavigationWidth(): number {
    return navigationWidth(this.windowWidthVp, this.navigationRatio, 1, 1, this.fontSizeScale);
  }

  private noteContentWidth(): number {
    const progress: number = this.noteNavigationProgress();
    const navWidth: number = this.noteNavigationWidth() * progress;
    return Math.max(0, this.windowWidthVp - navWidth);
  }

  private noteNavigationProgress(): number {
    if (this.focused) {
      return this.focusNavigationOpen ? 1 : 0;
    }
    return this.sidebarProgress;
  }

  private noteContentRatio(): number {
    return clampContentRatio(this.contentRatio, this.noteContentWidth(), this.fontSizeScale);
  }

  private settingsPaneWidthSummary(): string {
    const totalWidth: number = this.windowWidthVp;
    if (totalWidth <= 0) {
      return '—';
    }
    const singleScreenLayout: boolean = this.isSingleScreenLayout();
    const mdWidths: MdPaneWidths = this.mdPaneWidth();
    const navigationVisible: boolean = this.focused
      ? this.focusNavigationOpen
      : !singleScreenLayout && !this.sidebarCollapsed;
    const sidebarWidth: number = navigationVisible
      ? this.noteNavigationWidth() * this.noteNavigationProgress() : 0;
    const contentWidth: number = Math.max(0, totalWidth - sidebarWidth);
    let leftWidth: number = contentWidth;
    let rightWidth: number = 0;
    if (singleScreenLayout || this.focused) {
      leftWidth = this.activePane === 'left' ? contentWidth : 0;
      rightWidth = this.activePane === 'right' ? contentWidth : 0;
    } else if (this.breakpoint === Breakpoint.MD) {
      leftWidth = this.referenceVisible ? mdWidths.left : contentWidth;
      rightWidth = this.referenceVisible ? mdWidths.right : 0;
    } else if (this.breakpoint === Breakpoint.LG && this.referenceVisible) {
      leftWidth = contentWidth * this.noteContentRatio();
      rightWidth = contentWidth - leftWidth;
    }
    const percent = (width: number): string => (width / totalWidth * 100).toFixed(1) + '%';
    return '目录 ' + percent(sidebarWidth) + ' · 左栏 ' + percent(leftWidth) + ' · 右栏 ' + percent(rightWidth);
  }

  /**
   * md（物理双屏）等屏布局的三段宽度：NoteBody 的两栏宽度、
   * settingsPaneWidthSummary 的「当前栏宽」共用同一算法，
   * 避免「显示的数字」和「实际的栏宽」两套结果。
   *
   * ⚠️ 这里以前是硬编码「右栏 = 窗口宽 × 50% ×(1-目录进度)」，完全不读 contentRatio，
   * 所以设置页的「恢复等分栏宽」在双屏下点了毫无变化（2026-11-02 修复）。
   */
  private mdPaneWidth(): MdPaneWidths {
    return mdPaneWidths(this.windowWidthVp, this.noteNavigationWidth(),
      this.sidebarProgress, this.contentRatio, this.fontSizeScale);
  }

  private activeSharePaneWidthVp(): number {
    const pane: string = this.experienceMode === 'simple' ? this.simpleWorkspacePane() : this.activePane;
    const measuredWidth: number = pane === 'right' ? this.rightPaneWidthVp : this.leftPaneWidthVp;
    if (measuredWidth > 0) {
      return measuredWidth;
    }
    const layoutWidth: Length = this.notePaneWidth(pane);
    return typeof layoutWidth === 'number' && layoutWidth > 0 ? layoutWidth : this.noteContentWidth();
  }

  private shareLayoutWidthVp(widthId: string, paneWidthVp: number): number {
    if (widthId === 'wide') {
      return 720;
    }
    if (widthId === 'phone') {
      return 360;
    }
    return paneWidthVp;
  }

  /**
   * 正文分隔条是否可用：双屏（md）与三屏（lg）都能拖动左右栏比例。
   * md 以前只有硬编码 50%，既不能拖，设置页的「恢复等分栏宽」也就无从恢复。
   * v1.38：单屏布局（小屏 / 单屏横屏）不显示；目录右侧可用区域不足两栏最小宽
   * 时隐藏（38.1 / 38.3）。v1.39 39.2：最小宽随系统字号按 k=clamp(值,1,1.45) 放大。
   */
  private contentHandleVisible(): boolean {
    return (this.breakpoint === Breakpoint.LG || this.breakpoint === Breakpoint.MD) &&
      !this.focused && this.referenceVisible && !this.isSingleScreenLayout() &&
      this.noteContentWidth() >= contentMinVp(this.fontSizeScale) * 2;
  }

  private splitHandlePrimary(kind: string): string {
    if (kind === 'nav') {
      const total: number = this.windowWidthVp;
      const navigation: number = this.noteNavigationWidth();
      const navigationPercent: number = total > 0 ? Math.round(navigation / total * 100) : 0;
      return '目录 ' + navigationPercent + '% · 内容 ' + (100 - navigationPercent) + '%';
    }
    const total: number = this.noteContentWidth();
    const left: number = total * this.noteContentRatio();
    const leftPercent: number = total > 0 ? Math.round(left / total * 100) : 0;
    return '左栏 ' + leftPercent + '% · 右栏 ' + (100 - leftPercent) + '%';
  }

  private splitHandleWidths(kind: string): string {
    if (kind === 'nav') {
      const navigation: number = this.noteNavigationWidth();
      return '目录 ' + Math.round(navigation) + 'vp · 内容 ' +
        Math.round(Math.max(0, this.windowWidthVp - navigation)) + 'vp';
    }
    const total: number = this.noteContentWidth();
    const left: number = total * this.noteContentRatio();
    return '左栏 ' + Math.round(left) + 'vp · 右栏 ' + Math.round(Math.max(0, total - left)) + 'vp';
  }

  private splitHandleStatus(kind: string): string {
    if (kind === 'nav') {
      const total: number = this.windowWidthVp;
      const multiPane: boolean = this.breakpoint === Breakpoint.LG && !this.isSingleLandscape();
      const panes: number = multiPane ? 2 : 1;
      const splitters: number = multiPane ? 2 : 1;
      const navigation: number = this.noteNavigationWidth();
      const navMin: number = navMinVp(this.fontSizeScale);
      const contentMin: number = contentMinVp(this.fontSizeScale);
      const defaultRatio: number = this.breakpoint === Breakpoint.MD ? 0.38 : DEFAULT_NAV_RATIO;
      const defaultWidth: number = navigationWidth(total, defaultRatio, panes, 0,
        this.fontSizeScale, this.contentRatio);
      if (Math.abs(navigation - defaultWidth) <= 1) {
        return '默认比例';
      }
      const minimum: number = clampNavigationWidth(0, total, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      const maximum: number = clampNavigationWidth(total, total, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      if (navigation <= minimum + 1) {
        return total * MIN_NAV_RATIO < navMin
          ? '最小宽度 · 目录至少 ' + navMin + 'vp'
          : '最小比例 ' + Math.round(MIN_NAV_RATIO * 100) + '%';
      }
      if (navigation >= maximum - 1) {
        // v1.39 39.5：三栏时右侧按正文 / 参考比例收紧，边界文案按栏说明。
        const reservedRight: number = panes > 1
          ? Math.max(contentMin / Math.max(0.05, this.contentRatio),
            contentMin / Math.max(0.05, 1 - this.contentRatio))
          : contentMin;
        const contentLimit: number = total - reservedRight - splitters * Space.s4;
        return contentLimit < total * MAX_NAV_RATIO
          ? '最大宽度 · ' + (panes > 1 ? '正文与参考' : '正文') + '至少 ' + contentMin + 'vp'
          : '最大比例 ' + Math.round(MAX_NAV_RATIO * 100) + '%';
      }
      return '';
    }
    const total: number = this.noteContentWidth();
    const contentMin: number = contentMinVp(this.fontSizeScale);
    const left: number = total * this.noteContentRatio();
    if (total < contentMin * 2) {
      return '窗口不足，无法两栏各 ' + contentMin + 'vp';
    }
    if (Math.abs(left - total * DEFAULT_CONTENT_RATIO) <= 1) {
      return '默认比例';
    }
    if (left <= contentMin + 1) {
      return '最小宽度 · 正文至少 ' + contentMin + 'vp';
    }
    if (left >= total - contentMin - 1) {
      return '最大宽度 · 参考至少 ' + contentMin + 'vp';
    }
    return '';
  }

  private notePaneWidth(pane: string): Length {
    if (this.isSingleScreenLayout() || this.focused) {
      return this.activePane === pane ? '100%' : 0;
    }
    if (this.breakpoint === Breakpoint.MD) {
      const widths: MdPaneWidths = this.mdPaneWidth();
      if (pane === 'right') {
        return this.referenceVisible ? widths.right : 0;
      }
      return this.referenceVisible ? widths.left : this.noteContentWidth();
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
    if (!agent) {
      this.navigationRatioAtDragStart = this.navigationRatio;
    }
  }

  private updateNavigationDrag(offsetX: number, agent: boolean, altPressed: boolean = false): void {
    if (this.windowWidthVp <= 0 || (!agent && this.sidebarCollapsed)) {
      return;
    }
    const panes: number = !agent && this.breakpoint === Breakpoint.LG ? 2 : 1;
    const splitters: number = !agent && this.breakpoint === Breakpoint.LG ? 2 : 1;
    let candidate: number = this.navigationDragStart + offsetX;
    if (!agent && !altPressed) {
      const defaultRatio: number = this.breakpoint === Breakpoint.MD ? 0.38 : DEFAULT_NAV_RATIO;
      const defaultWidth: number = navigationWidth(this.windowWidthVp, defaultRatio, panes, 0,
        this.fontSizeScale, this.contentRatio);
      const minimum: number = clampNavigationWidth(0, this.windowWidthVp, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      const maximum: number = clampNavigationWidth(
        this.windowWidthVp, this.windowWidthVp, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      if (defaultWidth >= minimum && defaultWidth <= maximum &&
        Math.abs(candidate - defaultWidth) <= 10) {
        candidate = defaultWidth;
      }
    }
    const width: number = clampNavigationWidth(candidate, this.windowWidthVp, panes, splitters,
      this.fontSizeScale, this.contentRatio);
    this.navigationRatio = width / this.windowWidthVp;
  }

  private startContentDrag(): void {
    const width: number = this.noteContentWidth();
    this.splitDragging = true;
    this.contentRatioAtDragStart = this.contentRatio;
    this.contentDragStart = Math.max(0, width) * this.noteContentRatio();
  }

  private updateContentDrag(offsetX: number, altPressed: boolean = false): void {
    const width: number = this.noteContentWidth();
    if (width <= 0) {
      return;
    }
    let candidate: number = clampContentRatio((this.contentDragStart + offsetX) / width, width,
      this.fontSizeScale);
    const defaultWidth: number = width * DEFAULT_CONTENT_RATIO;
    const candidateWidth: number = width * candidate;
    if (!altPressed && width >= contentMinVp(this.fontSizeScale) * 2 &&
      Math.abs(candidateWidth - defaultWidth) <= 10) {
      candidate = DEFAULT_CONTENT_RATIO;
    }
    this.contentRatio = candidate;
  }

  private cancelNavigationDrag(): void {
    this.navigationRatio = this.navigationRatioAtDragStart;
    this.splitDragging = false;
  }

  private cancelContentDrag(): void {
    this.contentRatio = this.contentRatioAtDragStart;
    this.splitDragging = false;
  }

  private adjustSplitByKeyboard(kind: string, deltaVp: number): void {
    if (kind === 'nav') {
      const total: number = this.windowWidthVp;
      if (total <= 0 || this.sidebarCollapsed) {
        return;
      }
      const multiPane: boolean = this.breakpoint === Breakpoint.LG;
      const panes: number = multiPane ? 2 : 1;
      const splitters: number = multiPane ? 2 : 1;
      const width: number = clampNavigationWidth(
        this.noteNavigationWidth() + deltaVp, total, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      this.navigationRatio = width / total;
    } else {
      const total: number = this.noteContentWidth();
      if (total <= 0) {
        return;
      }
      const width: number = total * this.noteContentRatio();
      this.contentRatio = clampContentRatio((width + deltaVp) / total, total, this.fontSizeScale);
    }
    this.endSplitDrag();
  }

  private setSplitKeyboardLimit(kind: string, maximum: boolean): void {
    if (kind === 'nav') {
      const total: number = this.windowWidthVp;
      if (total <= 0 || this.sidebarCollapsed) {
        return;
      }
      const multiPane: boolean = this.breakpoint === Breakpoint.LG;
      const panes: number = multiPane ? 2 : 1;
      const splitters: number = multiPane ? 2 : 1;
      const minimum: number = clampNavigationWidth(0, total, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      const maximumWidth: number = clampNavigationWidth(total, total, panes, splitters,
        this.fontSizeScale, this.contentRatio);
      this.navigationRatio = (maximum ? maximumWidth : minimum) / total;
    } else {
      const total: number = this.noteContentWidth();
      if (total <= 0) {
        return;
      }
      this.contentRatio = maximum
        ? clampContentRatio(1, total, this.fontSizeScale)
        : clampContentRatio(0, total, this.fontSizeScale);
    }
    this.endSplitDrag();
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
    const alreadyDefault: boolean = this.navigationRatio < 0 &&
      Math.abs(this.contentRatio - DEFAULT_CONTENT_RATIO) < 0.001;
    this.navigationRatio = -1;
    this.contentRatio = DEFAULT_CONTENT_RATIO;
    this.ensureSplitLayoutStore();
    (this.splitLayoutStore as SplitLayoutStore).reset();
    this.scheduleWorkspaceSessionSave();
    // 重置发生在设置页（内容区被整体替换），栏宽变化当场看不见，必须给反馈，
    // 否则「点了没反应」和「点了没生效」无法区分。
    promptAction.showToast({ message: alreadyDefault ? '栏宽已是等分' : '已恢复等分栏宽' });
  }

  private setSidebarCollapsed(collapsed: boolean): void {
    this.sidebarCollapsed = collapsed;
    this.sidebarProgress = collapsed ? 0 : 1;
    this.scheduleWorkspaceSessionSave();
  }

  private workspaceTransitionDuration(): number {
    return this.navigationAnimationsEnabled && !this.splitDragging ? Motion.durNav : 0;
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

  private singleScreenNavigationOpen(): boolean {
    if (!this.isSingleScreenLayout()) {
      return false;
    }
    if (this.breakpoint === Breakpoint.SM) {
      return this.drawerOpen;
    }
    return this.focused ? this.focusNavigationOpen : !this.sidebarCollapsed;
  }

  private closeSingleScreenNavigationFromScrim(): void {
    if (!this.singleScreenNavigationOpen()) {
      return;
    }
    if (this.breakpoint === Breakpoint.SM) {
      this.setDrawerOpen(false);
    } else if (this.focused) {
      this.focusNavigationOpen = false;
    } else {
      this.setSidebarCollapsed(true);
    }
    setTimeout((): void => {
      FocusRequest.safely(this.getUIContext(), 'workspace-navigation-button');
    }, 0);
  }

  private ensureRecentOpenStore(): void {
    if (this.recentOpenStore === null) {
      this.recentOpenStore = new RecentOpenStore(VaultRegistry.get().abilityContext());
    }
  }

  private ensureRecentErrorStore(): void {
    if (this.recentErrorStore === null) {
      this.recentErrorStore = new RecentErrorStore(VaultRegistry.get().abilityContext());
    }
  }

  private recordFailureFeedback(operation: RecentErrorOperation, phase: RecentErrorPhase,
    category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep,
    detail: string, code?: number, message?: string): string {
    this.recordBackgroundFailure(operation, phase, category, outcome, nextStep, code, message);
    return formatRecentErrorFeedback(operation, phase, category, outcome, nextStep) + detail;
  }

  private recordBackgroundFailure(operation: RecentErrorOperation, phase: RecentErrorPhase,
    category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep,
    code?: number, message?: string): void {
    this.ensureRecentErrorStore();
    (this.recentErrorStore as RecentErrorStore).recordFailure(operation, phase, category, outcome, nextStep, code, message);
  }

  private showFailureFeedback(operation: RecentErrorOperation, phase: RecentErrorPhase,
    category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep,
    detail: string, code?: number, message?: string): void {
    promptAction.showToast({
      message: this.recordFailureFeedback(operation, phase, category, outcome, nextStep, detail, code, message)
    });
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
    this.refreshGitAheadCommitCount();
    if (this.topView === 'vaults') {
      this.refreshVaultManagerShareSummaries();
    }
  }

  private refreshVaultManagerShareSummaries(): void {
    const registry: VaultRegistry = VaultRegistry.get();
    const entries: VaultEntry[] = registry.list();
    const summaries: VaultManagerShareSummary[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      let noteCount: number = -1;
      try {
        noteCount = ShareArchiveService.countScope(registry, entries[i].id, '').noteCount;
      } catch (error) {
        noteCount = -1;
      }
      summaries.push({ vaultId: entries[i].id, noteCount: noteCount });
    }
    this.vaultManagerShareSummaries = summaries;
  }

  private refreshCurrentVaultNoteCount(): void {
    const paths: string[] = this.currentVaultId.length > 0
      ? FileTree.allNotesOf(VaultRegistry.get().accessFor(this.currentVaultId)) : [];
    this.currentVaultNoteCount = paths.length;
    this.refreshRecentOpenPaths(paths);
  }

  private refreshRecentOpenPaths(validPaths?: string[]): void {
    if (this.currentVaultId.length === 0) {
      this.recentOpenPaths = [];
      this.leftLastClosedPath = '';
      this.rightLastClosedPath = '';
      return;
    }
    const paths: string[] = validPaths === undefined
      ? FileTree.allNotesOf(VaultRegistry.get().accessFor(this.currentVaultId)) : validPaths;
    this.ensureRecentOpenStore();
    const store: RecentOpenStore = this.recentOpenStore as RecentOpenStore;
    this.recentOpenPaths = store.load(this.currentVaultId, paths);
    this.leftLastClosedPath = store.loadClosed(this.currentVaultId, 'left', paths);
    this.rightLastClosedPath = store.loadClosed(this.currentVaultId, 'right', paths);
  }

  private recordPaneOpened(vaultId: string, path: string, pane: string): void {
    if (vaultId.length === 0 || path.length === 0) {
      return;
    }
    this.ensureRecentOpenStore();
    const store: RecentOpenStore = this.recentOpenStore as RecentOpenStore;
    store.record(vaultId, path);
    store.clearClosed(vaultId, pane);
    this.refreshRecentOpenPaths();
  }

  /** 文件树内容变化时同步更新计数，并通知侧栏重扫。 */
  private refreshFileTree(): void {
    this.refreshCurrentVaultNoteCount();
    this.treeSeq++;
    void this.refreshBacklinks();
    void this.refreshActiveChaptersFromBridge();
  }

  private startExternalVaultPolling(): void {
    if (this.externalVaultPolling) {
      return;
    }
    this.externalVaultPolling = true;
    this.externalVaultSnapshotId = '';
    this.externalVaultSnapshotKey = '';
    this.scheduleExternalVaultPoll();
  }

  private stopExternalVaultPolling(): void {
    this.externalVaultPolling = false;
    if (this.externalVaultPollTimer !== -1) {
      clearTimeout(this.externalVaultPollTimer);
      this.externalVaultPollTimer = -1;
    }
    this.externalVaultSnapshotId = '';
    this.externalVaultSnapshotKey = '';
  }

  private scheduleExternalVaultPoll(): void {
    if (!this.externalVaultPolling || this.externalVaultPollTimer !== -1) {
      return;
    }
    this.externalVaultPollTimer = setTimeout((): void => {
      this.externalVaultPollTimer = -1;
      void this.pollExternalVault();
    }, EXTERNAL_VAULT_POLL_MS);
  }

  private snapshotKey(entries: VaultDirChild[]): string {
    const parts: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      parts.push((entries[i].isDir ? 'd:' : 'f:') + entries[i].name);
    }
    return parts.join('\u0000');
  }

  private snapshotHasFile(entries: VaultDirChild[], path: string): boolean {
    for (let i = 0; i < entries.length; i++) {
      if (!entries[i].isDir && entries[i].name === path) {
        return true;
      }
    }
    return false;
  }

  private async pollExternalVault(): Promise<void> {
    try {
      if (this.externalVaultPolling && this.topView === 'note' && this.currentVaultId.length > 0) {
        const vaultId: string = this.currentVaultId;
        const snapshot: VaultDirChild[] = VaultRegistry.get().accessFor(vaultId).snapshot();
        const key: string = this.snapshotKey(snapshot);
        if (this.externalVaultSnapshotId === vaultId && this.externalVaultSnapshotKey !== key) {
          this.refreshFileTree();
        }
        this.externalVaultSnapshotId = vaultId;
        this.externalVaultSnapshotKey = key;
        this.externalVaultAccessErrorShown = false;

        const leftPath: string = this.currentFilePath;
        const rightPath: string = this.rightFilePath;
        if (leftPath.length > 0) {
          await this.refreshOpenVaultNote(vaultId, leftPath, 'left', snapshot);
        }
        if (rightPath.length > 0 && rightPath !== leftPath) {
          await this.refreshOpenVaultNote(vaultId, rightPath, 'right', snapshot);
        }
      }
    } catch (error) {
      if (!this.externalVaultAccessErrorShown) {
        this.externalVaultAccessErrorShown = true;
        promptAction.showToast({ message: '知识库暂时无法访问，请检查目录是否仍可用以及授权状态' });
      }
    } finally {
      this.scheduleExternalVaultPoll();
    }
  }

  private async refreshOpenVaultNote(vaultId: string, path: string, pane: string,
    snapshot: VaultDirChild[]): Promise<void> {
    const shared: boolean = this.currentFilePath === path && this.rightFilePath === path;
    const editor: EditorBridge = shared ? this.sharedNoteEditor()
      : pane === 'right' ? this.rightEditorBridge : this.editorBridge;
    if (!editor.ready) {
      return;
    }
    const inSnapshot: boolean = this.snapshotHasFile(snapshot, path);
    const externalText: string | null = inSnapshot
      ? NoteService.tryReadNote(VaultRegistry.get(), vaultId, path) : null;
    let editorText: string;
    try {
      editorText = await editor.getContent();
    } catch (error) {
      return;
    }
    if (vaultId !== this.currentVaultId || this.topView !== 'note' ||
      (pane === 'right' ? this.rightFilePath : this.currentFilePath) !== path) {
      return;
    }

    const leftSessionForNote: EditorNoteSession | null = this.leftSession;
    const rightSessionForNote: EditorNoteSession | null = this.rightSession;
    const leftBaseline: string = leftSessionForNote !== null && leftSessionForNote.isFor(vaultId, path)
      ? leftSessionForNote.baseline : '';
    const rightBaseline: string = rightSessionForNote !== null && rightSessionForNote.isFor(vaultId, path)
      ? rightSessionForNote.baseline : '';
    const baseline: string = shared ? leftBaseline
      : pane === 'right' ? rightBaseline : leftBaseline;
    const localDirty: boolean = shared
      ? this.editorDirty || this.rightEditorDirty || this.leftComposing || this.rightComposing ||
        editorText !== baseline
      : pane === 'right'
        ? this.rightEditorDirty || this.rightComposing || editorText !== baseline
        : this.editorDirty || this.leftComposing || editorText !== baseline;
    if (!inSnapshot || externalText === null) {
      if (inSnapshot) {
        const readErrorKey: string = this.staleSaveNoticeKey(vaultId, path);
        if (this.externalVaultNoteReadErrorKeys.indexOf(readErrorKey) < 0) {
          this.externalVaultNoteReadErrorKeys.push(readErrorKey);
          promptAction.showToast({ message: '知识库笔记读取失败，请检查目录授权后重试' });
        }
        return;
      }
      if (localDirty) {
        this.showStaleSaveConflict(vaultId, path,
          '当前笔记已在外部删除或移动；本地未保存内容仍保留在编辑器中。请先复制内容，再决定如何处理。');
        return;
      }
      await this.clearMissingOpenVaultNote(vaultId, path, pane);
      promptAction.showToast({ message: '当前笔记已在外部删除或移动，已清除失效的编辑目标' });
      return;
    }
    this.clearExternalVaultNoteReadError(vaultId, path);
    if (externalText === baseline) {
      this.clearStaleSaveNotice(vaultId, path);
      return;
    }
    if (localDirty) {
      this.showStaleSaveConflict(vaultId, path,
        '笔记已在外部变化；本地未保存内容仍保留，保存会被阻止以保护外部版本。请先复制本地内容再处理。');
      return;
    }

    if (pane === 'right') {
      await this.readRightAndPush(path);
    } else {
      await this.readAndPush(path, false);
      if (this.rightFilePath === path && this.currentFilePath === path) {
        await this.readRightAndPush(path);
      }
    }
    this.clearStaleSaveNotice(vaultId, path);
    promptAction.showToast({ message: '打开的笔记已从外部更新并重新载入' });
  }

  private async clearMissingOpenVaultNote(vaultId: string, path: string, pane: string): Promise<void> {
    if (pane === 'right') {
      if (vaultId === this.currentVaultId && this.rightFilePath === path) {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      }
      return;
    }
    if (vaultId !== this.currentVaultId || this.currentFilePath !== path) {
      return;
    }
    this.currentFilePath = '';
    if (this.rightFilePath === path) {
      this.rightFilePath = '';
      await this.readRightAndPush('');
    }
    await this.readAndPush('', false);
  }

  private staleSaveNoticeKey(vaultId: string, path: string): string {
    return vaultId + '\u0000' + path;
  }

  private clearStaleSaveNotice(vaultId: string, path: string): void {
    const key: string = this.staleSaveNoticeKey(vaultId, path);
    const index: number = this.staleSaveNoticeKeys.indexOf(key);
    if (index >= 0) {
      this.staleSaveNoticeKeys.splice(index, 1);
    }
  }

  private clearExternalVaultNoteReadError(vaultId: string, path: string): void {
    const key: string = this.staleSaveNoticeKey(vaultId, path);
    const index: number = this.externalVaultNoteReadErrorKeys.indexOf(key);
    if (index >= 0) {
      this.externalVaultNoteReadErrorKeys.splice(index, 1);
    }
  }

  private showEditorMismatchRecovery(vaultId: string, path: string): void {
    if (this.editorMismatchDialogOpen) {
      hilog.warn(DOMAIN, TAG, '编辑恢复弹窗已在展示，跳过重复触发');
      return;
    }
    this.editorMismatchDialogOpen = true;
    void this.getUIContext().getPromptAction().showDialog({
      title: '编辑内容与笔记不一致',
      message: '为避免覆盖笔记，当前编辑区内容未保存。你可以留在当前页面并先复制需要保留的内容，或放弃编辑区未保存内容，重新载入笔记后再切换。',
      buttons: [
        { text: '留在当前页面', color: $r('app.color.text_secondary') },
        { text: '放弃并重新载入', color: $r('app.color.brand') }
      ]
    }).then((result): void => {
      this.editorMismatchDialogOpen = false;
      if (result.index === 1) {
        void this.reloadStaleVaultNote(vaultId, path);
      }
    }).catch((error: BusinessError): void => {
      this.editorMismatchDialogOpen = false;
      hilog.error(DOMAIN, TAG, '编辑恢复弹窗打开失败：%{public}s',
        error.message ?? 'unknown');
      promptAction.showToast({ message: '无法打开恢复提示，请稍后重试' });
    });
  }

  private showStaleSaveConflict(vaultId: string, path: string, message: string): void {
    const key: string = this.staleSaveNoticeKey(vaultId, path);
    if (this.staleSaveNoticeKeys.indexOf(key) >= 0) {
      return;
    }
    this.staleSaveNoticeKeys.push(key);
    void this.getUIContext().getPromptAction().showDialog({
      title: '笔记已在编辑器外发生变化',
      message: message + '\n\n重新载入会丢弃当前编辑器中的未保存内容；如需保留，请先复制本地内容。',
      buttons: [
        { text: '继续保留', color: $r('app.color.text_secondary') },
        { text: '放弃本地内容并重载', color: $r('app.color.brand') }
      ]
    }).then((result): void => {
      if (result.index === 1) {
        void this.reloadStaleVaultNote(vaultId, path);
      }
    });
  }

  private async reloadStaleVaultNote(vaultId: string, path: string): Promise<void> {
    if (vaultId !== this.currentVaultId || this.topView !== 'note' ||
      (this.currentFilePath !== path && this.rightFilePath !== path)) {
      hilog.warn(DOMAIN, TAG,
        '重新载入被跳过：vault不一致=%{public}s 视图=%{public}s 路径不匹配=%{public}s',
        String(vaultId !== this.currentVaultId), this.topView,
        String(this.currentFilePath !== path && this.rightFilePath !== path));
      return;
    }
    const externalText: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, path);
    if (externalText === null) {
      hilog.warn(DOMAIN, TAG, '重新载入失败：目标笔记已不存在或无法读取');
      await this.clearMissingOpenVaultNote(vaultId, path,
        this.currentFilePath === path ? 'left' : 'right');
      promptAction.showToast({ message: '笔记已不存在或无法读取，请从文件树重新选择' });
      return;
    }
    if (this.currentFilePath === path) {
      await this.readAndPush(path, false);
    }
    if (this.rightFilePath === path) {
      await this.readRightAndPush(path);
    }
    this.clearStaleSaveNotice(vaultId, path);
    promptAction.showToast({ message: '已载入外部版本' });
  }

  private handleEditorSaveError(vaultId: string, path: string, error: Object): void {
    const err = error as Error;
    const message: string = err.message ?? JSON.stringify(error);
    if (message.indexOf('STALE_CONTENT：') === 0 || message.indexOf('STALE_CONTENT:') === 0) {
      hilog.warn(DOMAIN, TAG, '保存因笔记版本已变化而拒绝，保留本地编辑器内容');
      this.recentErrorStore = this.recentErrorStore ??
        new RecentErrorStore(VaultRegistry.get().abilityContext());
      (this.recentErrorStore as RecentErrorStore).recordFailure(
        'note', 'save', 'conflict', 'not_completed', 'check_status');
      this.showStaleSaveConflict(vaultId, path,
        '写入前发现笔记内容已变化；本次本地编辑未保存，也没有覆盖外部版本。');
      return;
    }
    this.toastRegistryError('保存失败', error, 'note', 'save');
  }

  /** Keep a recoverable snapshot in the app-private store before attempting the vault write. */
  private async persistEditorDraftSnapshot(vaultId: string, path: string,
    baseText: string, content: string): Promise<boolean> {
    try {
      const persisted: boolean = await NoteDraftService.persist(VaultRegistry.get(), vaultId,
        path, baseText, content);
      if (!persisted) {
        this.showFailureFeedback('note', 'save', 'storage_failure', 'not_completed', 'retry',
          '恢复草稿未能安全写入；正式笔记未保存，当前编辑仍保留。请稍后重试。');
      }
      return persisted;
    } catch (error) {
      this.showFailureFeedback('note', 'save', 'unknown', 'not_completed', 'retry',
        '恢复草稿写入失败；正式笔记尚未保存，当前编辑仍保留。请稍后重试。');
      return false;
    }
  }

  /** The formal note is already safe; a stale private draft can be cleaned on the next open. */
  private async clearEditorDraftAfterSave(vaultId: string, path: string, content: string): Promise<void> {
    try {
      await NoteDraftService.clearIfMatches(VaultRegistry.get(), vaultId, path, content);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '笔记已保存，恢复草稿清理将在后续重试');
      this.showFailureFeedback('note', 'restore', 'storage_failure', 'completed_with_warning', 'retry',
        '笔记已保存；恢复草稿清理未完成，重开时可能再次提示恢复。');
    }
  }

  private reportDraftRecovery(vaultId: string, path: string, recovery: NoteDraftRecovery): void {
    if (!recovery.recovered && !recovery.conflict) {
      return;
    }
    const state: string = recovery.recovered ? 'restored' : 'conflict';
    const key: string = vaultId + '\u0000' + path + '\u0000' + state + '\u0000' +
      this.leftOpenRequestId.toString() + ':' + this.rightOpenRequestId.toString();
    if (key === this.lastDraftRecoveryNoticeKey) {
      return;
    }
    this.lastDraftRecoveryNoticeKey = key;
    promptAction.showToast({ message: recovery.recovered
      ? '已恢复上次未保存的修改' : '恢复草稿无法安全应用，已保留草稿' });
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
    this.closeBlockPropertyPanel(false);
    this.blockToolbarOpen = false;
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
   * 按优先级依次消费：① 快切/抽屉；② 工作区导航；③ 次级视图；④ 图片查看器；⑤ sm 预览态；
   * 都不是则返 false 走系统默认（退出应用）。
   */
  onBackPress(): boolean {
    // v1.58 58.4：统计弹窗优先于次级视图消费系统返回；cancel 回调负责焦点返还。
    if (this.statsDialogOpen) {
      this.statsDialogCtl?.close();
      this.statsDialogOpen = false;
      return true;
    }
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
    if (this.topView === 'note' && this.focused && this.focusNavigationOpen) {
      this.focusNavigationOpen = false;
      return true;
    }
    if (this.topView === 'note' && !this.focused && this.breakpoint !== Breakpoint.SM &&
      !this.sidebarCollapsed) {
      this.setSidebarCollapsed(true);
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
    if (this.experienceMode === 'professional' && this.breakpoint === Breakpoint.SM && this.smMode === 'preview') {
      this.smMode = 'edit';
      this.scheduleWorkspaceSessionSave();
      return true;
    }
    return false;
  }

  /** 页面隐藏（应用退到后台）：立刻落盘，兜底「杀进程重进内容还在」（2.3） */
  onPageHide(): void {
    this.stopExternalVaultPolling();
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
      if (this.settingsPrivacyPolicyOpen) {
        this.settingsPrivacyPolicyOpen = false;
        return;
      }
      if (this.isSingleScreenLayout() && this.settingsDetail) {
        this.settingsDetail = false;
        return;
      }
      this.topView = this.settingsReturnView;
      this.focusMoreMenuOnAppear = this.settingsReturnView === 'note';
    } else if (this.topView === 'vaults') {
      this.topView = this.vaultManagerReturnView;
    } else {
      this.topView = 'note';
    }
    this.scheduleWorkspaceSessionSave();
  }

  private returnFromSettings(): void {
    this.settingsDetail = false;
    this.settingsPrivacyPolicyOpen = false;
    this.topView = this.settingsReturnView;
    this.focusMoreMenuOnAppear = this.settingsReturnView === 'note';
    this.scheduleWorkspaceSessionSave();
  }

  private async openVaultManager(fromView: string): Promise<void> {
    if (fromView === 'note' && !await this.flushWorkspaceSaves()) {
      return;
    }
    this.vaultManagerReturnView = fromView;
    this.topView = 'vaults';
    this.refreshFromRegistry();
  }

  /**
   * v1.58 58.4：打开「写作统计」弹窗（宽屏居中 / 单屏半模态），不再替换内容区。
   * 弹窗自己在 aboutToAppear 重算；同一份结果由 scanVaultStats 回写侧栏连写条。
   * 关闭按钮 / 遮罩 / Esc / 系统返回都把焦点还给触发入口。
   */
  private async openVaultStats(fromView: string, focusReturnId: string): Promise<void> {
    if (!this.statsEnabled) {
      return;
    }
    if (fromView === 'note' && !await this.flushWorkspaceSaves()) {
      return;
    }
    this.moreMenuOpen = false;
    this.statsDialogCtl?.close();
    const sheet: boolean = this.isSingleScreenLayout();
    let focusRestored: boolean = false;
    const restoreFocus = (): void => {
      if (focusRestored || focusReturnId.length === 0) {
        return;
      }
      focusRestored = true;
      FocusRequest.safely(this.getUIContext(), focusReturnId);
    };
    this.statsDialogCtl = new CustomDialogController({
      builder: VaultStatsDialog({
        vaultName: this.currentVaultName(),
        singleScreen: sheet,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onRequestScan: (): Promise<VaultStatsScanOutcome> => {
          return this.scanVaultStats(this.currentVaultId);
        },
        onDismiss: restoreFocus
      }),
      cancel: restoreFocus,
      autoCancel: true,
      alignment: sheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      customStyle: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
        this.statsDialogOpen = false;
        restoreFocus();
      }
    });
    this.statsDialogOpen = true;
    this.statsDialogCtl.open();
  }

  /**
   * 扫描当前库并回填统计缓存（52.1：分块读取不阻塞 UI）。
   * 弹窗与空闲刷新共用这一次扫描；切库后的过期结果按 vaultId 丢弃。
   */
  private async scanVaultStats(vaultId: string): Promise<VaultStatsScanOutcome> {
    try {
      const access = VaultRegistry.get().accessFor(vaultId);
      const outcome: VaultStatsScanOutcome = await VaultStatsService.scanAccess(access, Date.now());
      if (this.currentVaultId === vaultId) {
        this.vaultStatsFailed = outcome.failed;
        this.vaultStatsModel = outcome.model !== null ? outcome.model : emptyStatsModel();
        this.vaultStatsScanning = false;
      }
      return outcome;
    } catch (_error) {
      if (this.currentVaultId === vaultId) {
        this.vaultStatsFailed = true;
        this.vaultStatsModel = emptyStatsModel();
        this.vaultStatsScanning = false;
      }
      const failed: VaultStatsScanOutcome = { model: null, failed: true };
      return failed;
    }
  }

  /** v1.58 §5：冷启动 / 切库后把首次扫描排到空闲时机，不进首帧关键路径。 */
  private scheduleIdleStatsRefresh(): void {
    if (!this.statsEnabled) {
      return;
    }
    if (this.statsIdleTimer >= 0) {
      clearTimeout(this.statsIdleTimer);
    }
    this.vaultStatsModel = emptyStatsModel();
    this.vaultStatsFailed = false;
    this.vaultStatsScanning = true;
    this.statsIdleTimer = setTimeout((): void => {
      this.statsIdleTimer = -1;
      void this.scanVaultStats(this.currentVaultId);
    }, 0);
  }

  /** 侧栏连写条本周圆点（最后一周 7 天；未来日为 false）。 */
  private statsWeekFlags(): boolean[] {
    return currentWeekFlagsOf(this.vaultStatsModel.weeks);
  }

  /** 今天的星期索引（周一 0 … 周日 6），用于圆点外圈与热力图 today 描边。 */
  private statsTodayIndex(): number {
    return (new Date().getDay() + 6) % 7;
  }

  private currentVaultIsGit(): boolean {
    const entry: VaultEntry | null = VaultRegistry.get().currentEntry();
    return entry !== null && entry.type === 'git';
  }

  /** 首页角标仅查询本地 Git 状态；失败或非 Git 库时清掉旧数值，不做后台同步。 */
  private refreshGitAheadCommitCount(): void {
    const entry: VaultEntry | null = VaultRegistry.get().currentEntry();
    if (entry === null || entry.type !== 'git') {
      this.gitAheadCommitCount = 0;
      return;
    }
    try {
      const repositoryPath: string = VaultRegistry.get().vaultDirOf(entry.id);
      const state = GitNativeService.repositoryState(repositoryPath, entry.pushBranch ?? 'xt2');
      this.gitAheadCommitCount = state.trackingKnown && state.aheadCount > 0 ? state.aheadCount : 0;
    } catch (_error) {
      this.gitAheadCommitCount = 0;
    }
  }

  private gitAheadBadgeLabel(): string {
    return this.gitAheadCommitCount > 99 ? '99+' : this.gitAheadCommitCount.toString();
  }

  private async openGitSyncPage(draft: GitImportDraft | null = null): Promise<void> {
    if (!await this.flushWorkspaceSaves()) {
      promptAction.showToast({ message: '当前笔记未保存，暂不能打开 Git 同步' });
      return;
    }
    this.moreMenuOpen = false;
    if (draft !== null) {
      // 令牌只在进程内交接，不进路由参数、日志或 preferences。
      GitImportDraftStore.set(draft);
      router.pushUrl({ url: 'pages/SyncPage' });
      return;
    }
    GitImportDraftStore.clear();
    const entry: VaultEntry | null = VaultRegistry.get().currentEntry();
    if (entry === null || entry.type !== 'git') {
      promptAction.showToast({ message: '当前库不是 Git 库' });
      return;
    }
    this.gitSyncBusy = false;
    let focusRestored: boolean = false;
    const focusReturnId: string = this.isSingleScreenLayout()
      ? 'workspace-more-button' : 'git-sync-button';
    const restoreFocus = (): void => {
      if (focusRestored) {
        return;
      }
      focusRestored = true;
      setTimeout((): void => {
        FocusRequest.safely(this.getUIContext(), focusReturnId);
      }, 0);
    };
    const syncSheet: boolean = this.isSingleScreenLayout();
    this.gitSyncCtl = new CustomDialogController({
      builder: GitSyncDialog({
        vaultId: entry.id,
        singleScreen: syncSheet,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onBusyChange: (busy: boolean): void => { this.gitSyncBusy = busy; },
        onDismiss: restoreFocus
      }),
      cancel: (): void => {
        if (!this.gitSyncBusy) {
          restoreFocus();
        }
      },
      autoCancel: true,
      alignment: syncSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      customStyle: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        if (!this.gitSyncBusy) {
          action.dismiss();
        }
      }
    });
    this.gitSyncCtl.open();
  }

  /** 统一导入入口：文件树选择器与库管理页共用。 */
  private async openImportVaultDialog(focusReturnId: string): Promise<void> {
    if (!await this.flushWorkspaceSaves()) {
      promptAction.showToast({ message: '当前笔记未保存，暂不能导入知识库' });
      return;
    }
    this.pendingExternalDirectory = null;
    this.importVaultDialogBusy = false;
    const importSheet: boolean = this.isSingleScreenLayout();
    let focusRestored: boolean = false;
    const restoreImportFocus = (): void => {
      if (focusRestored || focusReturnId.length === 0) {
        return;
      }
      focusRestored = true;
      setTimeout((): void => {
        FocusRequest.safely(this.getUIContext(), focusReturnId);
      }, 0);
    };
    this.restoreImportTriggerFocus = restoreImportFocus;
    const clearImportDraft = (): void => {
      GitImportDraftStore.clear();
      this.pendingExternalDirectory = null;
      this.cleanupZipImportState();
      restoreImportFocus();
    };
    this.importVaultCtl = new CustomDialogController({
      builder: ImportVaultDialog({
        singleScreen: importSheet,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onChooseDirectory: (): Promise<string | null> => this.chooseExternalDirectory(),
        onAssociateDirectory: (): Promise<boolean> => this.associateExternalDirectory(),
        onChooseZip: (): Promise<ZipChooseOutcome> => this.chooseZipBackup(),
        onImportZip: (name: string, onProgress: (done: number, total: number) => void): Promise<ZipImportOutcome> =>
          this.importZipBackup(name, onProgress),
        onBusyChange: (busy: boolean): void => { this.importVaultDialogBusy = busy; },
        onContinueGit: (draft: GitImportDraft): void => {
          void this.openGitSyncPage(draft);
        },
        onCancel: clearImportDraft
      }),
      cancel: (): void => {
        if (!this.importVaultDialogBusy) {
          clearImportDraft();
        }
      },
      autoCancel: true,
      alignment: importSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      customStyle: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        if (!this.importVaultDialogBusy) {
          action.dismiss();
        }
      }
    });
    this.importVaultCtl.open();
  }

  /** 返回选中目录的展示名交给弹窗自己显示；取消返回 null，失败提示后返回 null。 */
  private async chooseExternalDirectory(): Promise<string | null> {
    const authorization: ExternalVaultAuthorizationService =
      createExternalVaultAuthorization(VaultRegistry.get().abilityContext());
    let selection: ExternalDirectorySelection | null = null;
    try {
      selection = await authorization.pickDirectory();
    } catch (_error) {
      this.pendingExternalDirectory = null;
      this.showFailureFeedback('authorization', 'permission', 'unknown', 'not_completed', 'restore_permission',
        '目录尚未关联；请重新选择目录或检查系统授权后重试。');
      throw new Error('目录授权未完成');
    }
    if (selection === null) {
      return null;
    }
    this.pendingExternalDirectory = selection;
    return selection.displayName.length > 0 ? selection.displayName : '已选择目录';
  }

  /** 返回是否关联成功；失败时弹窗保持打开，可换目录重试。 */
  private async associateExternalDirectory(): Promise<boolean> {
    const selection: ExternalDirectorySelection | null = this.pendingExternalDirectory;
    if (selection === null) {
      return false;
    }
    const authorization: ExternalVaultAuthorizationService =
      createExternalVaultAuthorization(VaultRegistry.get().abilityContext());
    let grant: ExternalDirectoryGrant | null = null;
    let registered: VaultEntry | null = null;
    let revokeFailed: boolean = false;
    try {
      grant = await authorization.persistSelection(selection);
      registered = VaultRegistry.get().registerExternal(grant.displayName, grant.uri, grant.grantedAt);
    } catch (error) {
      if (grant !== null) {
        try {
          await authorization.revoke(grant.uri);
        } catch (_revokeError) {
          revokeFailed = true;
        }
      }
      const detail: string = revokeFailed
        ? '知识库未确认登记；授权回收状态未确认，外部笔记未改写。请检查授权和库列表后再处理。'
        : '知识库未完成登记；请重新选择目录后重试，外部笔记未改写。';
      this.pendingExternalDirectory = null;
      this.showFailureFeedback('authorization', 'permission', 'unknown', 'status_unknown', 'check_status', detail);
      return false;
    }

    this.pendingExternalDirectory = null;
    this.importVaultDialogBusy = false;
    this.importVaultCtl?.close();
    this.refreshFromRegistry();
    promptAction.showToast({ message: '目录已关联为知识库' });
    if (registered !== null) {
      void this.switchVault(registered.id);
    }
    this.restoreImportTriggerFocus();
    return true;
  }

  /** 36.6：启动时清理上次进程退出可能残留的 ZIP 暂存目录（cacheDir 下，App 私有）。 */
  private cleanupZipImportStaging(): void {
    try {
      const resolver: VaultPathResolver =
        new VaultPathResolver(VaultRegistry.get().abilityContext());
      this.removePathTreeForImport(resolver.zipImportStagingRoot());
    } catch (_error) {
      // 残留只占 cacheDir 空间；下次启动重试，不阻塞启动
    }
  }

  private removePathTreeForImport(path: string): void {
    if (!fileIo.accessSync(path)) {
      return;
    }
    if (!fileIo.statSync(path).isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const names: string[] = fileIo.listFileSync(path);
    for (let index: number = 0; index < names.length; index++) {
      this.removePathTreeForImport(path + '/' + names[index]);
    }
    fileIo.rmdirSync(path);
  }

  /** 换 ZIP / 关闭弹窗时清理暂存文件与解析结果（36.6）；失败静默，重选会重建。 */
  private cleanupZipImportState(): void {
    if (this.pendingZipStagingPath.length > 0) {
      removeStagingFile(this.pendingZipStagingPath);
    }
    this.pendingZipStagingPath = '';
    this.pendingZipParse = null;
  }

  /** 36.1/36.2：选 ZIP → 暂存复制 → 解析预览；取消 / 失败 / 成功三态回填弹窗。 */
  private async chooseZipBackup(): Promise<ZipChooseOutcome> {
    const registry: VaultRegistry = VaultRegistry.get();
    const resolver: VaultPathResolver = new VaultPathResolver(registry.abilityContext());
    const picker: DeviceZipPicker = new DeviceZipPicker(registry.abilityContext());
    let picked: ZipPickResult | null = null;
    try {
      picked = await picker.pick();
    } catch (_error) {
      // 选择器异常按取消处理（36.1：取消回到原状态）
      picked = null;
    }
    if (picked === null) {
      const cancelled: ZipChooseOutcome = {
        status: 'cancelled', kind: 'corrupt', detail: '', fileName: '', summary: '', defaultVaultName: ''
      };
      return cancelled;
    }
    this.cleanupZipImportState();
    const fileName: string = picked.fileName.length > 0 ? picked.fileName : '备份.zip';
    const stagingRoot: string = resolver.zipImportStagingRoot();
    const stagingPath: string = resolver.resolveZipImportStaging('import-' + Date.now().toString() + '.zip');
    try {
      if (!fileIo.accessSync(stagingRoot)) {
        fileIo.mkdirSync(stagingRoot, true);
      }
      await copyPickerZipToStaging(picked.uri, stagingPath);
      const reader: StagingZipReader = new StagingZipReader(stagingPath);
      let parsed: ZipParsed;
      try {
        parsed = await ZipImportService.parse(reader, ZipImportService.DEFAULT_LIMITS);
      } finally {
        reader.close();
      }
      const fileStem: string = fileName.toLowerCase().endsWith('.zip') ? fileName.slice(0, fileName.length - 4) : fileName;
      const baseName: string = parsed.topFolder.length > 0 ? parsed.topFolder : fileStem;
      const summary: string = parsed.noteCount.toString() + ' 篇笔记 · ' + parsed.imageCount.toString() +
        ' 张图片 · 跳过 ' + parsed.skippedCount.toString() + ' 个其他文件';
      const selected: ZipChooseOutcome = {
        status: 'selected', kind: 'corrupt', detail: '', fileName: fileName, summary: summary,
        defaultVaultName: registry.uniqueVaultId(sanitizeVaultName(baseName), '')
      };
      this.pendingZipParse = parsed;
      this.pendingZipStagingPath = stagingPath;
      return selected;
    } catch (error) {
      removeStagingFile(stagingPath);
      this.pendingZipParse = null;
      this.pendingZipStagingPath = '';
      const err = error as BusinessError;
      const kind: ZipImportErrorKind = error instanceof ZipImportError ? error.kind : 'io';
      const failed: ZipChooseOutcome = {
        status: 'failed', kind: kind,
        detail: err.message ?? String(error), fileName: fileName, summary: '', defaultVaultName: ''
      };
      return failed;
    }
  }

  /** 36.3–36.7：确认导入 —— 空间预检 → 隔离解压 → 原子登记 → 切库提示；失败清理不留半成品。 */
  private async importZipBackup(name: string,
    onProgress: (done: number, total: number) => void): Promise<ZipImportOutcome> {
    const parsed: ZipParsed | null = this.pendingZipParse;
    const stagingPath: string = this.pendingZipStagingPath;
    if (parsed === null || stagingPath.length === 0) {
      const stale: ZipImportOutcome = {
        status: 'failed', kind: 'io', detail: '暂存的解析结果已失效，请重新选择 ZIP 文件', result: null
      };
      return stale;
    }
    const registry: VaultRegistry = VaultRegistry.get();
    const resolver: VaultPathResolver = new VaultPathResolver(registry.abilityContext());
    const finalId: string = registry.uniqueVaultId(sanitizeVaultName(name), '');
    const tempId: string = registry.uniqueVaultId(finalId + GIT_IMPORTING_SUFFIX, '');
    const tempDir: string = registry.vaultDirOf(tempId);
    const finalDir: string = registry.vaultDirOf(finalId);
    let marked: boolean = false;
    let tempDirCreated: boolean = false;
    try {
      registry.beginGitImport(finalId, tempId);
      marked = true;
      // 空间预检（36.7 不报告虚假成功）：解压总量超过剩余空间按 no_space 失败。
      if (freeBytesUnder(resolver.vaultsRoot()) < parsed.totalUncompressed) {
        throw new ZipImportError('no_space', '设备存储空间不足');
      }
      fileIo.mkdirSync(tempDir, true);
      tempDirCreated = true;
      const reader: StagingZipReader = new StagingZipReader(stagingPath);
      try {
        const written: number = await ZipImportService.extract(reader,
          new TempVaultZipWriter(tempDir), new ZlibRawInflate(), parsed,
          { onProgress: onProgress });
        if (written !== parsed.entries.length) {
          throw new ZipImportError('corrupt', 'ZIP 数据损坏');
        }
      } finally {
        reader.close();
      }
      if (fileIo.accessSync(finalDir)) {
        throw new ZipImportError('io', '目标库目录已存在，拒绝覆盖');
      }
      // 发布仅 rename 本次新目录，不覆盖既有文件（36.3 只新建、不覆盖）。
      fileIo.renameSync(tempDir, finalDir);
      tempDirCreated = false;
      const entry: VaultEntry = registry.registerImportedLocal(finalId);
      registry.finishGitImport(finalId, tempId);
      marked = false;
      const result: ZipImportResult = {
        vaultId: entry.id,
        vaultName: entry.id,
        noteCount: parsed.noteCount,
        imageCount: parsed.imageCount,
        skippedCount: parsed.skippedCount
      };
      this.cleanupZipImportState();
      promptAction.showToast({ message: '已导入 ' + parsed.noteCount.toString() + ' 篇笔记' });
      void this.switchVault(entry.id);
      const ok: ZipImportOutcome = { status: 'ok', kind: 'corrupt', detail: '', result: result };
      return ok;
    } catch (error) {
      if (tempDirCreated) {
        this.removePathTreeForImport(tempDir);
      }
      if (marked) {
        try {
          registry.cleanupGitImport(finalId, tempId);
        } catch (_cleanupError) {
          // 标记清理失败留给启动恢复（recoverGitImportResidues）
        }
      }
      const err = error as BusinessError;
      const kind: ZipImportErrorKind = error instanceof ZipImportError ? error.kind : 'io';
      const failed: ZipImportOutcome = {
        status: 'failed', kind: kind, detail: err.message ?? String(error), result: null
      };
      return failed;
    }
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
    this.focusMoreMenuOnAppear = fromView === 'note';
    this.settingsReturnView = fromView;
    this.settingsCategory = initialTab;
    this.settingsDetail = this.isSingleScreenLayout() && fromView === 'agent';
    this.settingsPrivacyPolicyOpen = false;
    this.topView = 'settings';
  }

  private openAgentNote(path: string): void {
    void this.loadAgentNote(path);
  }

  private async loadAgentNote(path: string): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const text: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, path);
    if (text === null) {
      this.showFailureFeedback('note', 'read', 'unknown', 'not_completed', 'reopen_note',
        '目标笔记未打开；当前笔记仍保留。请从文件树重新选择或重试。');
      return;
    }
    // Agent 页打开期间 Web 编辑器已卸载；不能 flush 它持有的旧内容覆盖 Agent 写入。
    this.resetSaveFeedback();
    this.currentFilePath = path;
    // 清掉旧会话：readAndPush 完成前任何保存都拒绝（无会话=无写入目标），防旧账本串写。
    this.leftSession = null;
    WorkspaceEditGuard.clear('left', this.currentVaultId, path);
    this.editorDirty = false;
    this.topView = 'note';
    await this.readAndPush(path);
    this.recordPaneOpened(vaultId, path, 'left');
  }

  /**
   * 返回本页（router.back from 导入页等）：注册表的当前库可能已被外部切换
   * （v0.3 导入完成自动切库）—— 与本地 currentVaultId 不一致时对齐上下文。
   */
  onPageShow(): void {
    this.startExternalVaultPolling();
    const regId: string = VaultRegistry.get().currentId();
    if (regId.length > 0 && regId !== this.currentVaultId) {
      void this.adoptExternalVaultSwitch();
      return;
    }
    this.refreshGitAheadCommitCount();
  }

  /** 外部入口切换了当前库：落盘旧库编辑后按 switchVault 的恢复序列对齐本页状态。 */
  private async adoptExternalVaultSwitch(): Promise<void> {
    try {
      if (!await this.flushWorkspaceSaves()) {
        return;
      }
      this.ensureWorkspaceSessionStore();
      // v1.47 47.4：与 switchVault 一致，切库后恢复目标库自己的工作区会话。
      // 注意此刻本页 currentVaultId 还是旧库，目标库以注册表为准。
      const targetSession: WorkspaceSession | null =
        (this.workspaceSessionStore as WorkspaceSessionStore).loadFor(VaultRegistry.get().currentId());
      this.leftOpenRequestId++;
      this.rightOpenRequestId++;
      this.stopWorkspaceSessionSaving();
      this.refreshFromRegistry();
      this.currentFilePath = '';
      this.rightFilePath = '';
      this.rightPaneIntentionallyEmpty = false;
      this.quickSwitchOpen = false;
      this.quickSwitchFiles = [];
      this.recentOpenPaths = [];
      // 直接写 drawerOpen 会让 drawerProgress 悬停在 1：抽屉视觉开着但
      // .enabled(drawerOpen) 已禁用 → 文件列表点任何东西都无反应。必须走同步器。
      this.setDrawerOpen(false);
      this.smMode = 'edit';
      if (targetSession === null) {
        await this.readAndPush('');
        await this.readRightAndPush('');
      } else {
        this.workspaceSessionRestoring = true;
        try {
          await this.applyWorkspaceSession(targetSession);
        } finally {
          this.workspaceSessionRestoring = false;
        }
      }
      this.workspaceSessionSavingEnabled = true;
      this.flushWorkspaceSessionSave(true);
    } catch (error) {
      this.toastRegistryError('切换库失败', error, 'vault', 'switch');
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
    return noteDisplayName(this.currentFileName());
  }

  /** v1.31 31.1：切换笔记项显示笔记标题（去 .md），不显示带扩展名的文件名 */
  private paneNoteTitle(path: string): string {
    return noteDisplayNameOfPath(path);
  }

  private activeNotePane(): string {
    return this.experienceMode === 'simple' ? this.simpleWorkspacePane() : this.activePane;
  }

  private activeFilePath(): string {
    const pane: string = this.activeNotePane();
    return pane === 'right' ? this.rightFilePath : this.currentFilePath;
  }

  private activeNoteMenuScopeLabel(): string {
    if (!this.isSingleScreenLayout() && this.isReferenceShown() &&
      this.currentFilePath.length > 0 && this.rightFilePath.length > 0) {
      return '当前笔记 · ' + (this.activeNotePane() === 'right' ? '右栏' : '左栏');
    }
    return '当前笔记';
  }

  private activeEditorBridge(): EditorBridge {
    const pane: string = this.experienceMode === 'simple' ? this.simpleWorkspacePane() : this.activePane;
    return pane === 'right' ? this.rightEditorBridge : this.editorBridge;
  }

  private sharedNoteEditor(): EditorBridge {
    if (this.leftComposing) {
      return this.editorBridge;
    }
    if (this.rightComposing || this.rightEditorDirty ||
      (this.experienceMode === 'simple' ? this.simpleWorkspacePane() === 'right' :
        this.rightEditing && this.activePane === 'right')) {
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
    if (this.experienceMode === 'simple') {
      this.previewBridgeForPane(this.simpleWorkspacePane()).scrollToHeading(index);
    } else if (this.activePane === 'right') {
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

  private setActivePane(pane: string, preserveEmpty: boolean = false): void {
    const nextPane: string = pane === 'right' ? 'right' : 'left';
    const paneChanged: boolean = this.activePane !== nextPane;
    this.activePane = nextPane;
    this.scheduleWorkspaceSessionSave();
    void this.refreshSharedEditability();
    void this.refreshActiveChaptersFromBridge();
    void this.refreshBacklinks();
    if (paneChanged && !preserveEmpty && !this.rightPaneIntentionallyEmpty && this.activePane === 'right' &&
      this.rightFilePath.length === 0 && this.currentFilePath.length > 0) {
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
    const generation: number = ++this.sharedEditabilityGeneration;
    const sharedNote: boolean = this.currentFilePath.length > 0 && this.currentFilePath === this.rightFilePath;
    const simplePane: string = this.simpleWorkspacePane();
    const leftRequested: boolean = this.experienceMode === 'simple'
      ? simplePane === 'left' : this.smMode === 'edit';
    const rightRequested: boolean = this.experienceMode === 'simple'
      ? simplePane === 'right' : this.rightEditing;
    const leftEditable: boolean = this.leftComposing || (!this.vaultSwitchInProgress && leftRequested &&
      (!sharedNote || (!this.rightComposing && (this.experienceMode === 'simple'
        ? simplePane === 'left' : this.activePane === 'left'))));
    const rightEditable: boolean = this.rightComposing || (!this.vaultSwitchInProgress && rightRequested &&
      (!sharedNote || (!this.leftComposing && (this.experienceMode === 'simple'
        ? simplePane === 'right' : this.activePane === 'right'))));

    // Revoke the old editor first so a same-note pane switch never leaves two active carets.
    if (!leftEditable && this.editorBridge.ready) {
      await this.editorBridge.setEditable(false);
      if (generation !== this.sharedEditabilityGeneration) {
        return;
      }
      this.editorBridge.blur();
    }
    if (!rightEditable && this.rightEditorBridge.ready) {
      await this.rightEditorBridge.setEditable(false);
      if (generation !== this.sharedEditabilityGeneration) {
        return;
      }
      this.rightEditorBridge.blur();
    }
    if (leftEditable && this.editorBridge.ready) {
      await this.editorBridge.setEditable(true);
      if (generation !== this.sharedEditabilityGeneration) {
        return;
      }
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
    const show: boolean = this.focused || !this.isReferenceShown();
    if (this.focused) {
      this.focused = false;
      this.focusNavigationOpen = false;
    }
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

  private canToggleFocus(): boolean {
    if (this.focused) {
      return true;
    }
    const bothPanesOpen: boolean = this.currentFilePath.length > 0 && this.rightFilePath.length > 0;
    if (this.isSingleScreenLayout() || !bothPanesOpen) {
      return false;
    }
    return this.isReferenceShown();
  }

  private toggleFocus(): void {
    if (!this.focused && !this.canToggleFocus()) {
      return;
    }
    this.focused = !this.focused;
    if (!this.focused) {
      this.focusNavigationOpen = false;
    }
    this.scheduleWorkspaceSessionSave();
    this.moreMenuOpen = false;
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
    if (this.vaultSwitchInProgress) {
      return false;
    }
    if (this.experienceMode === 'simple') {
      return this.previewBridgeForPane(pane).ready && this.simplePreviewEditable(pane) &&
        this.paneFilePath(pane).length > 0;
    }
    const sharedNote: boolean = this.currentFilePath.length > 0 && this.currentFilePath === this.rightFilePath;
    if (pane === 'right') {
      return this.rightEditorBridge.ready && (this.rightComposing || (this.rightEditing &&
        (!sharedNote || (!this.leftComposing && this.activePane === 'right'))));
    }
    return this.editorBridge.ready && (this.leftComposing || (this.smMode === 'edit' &&
      (!sharedNote || (!this.rightComposing && this.activePane === 'left'))));
  }

  /** v1.30 30.1：web 侧正文焦点变化 → 停靠格式栏显隐（失焦 250ms 去抖 + 组合输入保护） */
  private setSimpleTextFocus(pane: string, focused: boolean): void {
    if (focused) {
      this.clearSimpleFocusHideTimer(pane);
      this.applySimpleTextFocus(pane, true);
      return;
    }
    this.scheduleSimpleFocusHide(pane);
  }

  private applySimpleTextFocus(pane: string, focused: boolean): void {
    if (pane === 'right') {
      this.rightSimpleTextFocus = focused;
    } else {
      this.leftSimpleTextFocus = focused;
    }
  }

  private clearSimpleFocusHideTimer(pane: string): void {
    if (pane === 'right') {
      if (this.rightSimpleFocusHideTimer !== -1) {
        clearTimeout(this.rightSimpleFocusHideTimer);
        this.rightSimpleFocusHideTimer = -1;
      }
    } else if (this.leftSimpleFocusHideTimer !== -1) {
      clearTimeout(this.leftSimpleFocusHideTimer);
      this.leftSimpleFocusHideTimer = -1;
    }
  }

  private scheduleSimpleFocusHide(pane: string): void {
    this.clearSimpleFocusHideTimer(pane);
    const timerId: number = setTimeout((): void => {
      this.clearSimpleFocusHideTimer(pane);
      const composing: boolean = pane === 'right' ? this.rightComposing : this.leftComposing;
      if (composing) {
        this.scheduleSimpleFocusHide(pane);
        return;
      }
      this.applySimpleTextFocus(pane, false);
    }, 250);
    if (pane === 'right') {
      this.rightSimpleFocusHideTimer = timerId;
    } else {
      this.leftSimpleFocusHideTimer = timerId;
    }
  }

  /** v1.30 30.1/30.6：停靠格式栏可见 = 该栏正文聚焦，或该栏 Aa 面板/表格网格持焦 */
  private simpleFormatBarVisible(pane: string): boolean {
    if (this.experienceMode !== 'simple') {
      return false;
    }
    if ((this.formatMenuOpen && this.formatMenuPane === pane) ||
      (this.tableGridOpen && this.tableGridPane === pane)) {
      return true;
    }
    return pane === 'right' ? this.rightSimpleTextFocus : this.leftSimpleTextFocus;
  }

  /** v1.30 30.4：完成编辑 —— 收键盘、结束编辑焦点、收起停靠栏，焦点移到该栏路径行 */
  private finishSimpleEditingFor(pane: string): void {
    this.previewBridgeForPane(pane).finishSimpleEditing();
    this.clearSimpleFocusHideTimer(pane);
    this.applySimpleTextFocus(pane, false);
    // pane-title-* 仅在 PaneTitle 且该栏有文件路径时挂载，目标可缺失：必须走安全收焦
    //（裸调 requestFocus 抛 150003 未捕获曾致闪退，DFX JSCrash 2026-11-08，同 2026-11-06 focusEmptyPane）。
    FocusRequest.safely(this.getUIContext(), 'pane-title-' + pane);
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
    if (this.tableGridOpen && (this.topView !== 'note' ||
      this.currentVaultId !== this.formatMenuSourceVaultId ||
      this.paneFilePath(this.tableGridPane) !== this.formatMenuSourcePath ||
      !this.isPaneEditable(this.tableGridPane))) {
      this.tableGridOpen = false;
    }
    this.synchronizePreviewFollowContext();
    if (this.isBlockPropertyPanelOpen()) {
      if (this.topView !== 'note' || this.activePane !== this.blockPanelPane ||
        this.currentVaultId !== this.blockPanelSourceVaultId ||
        this.paneFilePath(this.blockPanelPane) !== this.blockPanelSourcePath ||
        !this.isPaneEditable(this.blockPanelPane)) {
        this.closeBlockPropertyPanel(false);
      } else {
        this.updateBlockPropertyPanelLayout(this.blockPanelPane);
      }
    }
    if (this.formatMenuOpen) {
      this.updateFormatPopupLayout(this.formatMenuPane);
    }
    this.updateBlockToolbarLayout(this.activePane);
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
      } else if (current !== this.sessionBaselineFor(vaultId, leftPath, 'left')) {
        await this.readAndPush(leftPath);
      }
    }
    if (rightPath.length > 0 && rightPath === leftPath && leftPath.length > 0 &&
      !WorkspaceEditGuard.isUnsaved(vaultId, rightPath)) {
      const current: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, rightPath);
      if (current === null) {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      } else if (current !== this.sessionBaselineFor(vaultId, rightPath, 'right')) {
        await this.readRightAndPush(rightPath);
      }
    } else if (rightPath.length > 0 && rightPath !== leftPath &&
      !WorkspaceEditGuard.isUnsaved(vaultId, rightPath)) {
      const current: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, rightPath);
      if (current === null) {
        this.rightFilePath = '';
        await this.readRightAndPush('');
      } else if (current !== this.sessionBaselineFor(vaultId, rightPath, 'right')) {
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

  private onFormatKeyboardInsetChanged(): void {
    if (this.formatMenuOpen) {
      this.updateFormatPopupLayout(this.formatMenuPane);
    }
    if (this.blockToolbarOpen) {
      this.updateBlockToolbarLayout(this.blockToolbarPane);
    }
    if (this.isBlockPropertyPanelOpen()) {
      this.updateBlockPropertyPanelLayout(this.blockPanelPane);
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
    if (this.blockToolbarOpen) {
      this.updateBlockToolbarLayout(this.blockToolbarPane);
    }
    if (this.isBlockPropertyPanelOpen()) {
      this.updateBlockPropertyPanelLayout(this.blockPanelPane);
    }
  }

  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {
    if (pane === 'right') {
      this.rightBlockAnchor = anchor;
    } else {
      this.leftBlockAnchor = anchor;
    }
    if (this.isBlockPropertyPanelOpen() && pane === this.blockPanelPane) {
      if (anchor !== null) {
        if (this.blockPanelAnchor !== null &&
          (anchor.from !== this.blockPanelAnchor.from || anchor.to !== this.blockPanelAnchor.to)) {
          this.closeBlockPropertyPanel(false);
        } else {
          const currentAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
          let panelAnchor: PreviewBlockAnchor = anchor;
          if (currentAnchor !== null && currentAnchor.tapType.length > 0 && anchor.tapType.length === 0) {
            panelAnchor = {
              type: anchor.type,
              tapType: currentAnchor.tapType,
              from: anchor.from,
              to: anchor.to,
              inlineItems: anchor.inlineItems.length > 0 ? anchor.inlineItems : currentAnchor.inlineItems,
              inlineSafe: anchor.inlineSafe,
              inlineIndex: currentAnchor.inlineIndex,
              itemFrom: currentAnchor.itemFrom,
              itemTo: currentAnchor.itemTo,
              codeLanguage: anchor.codeLanguage,
              codeLanguageFrom: anchor.codeLanguageFrom,
              codeLanguageTo: anchor.codeLanguageTo,
              codeLanguageSelectable: anchor.codeLanguageSelectable,
              codeLanguages: anchor.codeLanguages,
              codeEditable: anchor.codeEditable,
              tableRow: anchor.tableRow,
              tableColumn: anchor.tableColumn,
              tableRows: anchor.tableRows,
              tableColumns: anchor.tableColumns,
              tableStructureEditable: anchor.tableStructureEditable,
              x: anchor.x,
              y: anchor.y,
              width: anchor.width,
              height: anchor.height
            };
          }
          this.blockPanelAnchor = panelAnchor;
          this.pushedAnchor = panelAnchor;
          this.pushedAnchorMode = 'merge';
          this.pushedAnchorSeq++;
          this.blockPanelTitle = this.blockSourceEditing ? '以源码编辑' : blockPanelTitleFor(panelAnchor);
          this.updateBlockPropertyPanelLayout(pane);
        }
      }
    }
    if (pane !== this.activePane) {
      return;
    }
    this.blockToolbarPane = pane;
    this.updateBlockToolbarLayout(pane);
  }

  private onPreviewContentReplacing(pane: string): void {
    if (pane === this.blockPanelPane) {
      this.blockPanelPendingAction = false;
      if (this.isBlockPropertyPanelOpen()) {
        this.closeBlockPropertyPanel(false);
      } else {
        this.blockPanelRestoreFocus = false;
      }
    }
    this.onBlockAnchorChange(pane, null);
  }

  private onCodeBlockEditingChange(pane: string, editing: boolean): void {
    if (pane === 'right') {
      this.rightCodePreviewEditing = editing;
    } else {
      this.leftCodePreviewEditing = editing;
    }
  }

  private async handlePreviewCodeBlockEdit(pane: string, request: PreviewCodeEditRequest): Promise<void> {
    const vaultId: string = this.currentVaultId;
    const path: string = this.paneFilePath(pane);
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    const preview: PreviewBridge = this.previewBridgeForPane(pane);
    const revision: number = editor.currentDocumentRevision;
    if (this.experienceMode !== 'simple' || path.length === 0 ||
      !this.isCurrentSimplePreviewTarget(pane, path, vaultId, requestId) ||
      !Number.isInteger(request.from) || !Number.isInteger(request.to) || request.from < 0 ||
      request.to < request.from || (request.userEvent !== 'input.type' && request.userEvent !== 'input')) {
      preview.completeCodeBlockEdit(request.id, false);
      return;
    }
    let expectedAfter: string = '';
    if (request.historyIsolated || request.refreshPreview || request.showUndo) {
      let before: string = '';
      try {
        before = await editor.getContent();
      } catch {
        preview.completeCodeBlockEdit(request.id, false);
        promptAction.showToast({ message: '无法确认当前笔记，未应用表格操作' });
        return;
      }
      if (!this.isCurrentSimplePreviewTarget(pane, path, vaultId, requestId) ||
        editor.currentDocumentRevision !== revision || request.to > before.length ||
        before.slice(request.from, request.to) !== request.expectedSource) {
        preview.completeCodeBlockEdit(request.id, false);
        promptAction.showToast({ message: '内容已变化，未应用表格操作' });
        return;
      }
      expectedAfter = before.slice(0, request.from) + request.replacement + before.slice(request.to);
    }
    if (pane === 'right') {
      this.rightCodeEditPending = true;
    } else {
      this.leftCodeEditPending = true;
    }
    let applied: boolean = false;
    try {
      applied = await editor.replaceBlockSource(request.from, request.to, request.expectedSource,
        request.replacement, revision, request.userEvent, false, request.historyIsolated);
    } catch {
      hilog.warn(DOMAIN, TAG, '简单模式块内容回写失败');
    }
    if (!this.isCurrentSimplePreviewTarget(pane, path, vaultId, requestId) ||
      editor.currentDocumentRevision !== revision) {
      applied = false;
    }
    preview.completeCodeBlockEdit(request.id, applied);
    if (pane === 'right') {
      this.rightCodeEditPending = false;
    } else {
      this.leftCodeEditPending = false;
    }
    if (!applied && this.isCurrentSimplePreviewTarget(pane, path, vaultId, requestId)) {
      promptAction.showToast({ message: '内容已变化，未应用编辑' });
      return;
    }
    if (applied && request.refreshPreview) {
      let content: string = '';
      try {
        content = await editor.getContent();
      } catch {
        if (pane === 'right') {
          void this.syncRightContentToLeft();
        } else {
          this.schedulePreviewUpdate();
        }
        if (request.showUndo) {
          this.showUndo(`${request.undoMessage}；无法确认撤销目标`, null);
        }
        return;
      }
      if (!this.isCurrentSimplePreviewTarget(pane, path, vaultId, requestId) ||
        editor.currentDocumentRevision !== revision) {
        return;
      }
      if (pane === 'right') {
        this.pushRightPreview(content, true);
      } else {
        this.pushPreview(content, true);
      }
      if (request.focusTableFrom >= 0 && request.focusTableTo >= request.focusTableFrom) {
        preview.focusTableCell(request.focusTableFrom, request.focusTableTo,
          request.focusTableRow, request.focusTableColumn);
      }
      if (request.showUndo) {
        if (content === expectedAfter) {
          this.showUndo(request.undoMessage, null);
          this.tableEditUndoState = {
            pane: pane,
            vaultId: vaultId,
            path: path,
            requestId: requestId,
            documentRevision: revision,
            expectedContent: expectedAfter
          };
        } else {
          this.showUndo(`${request.undoMessage}；内容已变化，无法撤销`, null);
        }
      }
    }
  }

  private recordBlockToolbarPaneArea(pane: string, area: Area): void {
    this.recordFormatArea(pane === 'right' ? this.rightBlockToolbarPaneArea : this.leftBlockToolbarPaneArea, area);
    if (this.blockToolbarOpen && this.blockToolbarPane === pane) {
      this.updateBlockToolbarLayout(pane);
    }
    if (this.isBlockPropertyPanelOpen() && this.blockPanelPane === pane) {
      this.updateBlockPropertyPanelLayout(pane);
    }
  }

  private blockToolbarAnchorGeometry(pane: string): number[] {
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    const paneArea: number[] = pane === 'right'
      ? this.rightBlockToolbarPaneArea : this.leftBlockToolbarPaneArea;
    if (anchor === null) {
      return [0, 0, 0, 0];
    }
    return [anchor.x - paneArea[0], anchor.y - paneArea[1], anchor.width, anchor.height];
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
      this.closeFormatMenu();
      this.applyEditorFormat(kind, this.formatMenuPane);
    })
  }

  @Builder
  TableToolbarAction(text: string, label: string, type: string, side: string, enabled: boolean) {
    Text(text)
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_primary'))
      .width(Size.touch)
      .height(Size.touch)
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.icon)
      .enabled(enabled)
      .onClick((): void => {
        this.blockToolbarOpen = false;
        if (type === 'more') {
          this.openBlockPropertyPanel(this.blockToolbarPane);
        } else {
          this.applyTableStructureOperation(this.blockToolbarPane, type, side);
        }
      })
      .accessibilityText(label)
  }

  @Builder
  BlockToolbarContent() {
    Row({ space: Space.s1 }) {
      if (this.tableToolbarForPane(this.blockToolbarPane)) {
        this.TableToolbarAction('下加行', '下方加行', 'insertRow', 'down', true)
        this.TableToolbarAction('右加列', '右侧加列', 'insertColumn', 'right', true)
        this.TableToolbarAction('删除', '删除当前行', 'deleteRow', 'down',
          this.tableToolbarCanDeleteRow(this.blockToolbarPane))
        this.TableToolbarAction('更多', '更多表格操作', 'more', '', true)
      } else {
        ForEach(this.blockToolbarActions.slice(0, 4), (action: BlockToolbarAction) => {
          Row() {
            Icon(action.icon, Space.s5, $r('app.color.text_primary'))
          }
          .width(Size.touch)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .onClick((): void => {
            this.blockToolbarOpen = false;
            action.onActivate();
          })
          .accessibilityText(action.accessibilityText)
        }, (action: BlockToolbarAction) => action.id)
        if (this.blockToolbarActions.length > 0) {
          Row() {
            Icon('more', Space.s5, $r('app.color.text_primary'))
          }
          .width(Size.touch)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .onClick((): void => {
            this.openBlockPropertyPanel(this.blockToolbarPane);
          })
          .accessibilityText('更多')
        }
      }
    }
    .width(this.blockToolbarWidth)
    .constraintSize({ maxHeight: this.blockToolbarMaxHeight })
    .padding({ left: Space.s2, right: Space.s2, top: Space.s2, bottom: Space.s2 })
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.closeBlockToolbar(true);
      }
    })
  }

  /** v1.30 30.2：格式按钮序列（Aa/B/I/任务/表格/图片）；专业浮条与简单模式停靠栏共用，按钮集合不变（30.7） */
  @Builder
  FormatActionsRow(pane: string, gap: number) {
    Row({ space: gap }) {
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
          this.closeFormatMenu();
        }
      })
      this.FormatAction('B', 'bold', pane)
      if ((pane === 'right' ? this.rightPaneWidthVp : this.leftPaneWidthVp) >= 280) {
        this.FormatAction('I', 'italic', pane)
      }
      this.FormatAction('☐', 'task', pane)
      if (this.experienceMode === 'simple') {
        this.TableInsertAction(pane)
      }
      if (this.paneFilePath(pane).length > 0) {
        this.ImageFormatAction(pane)
      }
    }
  }

  private toggleTableGrid(pane: string): void {
    if (this.tableGridOpen && this.tableGridPane === pane) {
      this.tableGridOpen = false;
      return;
    }
    if (this.experienceMode !== 'simple' || !this.isPaneEditable(pane)) {
      return;
    }
    this.setActivePane(pane);
    this.tableGridPane = pane;
    this.formatMenuSourceVaultId = this.currentVaultId;
    this.formatMenuSourcePath = this.paneFilePath(pane);
    this.tableGridFocusedRows = 1;
    this.tableGridFocusedColumns = 1;
    this.tableGridOpen = true;
  }

  private tableGridCellFocusId(pane: string, rows: number, columns: number): string {
    return `table-grid-${pane}-${rows}-${columns}`;
  }

  private onTableGridCellKey(pane: string, rows: number, columns: number, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    let nextRows: number = rows;
    let nextColumns: number = columns;
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      nextRows = Math.max(1, rows - 1);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      nextRows = Math.min(8, rows + 1);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
      nextColumns = Math.max(1, columns - 1);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
      nextColumns = Math.min(6, columns + 1);
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER ||
      event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
      this.insertTableFromGrid(pane, rows, columns);
      return true;
    } else if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.tableGridOpen = false;
      return true;
    } else {
      return false;
    }
    this.tableGridFocusedRows = nextRows;
    this.tableGridFocusedColumns = nextColumns;
    FocusRequest.safely(this.getUIContext(), this.tableGridCellFocusId(pane, nextRows, nextColumns));
    return true;
  }

  private insertTableFromGrid(pane: string, rows: number, columns: number): void {
    if (!this.tableGridOpen || this.tableGridPane !== pane ||
      this.currentVaultId !== this.formatMenuSourceVaultId ||
      this.paneFilePath(pane) !== this.formatMenuSourcePath || !this.isPaneEditable(pane)) {
      this.tableGridOpen = false;
      promptAction.showToast({ message: '笔记已变化，请重新选择插入位置' });
      return;
    }
    this.tableGridOpen = false;
    this.previewBridgeForPane(pane).insertTable(rows, columns);
  }

  private onFormatMenuKey(pane: string, event: KeyEvent): void {
    if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.closeFormatMenu(true);
    }
  }

  private hasBlockToolbarForPane(pane: string): boolean {
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    const tableActions: boolean = anchor !== null &&
      anchor.type === 'table' && anchor.tableStructureEditable;
    return this.experienceMode === 'simple' && this.topView === 'note' && this.activePane === pane &&
      !this.formatMenuOpen && this.isPaneEditable(pane) && anchor !== null &&
      (tableActions || (this.blockToolbarActions.length > 0 && anchor.type !== 'code')) &&
      (pane !== 'right' || this.notePaneVisible(pane));
  }

  private applyTableStructureOperation(pane: string, type: string, side: string): void {
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    if (anchor === null || anchor.type !== 'table' || !anchor.tableStructureEditable ||
      !this.isPaneEditable(pane)) {
      return;
    }
    this.previewBridgeForPane(pane).applyTableStructureOperation(type, side, anchor.tableRow,
      anchor.tableColumn, anchor.from, anchor.to);
  }

  private tableToolbarForPane(pane: string): boolean {
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    return anchor !== null && anchor.type === 'table' && anchor.tableStructureEditable;
  }

  private tableToolbarCanDeleteRow(pane: string): boolean {
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    return anchor !== null && anchor.type === 'table' && anchor.tableRow > 0;
  }

  private hasBlockPropertyPanelForPane(pane: string, requestedAnchor: PreviewBlockAnchor | null = null): boolean {
    const anchor: PreviewBlockAnchor | null = requestedAnchor !== null
      ? requestedAnchor : pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    return this.experienceMode === 'simple' && this.topView === 'note' &&
      this.isPaneEditable(pane) && anchor !== null && (pane !== 'right' || this.notePaneVisible(pane));
  }

  private isBlockPropertyPanelOpen(): boolean {
    return this.leftBlockPanelOpen || this.rightBlockPanelOpen;
  }

  private blockPanelAnchorGeometry(pane: string): number[] {
    const paneArea: number[] = pane === 'right'
      ? this.rightBlockToolbarPaneArea : this.leftBlockToolbarPaneArea;
    if (this.breakpoint === Breakpoint.SM) {
      return [0, 0, Space.s1, Space.s1];
    }
    return [this.blockPanelHostX - paneArea[0], this.blockPanelHostY - paneArea[1], Space.s1, Space.s1];
  }


  private updateBlockPropertyPanelLayout(pane: string): void {
    if (!this.isBlockPropertyPanelOpen() || pane !== this.blockPanelPane ||
      this.breakpoint === Breakpoint.SM) {
      return;
    }
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null) {
      this.closeBlockPropertyPanel(false);
      return;
    }
    const paneArea: number[] = pane === 'right'
      ? this.rightBlockToolbarPaneArea : this.leftBlockToolbarPaneArea;
    const anchorArea: number[] = [anchor.x, anchor.y, anchor.width, anchor.height];
    const panelWidth: number = this.blockSourceEditing ? Size.blockSourceW : Size.blockPanelW;
    const layout: AnchoredPopupLayout | null = this.calculateAnchoredPopupLayout(
      pane, paneArea, anchorArea, panelWidth, Size.menuMaxH, anchor.x);
    if (layout === null) {
      this.closeBlockPropertyPanel(false);
      return;
    }
    const minX: number = paneArea[0] + Space.s2;
    const maxX: number = paneArea[0] + paneArea[2] - Space.s2 - layout.width;
    this.blockPanelHostX = Math.max(minX, Math.min(anchor.x + layout.offsetX, maxX));
    this.blockPanelHostY = anchor.y + layout.offsetY;
    this.blockPanelPlacement = layout.placement;
    this.blockPanelWidth = layout.width;
    this.blockPanelMaxHeight = Math.min(Size.menuMaxH, layout.maxHeight);
  }

  private blockPanelSheetOptions(): SheetOptions {
    if (this.breakpoint === Breakpoint.SM) {
      return {
        height: SheetSize.MEDIUM,
        width: '100%',
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: true,
        title: { title: this.blockPanelTitle },
        onDisappear: (): void => { this.onBlockPropertyPanelDisappear(); }
      };
    }
    return {
      height: SheetSize.FIT_CONTENT,
      width: this.blockPanelWidth,
      preferType: SheetType.POPUP,
      dragBar: false,
      showClose: true,
      title: { title: this.blockPanelTitle },
      placement: this.blockPanelPlacement,
      maskColor: Color.Transparent,
      onDisappear: (): void => { this.onBlockPropertyPanelDisappear(); }
    };
  }

  private closeFormatMenu(restoreEditor: boolean = false): void {
    const pane: string = this.formatMenuPane;
    if (this.formatMenuOpen) {
      this.restoreSuppressedPaneSelectionUi();
    }
    this.formatMenuOpen = false;
    if (restoreEditor) {
      const bridge: EditorBridge = pane === 'right' ? this.rightEditorBridge : this.editorBridge;
      bridge.focus();
    }
  }

  private closeBlockPropertyPanel(restoreFocus: boolean = true): void {
    this.blockPanelRestoreFocus = restoreFocus;
    this.leftBlockPanelOpen = false;
    this.rightBlockPanelOpen = false;
    this.resetBlockSourceEditor();
  }

  private resetBlockSourceEditor(): void {
    this.blockSourceEditing = false;
  }

  private async copyTextToPasteboard(content: string, label: string): Promise<void> {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content));
      promptAction.showToast({ message: `已复制${label}` });
    } catch {
      promptAction.showToast({ message: `复制${label}失败，请重试` });
    }
  }

  private async copyCodeTextToPasteboard(content: string): Promise<void> {
    await this.copyTextToPasteboard(content, '代码');
  }

  private isCurrentBlockSourceTarget(pane: string, vaultId: string, path: string, requestId: number,
    documentRevision: number): boolean {
    return this.isBlockPropertyPanelOpen() && this.blockPanelPane === pane && this.activePane === pane &&
      this.topView === 'note' && this.experienceMode === 'simple' && this.currentVaultId === vaultId &&
      this.paneFilePath(pane) === path && this.isPaneEditable(pane) &&
      (pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId) === requestId &&
      this.editorBridgeForPane(pane).currentDocumentRevision === documentRevision;
  }



  private closeBlockPanelForContentAction(): void {
    this.blockPanelPendingAction = true;
    this.closeBlockPropertyPanel(false);
  }

  private onBlockPropertyPanelDisappear(): void {
    if (this.blockPanelPendingAction) {
      this.blockPanelPendingAction = false;
      const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
      const pane: string = this.blockPanelPane;
      if (anchor !== null && this.activePane === pane && this.topView === 'note' &&
        this.experienceMode === 'simple' && this.currentVaultId === this.blockPanelSourceVaultId &&
        this.paneFilePath(pane) === this.blockPanelSourcePath && this.isPaneEditable(pane)) {
        this.previewBridgeForPane(pane).activateLockedContent(anchor.from, anchor.to, anchor.inlineIndex);
      }
      this.blockPanelRestoreFocus = false;
      return;
    }
    const restoreFocus: boolean = this.blockPanelRestoreFocus;
    this.blockPanelRestoreFocus = false;
    if (restoreFocus) {
      this.restoreBlockPanelFocus();
    }
  }

  private restoreBlockPanelFocus(): void {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    if (anchor === null || this.activePane !== pane || this.topView !== 'note' ||
      this.experienceMode !== 'simple' || !this.isPaneEditable(pane) ||
      this.currentVaultId !== this.blockPanelSourceVaultId || this.paneFilePath(pane) !== this.blockPanelSourcePath) {
      return;
    }
    this.previewBridgeForPane(pane).focusBlock(anchor.from, anchor.to);
  }

  private restoreBlockFocus(pane: string, anchor: PreviewBlockAnchor | null): void {
    if (anchor !== null) {
      this.previewBridgeForPane(pane).focusBlock(anchor.from, anchor.to);
    }
  }

  private closeBlockToolbar(restoreFocus: boolean): void {
    const pane: string = this.blockToolbarPane;
    const anchor: PreviewBlockAnchor | null = pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    this.blockToolbarOpen = false;
    if (restoreFocus) {
      this.restoreBlockFocus(pane, anchor);
    }
  }


  private calculateAnchoredPopupLayout(
    pane: string,
    paneArea: number[],
    anchorArea: number[],
    maxWidth: number,
    naturalHeight: number,
    defaultPopupLeft: number
  ): AnchoredPopupLayout | null {
    const paneX: number = paneArea[0];
    const paneY: number = paneArea[1];
    const paneWidth: number = paneArea[2];
    const paneHeight: number = paneArea[3];
    const anchorX: number = anchorArea[0];
    const anchorY: number = anchorArea[1];
    const anchorWidth: number = anchorArea[2];
    const anchorHeight: number = anchorArea[3];
    if (paneWidth <= 0 || paneHeight <= 0 || anchorWidth <= 0 || anchorHeight <= 0) {
      return null;
    }

    const windowWidth: number = this.formatWindowArea[2];
    const windowHeight: number = this.formatWindowArea[3];
    const visibleLeft: number = Math.max(paneX, windowWidth > 0 ? this.formatWindowArea[0] : paneX);
    const visibleTop: number = Math.max(paneY, windowHeight > 0 ? this.formatWindowArea[1] : paneY);
    const visibleRight: number = Math.min(paneX + paneWidth,
      windowWidth > 0 ? this.formatWindowArea[0] + windowWidth : paneX + paneWidth);
    const visibleBottom: number = Math.min(paneY + paneHeight,
      windowHeight > 0 ? this.formatWindowArea[1] + windowHeight : paneY + paneHeight);
    const keyboardSafeBottom: number = Math.max(visibleTop, visibleBottom - this.keyboardInsetVp());
    const gap: number = Space.s2;
    const safeAnchorTop: number = Math.max(visibleTop, Math.min(anchorY, keyboardSafeBottom));
    const safeAnchorBottom: number = Math.max(visibleTop,
      Math.min(anchorY + anchorHeight, keyboardSafeBottom));
    const width: number = Math.min(maxWidth, visibleRight - visibleLeft - gap * 2);
    const above: number = Math.max(0, safeAnchorTop - visibleTop - gap * 2);
    const below: number = Math.max(0, keyboardSafeBottom - safeAnchorBottom - gap * 2);
    const showAbove: boolean = above >= naturalHeight || above >= below;
    const availableHeight: number = showAbove ? above : below;
    if (width <= 0 || availableHeight <= 0) {
      return null;
    }

    const minLeft: number = visibleLeft + gap;
    const maxLeft: number = visibleRight - gap - width;
    const minCenterX: number = minLeft + width / 2;
    const maxCenterX: number = maxLeft + width / 2;
    const centerX: number = Math.max(minCenterX, Math.min(anchorX + anchorWidth / 2, maxCenterX));
    const left: number = centerX - width / 2;
    const windowLeft: number = windowWidth > 0 ? this.formatWindowArea[0] : paneX;
    const windowRight: number = windowWidth > 0 ? windowLeft + windowWidth : paneX + paneWidth;
    const defaultPopupLeftInWindow: number = Math.max(windowLeft + gap,
      Math.min(defaultPopupLeft, windowRight - gap - width));
    return {
      placement: showAbove ? Placement.TopLeft : Placement.BottomLeft,
      offsetX: left - defaultPopupLeftInWindow,
      offsetY: showAbove
        ? safeAnchorTop - anchorY - gap
        : safeAnchorBottom - anchorY - anchorHeight + gap,
      width: width,
      maxHeight: availableHeight
    };
  }

  private updateFormatPopupLayout(pane: string): void {
    if (!this.formatMenuOpen || pane !== this.formatMenuPane) {
      return;
    }
    if (this.topView !== 'note' || this.activePane !== pane ||
      this.currentVaultId !== this.formatMenuSourceVaultId ||
      this.paneFilePath(pane) !== this.formatMenuSourcePath || !this.isPaneEditable(pane) ||
      (pane === 'right' && !this.notePaneVisible(pane))) {
      this.closeFormatMenu();
      return;
    }

    const paneArea: number[] = pane === 'right' ? this.rightFormatPaneArea : this.leftFormatPaneArea;
    const anchorArea: number[] = pane === 'right' ? this.rightFormatAnchorArea : this.leftFormatAnchorArea;
    const paneWidth: number = paneArea[2];
    const paneHeight: number = paneArea[3];
    const anchorX: number = anchorArea[0];
    const anchorWidth: number = anchorArea[2];
    const anchorHeight: number = anchorArea[3];
    if (paneWidth <= 0 || paneHeight <= 0 || anchorWidth <= 0 || anchorHeight <= 0) {
      return;
    }

    const naturalHeight: number =
      Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2 + Size.touch + Space.s2;
    const gap: number = Space.s2;
    const defaultPopupLeft: number = pane === 'right' ? anchorX - anchorWidth + gap : anchorX;
    const layout: AnchoredPopupLayout | null = this.calculateAnchoredPopupLayout(
      pane, paneArea, anchorArea, Size.formatMenuW, naturalHeight, defaultPopupLeft);
    if (layout === null) {
      this.closeFormatMenu();
      return;
    }

    this.formatPopupPlacement = layout.placement;
    this.formatPopupOffsetX = layout.offsetX;
    this.formatPopupOffsetY = layout.offsetY;
    if (Math.abs(this.formatMenuWidth - layout.width) >= 0.5) {
      this.formatMenuWidth = layout.width;
    }
    if (Math.abs(this.formatMenuMaxHeight - layout.maxHeight) >= 0.5) {
      this.formatMenuMaxHeight = layout.maxHeight;
    }
  }

  private updateBlockToolbarLayout(pane: string): void {
    if (!this.hasBlockToolbarForPane(pane)) {
      this.blockToolbarOpen = false;
      return;
    }
    const anchor: PreviewBlockAnchor = pane === 'right'
      ? this.rightBlockAnchor as PreviewBlockAnchor
      : this.leftBlockAnchor as PreviewBlockAnchor;
    const paneArea: number[] = pane === 'right'
      ? this.rightBlockToolbarPaneArea : this.leftBlockToolbarPaneArea;
    if (paneArea[2] <= 0 || paneArea[3] <= 0) {
      return;
    }
    const anchorArea: number[] = [anchor.x, anchor.y, anchor.width, anchor.height];
    const actionCount: number = anchor.type === 'table'
      ? 4 : Math.min(4, this.blockToolbarActions.length) + 1;
    const naturalWidth: number = actionCount * Size.touch + Space.s2 * Math.max(0, actionCount - 1) +
      Space.s4 * 2;
    const naturalHeight: number = Size.touch + Space.s4 * 2;
    const layout: AnchoredPopupLayout | null = this.calculateAnchoredPopupLayout(
      pane, paneArea, anchorArea, naturalWidth, naturalHeight, anchor.x);
    if (layout === null) {
      this.blockToolbarOpen = false;
      return;
    }
    this.blockToolbarPane = pane;
    this.blockToolbarPlacement = layout.placement;
    this.blockToolbarOffsetX = layout.offsetX;
    this.blockToolbarOffsetY = layout.offsetY;
    this.blockToolbarWidth = layout.width;
    this.blockToolbarMaxHeight = layout.maxHeight;
    this.blockToolbarOpen = true;
  }

  private applyEditorFormat(kind: string, pane: string): void {
    if (!this.isPaneEditable(pane)) {
      return;
    }
    if (this.experienceMode === 'simple') {
      if (kind === 'inlineCode' || kind === 'code' || kind === 'link') {
        promptAction.showToast({ message: '此格式请在专业模式编辑' });
        return;
      }
      this.previewBridgeForPane(pane).applyFormat(kind);
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
  private onSelectFile(relPath: string, targetPane: string = this.activePane, returnFocus: boolean = false): void {
    const pane: string = targetPane === 'right' ? 'right' : 'left';
    if (pane !== this.activePane) {
      this.setActivePane(pane, true);
    }
    if (this.isSingleScreenLayout()) {
      this.setDrawerOpen(false);
      if (this.isSingleLandscape()) {
        this.setSidebarCollapsed(true);
      }
      this.smMode = 'edit';
    }
    const vaultId: string = this.currentVaultId;
    const opening: Promise<void> = pane === 'right'
      ? this.loadRightFile(relPath) : this.loadFile(relPath);
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    if (returnFocus) {
      void opening.then((): void => {
        const currentPath: string = this.paneFilePath(pane);
        const currentRequestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
        if (this.currentVaultId === vaultId && currentPath === relPath && currentRequestId === requestId) {
          this.focusPaneBody(pane);
        }
      });
    }
  }

  private async closePaneNote(paneName: string): Promise<void> {
    const pane: string = paneName === 'right' ? 'right' : 'left';
    const path: string = this.paneFilePath(pane);
    const vaultId: string = this.currentVaultId;
    if (this.topView !== 'note' || path.length === 0 || vaultId.length === 0) {
      return;
    }
    if ((pane === 'right' ? this.rightCloseRequestId : this.leftCloseRequestId) > 0) {
      return;
    }
    if (this.workspaceOpenRequests > 0) {
      promptAction.showToast({ message: '笔记正在切换，请稍后再关闭' });
      return;
    }
    const sharedNote: boolean = path === (pane === 'right' ? this.currentFilePath : this.rightFilePath);
    const composing: boolean = pane === 'right' ? this.rightComposing : this.leftComposing;
    if (composing || (sharedNote && (this.leftComposing || this.rightComposing))) {
      promptAction.showToast({ message: '请先完成当前输入，再关闭笔记' });
      return;
    }

    const leftRequestId: number = this.leftOpenRequestId;
    const rightRequestId: number = this.rightOpenRequestId;
    const previousRightEmpty: boolean = this.rightPaneIntentionallyEmpty;
    const closeId: number = ++this.paneCloseRequestSequence;
    if (pane === 'right') {
      this.rightCloseRequestId = closeId;
    } else {
      this.leftCloseRequestId = closeId;
    }
    const isCurrentClose = (): boolean => this.currentVaultId === vaultId &&
      this.paneFilePath(pane) === path && this.leftOpenRequestId === leftRequestId &&
      this.rightOpenRequestId === rightRequestId && this.workspaceOpenRequests === 0 &&
      (pane === 'right' ? this.rightCloseRequestId : this.leftCloseRequestId) === closeId;
    let transition: number = -1;
    let clearRequestId: number = 0;
    let pointerCleared: boolean = false;
    let clearCommitted: boolean = false;

    try {
      if (this.experienceMode === 'simple') {
        const savePane: string = sharedNote ? this.simpleWorkspacePane() : pane;
        const previewError: string = await this.flushSimplePreviewPane(savePane);
        if (!isCurrentClose()) {
          return;
        }
        if (previewError.length > 0) {
          this.showFailureFeedback('note', 'bridge', 'unknown', 'not_completed', 'retry',
            '笔记仍保持打开；' + previewError + '。请检查内容后重试。');
          return;
        }
      }

      let saved: boolean = false;
      if (pane === 'right') {
        saved = await this.flushRightSave(path, vaultId, false);
      } else {
        const source: EditorBridge = sharedNote ? this.sharedNoteEditor() : this.editorBridge;
        saved = await this.flushSave(path, vaultId, source, false);
      }
      if (!saved || !isCurrentClose()) {
        return;
      }

      this.setActivePane(pane, true);
      if (this.formatMenuOpen && this.formatMenuPane === pane) {
        this.closeFormatMenu();
      }
      if (this.tableGridOpen && this.tableGridPane === pane) {
        this.tableGridOpen = false;
      }
      if (this.blockPanelPane === pane && this.isBlockPropertyPanelOpen()) {
        this.closeBlockPropertyPanel(false);
      }
      if (this.blockToolbarPane === pane) {
        this.closeBlockToolbar(false);
      }
      if (this.backlinksPane === pane) {
        this.backlinksExpanded = false;
        this.backlinksPane = '';
      }
      this.paneCloseHovered = '';

      const bridge: EditorBridge = pane === 'right' ? this.rightEditorBridge : this.editorBridge;
      transition = bridge.beginDocumentTransition();
      if (pane === 'right') {
        clearRequestId = ++this.rightOpenRequestId;
        this.rightFilePath = '';
        this.rightPaneIntentionallyEmpty = true;
      } else {
        clearRequestId = ++this.leftOpenRequestId;
        this.currentFilePath = '';
      }
      pointerCleared = true;
      const cleared: boolean = pane === 'right'
        ? await this.readRightAndPush('', clearRequestId, vaultId)
        : await this.readAndPush('', false, clearRequestId, vaultId, this.rightOpenRequestId);
      const clearStillCurrent: boolean = this.currentVaultId === vaultId &&
        this.paneFilePath(pane).length === 0 &&
        (pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId) === clearRequestId;
      if (!clearStillCurrent) {
        return;
      }
      if (!cleared) {
        if (pane === 'right') {
          this.rightFilePath = path;
          this.rightPaneIntentionallyEmpty = false;
          this.rightEditorBridge.restoreDocumentTransition(transition);
          void this.readRightAndPush(path, clearRequestId, vaultId);
        } else {
          this.currentFilePath = path;
          this.editorBridge.restoreDocumentTransition(transition);
          void this.readAndPush(path, false, clearRequestId, vaultId, this.rightOpenRequestId);
        }
        this.showFailureFeedback('note', 'bridge', 'unknown', 'not_completed', 'reopen_note',
          '笔记已保存，但栏位未能清空；原笔记仍保留，请重试关闭。');
        return;
      }

      clearCommitted = true;
      this.ensureRecentOpenStore();
      const store: RecentOpenStore = this.recentOpenStore as RecentOpenStore;
      store.recordClosed(vaultId, pane, path);
      try {
        this.refreshRecentOpenPaths();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '关闭后刷新最近笔记失败');
      }
      if (!this.flushWorkspaceSessionSave(true)) {
        this.showFailureFeedback('workspace', 'save', 'storage_failure', 'not_completed', 'check_status',
          '笔记已保存并关闭，但空栏状态未能写入工作区会话；重启后可能恢复旧布局。请检查存储状态。');
      }
      this.focusEmptyPane(pane);
    } catch (error) {
      const clearStillCurrent: boolean = pointerCleared && this.currentVaultId === vaultId &&
        this.paneFilePath(pane).length === 0 &&
        (pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId) === clearRequestId;
      if (!clearCommitted && clearStillCurrent) {
        if (pane === 'right') {
          this.rightFilePath = path;
          this.rightPaneIntentionallyEmpty = previousRightEmpty;
          this.rightEditorBridge.restoreDocumentTransition(transition);
          try {
            await this.readRightAndPush(path, clearRequestId, vaultId);
          } catch (restoreError) {
            hilog.warn(DOMAIN, TAG, '关闭失败后恢复右栏内容失败');
          }
        } else {
          this.currentFilePath = path;
          this.editorBridge.restoreDocumentTransition(transition);
          try {
            await this.readAndPush(path, false, clearRequestId, vaultId, this.rightOpenRequestId);
          } catch (restoreError) {
            hilog.warn(DOMAIN, TAG, '关闭失败后恢复左栏内容失败');
          }
        }
      }
      if (clearCommitted) {
        hilog.error(DOMAIN, TAG, '栏位已关闭，但关闭后的状态更新失败');
        this.showFailureFeedback('workspace', 'save', 'storage_failure', 'not_completed', 'check_status',
          '笔记已关闭，但工作区状态更新失败；重启后可能恢复旧布局。请检查存储状态。');
      } else if (clearStillCurrent || isCurrentClose()) {
        this.showFailureFeedback('note', 'save', 'unknown', 'not_completed', 'retry',
          '笔记未关闭，当前内容仍保留。请检查保存状态后重试。');
      }
    } finally {
      if (pane === 'right' && this.rightCloseRequestId === closeId) {
        this.rightCloseRequestId = 0;
      } else if (pane === 'left' && this.leftCloseRequestId === closeId) {
        this.leftCloseRequestId = 0;
      }
    }
  }

  private focusEmptyPane(pane: string): void {
    // L-19 结论2 / L-20：零延迟定时器不保证目标挂树（2026-11-06 DFX JSCrash 实证），
    // 事件驱动才是可靠模式——目标已挂载立即请求；否则记待聚焦栏位，
    // 由目标行 onAppear 挂树后经 consumeEmptyPaneFocus 补齐（v1.46 46.5）。
    const focusId: string = this.emptyPaneFocusId(pane);
    try {
      if (this.getUIContext().getAttachedFrameNodeById(focusId) !== null) {
        FocusRequest.safely(this.getUIContext(), focusId);
        return;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '空栏焦点预查询失败，转由挂载事件补齐');
    }
    this.pendingEmptyPaneFocus = pane;
  }

  private emptyPaneFocusId(pane: string): string {
    // 与 EmptyPane 渲染分支对齐：空库不渲染「重新打开」行，只能聚焦「新建笔记」
    //（DFX JSCrash 2026-11-06：空库 + 有最近关闭路径时曾指向必然不存在的
    // pane-empty-reopen-*，requestFocus 抛 150003 未捕获导致闪退；
    // 2026-11-08 起全应用收口 FocusRequest.safely，见 common/FocusRequest.ets）。
    return this.currentVaultNoteCount > 0 && this.paneLastClosedPath(pane).length > 0
      ? 'pane-empty-reopen-' + pane : 'pane-empty-new-' + pane;
  }

  private consumeEmptyPaneFocus(pane: string, focusId: string): void {
    if (this.pendingEmptyPaneFocus !== pane || this.emptyPaneFocusId(pane) !== focusId) {
      return; // 无待聚焦，或同栏其他动作先挂树（目标为 reopen 时 new 行不抢焦点）
    }
    this.pendingEmptyPaneFocus = '';
    FocusRequest.safely(this.getUIContext(), focusId);
  }

  private focusPaneBody(pane: string): void {
    const editing: boolean = this.experienceMode === 'professional' &&
      (pane === 'right' ? this.rightEditing : this.smMode === 'edit');
    if (editing) {
      (pane === 'right' ? this.rightEditorBridge : this.editorBridge).focus();
      return;
    }
    FocusRequest.safely(this.getUIContext(),
      pane === 'right' ? 'note-right-preview-web' : 'note-left-preview-web');
  }

  private paneLastClosedPath(pane: string): string {
    return pane === 'right' ? this.rightLastClosedPath : this.leftLastClosedPath;
  }

  private paneEmptyTitleSize(pane: string): number {
    return pane === 'right' ? Size.paneEmptyTitleRight :
      (this.isSingleScreenLayout() ? Size.paneEmptyTitleSingle : Size.paneEmptyTitleWide);
  }

  /** 行尾全角句号悬挂：负字距抵消「。」字身框右侧空档，使墨迹（而非文本框）视觉居中 */
  private paneEmptyPunctHang(fontSize: number): number {
    return -fontSize * Size.paneEmptyPunctHangRatio;
  }

  private paneRecentPaths(pane: string): string[] {
    const closedPath: string = this.paneLastClosedPath(pane);
    const paths: string[] = [];
    for (const path of this.recentOpenPaths) {
      if (path !== closedPath && paths.length < 4) {
        paths.push(path);
      }
    }
    return paths;
  }

  private noteTitleForPath(path: string): string {
    return noteDisplayNameOfPath(path);
  }

  private noteFolderForPath(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(0, slash) : '根目录';
  }

  private openNoteNavigation(): void {
    if (this.focused) {
      this.focusNavigationOpen = true;
    } else if (this.breakpoint === Breakpoint.SM) {
      this.setDrawerOpen(true);
    } else {
      this.setSidebarCollapsed(false);
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
  private openQuickSwitcher(targetPane: string = this.activePane): void {
    if (this.topView !== 'note' || this.currentVaultId.length === 0) {
      return;
    }
    const pane: string = targetPane === 'right' ? 'right' : 'left';
    if (pane !== this.activePane) {
      this.setActivePane(pane, true);
    }
    this.quickSwitchTargetPane = pane;
    const registry: VaultRegistry = VaultRegistry.get();
    const files: string[] = FileTree.allNotesOf(registry.accessFor(this.currentVaultId));
    this.ensureRecentOpenStore();
    const store: RecentOpenStore = this.recentOpenStore as RecentOpenStore;
    this.quickSwitchFiles = files;
    this.recentOpenPaths = store.load(this.currentVaultId, files);
    this.quickSwitchOpen = true;
  }

  /** v1.35 35.4：点开其他库的搜索结果先按现有流程切换到该库，成功后再打开笔记；失败停留原库。 */
  private async selectQuickSwitchFile(vaultId: string, relPath: string): Promise<void> {
    if (vaultId !== this.currentVaultId) {
      if (this.vaultSwitchInProgress) {
        promptAction.showToast({ message: '正在切换知识库，请稍候' });
        return;
      }
      await this.switchVault(vaultId);
      if (this.currentVaultId !== vaultId) {
        // switchVault 内部已给出失败原因并回滚到原库；不打开笔记。
        return;
      }
    }
    this.quickSwitchOpen = false;
    this.onSelectFile(relPath, this.quickSwitchTargetPane, true);
  }

  private isCurrentLeftOpenTarget(path: string, vaultId: string, requestId: number = -1): boolean {
    return path === this.currentFilePath && vaultId === this.currentVaultId &&
      (requestId < 0 || requestId === this.leftOpenRequestId);
  }

  private isCurrentRightOpenTarget(path: string, vaultId: string, requestId: number = -1): boolean {
    return vaultId === this.currentVaultId && (requestId < 0 || requestId === this.rightOpenRequestId) &&
      (path.length === 0 || path === this.rightFilePath);
  }

  /** 取某栏会话的已落盘基线；会话缺失或不属于该笔记时返回 null（调用方按「状态未知」处理）。 */
  private sessionBaselineFor(vaultId: string, path: string, pane: string): string | null {
    const session: EditorNoteSession | null = pane === 'right' ? this.rightSession : this.leftSession;
    return session !== null && session.isFor(vaultId, path) ? session.baseline : null;
  }

  /**
   * 读取笔记全文并下发给 Web 编辑器（M0.5 spike 的加载路径）。
   * 读文件在 ArkTS 侧做（组件不碰 IO，硬约束 14）；读取失败返回 false，由切换方保留当前笔记并提示。
   * ⚠️ **先记会话基线再下发给编辑器**：若 Web 的 setContent 回灌一个 change
   * 事件，guard 才能识别「内容没变」跳过冗余写（否则会被当成新编辑重写一遍）。
   */
  private async readAndPush(relPath: string, initializeRight: boolean = true, requestId: number = -1,
    requestVaultId: string = '', rightRequestId: number = -1): Promise<boolean> {
    const targetVaultId: string = requestVaultId.length > 0 ? requestVaultId : this.currentVaultId;
    const effectiveRequestId: number = requestId < 0 ? this.leftOpenRequestId : requestId;
    const effectiveRightRequestId: number = rightRequestId < 0 ? this.rightOpenRequestId : rightRequestId;
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    let text: string | null = '';
    if (targetVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.tryReadNote(VaultRegistry.get(), targetVaultId, relPath);
      if (text === null) {
        return false;
      }
    }
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    let displayText: string = text;
    let draftRecovered: boolean = false;
    if (targetVaultId.length > 0 && relPath.length > 0) {
      try {
        const recovery: NoteDraftRecovery = await NoteDraftService.recover(
          VaultRegistry.get(), targetVaultId, relPath, text);
        if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
          return false;
        }
        displayText = recovery.content;
        draftRecovered = recovery.recovered;
        this.reportDraftRecovery(targetVaultId, relPath, recovery);
      } catch (error) {
        if (this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
          this.showFailureFeedback('note', 'restore', 'unknown', 'status_unknown', 'check_status',
            '正式笔记已打开，但恢复草稿未能读取；草稿状态未确认。请先检查笔记，再重试恢复。');
        }
      }
    }
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    WorkspaceEditGuard.clear('left', targetVaultId, relPath);
    if (!this.workspaceSessionRestoring &&
      !(this.leftSession !== null && this.leftSession.isFor(targetVaultId, relPath))) {
      this.leftEditorScrollTop = 0;
      this.leftPreviewScrollTop = 0;
    }
    this.clearStaleSaveNotice(targetVaultId, relPath);
    this.editorDirty = false;
    this.editorLen = displayText.length;
    this.editorBridge.setNoteContext(targetVaultId, relPath.indexOf('/') >= 0
      ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    const contentRevision: number = await this.editorBridge.setContent(displayText);
    // 会话镜像编辑器现实：无条件创建（即使本次加载随后被取代）。撕裂窗口内的保存
    // 由 revision 校验拒绝 —— 不一致只会导致少存一次，绝不会存错文件（见 EditorNoteSession）。
    this.leftSession = new EditorNoteSession(targetVaultId, relPath, text, contentRevision);
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    this.editorDirty = draftRecovered;
    if (relPath.length > 0 && relPath === this.rightFilePath) {
      // 同一篇笔记双栏打开：左栏加载后右栏的磁盘基线同步更新（仅当右会话仍属于该笔记）。
      if (this.rightSession !== null && this.rightSession.isFor(targetVaultId, relPath)) {
        this.rightSession.baseline = text;
      }
      this.rightEditorDirty = draftRecovered;
    }
    // M3 联动：文件加载后预览同步本页内容 + 告知笔记目录（相对图片引用的解析基准）
    this.previewBridge.resetDocument();
    this.previewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushPreview(displayText, true);
    if (!this.workspaceSessionRestoring) {
      this.editorBridge.restoreScrollTop(this.leftEditorScrollTop);
      this.previewBridge.restoreScrollTop(this.leftPreviewScrollTop);
    }
    if (initializeRight && relPath.length > 0 && this.rightFilePath.length === 0 &&
      !this.rightPaneIntentionallyEmpty) {
      if (effectiveRightRequestId === this.rightOpenRequestId) {
        this.rightFilePath = relPath;
        await this.readRightAndPush(relPath, effectiveRightRequestId, targetVaultId);
      }
    } else if (initializeRight && this.rightFilePath === relPath && relPath.length > 0) {
      if (effectiveRightRequestId === this.rightOpenRequestId) {
        await this.readRightAndPush(relPath, effectiveRightRequestId, targetVaultId);
      }
    }
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    if (this.activePane === 'left') {
      this.updateChapterEntries(displayText, relPath);
    }
    await this.refreshSharedEditability();
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    await this.refreshActiveChaptersFromBridge();
    if (!this.isCurrentLeftOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    this.applyRestoredChapterSelection();
    if (!this.workspaceSessionRestoring && relPath.length > 0 && this.topView === 'note') {
      this.workspaceSessionSavingEnabled = true;
    }
    this.scheduleWorkspaceSessionSave();
    if (draftRecovered) {
      this.scheduleSave();
    }
    void this.refreshBacklinks();
    return true;
  }

  private async readRightAndPush(relPath: string, requestId: number = -1,
    requestVaultId: string = ''): Promise<boolean> {
    const targetVaultId: string = requestVaultId.length > 0 ? requestVaultId : this.currentVaultId;
    const effectiveRequestId: number = requestId < 0 ? this.rightOpenRequestId : requestId;
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    let text: string | null = '';
    if (targetVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.tryReadNote(VaultRegistry.get(), targetVaultId, relPath);
      if (text === null) {
        return false;
      }
    }
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    let displayText: string = text;
    let draftRecovered: boolean = false;
    if (targetVaultId.length > 0 && relPath.length > 0) {
      try {
        const recovery: NoteDraftRecovery = await NoteDraftService.recover(
          VaultRegistry.get(), targetVaultId, relPath, text);
        if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
          return false;
        }
        displayText = recovery.content;
        draftRecovered = recovery.recovered;
        this.reportDraftRecovery(targetVaultId, relPath, recovery);
      } catch (error) {
        if (this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
          this.showFailureFeedback('note', 'restore', 'unknown', 'status_unknown', 'check_status',
            '正式笔记已打开，但恢复草稿未能读取；草稿状态未确认。请先检查笔记，再重试恢复。');
        }
      }
    }
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    if (!this.workspaceSessionRestoring &&
      !(this.rightSession !== null && this.rightSession.isFor(targetVaultId, relPath))) {
      this.rightEditorScrollTop = 0;
      this.rightPreviewScrollTop = 0;
    }
    this.clearStaleSaveNotice(targetVaultId, relPath);
    WorkspaceEditGuard.clear('right', targetVaultId, relPath);
    this.rightEditorDirty = false;
    this.rightEditorLen = displayText.length;
    this.rightEditorBridge.setNoteContext(targetVaultId, relPath.indexOf('/') >= 0
      ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    const contentRevision: number = await this.rightEditorBridge.setContent(displayText);
    // 同 readAndPush：会话无条件镜像编辑器现实，保存链用 revision 校验兜底。
    this.rightSession = new EditorNoteSession(targetVaultId, relPath, text, contentRevision);
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    this.rightEditorDirty = draftRecovered;
    this.rightPreviewBridge.resetDocument();
    this.rightPreviewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushRightPreview(displayText, true);
    if (!this.workspaceSessionRestoring) {
      this.rightEditorBridge.restoreScrollTop(this.rightEditorScrollTop);
      this.rightPreviewBridge.restoreScrollTop(this.rightPreviewScrollTop);
    }
    if (this.activePane === 'right') {
      this.updateChapterEntries(displayText, relPath);
    }
    await this.refreshSharedEditability();
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    await this.refreshActiveChaptersFromBridge();
    if (!this.isCurrentRightOpenTarget(relPath, targetVaultId, effectiveRequestId)) {
      return false;
    }
    if (relPath.length > 0) {
      this.rightPaneIntentionallyEmpty = false;
    }
    this.applyRestoredChapterSelection();
    if (!this.workspaceSessionRestoring && relPath.length > 0 && this.topView === 'note') {
      this.workspaceSessionSavingEnabled = true;
    }
    this.scheduleWorkspaceSessionSave();
    if (draftRecovered) {
      if (relPath === this.currentFilePath) {
        this.scheduleSave();
      } else {
        this.scheduleRightSave();
      }
    }
    return true;
  }

  private async loadRightFile(relPath: string): Promise<void> {
    const previousPath: string = this.rightFilePath;
    const vaultId: string = this.currentVaultId;
    if (relPath === previousPath) {
      return;
    }
    const requestId: number = ++this.rightOpenRequestId;
    const documentTransition: number = this.rightEditorBridge.beginDocumentTransition();
    this.workspaceOpenRequests++;
    try {
      this.resetSaveFeedback();
      if (!await this.flushRightSave(previousPath, vaultId, false)) {
        this.rightEditorBridge.restoreDocumentTransition(documentTransition);
        return;
      }
      if (!this.isCurrentRightOpenTarget('', vaultId, requestId)) {
        return;
      }
      this.resetSaveFeedback();
      this.rightFilePath = relPath;
      if (!await this.readRightAndPush(relPath, requestId, vaultId)) {
        if (this.isCurrentRightOpenTarget(relPath, vaultId, requestId)) {
          this.rightFilePath = previousPath;
          this.rightEditorBridge.restoreDocumentTransition(documentTransition);
          this.showFailureFeedback('note', 'read', 'unknown', 'not_completed', 'reopen_note',
            '右栏目标笔记未打开；原右栏笔记仍保留。请重新选择或重试。');
        }
        return;
      }
      if (!this.isCurrentRightOpenTarget(relPath, vaultId, requestId)) {
        return;
      }
      this.recordPaneOpened(vaultId, relPath, 'right');
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
    // 会话即写入许可：右栏没有「本笔记」的活动会话 → 拒绝（编辑器内容身份未确认）。
    const session: EditorNoteSession | null = this.rightSession;
    if (session === null || !session.isFor(targetVaultId, targetPath)) {
      return false;
    }
    const savedText: string = session.baseline;
    if (this.rightComposing) {
      return false;
    }
    const feedbackRevision: number = this.saveFeedbackRevision;
    let text: string = '';
    let textRevision: number = -1;
    try {
      const snapshot: EditorSnapshot = await this.rightEditorBridge.getContentSnapshot();
      text = snapshot.text;
      textRevision = snapshot.revision;
    } catch (error) {
      this.showFailureFeedback('note', 'bridge', 'unknown', 'not_completed', 'retry',
        '未能读取右栏编辑内容；本次未写入文件，当前编辑仍保留。请稍后重试。');
      return false;
    }
    if (this.rightComposing || (targetPath.length > 0 && targetPath === this.currentFilePath &&
      targetPath === this.rightFilePath && this.leftComposing)) {
      return false;
    }
    // 内容身份校验（防串写核心）：编辑器回包的 revision 必须与创建会话那次 setContent
    // 下发的 revision 一致，且回包期间会话未被换掉，才允许把正文写入 targetPath。
    if (this.rightSession !== session || textRevision !== session.revision) {
      return false;
    }
    if (text !== savedText && !this.rightEditorDirty) {
      if (text.replace(/\r\n/g, '\n') === savedText.replace(/\r\n/g, '\n')) {
        return true;
      }
      hilog.error(DOMAIN, TAG,
        '右栏保存前校验失败：编辑器内容与最近保存版本不一致且无未保存标记，触发编辑恢复弹窗');
      this.showEditorMismatchRecovery(targetVaultId, targetPath);
      return false;
    }
    if (text === savedText) {
      if (targetPath === this.rightFilePath && targetVaultId === this.currentVaultId) {
        WorkspaceEditGuard.clear('right', targetVaultId, targetPath);
        this.rightEditorDirty = false;
      }
      return true;
    }
    try {
      if (!await this.persistEditorDraftSnapshot(targetVaultId, targetPath, savedText, text)) {
        return false;
      }
      if (this.rightSession !== session) {
        return false;
      }
      await NoteService.saveNote(VaultRegistry.get(), targetVaultId, targetPath, text, savedText);
      await this.clearEditorDraftAfterSave(targetVaultId, targetPath, text);
      if (this.rightSession !== session) {
        WorkspaceEditGuard.clear('right', targetVaultId, targetPath);
        return true;
      }
      this.clearStaleSaveNotice(targetVaultId, targetPath);
      if (targetPath === this.rightFilePath && targetVaultId === this.currentVaultId) {
        session.baseline = text;
        WorkspaceEditGuard.clear('right', targetVaultId, targetPath);
        this.rightEditorDirty = false;
      }
      if (targetPath === this.currentFilePath && targetVaultId === this.currentVaultId) {
        if (this.leftSession !== null && this.leftSession.isFor(targetVaultId, targetPath)) {
          this.leftSession.baseline = text;
        }
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
      this.handleEditorSaveError(targetVaultId, targetPath, error);
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
      const rendered = WikiLinkParser.renderForPreviewWithSourceMap(text, this.rightFilePath, files);
      this.rightPreviewBridge.setContent(rendered.markdown, text, rendered.edits);
    } else {
      this.rightPreviewBridge.setContent(text, text);
    }
  }

  private async syncLeftContentToRight(): Promise<void> {
    if (this.currentFilePath.length === 0 || this.rightFilePath !== this.currentFilePath ||
      !this.editorBridge.ready) {
      return;
    }
    const vaultId: string = this.currentVaultId;
    const targetPath: string = this.currentFilePath;
    const leftRequestId: number = this.leftOpenRequestId;
    const rightRequestId: number = this.rightOpenRequestId;
    const isCurrentMirrorTarget = (): boolean => this.currentVaultId === vaultId &&
      this.currentFilePath === targetPath && this.rightFilePath === targetPath &&
      this.leftOpenRequestId === leftRequestId && this.rightOpenRequestId === rightRequestId;
    try {
      // 镜像前置校验：源会话必须仍属于本笔记，读到的正文才可信为本笔记内容。
      const sourceSession: EditorNoteSession | null = this.leftSession;
      if (sourceSession === null || !sourceSession.isFor(vaultId, targetPath)) {
        return;
      }
      const snapshot: EditorSnapshot = await this.editorBridge.getContentSnapshot();
      if (snapshot.revision !== sourceSession.revision || this.leftSession !== sourceSession ||
        !isCurrentMirrorTarget()) {
        return;
      }
      const text: string = snapshot.text;
      this.pushRightPreview(text);
      this.updateChapterEntries(text, targetPath);
      if (this.rightEditorBridge.ready && !this.rightComposing) {
        const mirrorRevision: number = await this.rightEditorBridge.setContent(text);
        if (!isCurrentMirrorTarget()) {
          return;
        }
        // 会话镜像编辑器现实：右栏编辑器已持有新代次内容，右会话对象未换则记入新 revision。
        if (this.rightSession !== null && this.rightSession.isFor(vaultId, targetPath)) {
          this.rightSession.revision = mirrorRevision;
        }
        WorkspaceEditGuard.clear('right', vaultId, targetPath);
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
    const vaultId: string = this.currentVaultId;
    const targetPath: string = this.currentFilePath;
    const leftRequestId: number = this.leftOpenRequestId;
    const rightRequestId: number = this.rightOpenRequestId;
    const isCurrentMirrorTarget = (): boolean => this.currentVaultId === vaultId &&
      this.currentFilePath === targetPath && this.rightFilePath === targetPath &&
      this.leftOpenRequestId === leftRequestId && this.rightOpenRequestId === rightRequestId;
    try {
      // 镜像前置校验（2026-11-08 跨笔记串写主防线）：源会话必须仍属于本笔记，
      // 且编辑器回包 revision 与会话记录一致 —— 否则源栏持有的是别的笔记的正文，拒绝镜像。
      const sourceSession: EditorNoteSession | null = this.rightSession;
      if (sourceSession === null || !sourceSession.isFor(vaultId, targetPath)) {
        return;
      }
      const snapshot: EditorSnapshot = await this.rightEditorBridge.getContentSnapshot();
      if (snapshot.revision !== sourceSession.revision || this.rightSession !== sourceSession ||
        !isCurrentMirrorTarget()) {
        return;
      }
      const text: string = snapshot.text;
      this.pushPreview(text);
      if (!this.rightCodePreviewEditing && !this.rightCodeEditPending) {
        this.pushRightPreview(text);
      }
      if (this.editorBridge.ready && !this.leftComposing) {
        const mirrorRevision: number = await this.editorBridge.setContent(text);
        if (!isCurrentMirrorTarget()) {
          return;
        }
        if (this.leftSession !== null && this.leftSession.isFor(vaultId, targetPath)) {
          this.leftSession.revision = mirrorRevision;
        }
        WorkspaceEditGuard.mark('left', vaultId, targetPath);
        this.editorDirty = true;
      }
      if (!isCurrentMirrorTarget()) {
        return;
      }
      WorkspaceEditGuard.clear('right', vaultId, targetPath);
      this.rightEditorDirty = false;
      this.updateChapterEntries(text, targetPath);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '双栏同步左栏失败');
    }
  }

  private onLeftCompositionChange(composing: boolean): void {
    this.leftComposing = composing;
    void this.refreshSharedEditability();
  }

  private onRightCompositionChange(composing: boolean): void {
    this.rightComposing = composing;
    void this.refreshSharedEditability();
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
      const requestId: number = ++this.leftOpenRequestId;
      const rightRequestId: number = this.rightOpenRequestId;
      const documentTransition: number = this.editorBridge.beginDocumentTransition();
      const rightSharesPrevious: boolean = this.rightFilePath === prev && prev.length > 0;
      const rightIsActiveEditor: boolean = rightSharesPrevious && !this.leftComposing &&
        (this.rightComposing || this.rightEditorDirty || (this.rightEditing && this.activePane === 'right'));
      this.currentFilePath = relPath;
      if (rightIsActiveEditor && !await this.flushRightSave(prev, vaultId)) {
        if (this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
          hilog.warn(DOMAIN, TAG, '共享笔记右栏保存失败，回滚本次左栏打开操作');
          this.currentFilePath = prev;
          this.editorBridge.restoreDocumentTransition(documentTransition);
          this.scheduleSave();
        }
        return;
      }
      if (!this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
        return;
      }
      if (!rightIsActiveEditor && !await this.flushSave(prev, vaultId)) {
        if (this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
          hilog.warn(DOMAIN, TAG, '旧笔记保存失败，回滚本次打开操作，新笔记未加载');
          this.currentFilePath = prev;
          this.editorBridge.restoreDocumentTransition(documentTransition);
          this.scheduleSave();
        }
        return;
      }
      if (!this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
        return;
      }
      if (!rightSharesPrevious && this.rightFilePath.length > 0 &&
        !await this.flushRightSave(this.rightFilePath, vaultId)) {
        if (this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
          hilog.warn(DOMAIN, TAG, '右栏笔记保存失败，回滚本次左栏打开操作');
          this.currentFilePath = prev;
          this.editorBridge.restoreDocumentTransition(documentTransition);
          this.scheduleSave();
        }
        return;
      }
      if (!this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
        return;
      }
      if (!await this.readAndPush(relPath, true, requestId, vaultId, rightRequestId)) {
        if (!this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
          return;
        }
        hilog.warn(DOMAIN, TAG, '目标笔记加载失败，回滚本次打开操作');
        this.currentFilePath = prev;
        this.editorBridge.restoreDocumentTransition(documentTransition);
        this.showFailureFeedback('note', 'read', 'unknown', 'not_completed', 'reopen_note',
          '目标笔记未打开；原笔记仍保留。请从文件树重新选择或重试。');
        return;
      }
      if (!this.isCurrentLeftOpenTarget(relPath, vaultId, requestId)) {
        return;
      }
      this.recordPaneOpened(vaultId, relPath, 'left');
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
    const sourceIsRight: boolean = source === this.rightEditorBridge;
    // 会话即写入许可：源栏没有「本笔记」的活动会话 → 拒绝（编辑器内容身份未确认）。
    const session: EditorNoteSession | null = sourceIsRight ? this.rightSession : this.leftSession;
    if (session === null || !session.isFor(vaultId, path)) {
      return false;
    }
    const expectedText: string = session.baseline;
    const sharedNoteCompositionActive: boolean = path === this.currentFilePath &&
      path === this.rightFilePath && (this.leftComposing || this.rightComposing);
    const sourceCompositionActive: boolean = source === this.rightEditorBridge
      ? this.rightComposing : this.leftComposing;
    if (sharedNoteCompositionActive || sourceCompositionActive) {
      // IME 的 compositionend 与最终 input/change 可能不是同一时刻；不要把候选串写盘。
      // 提交后的 change 事件会重新安排自动保存。
      return false;
    }
    let text: string = '';
    let textRevision: number = -1;
    try {
      const snapshot: EditorSnapshot = await source.getContentSnapshot();
      text = snapshot.text;
      textRevision = snapshot.revision;
    } catch (error) {
      // 拉不到内容：放弃这次保存（拿空串落盘会清空文件），但绝不让异常外泄挡住调用方
      const fetchError = error as Error;
      hilog.warn(DOMAIN, TAG, 'flushSave 拉取编辑器内容失败，跳过保存：%{public}s',
        fetchError.message ?? 'unknown');
      this.showFailureFeedback('note', 'bridge', 'unknown', 'not_completed', 'retry',
        '未能读取编辑器内容；本次未写入文件，当前编辑仍保留。请稍后重试。');
      return false;
    }
    const sharedNoteCompositionStarted: boolean = path === this.currentFilePath &&
      path === this.rightFilePath && (this.leftComposing || this.rightComposing);
    const sourceCompositionStarted: boolean = source === this.rightEditorBridge
      ? this.rightComposing : this.leftComposing;
    if (sharedNoteCompositionStarted || sourceCompositionStarted) {
      return false;
    }
    // 内容身份校验（防串写核心，见 EditorNoteSession）：编辑器回包的 revision 必须与
    // 创建会话那次 setContent 下发的 revision 一致，且回包期间会话未被换掉。
    if ((sourceIsRight ? this.rightSession : this.leftSession) !== session ||
      textRevision !== session.revision) {
      return false;
    }
    const sourceDirty: boolean = sourceIsRight ? this.rightEditorDirty : this.editorDirty;
    const sharedNoteDirty: boolean = path === this.currentFilePath && path === this.rightFilePath &&
      (this.editorDirty || this.rightEditorDirty);
    if (text !== expectedText && !sourceDirty && !sharedNoteDirty) {
      if (text.replace(/\r\n/g, '\n') === expectedText.replace(/\r\n/g, '\n')) {
        return true;
      }
      hilog.error(DOMAIN, TAG,
        '保存前校验失败（pane=%{public}s）：编辑器内容与最近保存版本不一致且无未保存标记，触发编辑恢复弹窗',
        sourceIsRight ? 'right' : 'left');
      this.showEditorMismatchRecovery(vaultId, path);
      return false;
    }
    if (text === expectedText) {
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
      if (!await this.persistEditorDraftSnapshot(vaultId, path, expectedText, text)) {
        return false;
      }
      if ((sourceIsRight ? this.rightSession : this.leftSession) !== session) {
        return false;
      }
      await NoteService.saveNote(VaultRegistry.get(), vaultId, path, text, expectedText);
      await this.clearEditorDraftAfterSave(vaultId, path, text);
      if ((sourceIsRight ? this.rightSession : this.leftSession) !== session) {
        WorkspaceEditGuard.clear('left', vaultId, path);
        return true;
      }
      this.clearStaleSaveNotice(vaultId, path);
      // 保存成功：源会话基线推进到新落盘内容（会话对象未变，直接改 baseline）。
      session.baseline = text;
      WorkspaceEditGuard.clear('left', vaultId, path);
      if (path === this.currentFilePath && vaultId === this.currentVaultId) {
        this.editorDirty = false;
        if (path === this.rightFilePath) {
          const sharedRightSession: EditorNoteSession | null = this.rightSession;
          if (sharedRightSession !== null && sharedRightSession.isFor(vaultId, path)) {
            sharedRightSession.baseline = text;
          }
          WorkspaceEditGuard.clear('right', vaultId, path);
          this.rightEditorDirty = false;
          const mirror: EditorBridge = source === this.rightEditorBridge
            ? this.editorBridge : this.rightEditorBridge;
          if (mirror.ready && !this.leftComposing && !this.rightComposing) {
            const mirrorRevision: number = await mirror.setContent(text);
            // 镜像编辑器已持有新代次内容；其会话对象未换且仍属于本笔记则记入新 revision。
            const mirrorSession: EditorNoteSession | null = mirror === this.editorBridge
              ? this.leftSession : this.rightSession;
            if (mirrorSession !== null && mirrorSession.isFor(vaultId, path)) {
              mirrorSession.revision = mirrorRevision;
            }
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
      this.handleEditorSaveError(vaultId, path, error);
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
      const rendered = WikiLinkParser.renderForPreviewWithSourceMap(text, this.currentFilePath, files);
      this.previewBridge.setContent(rendered.markdown, text, rendered.edits);
    } else {
      this.previewBridge.setContent(text, text);
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
        this.setDrawerOpen(false);
        this.smMode = 'edit';
      }
      if (pane === 'right') {
        await this.loadRightFile(createdPath);
      } else {
        await this.loadFile(createdPath);
      }
    } catch (error) {
      this.toastRegistryError('创建链接目标失败', error, 'file', 'create');
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
   * 从编辑器拉当前内容 → 推给预览。编辑器未就绪时退回左栏会话基线
   * （已加载内容的镜像），保证预览永远有东西可渲染而不是空白。
   */
  private async updatePreviewFromEditor(force: boolean = false): Promise<void> {
    if (!this.editorBridge.ready) {
      this.pushPreview(this.leftSession !== null ? this.leftSession.baseline : '', force);
      return;
    }
    let text: string = '';
    try {
      text = await this.editorBridge.getContent();
    } catch (_error) {
      hilog.warn(DOMAIN, TAG, '预览拉取编辑器内容失败');
      return;
    }
    this.pushPreview(text, force);
  }

  /**
   * 读库内图片 → data URI，供 PreviewWebView 和简单模式编辑器的 readAsset 桥使用。
   * 返回空串 = 图片不存在 / 不支持，Web 侧显示图片占位。
   */
  private readVaultAsset(relPath: string): string {
    return this.readVaultAssetFor(this.currentVaultId, relPath);
  }

  private readVaultAssetFor(vaultId: string, relPath: string): string {
    if (vaultId.length === 0 || vaultId !== this.currentVaultId || relPath.length === 0) {
      return '';
    }
    try {
      return NoteService.readAssetDataUri(VaultRegistry.get(), vaultId, relPath);
    } catch (error) {
      return '';
    }
  }

  /** Select one Gallery image, copy it into the current vault, and insert its relative Markdown path. */
  private async pickImageForCurrentNote(pane: string = 'left',
    replaceSelectedImage: boolean = false, context: PanelImageReplaceContext | null = null): Promise<void> {
    const isRight: boolean = pane === 'right';
    const notePath: string = isRight ? this.rightFilePath : this.currentFilePath;
    const editorBridge: EditorBridge = isRight ? this.rightEditorBridge : this.editorBridge;
    const previewBridge: PreviewBridge = isRight ? this.rightPreviewBridge : this.previewBridge;
    const imageAnchor: PreviewBlockAnchor | null = replaceSelectedImage && context !== null ? context.anchor : null;
    const imageRaw: string = replaceSelectedImage && context !== null ? context.raw : '';
    const imageParts: MarkdownImageParts | null = replaceSelectedImage && context !== null ? context.parts : null;
    const requestId: number = isRight ? this.rightOpenRequestId : this.leftOpenRequestId;
    const documentRevision: number = editorBridge.currentDocumentRevision;
    if (this.imagePickerBusy || this.rightImagePickerBusy) {
      return;
    }
    if (replaceSelectedImage && (imageAnchor === null || imageParts === null || imageRaw.length === 0 ||
      pane !== this.blockPanelPane || imageAnchor.tapType !== 'image' ||
      !this.isCurrentBlockSourceTarget(pane, this.blockPanelSourceVaultId, notePath,
        requestId, documentRevision))) {
      promptAction.showToast({ message: '图片已变化，请重新打开面板' });
      return;
    }
    if (this.currentVaultId.length === 0 || notePath.length === 0) {
      promptAction.showToast({ message: '请先打开一篇笔记' });
      return;
    }
    if (this.experienceMode === 'simple' ? !previewBridge.ready : !editorBridge.ready) {
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
      if (replaceSelectedImage && (imageAnchor === null ||
        !this.isCurrentBlockSourceTarget(pane, vaultId, notePath, requestId, documentRevision) ||
        !isSameBlockPanelTarget(this.blockPanelAnchor, imageAnchor))) {
        promptAction.showToast({ message: '图片已变化，未替换' });
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
      if (replaceSelectedImage && (imageAnchor === null ||
        !this.isCurrentBlockSourceTarget(pane, vaultId, notePath, requestId, documentRevision) ||
        !isSameBlockPanelTarget(this.blockPanelAnchor, imageAnchor))) {
        NoteImageService.removeImportedImage(registry, vaultId, imported.assetPath);
        promptAction.showToast({ message: '图片已变化，未替换' });
        return;
      }
      if (replaceSelectedImage) {
        const importedParts: MarkdownImageParts | null =
          MarkdownInlineParser.parseImage(imported.markdownReference);
        if (imageParts === null || importedParts === null) {
          NoteImageService.removeImportedImage(registry, vaultId, imported.assetPath);
          promptAction.showToast({ message: '新图片引用无效，未替换原图片' });
          return;
        }
        let replacement: string = MarkdownInlineParser.replaceImageAlt(
          imported.markdownReference, importedParts, imageParts.alt);
        let replacementParts: MarkdownImageParts | null = MarkdownInlineParser.parseImage(replacement);
        if (replacementParts !== null && imageParts.width.length > 0) {
          const withWidth: string | null = MarkdownInlineParser.replaceImageWidth(
            replacement, replacementParts, imageParts.width);
          if (withWidth === null) {
            NoteImageService.removeImportedImage(registry, vaultId, imported.assetPath);
            promptAction.showToast({ message: '原图片宽度写法不支持，未替换图片' });
            return;
          }
          replacement = withWidth;
        }
        const applied: boolean = context !== null
          ? await context.replaceInlineSource(imageRaw, replacement, '替换图片失败，请重试') : false;
        if (!applied) {
          NoteImageService.removeImportedImage(registry, vaultId, imported.assetPath);
          return;
        }
        if (context !== null) {
          context.onImageReplaced(replacement);
        }
        return;
      }
      if (this.experienceMode === 'simple') {
        previewBridge.insertText(imported.markdownReference);
      } else {
        editorBridge.insertText(imported.markdownReference);
      }
    } catch (error) {
      this.showFailureFeedback('note', 'create', 'unknown', 'status_unknown', 'check_status',
        '图片导入或引用插入未完成；请重新打开笔记并检查附件后，再决定是否重试。');
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
    // 专注下点汉堡只推入/收回文件列表，保持专注单栏（v1.8 语义修正：
    // 退出专注恢复进入前布局只走右上角专注入口，汉堡不再顺带退出专注）。
    if (this.focused) {
      this.focusNavigationOpen = !this.focusNavigationOpen;
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

  /** 单屏文件导航切库后留在文件列表；宽屏沿用原导航收起处理。 */
  private switchVaultFromNavigation(id: string): void {
    if (!this.isSingleScreenLayout()) {
      this.closeNoteNavigation();
    }
    this.doSwitchVault(id);
  }

  private async switchVault(id: string): Promise<void> {
    const previousVaultId: string = this.currentVaultId;
    const previousFilePath: string = this.currentFilePath;
    const previousRightFilePath: string = this.rightFilePath;
    const previousRightEmpty: boolean = this.rightPaneIntentionallyEmpty;
    const previousSmMode: string = this.smMode;
    const previousRightEditing: boolean = this.rightEditing;
    const previousActivePane: string = this.activePane;
    const previousReferenceVisible: boolean = this.referenceVisible;
    const previousFocused: boolean = this.focused;
    const previousSidebarTab: string = this.sidebarTab;
    const previousSidebarCollapsed: boolean = this.sidebarCollapsed;
    const previousDrawerOpen: boolean = this.drawerOpen;
    const previousLeftEditorScrollTop: number = this.leftEditorScrollTop;
    const previousLeftPreviewScrollTop: number = this.leftPreviewScrollTop;
    const previousRightEditorScrollTop: number = this.rightEditorScrollTop;
    const previousRightPreviewScrollTop: number = this.rightPreviewScrollTop;
    const sessionSavingWasEnabled: boolean = this.workspaceSessionSavingEnabled;
    if (this.vaultSwitchInProgress || id === previousVaultId) {
      return;
    }
    this.vaultSwitchInProgress = true;
    try {
      await this.refreshSharedEditability();
      const editorMounted: boolean = this.topView === 'note';
      if (editorMounted && !await this.flushWorkspaceSaves()) {
        return;
      }
      this.ensureWorkspaceSessionStore();
      // v1.47 47.4：切库前先取目标库自己的工作区会话，切过去后按它恢复。
      const targetSession: WorkspaceSession | null =
        (this.workspaceSessionStore as WorkspaceSessionStore).loadFor(id);
      this.leftOpenRequestId++;
      this.rightOpenRequestId++;
      this.stopWorkspaceSessionSaving();
      VaultRegistry.get().setCurrent(id);
      this.refreshFromRegistry();
      this.currentFilePath = '';
      this.rightFilePath = '';
      this.rightPaneIntentionallyEmpty = false;
      this.quickSwitchOpen = false;
      this.quickSwitchFiles = [];
      this.recentOpenPaths = [];
      this.smMode = 'edit';
      if (targetSession === null) {
        if (!await this.readAndPush('') || !await this.readRightAndPush('')) {
          throw new Error('工作区清理未完成');
        }
      } else {
        // 目标库有上次的工作区：恢复左右栏笔记、单屏编辑/预览、激活栏等状态。
        this.workspaceSessionRestoring = true;
        try {
          await this.applyWorkspaceSession(targetSession);
        } finally {
          this.workspaceSessionRestoring = false;
        }
      }
      this.workspaceSessionSavingEnabled = true;
      this.flushWorkspaceSessionSave(true);
      // v1.58 58.2：连写条按当前库显示，切库后空闲重算（旧库的过期结果按 vaultId 丢弃）。
      this.scheduleIdleStatsRefresh();
    } catch (error) {
      const registry: VaultRegistry = VaultRegistry.get();
      let registryCurrentId: string = registry.currentId();
      if (registryCurrentId === id && previousVaultId.length > 0) {
        try {
          registry.setCurrent(previousVaultId);
          this.refreshFromRegistry();
          if (this.currentVaultId !== previousVaultId) {
            throw new Error('原知识库恢复失败');
          }
          this.currentFilePath = previousFilePath;
          this.rightFilePath = previousRightFilePath;
          this.rightPaneIntentionallyEmpty = previousRightEmpty;
          this.smMode = previousSmMode;
          this.rightEditing = previousRightEditing;
          this.activePane = previousActivePane;
          this.referenceVisible = previousReferenceVisible;
          this.focused = previousFocused;
          this.sidebarTab = previousSidebarTab;
          this.setSidebarCollapsed(previousSidebarCollapsed);
          this.setDrawerOpen(previousDrawerOpen);
          this.leftEditorScrollTop = previousLeftEditorScrollTop;
          this.leftPreviewScrollTop = previousLeftPreviewScrollTop;
          this.rightEditorScrollTop = previousRightEditorScrollTop;
          this.rightPreviewScrollTop = previousRightPreviewScrollTop;
          const leftRequestId: number = ++this.leftOpenRequestId;
          const rightRequestId: number = ++this.rightOpenRequestId;
          this.workspaceSessionRestoring = true;
          let leftRestored: boolean = false;
          let rightRestored: boolean = false;
          try {
            leftRestored = await this.readAndPush(previousFilePath, false,
              leftRequestId, previousVaultId, rightRequestId);
            rightRestored = await this.readRightAndPush(previousRightFilePath,
              rightRequestId, previousVaultId);
          } finally {
            this.workspaceSessionRestoring = false;
          }
          this.restoreWorkspaceScrollPositions();
          if (!leftRestored || !rightRestored) {
            throw new Error('原工作区恢复失败');
          }
          this.workspaceSessionSavingEnabled = sessionSavingWasEnabled;
          if (sessionSavingWasEnabled) {
            this.scheduleWorkspaceSessionSave();
          }
          this.showFailureFeedback('vault', 'switch', 'unknown', 'not_completed', 'retry',
            '切换知识库未完成；已恢复原知识库和已保存笔记。请检查目标知识库后再重试。');
          return;
        } catch (restoreError) {
          this.refreshFromRegistry();
          this.currentFilePath = '';
          this.rightFilePath = '';
          this.rightPaneIntentionallyEmpty = false;
          this.leftSession = null;
          this.rightSession = null;
          this.editorDirty = false;
          this.rightEditorDirty = false;
          this.workspaceSessionSavingEnabled = false;
          this.showFailureFeedback('vault', 'switch', 'unknown', 'status_unknown', 'check_status',
            '切换知识库未完成；已保存笔记未覆盖，但工作区恢复未完成。请检查当前知识库，并从文件树重新打开笔记。');
          return;
        }
      }
      if (sessionSavingWasEnabled && registryCurrentId === previousVaultId &&
        this.currentVaultId === previousVaultId) {
        this.workspaceSessionSavingEnabled = true;
        this.scheduleWorkspaceSessionSave();
      }
      this.toastRegistryError('切换库失败', error, 'vault', 'switch');
    } finally {
      this.vaultSwitchInProgress = false;
      void this.refreshSharedEditability();
    }
  }

  private doCreateVault(name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const entry: VaultEntry = reg.createLocal(name);
      // 原型行为：新建后自动切到新库（doCreate → switchVault）
      void this.switchVault(entry.id);
    } catch (error) {
      this.toastRegistryError('新建库失败', error, 'vault', 'create');
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
        } catch (_error) {
          hilog.warn(DOMAIN, TAG, '令牌迁移失败');
          promptAction.showToast({ message: '改名成功，但令牌迁移失败，下次同步需重新填写' });
        }
      }
      this.refreshFromRegistry();
      if (this.currentVaultId === renamed.id && id !== renamed.id) {
        this.scheduleWorkspaceSessionSave();
      }
      // v1.47 47.4：库改名换 id 时迁移每库工作区会话（含 latest 指向修正）。
      if (id !== renamed.id) {
        try {
          this.ensureWorkspaceSessionStore();
          (this.workspaceSessionStore as WorkspaceSessionStore).retargetVault(id, renamed.id);
        } catch (sessionError) {
          hilog.warn(DOMAIN, TAG, '工作区会话随库改名迁移失败');
        }
      }
    } catch (error) {
      this.toastRegistryError('改名失败', error, 'vault', 'rename');
    }
  }

  private async doDeleteVault(id: string): Promise<void> {
    const deletingCurrent: boolean = id === this.currentVaultId;
    const wasSessionSavingEnabled: boolean = this.workspaceSessionSavingEnabled;
    if (deletingCurrent) {
      this.stopWorkspaceSessionSaving();
      // 删库过程中先摘掉笔记防抖写盘定时器：库目录一旦被 removeVaultTree 删掉，
      // 定时器再触发就会拿旧路径写盘，accessFor(旧库) 会抛「库不存在」把界面卡死。
      // 删除失败时由下方 reschedulePendingNoteSaves() 排回去，不丢未保存改动。
      this.cancelPendingNoteSaves();
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const target: VaultEntry | undefined = this.vaults.find((v: VaultEntry): boolean => v.id === id);
      const vaultKey: string = reg.vaultKeyOf(id);
      const removed: boolean = await AgentRuntime.deleteVaultWithCleanup(id,
        async (): Promise<void> => {
          await AgentMemoryStore.removeVaultData(id);
          // 外部目录授权释放是异步的，必须待在会被 await 的 cleanup 里。
          // 放进 removeVault 会让该回调变成 async 却没人 await，
          // removed=true 先返回、注册表还没移除，UI 拿旧 currentVaultId 清工作区就错序。
          if (target !== undefined && target.rootKind === 'external' && target.rootUri !== undefined) {
            const authorization: ExternalVaultAuthorizationService =
              createExternalVaultAuthorization(reg.abilityContext());
            await authorization.release(target.rootUri);
          }
        },
        (): void => {
          AgentRuntime.forgetVault(id, reg);
          reg.remove(id);
          // 注册表已移除该库。必须**同步**、且赶在 refreshFromRegistry() 触发重渲染之前
          // 清掉已打开的笔记状态：否则下一帧渲染拿旧库 id 的 currentFilePath 去
          // accessFor() 会抛「库不存在」把界面卡死。等 await 返回再清就来不及了。
          if (deletingCurrent) {
            this.resetOpenNotesAfterVaultRemoval();
          }
          // v1.47 47.4：删库时清理其每库工作区会话，避免 Preferences 键泄漏。
          try {
            this.ensureWorkspaceSessionStore();
            (this.workspaceSessionStore as WorkspaceSessionStore).removeFor(id);
          } catch (sessionError) {
            hilog.warn(DOMAIN, TAG, '删除库的工作区会话清理失败');
          }
          // v1.40：此时注册表已无该库，必须直接给稳定 vaultKey（40.9）。
          FullTextSearchService.discardVaultKey(vaultKey);
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
        if (deletingCurrent) {
          this.reschedulePendingNoteSaves();
        }
        promptAction.showToast({ message: '该库的 Agent 正在运行或删除；稍后再试。' });
      } else if (deletingCurrent) {
        // 当前库已删：注册表把 currentVaultId 回落到别的库（或空串），但左右栏打开的
        // 笔记、编辑器会话与 Web 内容仍属于被删库。不清理，后续渲染 / 预览重算 /
        // 自动保存都会拿旧路径去 accessFor()，抛「库不存在」把界面卡死。
        // 清理失败只记日志，不改变删除成功的结果。
        try {
          await this.restoreWorkspaceAfterVaultRemoval();
        } catch (workspaceError) {
          hilog.warn(DOMAIN, TAG, '删库后重建工作区失败');
        }
      }
    } catch (error) {
      try {
        await AgentMemoryStore.flushVault(id);
      } catch (persistError) {
        // Keep the deletion error visible; a later user edit can retry the conversation save.
      }
      if (deletingCurrent) {
        // 删除失败（库仍在）或 reg.remove 已落地但后续清理抛错（库已不在、currentVaultId
        // 已回落）时都要恢复会话保存，否则本页之后再也不会自动保存工作区会话。
        if (wasSessionSavingEnabled || this.currentVaultId !== id) {
          this.workspaceSessionSavingEnabled = true;
        }
        this.reschedulePendingNoteSaves();
      }
      this.toastRegistryError('删除失败', error, 'vault', 'delete');
    }
  }

  /** 摘掉左右栏的防抖写盘定时器；删库期间避免把内容写进已删除的库。 */
  private cancelPendingNoteSaves(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.rightSaveTimer !== -1) {
      clearTimeout(this.rightSaveTimer);
      this.rightSaveTimer = -1;
    }
  }

  /** 删除未执行/失败，库仍在：把被摘掉的防抖写盘排回去，不让未保存改动丢掉。 */
  private reschedulePendingNoteSaves(): void {
    this.scheduleSave();
    this.scheduleRightSave();
  }

  /**
   * 删除当前库后**同步**清空已打开笔记的全部 UI 状态。
   *
   * 必须在 reg.remove(id) 之后、refreshFromRegistry() 之前调用：注册表一移除，
   * currentFilePath / rightFilePath、leftSession / rightSession 与常驻 Web 组件里
   * 的正文仍属于被删库，下一帧渲染或预览重算会拿旧库 id 调
   * VaultRegistry.accessFor()，而它对已删除的库直接抛「库不存在: id」→ 界面卡死。
   *
   * 与 switchVault / adoptExternalVaultSwitch 的切库清理同构（作废在途请求、清两栏、
   * 清面板），差别是删库**不 flush 旧库编辑** —— 库目录已删，写回无意义且会抛错。
   */
  private resetOpenNotesAfterVaultRemoval(): void {
    // 作废在途的异步打开/关闭，避免删库期间的旧结果回灌到已清理的工作区。
    this.leftOpenRequestId++;
    this.rightOpenRequestId++;
    this.cancelPendingNoteSaves();
    this.stopWorkspaceSessionSaving();

    this.currentFilePath = '';
    this.rightFilePath = '';
    this.rightPaneIntentionallyEmpty = false;
    this.quickSwitchOpen = false;
    this.quickSwitchFiles = [];
    this.recentOpenPaths = [];
    this.leftLastClosedPath = '';
    this.rightLastClosedPath = '';
    this.smMode = 'edit';
    this.leftSession = null;
    this.rightSession = null;
    this.editorDirty = false;
    this.rightEditorDirty = false;
    this.chapterEntries = [];
    this.selectedChapterIndex = -1;
    this.chapterPath = '';
    this.closeFormatMenu(false);
    this.closeBlockPropertyPanel(false);
    this.tableGridOpen = false;
    this.backlinksExpanded = false;
    this.backlinksPane = '';
    this.paneCloseHovered = '';
  }

  /**
   * 删库成功、注册表已刷新后重建工作区：优先按回落库自己的会话恢复，
   * 没有会话（或恢复失败）则把常驻编辑器 / 预览推空。
   * 只改 ArkTS 状态不够，Web 组件仍显示被删库的笔记正文，必须显式推内容。
   */
  private async restoreWorkspaceAfterVaultRemoval(): Promise<void> {
    const nextVaultId: string = this.currentVaultId;
    let targetSession: WorkspaceSession | null = null;
    if (nextVaultId.length > 0) {
      try {
        this.ensureWorkspaceSessionStore();
        targetSession = (this.workspaceSessionStore as WorkspaceSessionStore).loadFor(nextVaultId);
      } catch (sessionError) {
        targetSession = null;
        hilog.warn(DOMAIN, TAG, '删库后读取回落库工作区会话失败');
      }
    }

    let restored: boolean = false;
    if (targetSession !== null) {
      this.workspaceSessionRestoring = true;
      try {
        restored = await this.applyWorkspaceSession(targetSession);
      } catch (sessionError) {
        restored = false;
        hilog.warn(DOMAIN, TAG, '删库后恢复回落库工作区失败');
      } finally {
        this.workspaceSessionRestoring = false;
      }
    }
    if (!restored) {
      // 空路径不读盘，也不会访问已删除的库。
      this.currentFilePath = '';
      this.rightFilePath = '';
      await this.readAndPush('', false);
      await this.readRightAndPush('');
    }
    this.workspaceSessionSavingEnabled = true;
    if (restored) {
      this.flushWorkspaceSessionSave(true);
    }
  }

  /**
   * 新建笔记（顺序不能乱）：
   * 1. `normalizeRelPath` —— 消毒 + 补 `.md`（非法输入在这一步就抛错，不会落到磁盘）；
   * 2. `createNote` —— 逐级补建父目录 + 写空文件，重名自动加后缀；
   * 3. 置 currentFilePath / revealPath / treeSeq —— 让用户立刻看到刚建的那篇。
   * 失败一律 toast，且**不改动任何 UI 状态**（笔记没建成就不该「选中」它）。
   */
  private doCreateNote(rawName: string, targetPane: string = 'left'): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeRelPath(rawName);
      const actual: string = NoteService.createNote(reg, this.currentVaultId, rel);
      // 新笔记是空文件：沿用目标栏的加载与保存保护。
      this.onSelectFile(actual, targetPane, true);
      this.revealPath = actual;
      this.refreshFileTree();
      if (this.breakpoint === Breakpoint.SM) {
        this.setDrawerOpen(false);
        this.smMode = 'edit';
      }
    } catch (error) {
      this.toastRegistryError('新建笔记失败', error, 'file', 'create');
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
        this.setDrawerOpen(false);
      }
    } catch (error) {
      this.toastRegistryError('新建文件夹失败', error, 'file', 'create');
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
      this.toastRegistryError('删除失败', error, 'file', 'delete');
    }
  }

  /** 注册表操作失败：真实错误码与异常原文进日志和诊断记录；用户提示保持固定阶段与状态说明。 */
  private toastRegistryError(prefix: string, error: Object,
    operation: RecentErrorOperation = 'file', phase: RecentErrorPhase = 'delete'): void {
    const err = error as BusinessError;
    const code: number = typeof err?.code === 'number' ? err.code : -1;
    const message: string = err?.message ?? '';
    hilog.warn(DOMAIN, TAG, '%{public}s code=%{public}d message=%{public}s', prefix, code, message);
    let nextStep: RecentErrorNextStep = 'check_status';
    let detail: string = '操作结果未确认；请先检查当前知识库和文件列表，再决定是否重试。';
    switch (prefix) {
      case '保存失败':
        operation = 'note';
        phase = 'save';
        nextStep = 'retry';
        detail = '当前编辑和恢复草稿仍保留；正式笔记保存结果未确认。请先核对笔记，再重试保存。';
        break;
      case '切换库失败':
        operation = 'vault';
        phase = 'switch';
        detail = '请先检查当前知识库和已打开笔记，再决定是否重试。';
        break;
      case '新建库失败':
        operation = 'vault';
        phase = 'create';
        detail = '新建结果未确认；请检查知识库列表后再决定是否重试。';
        break;
      case '改名失败':
        operation = 'vault';
        phase = 'rename';
        detail = '改名结果未确认；请检查知识库列表和当前库后再决定是否重试。';
        break;
      case '新建笔记失败':
        operation = 'file';
        phase = 'create';
        detail = '笔记创建结果未确认；请刷新文件列表并检查目标后再决定是否重试。';
        break;
      case '新建文件夹失败':
        operation = 'file';
        phase = 'create';
        detail = '文件夹创建结果未确认；请刷新文件列表并检查目标后再决定是否重试。';
        break;
      case '创建链接目标失败':
        operation = 'file';
        phase = 'create';
        detail = '链接目标创建结果未确认；请检查文件列表后再决定是否重试。';
        break;
      case '重命名失败':
        operation = 'file';
        phase = 'rename';
        detail = '重命名结果未确认；请刷新文件列表并检查原位置和新位置。';
        break;
      case '移动失败':
        operation = 'file';
        phase = 'move';
        detail = '移动结果未确认；请刷新文件列表并检查原位置和目标位置。';
        break;
      case '删除失败':
        detail = operation === 'vault'
          ? '知识库删除结果未确认；请检查知识库列表和本地数据后再决定是否重试。'
          : '文件操作结果未确认；请刷新文件列表和回收站，确认目标位置后再决定是否重试。';
        break;
    }
    this.showFailureFeedback(operation, phase, 'unknown', 'status_unknown', nextStep, detail, code, message);
  }

  // ===== 1.7 回收站：删除入站 + 5 秒撤销条 =====

  /**
   * 把文件移入回收站（滑到底直接删 / 删除确认框的「确认删除」，文件分支）。
   * 顺序：删的是当前文件 → 先 flush 落盘再移（与 doDeletePath 同一条铁律）；
   * 然后把正式笔记复制校验到沙箱回收站，再经 VaultAccess 移除源笔记 → 刷树/回收站。
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
      const trashRel: string = await TrashService.moveToTrash(reg, this.currentVaultId, relPath);
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
      this.toastRegistryError('删除失败', error, 'file', 'delete');
    }
  }

  /** 撤销条：弹出（snap 为 null = 无按钮的纯提示条，原型 showToast 的无 undoFn 分支） */
  private showUndo(msg: string, snap: UndoSnap | null): void {
    this.undoMsg = msg;
    this.undoSnap = snap;
    this.tableEditUndoState = null;
    this.undoVisible = true;
    if (this.undoTimer !== -1) {
      clearTimeout(this.undoTimer);
    }
    this.undoTimer = setTimeout((): void => {
      this.undoTimer = -1;
      this.undoVisible = false;
      this.tableEditUndoState = null;
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
  private async undoTrashRestore(): Promise<void> {
    const snap: UndoSnap | null = this.undoSnap;
    this.hideUndo();
    if (snap === null) {
      return;
    }
    try {
      await TrashService.restore(VaultRegistry.get(), snap.vaultId, snap.relPath);
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
      const err = error as BusinessError;
      const code: number = typeof err.code === 'number' ? err.code : -1;
      const reason: string = err.message ?? '原因未确定';
      this.showUndo(this.recordFailureFeedback('file', 'restore_trash', 'unknown',
        'status_unknown', 'check_status', reason, code, reason), null);
    }
  }

  private async undoTableEdit(): Promise<void> {
    const state: TableEditUndoState | null = this.tableEditUndoState;
    this.hideUndo();
    this.tableEditUndoState = null;
    if (state === null || !this.isCurrentSimplePreviewTarget(
      state.pane, state.path, state.vaultId, state.requestId)) {
      this.showUndo('笔记已变化，未撤销表格转换', null);
      return;
    }
    const editor: EditorBridge = this.editorBridgeForPane(state.pane);
    const revision: number = editor.currentDocumentRevision;
    if (revision !== state.documentRevision) {
      this.showUndo('笔记已变化，未撤销表格转换', null);
      return;
    }
    let undone: boolean = false;
    try {
      undone = await editor.undoHistoryIfContentMatches(state.expectedContent, revision);
    } catch {
      this.showUndo('撤销未完成，当前内容仍保留', null);
      return;
    }
    if (!this.isCurrentSimplePreviewTarget(state.pane, state.path, state.vaultId, state.requestId) ||
      editor.currentDocumentRevision !== revision) {
      return;
    }
    if (!undone) {
      this.showUndo('内容已变化，未撤销表格转换', null);
      return;
    }
    try {
      const content: string = await editor.getContent();
      if (!this.isCurrentSimplePreviewTarget(state.pane, state.path, state.vaultId, state.requestId) ||
        editor.currentDocumentRevision !== revision) {
        return;
      }
      if (state.pane === 'right') {
        this.pushRightPreview(content, true);
      } else {
        this.pushPreview(content, true);
      }
    } catch {
      if (state.pane === 'right') {
        void this.syncRightContentToLeft();
      } else {
        this.schedulePreviewUpdate();
      }
    }
  }

  /** 回收站视图「恢复」（1.8）：与撤销共用 TrashService.restore；失败 toast 真实原因 */
  private async doRestoreFromTrash(relPath: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      await TrashService.restore(VaultRegistry.get(), this.currentVaultId, relPath);
      this.refreshFileTree();
      this.trashSeq++;
    } catch (error) {
      const err = error as BusinessError;
      const code: number = typeof err.code === 'number' ? err.code : -1;
      const reason: string = err.message ?? '原因未确定';
      this.showFailureFeedback('file', 'restore_trash', 'unknown', 'status_unknown', 'check_status',
        reason, code, reason);
    }
  }

  /** 回收站视图「永久删除」（47.3）：确认弹窗即唯一保护，确认后真删，不进撤销。 */
  private openPurgeTrashDialog(relPath: string): void {
    const display: string = noteDisplayNameOfPath(relPath);
    const slash: number = relPath.lastIndexOf('/');
    const origin: string = slash >= 0 ? relPath.substring(0, slash) : '根目录';
    this.purgeTrashCtl = new CustomDialogController({
      builder: PurgeTrashDialog({
        noteName: display,
        origin: origin,
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (): void => {
          void this.doPurgeFromTrash(relPath);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: true,
      customStyle: true
    });
    this.purgeTrashCtl.open();
  }

  private async doPurgeFromTrash(relPath: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    const display: string = relPath.substring(relPath.lastIndexOf('/') + 1);
    try {
      await TrashService.purge(VaultRegistry.get(), this.currentVaultId, relPath);
      this.trashSeq++;
      promptAction.showToast({ message: '已永久删除：' + display });
    } catch (error) {
      const err = error as BusinessError;
      const code: number = typeof err.code === 'number' ? err.code : -1;
      const reason: string = err.message ?? '原因未确定';
      this.showFailureFeedback('file', 'purge_trash', 'unknown', 'status_unknown', 'check_status',
        reason, code, reason);
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
      this.toastRegistryError('重命名失败', error, 'file', 'rename');
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
      this.toastRegistryError('移动失败', error, 'file', 'move');
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
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (name: string): void => {
          this.doCreateVault(name);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
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
    this.openShareDialog('note', path, this.currentVaultId);
  }

  private openSharePath(relPath: string, isDir: boolean): void {
    if (this.topView !== 'note' || !isDir) {
      return;
    }
    this.openShareDialog('folder', relPath, this.currentVaultId);
  }

  private openShareVaultFromManager(vaultId: string, focusId: string): void {
    const registry: VaultRegistry = VaultRegistry.get();
    let noteCount: number = 0;
    try {
      noteCount = ShareArchiveService.countScope(registry, vaultId, '').noteCount;
    } catch (error) {
      promptAction.showToast({ message: '无法读取该知识库，暂时无法分享' });
      return;
    }
    if (noteCount === 0) {
      this.refreshVaultManagerShareSummaries();
      promptAction.showToast({ message: '这个库还没有笔记' });
      return;
    }
    this.openShareDialog('vault', '', vaultId, noteCount, focusId);
  }

  private sharePathForScope(targetScope: ShareLinkScope, entryScope: ShareLinkScope, entryPath: string,
    notePath: string): string {
    if (targetScope === 'vault') {
      return '';
    }
    if (targetScope === 'note') {
      return notePath;
    }
    return entryScope === 'folder' ? entryPath : NoteShareService.parentOf(notePath);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 长图捕获层放最底层：被下方不透明工作区完全遮住，挂载/卸载不再闪到笔记页；
      // 组件截图只截目标自身内容，遮住它的兄弟节点不会进入快照（见 api_notes.md）。
      if (this.shareCaptureActive) {
        this.ShareImageCaptureLayer()
      }
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
          singleScreen: this.isSingleScreenLayout(),
          windowWidthVp: this.windowWidthVp,
          windowHeightVp: this.windowHeightVp,
          vaultCount: this.vaults.length,
          currentVaultId: this.currentVaultId,
          searchContent: (query: string,
            onProgress: (completed: number, total: number) => void): Promise<SearchOutcome> => {
            return FullTextSearchService.searchDetailed(
              VaultRegistry.get(), this.currentVaultId, query, onProgress);
          },
          searchAllVaults: (query: string, mode: string,
            onVaultStart: (vaultName: string) => void): Promise<CrossVaultSearchOutcome> => {
            return CrossVaultSearchService.run(VaultRegistry.get(), this.vaults,
              this.currentVaultId, query, mode, onVaultStart);
          },
          cancelAllVaultSearch: (): void => {
            CrossVaultSearchService.cancel();
          },
          onSelect: (vaultId: string, relPath: string): void => {
            void this.selectQuickSwitchFile(vaultId, relPath);
          },
          onClose: (): void => {
            this.quickSwitchOpen = false;
          }
        })
          .width('100%')
          .height('100%')
      }
      // v1.41 启动页品牌遮罩：常驻挂载，ready 后组件内部 240ms 淡出并隐藏。
      StartupMask({ ready: this.workspaceInitialRenderReady })
      // v1.65 65.2：屏保 / 台历覆盖层。条件渲染，退出即销毁并清理全部定时器 / 循环。
      if (this.screenSaverOpen) {
        StartupMask({
          ready: false,
          screenSaver: true,
          quoteIntervalMs: this.screenSaverIntervalMs,
          onExit: (): void => { this.closeScreenSaver(); }
        })
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

  private openShareImageSettings(vaultId: string, notePath: string, itemName: string): void {
    const paneWidthVp: number = this.activeSharePaneWidthVp();
    this.shareCapturePaneWidthVp = paneWidthVp;
    this.shareCaptureWidthVp = this.shareLayoutWidthVp(this.shareCaptureWidthId, paneWidthVp);
    this.cleanupShareImagePreview();
    this.openShareImagePreview(itemName, {
      uri: '', aspectRatio: 1, width: 0, height: 0,
      theme: this.shareCaptureTheme, scaled: false, widthId: this.shareCaptureWidthId
    }, notePath, vaultId, '', paneWidthVp);
  }

  /**
   * 分享 / 导出取笔记正文（v1.53 53.6 修复）：编辑器桥就绪时走桥（含编辑器内未保存改动）；
   * 未就绪（隐藏的源码编辑器 Web 未加载或加载失败——预览显示与简单模式编辑不受影响）时
   * 直接读库文件兜底：编辑器未就绪就不存在「编辑器内未保存改动」，简单模式的预览编辑
   * 直接落盘，磁盘文件即权威内容。不再因「编辑器尚未就绪」阻断分享。
   */
  private async noteMarkdownForShare(vaultId: string, path: string): Promise<string> {
    const bridge: EditorBridge = this.editorBridgeForPath(path);
    if (bridge.ready) {
      return await bridge.getContent();
    }
    const text: string | null = NoteService.tryReadNote(VaultRegistry.get(), vaultId, path);
    if (text === null) {
      throw new Error('未能读取笔记内容，暂时无法分享');
    }
    return text;
  }

  private async prepareShare(scope: ShareLinkScope, path: string, format: string, itemName: string,
    vault: VaultEntry, vaultNoteCount: number = -1, focusReturnId: string = ''): Promise<void> {
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
        this.openShareImageSettings(vault.id, path, itemName);
        return;
      }
      if (format === 'pdf' && scope === 'note') {
        await this.prepareNotePdfShare(vault.id, path, itemName);
        return;
      }
      if (format === 'text' && scope === 'note') {
        const markdown: string = await this.noteMarkdownForShare(vault.id, path);
        const preview: NoteTextSharePreview = NoteTextShareService.createPreview(path, markdown);
        this.openShareTextPreview(preview, path);
        return;
      }
      if (scope === 'note') {
        const markdown: string = await this.noteMarkdownForShare(vault.id, path);
        const prepared: PreparedNoteShare = await NoteShareService.prepareNote(registry, vault.id,
          path, markdown);
        this.openShareFilePreview(prepared.filePath, prepared.fileName, prepared.format, prepared.entries,
          itemName, 1, prepared.imageCount, scope, path, registry, '', async (): Promise<void> => {},
          vault.id, vaultNoteCount, focusReturnId);
        return;
      }
      let snapshot: ShareSnapshot | null = null;
      const activePath: string = this.activeFilePath();
      const activeBridge: EditorBridge = this.editorBridgeForPath(activePath);
      if (vault.id === this.currentVaultId && activeBridge.ready && activePath.length > 0 &&
        (scope === 'vault' || activePath.startsWith(path + '/') || activePath === path)) {
        snapshot = { path: activePath, markdown: await activeBridge.getContent() };
      }
      const prepared: PreparedArchiveShare = await ShareArchiveService.prepareZip(registry, vault.id,
        path, snapshot);
      this.openShareFilePreview(prepared.filePath, prepared.fileName, 'ZIP', prepared.entries,
        itemName, prepared.noteCount, prepared.imageCount, scope, path, registry,
        '', async (): Promise<void> => {}, vault.id, vaultNoteCount, focusReturnId);
    } catch (error) {
      if (this.shareCaptureCancelled) {
        return;
      }
      if (scope === 'note' && format === 'text') {
        this.openShareTextPreview(NoteTextShareService.createPreview(path, ''), path,
          shareFailureMessage(error, 'text_prepare'),
          (): Promise<void> => {
            return this.prepareShare(scope, path, format, itemName, vault, vaultNoteCount, focusReturnId);
          });
        return;
      }
      if (format === 'pdf' && scope === 'note') {
        this.openShareFilePreview('', this.pdfFileNameOf(itemName), 'PDF', [],
          itemName, 0, 0, scope, path, registry,
          shareFailureMessage(error, 'file_prepare'),
          (): Promise<void> => {
            return this.prepareShare(scope, path, format, itemName, vault, vaultNoteCount, focusReturnId);
          }, vault.id, vaultNoteCount, focusReturnId,
          uniformTypeDescriptor.UniformDataType.PDF);
        return;
      }
      if (format !== 'link') {
        const detailFormat: string = format === 'file' ? 'Markdown / ZIP' : 'ZIP';
        this.openShareFilePreview('', itemName, detailFormat, [], itemName, 0, 0, scope, path, registry,
          shareFailureMessage(error, 'file_prepare'),
          (): Promise<void> => {
            return this.prepareShare(scope, path, format, itemName, vault, vaultNoteCount, focusReturnId);
          }, vault.id, vaultNoteCount, focusReturnId);
        return;
      }
      const err = error as BusinessError;
      const linkFailureReason: string = err.message ?? '';
      void this.getUIContext().getPromptAction().showDialog({
        title: '分享失败',
        message: linkFailureReason.length > 0 ? linkFailureReason
          : '分享链接准备失败；请重试，或返回后选择其他分享方式。',
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

  private openShareFilePreview(filePath: string, fileName: string, format: string, entries: string[],
    itemName: string, noteCount: number, imageCount: number, scope: ShareLinkScope, path: string,
    registry: VaultRegistry, initialError: string = '',
    onRetryPreparation: () => Promise<void> = async (): Promise<void> => {},
    targetVaultId: string = this.currentVaultId, vaultNoteCount: number = -1,
    focusReturnId: string = '', utd: string = uniformTypeDescriptor.UniformDataType.FILE): void {
    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    this.shareFilePreviewCtl?.close();
    this.shareFilePreviewCtl = new CustomDialogController({
      builder: ShareFilePreviewDialog({
        fileName: fileName,
        format: format,
        itemName: itemName,
        noteCount: noteCount,
        imageCount: imageCount,
        entries: entries,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        singleScreen: shareSheet,
        initialError: initialError,
        canShare: filePath.length > 0,
        onBack: (): void => {
          this.openShareDialog(scope, path, targetVaultId, vaultNoteCount, focusReturnId);
        },
        onRetryPreparation: onRetryPreparation,
        onConfirm: (): Promise<void> => {
          return this.shareFile(filePath, fileName, utd, registry);
        }
      }),
      alignment: shareSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: false,
      customStyle: true
    });
    this.shareFilePreviewCtl.open();
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

  private openShareTextPreview(preview: NoteTextSharePreview, notePath: string, initialError: string = '',
    onRetryPreparation: () => Promise<void> = async (): Promise<void> => {}): void {
    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    this.shareTextPreviewCtl?.close();
    this.shareTextPreviewCtl = new CustomDialogController({
      builder: ShareTextPreviewDialog({
        itemName: preview.title,
        initialContent: preview.content,
        limitations: preview.limitations,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        singleScreen: shareSheet,
        initialError: initialError,
        onRetryPreparation: onRetryPreparation,
        onBack: (): void => { this.openShareDialog('note', notePath); },
        onConfirm: (content: string): Promise<void> => { return this.shareTextContent(preview.title, content); }
      }),
      alignment: shareSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: false,
      customStyle: true
    });
    this.shareTextPreviewCtl.open();
  }

  private async shareTextContent(title: string, content: string): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
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
  }

  /** v1.56 56.2：@Watch 入口（热启动 / 冷启动晚到的分享载荷）。 */
  private onIncomingShareChanged(): void {
    if (this.incomingShareJson.length > 0) {
      setTimeout((): void => {
        this.consumeIncomingShare();
      }, 0);
    }
  }

  /**
   * v1.56 56.4：消费分享载荷。读 → **立刻清键**（防 @Watch 与消费双触发、防同键
   * 重复弹层）→ 校验 → 错误载荷 toast、有效载荷弹保存确认层。
   * JSON.parse 结果先 cast 到具名模型再校验（ShareIngestService.isValidPayload），
   * 脏数据一律按「无法读取分享内容」兜住，不崩、不弹层。
   */
  private consumeIncomingShare(): void {
    const raw: string = AppStorage.get<string>(ShareIngestService.STORAGE_KEY) ?? '';
    AppStorage.setOrCreate(ShareIngestService.STORAGE_KEY, '');
    if (raw.length === 0) {
      return;
    }
    let payload: ShareIngestPayload;
    try {
      payload = JSON.parse(raw) as ShareIngestPayload;
    } catch (error) {
      promptAction.showToast({ message: '无法读取分享内容' });
      return;
    }
    if (!ShareIngestService.isValidPayload(payload)) {
      promptAction.showToast({ message: '无法读取分享内容' });
      return;
    }
    if (payload.message.length > 0) {
      promptAction.showToast({ message: payload.message });
      return;
    }
    this.openSaveShareDialog(payload);
  }

  /** v1.56 56.3：拉起保存确认层（默认草稿按 56.3 标题链 / 正文模板算好再传入）。 */
  private openSaveShareDialog(payload: ShareIngestPayload): void {
    const registry: VaultRegistry = VaultRegistry.get();
    const vaults: VaultEntry[] = registry.list();
    if (vaults.length === 0) {
      promptAction.showToast({ message: '还没有可写入的笔记本，无法保存分享内容' });
      return;
    }
    const draft: ShareIngestDraft = ShareIngestService.buildDraft(payload, Date.now());
    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    this.saveShareCtl?.close();
    this.saveShareCtl = new CustomDialogController({
      builder: SaveShareDialog({
        initialTitle: draft.title,
        initialContent: draft.content,
        vaults: vaults,
        defaultVaultId: this.currentVaultId.length > 0 ? this.currentVaultId : vaults[0].id,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        singleScreen: shareSheet,
        onCancel: (): void => {
        },
        onConfirm: (vaultId: string, rawName: string, content: string): Promise<void> => {
          return this.saveSharedNote(vaultId, rawName, content);
        }
      }),
      alignment: shareSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: false,
      customStyle: true
    });
    this.saveShareCtl.open();
  }

  /**
   * v1.56 56.4：落盘与打开。
   * - 保存位置固定目标库根（首期不做文件夹选择）：normalizeRelPath 后含 `/` 即拒绝；
   * - 唯一命名去重走 NoteService.previewCreatePath + createNoteWithContent
   *   （AtomicFile 原子写、CREATE_CONFLICT 不覆盖现有文件，硬约束 10/15 语义）；
   * - 跨库保存先 switchVault；切换未完成只 toast，不盲目打开（避免把笔记开进错库）；
   * - 成功：打开 + revealPath + 刷新树 + toast「已保存到〈库〉/〈文件名〉」。
   */
  private async saveSharedNote(vaultId: string, rawName: string, content: string): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    const rel: string = NoteService.normalizeRelPath(rawName);
    if (rel.indexOf('/') >= 0) {
      throw new Error('保存位置固定在库根，标题不能包含 /');
    }
    const target: string = NoteService.previewCreatePath(registry, vaultId, rel);
    await NoteService.createNoteWithContent(registry, vaultId, target, content);
    if (vaultId !== this.currentVaultId) {
      await this.switchVault(vaultId);
      if (this.currentVaultId !== vaultId) {
        promptAction.showToast({ message: '已保存到 ' + vaultId + '/' + target + '，但切换知识库未完成' });
        return;
      }
    }
    this.onSelectFile(target, 'left', true);
    this.revealPath = target;
    this.refreshFileTree();
    if (this.breakpoint === Breakpoint.SM) {
      this.setDrawerOpen(false);
      this.smMode = 'edit';
    }
    promptAction.showToast({ message: '已保存到 ' + vaultId + '/' + target });
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

  /**
   * 53.10：读取分段快照的像素缓冲，用于旧帧检测。
   * XT2 实测：滚动后 DOM 状态正确（scrollTop 回读一致），但组件快照可能取到
   * 滚动前的旧合成表面（「一页渲染两页且重复」）。两段快照像素完全相同即旧帧。
   */
  private async readSegmentBuffer(snapshot: image.PixelMap): Promise<ArrayBuffer> {
    const info: image.ImageInfo = await snapshot.getImageInfo();
    const buffer: ArrayBuffer = new ArrayBuffer(info.size.width * info.size.height * 4);
    await snapshot.readPixelsToBuffer(buffer);
    return buffer;
  }

  /** 逐字节比较两个分段缓冲；首处差异立即判定不同（连续分段正常应在头部附近即分叉）。 */
  private segmentBuffersIdentical(a: ArrayBuffer, b: ArrayBuffer): boolean {
    if (a.byteLength !== b.byteLength) {
      return false;
    }
    const av: Uint8Array = new Uint8Array(a);
    const bv: Uint8Array = new Uint8Array(b);
    for (let i: number = 0; i < av.length; i++) {
      if (av[i] !== bv[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 53.10：带旧帧校验的分段快照。与上一分段像素完全相同 → 判定合成器未出新帧，
   * 等待 180ms 重拍（最多 4 次）；重试耗尽报错，绝不输出重复内容。
   * Markdown 连续空白会折叠、分页贪心装填，两段合法快照像素完全相同几乎不可能；
   * 若出现该极端场景将以明确报错替代静默输出重复图。
   */
  private async captureSegmentVerified(prevBuffer: ArrayBuffer | null): Promise<ShareSegmentCapture> {
    const maxAttempts: number = 4;
    let attempt: number = 0;
    while (true) {
      const snapshot: image.PixelMap = await this.getUIContext().getComponentSnapshot()
        .get(this.shareCaptureComponentId, { waitUntilRenderFinished: true });
      const buffer: ArrayBuffer = await this.readSegmentBuffer(snapshot);
      if (prevBuffer === null || !this.segmentBuffersIdentical(buffer, prevBuffer)) {
        return { snapshot: snapshot, buffer: buffer };
      }
      await snapshot.release();
      attempt++;
      // 临时调试 53.10：旧帧重试记录（定位 XT2「两页重复」后移除）
      hilog.info(0x0000, 'ShareDbg', 'stale segment retry attempt=%{public}d', attempt);
      if (attempt >= maxAttempts) {
        throw new Error('分享预览渲染未更新，请重试');
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout((): void => {
          resolve();
        }, 180);
      });
    }
  }

  private async prepareNoteImageShare(vaultId: string, notePath: string,
    itemName: string): Promise<ShareImagePreviewImage> {
    const registry: VaultRegistry = VaultRegistry.get();
    this.shareCaptureCancelled = false;
    this.shareCapturePdfMode = false;
    let sessionId: string = '';
    let longImage: image.PixelMap | null = null;
    const bridge: PreviewBridge = new PreviewBridge();
    this.shareCaptureBridge = bridge;
    try {
      const markdown: string = await this.noteMarkdownForShare(vaultId, notePath);
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      bridge.setNoteDir(NoteShareService.parentOf(notePath));
      bridge.setContent(markdown);
      this.shareCaptureActive = true;
      const ready: Promise<void> = this.waitForShareCaptureReady();
      await ready;
      await bridge.requestShareCaptureMetrics();
      const initial: PreviewCaptureResult = await bridge.appendShareWatermark();
      const captureTops: number[] = NoteImageShareService.pageTops(initial.scrollHeight, initial.viewportHeight);
      const prepared: PreviewCaptureResult = await bridge.prepareShareCapturePages(captureTops.length);
      // 临时调试：53.8 长图分页度量诊断（定位「长图分段尺寸不足」真因后移除）
      hilog.info(0x0000, 'ShareDbg', 'initial sh=%{public}d vh=%{public}d vw=%{public}d st=%{public}d n=%{public}d',
        initial.scrollHeight, initial.viewportHeight, initial.viewportWidth, initial.scrollTop, captureTops.length);
      hilog.info(0x0000, 'ShareDbg', 'initialDbg %{public}s', initial.debug ?? '');
      hilog.info(0x0000, 'ShareDbg', 'prepared sh=%{public}d vh=%{public}d vw=%{public}d st=%{public}d',
        prepared.scrollHeight, prepared.viewportHeight, prepared.viewportWidth, prepared.scrollTop);
      hilog.info(0x0000, 'ShareDbg', 'preparedDbg %{public}s', prepared.debug ?? '');
      if (prepared.viewportHeight <= 0 || prepared.viewportWidth <= 0 ||
        prepared.scrollHeight < captureTops.length * prepared.viewportHeight) {
        throw new Error('长图分段尺寸不足，无法覆盖全文');
      }
      sessionId = NoteImageShareService.createSession(registry);
      let geometry: NoteImageShareGeometry | null = null;
      let captureWidth: number = 0;
      let captureHeight: number = 0;
      let prevSegmentBuffer: ArrayBuffer | null = null;
      for (let i = 0; i < captureTops.length; i++) {
        if (this.shareCaptureCancelled) {
          throw new Error('分享图片生成已取消');
        }
        const positioned: PreviewCaptureResult = await bridge.setShareCaptureScrollTop(captureTops[i]);
        if (Math.abs(positioned.scrollTop - captureTops[i]) > 1) {
          throw new Error('分享预览无法定位到第 ' + (i + 1).toString() + ' 个渲染分段');
        }
        if (Math.abs(positioned.viewportWidth - initial.viewportWidth) > 1 ||
          Math.abs(positioned.viewportHeight - initial.viewportHeight) > 1) {
          throw new Error('分享预览尺寸发生变化，请重新生成长图');
        }
        // 53.10：旧帧校验快照——与上一分段完全相同即重拍，杜绝「两页重复」
        const captured: ShareSegmentCapture = await this.captureSegmentVerified(prevSegmentBuffer);
        const segment = captured.snapshot;
        prevSegmentBuffer = captured.buffer;
        try {
          const imageInfo = await segment.getImageInfo();
          let segmentGeometry: NoteImageShareGeometry;
          if (geometry === null) {
            captureWidth = imageInfo.size.width;
            captureHeight = imageInfo.size.height;
            segmentGeometry = NoteImageShareService.longImageGeometry(imageInfo.size.width, imageInfo.size.height,
              initial.scrollHeight, initial.viewportHeight);
            geometry = segmentGeometry;
            longImage = NoteImageShareService.createLongImage(segmentGeometry);
          } else if (imageInfo.size.width !== captureWidth || imageInfo.size.height !== captureHeight) {
            throw new Error('长图渲染期间视口尺寸发生变化，请重新生成');
          } else {
            segmentGeometry = geometry;
          }
          const segmentEnd: number = Math.min(initial.scrollHeight, captureTops[i] + initial.viewportHeight);
          const destinationTop: number = Math.round(captureTops[i] * segmentGeometry.pixelsPerVp * segmentGeometry.scale);
          const destinationBottom: number = i === captureTops.length - 1 ? segmentGeometry.height :
            Math.round(segmentEnd * segmentGeometry.pixelsPerVp * segmentGeometry.scale);
          const destinationHeight: number = destinationBottom - destinationTop;
          const remainingHeight: number = segmentEnd - captureTops[i];
          const cropHeight: number = Math.max(1, Math.min(imageInfo.size.height,
            Math.round(imageInfo.size.height * remainingHeight / initial.viewportHeight)));
          if (cropHeight < imageInfo.size.height) {
            await segment.crop({ x: 0, y: 0, size: { width: imageInfo.size.width, height: cropHeight } });
          }
          if (longImage === null || destinationHeight <= 0) {
            throw new Error('长图分段输出尺寸无效');
          }
          await NoteImageShareService.appendSegment(segment, longImage, destinationTop,
            segmentGeometry.width, destinationHeight);
        } finally {
          await segment.release();
        }
      }
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      if (geometry === null || longImage === null) {
        throw new Error('没有生成可分享的长图');
      }
      const filePath: string = NoteImageShareService.imagePath(registry, sessionId);
      const completedImage: image.PixelMap = longImage;
      longImage = null;
      await NoteImageShareService.writeJpeg(filePath, completedImage);
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      this.shareCaptureActive = false;
      this.shareImagePreviewSessionId = sessionId;
      this.shareImagePreviewTitle = itemName;
      this.shareImagePreviewImage = {
        uri: fileUri.getUriFromPath(filePath),
        aspectRatio: geometry.width / geometry.height,
        width: geometry.width,
        height: geometry.height,
        theme: this.shareCaptureTheme,
        scaled: geometry.scale < 1,
        widthId: this.shareCaptureWidthId
      };
      return this.shareImagePreviewImage;
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
      const err = error as Error;
      throw new Error(err.message);
    } finally {
      if (longImage !== null) {
        await longImage.release();
      }
      if (this.shareCaptureReadyTimer >= 0) {
        clearTimeout(this.shareCaptureReadyTimer);
        this.shareCaptureReadyTimer = -1;
      }
      this.shareCaptureReadyResolver = null;
      this.shareCaptureReadyRejecter = null;
    }
  }

  /** PDF 捕获页尺寸自适应（2026-11-11 修复，见字段注释）：挂捕获层前按当前窗口重算。 */
  private updatePdfPageSize(): void {
    const widthByHeight: number = this.windowHeightVp > 0 ? this.windowHeightVp *
      NotePdfDocumentService.A4_WIDTH_PT / NotePdfDocumentService.A4_HEIGHT_PT : this.pdfPageWidthVp;
    const widthByWindow: number = this.windowWidthVp > 0 ? this.windowWidthVp : widthByHeight;
    this.pdfPageWidthVp = Math.min(700, widthByWindow, widthByHeight);
    this.pdfPageHeightVp = Math.round(this.pdfPageWidthVp *
      NotePdfDocumentService.A4_HEIGHT_PT / NotePdfDocumentService.A4_WIDTH_PT);
  }

  /**
   * v1.53 导出 PDF（需求 53.3）：复用隐藏捕获层按 A4 比例逐页渲染截图，
   * 逐页 JPEG 经 PDF Kit 合成 note.pdf 后走文件预览分享（utd 精确类型 com.adobe.pdf）。
   * 失败清理会话目录不留半成品；取消语义与长图一致。
   */
  private async prepareNotePdfShare(vaultId: string, notePath: string,
    itemName: string): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    if (!NotePdfDocumentService.isSupported()) {
      throw new Error('此设备不支持 PDF 导出');
    }
    this.shareCaptureCancelled = false;
    let sessionId: string = '';
    const bridge: PreviewBridge = new PreviewBridge();
    this.shareCaptureBridge = bridge;
    try {
      const markdown: string = await this.noteMarkdownForShare(vaultId, notePath);
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      bridge.setNoteDir(NoteShareService.parentOf(notePath));
      bridge.setContent(markdown);
      this.updatePdfPageSize();
      this.shareCapturePdfMode = true;
      this.shareCaptureActive = true;
      await this.waitForShareCaptureReady();
      await bridge.requestShareCaptureMetrics();
      await bridge.appendShareWatermark();
      const prepared: PreviewCaptureResult = await bridge.preparePdfPages(this.pdfPageHeightVp);
      const pageCount: number = prepared.pageCount ?? 0;
      if (pageCount <= 0 || pageCount > NotePdfDocumentService.MAX_PAGES) {
        throw new Error('笔记超过单文件 PDF 页数上限；请改用 Markdown / ZIP');
      }
      const tops: number[] = JSON.parse(prepared.pageTops ?? '[]') as number[];
      if (tops.length !== pageCount) {
        throw new Error('PDF 分页结果无效，请重试');
      }
      if (Math.abs(prepared.viewportHeight - this.pdfPageHeightVp) > 2) {
        throw new Error('PDF 页面尺寸与渲染视口不符，请重试');
      }
      sessionId = NoteImageShareService.createSession(registry);
      const pageJpegs: string[] = [];
      const pageAspects: number[] = [];
      let expectedWidth: number = 0;
      let expectedHeight: number = 0;
      let prevPageBuffer: ArrayBuffer | null = null;
      for (let i: number = 0; i < tops.length; i++) {
        if (this.shareCaptureCancelled) {
          throw new Error('分享图片生成已取消');
        }
        const positioned: PreviewCaptureResult = await bridge.setShareCaptureScrollTop(tops[i]);
        if (Math.abs(positioned.scrollTop - tops[i]) > 1) {
          throw new Error('PDF 预览无法定位到第 ' + (i + 1).toString() + ' 页');
        }
        // 53.10：旧帧校验快照——与上一页完全相同即重拍，杜绝「一页内容渲染成两页」
        const captured: ShareSegmentCapture = await this.captureSegmentVerified(prevPageBuffer);
        const pageShot: image.PixelMap = captured.snapshot;
        prevPageBuffer = captured.buffer;
        try {
          const imageInfo: image.ImageInfo = await pageShot.getImageInfo();
          if (i === 0) {
            expectedWidth = imageInfo.size.width;
            expectedHeight = imageInfo.size.height;
            if (Math.abs(expectedWidth / expectedHeight -
              NotePdfDocumentService.A4_WIDTH_PT / NotePdfDocumentService.A4_HEIGHT_PT) > 0.01) {
              throw new Error('PDF 页面比例异常，请重试');
            }
          } else if (imageInfo.size.width !== expectedWidth || imageInfo.size.height !== expectedHeight) {
            throw new Error('PDF 渲染期间页面尺寸变化，请重试');
          }
          // 53.12：贪心分页切片高（块边界）小于页高，整屏快照会把下一页开头的
          // 内容重复拍进本页页尾（XT2 实测「三种形态」在页缝出现两次）。非末页
          // 裁到切片高；末页含水印与补白保持整页。纸面纯白（PDF 模式强制 light，
          // --paper:#fff），A4 页上图片下方留白即自然分页留白，无缝衔接。
          const sliceVp: number = i === tops.length - 1 ? this.pdfPageHeightVp :
            Math.max(1, Math.min(this.pdfPageHeightVp, tops[i + 1] - tops[i]));
          const cropPx: number = Math.max(1, Math.min(imageInfo.size.height,
            Math.round(imageInfo.size.height * sliceVp / this.pdfPageHeightVp)));
          if (cropPx < imageInfo.size.height) {
            await pageShot.crop({ x: 0, y: 0, size: { width: imageInfo.size.width, height: cropPx } });
          }
          const pagePath: string = registry.sharePath(sessionId + '/page-' + (i + 1).toString() + '.jpg');
          await NoteImageShareService.writeJpegTo(pagePath, pageShot);
          pageJpegs.push(pagePath);
          pageAspects.push(imageInfo.size.width / cropPx);
        } finally {
          await pageShot.release();
        }
      }
      if (this.shareCaptureCancelled) {
        throw new Error('分享图片生成已取消');
      }
      // 53.7：先逐页捕获成 JPEG 进分页预览弹窗；「分享 PDF」确认后才在 onConfirm
      // 里合成 PDF。捕获层此时卸下（页面已落盘），预览读会话目录里的 JPEG。
      this.shareCaptureActive = false;
      this.shareCapturePdfMode = false;
      this.openSharePdfPreview(itemName, notePath, sessionId, pageJpegs, pageAspects, vaultId);
    } catch (error) {
      this.shareCaptureActive = false;
      this.shareCapturePdfMode = false;
      bridge.cancelShareCaptureRequests('PDF 导出已结束');
      if (sessionId.length > 0) {
        try {
          NoteShareService.removeTree(registry, sessionId);
        } catch (cleanupError) {
          // 失败清理不掩盖原错误；会话目录有 24 小时过期机制兜底。
        }
      }
      const err = error as Error;
      throw new Error(err.message);
    } finally {
      if (this.shareCaptureReadyTimer >= 0) {
        clearTimeout(this.shareCaptureReadyTimer);
        this.shareCaptureReadyTimer = -1;
      }
      this.shareCaptureReadyResolver = null;
      this.shareCaptureReadyRejecter = null;
    }
  }

  /** v1.53 PDF 文件名：笔记名去 .md 后缀加 .pdf（无后缀直接加）。 */
  private pdfFileNameOf(itemName: string): string {
    return noteDisplayName(itemName) + '.pdf';
  }

  /**
   * 53.7：PDF 分页预览。会话与弹窗编排在 model/SharePdfPreviewFlow，
   * 此处只补布局参数与「合成完成 → 文件预览」「取消 → 回分享面板」两条回调。
   */
  private openSharePdfPreview(itemName: string, notePath: string, sessionId: string,
    pageJpegs: string[], pageAspects: number[], vaultId: string): void {
    const registry: VaultRegistry = VaultRegistry.get();
    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    const request: SharePdfPreviewRequest = {
      itemName: itemName,
      fileName: this.pdfFileNameOf(itemName),
      sessionId: sessionId,
      pageJpegs: pageJpegs,
      pageAspects: pageAspects,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      singleScreen: shareSheet,
      onComposed: (pdfPath: string): void => {
        this.openShareFilePreview(pdfPath, this.pdfFileNameOf(itemName), 'PDF', [],
          itemName, 1, 0, 'note', notePath, registry, '', async (): Promise<void> => {},
          vaultId, -1, '', uniformTypeDescriptor.UniformDataType.PDF);
      },
      onCancelled: (): void => {
        this.openShareDialog('note', notePath);
      }
    };
    this.sharePdfPreviewFlow.open(request);
  }

  private openShareImagePreview(itemName: string, previewImage: ShareImagePreviewImage, notePath: string,
    vaultId: string, initialError: string = '', paneWidthVp: number = 0): void {
    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    const resolvedPaneWidthVp: number = paneWidthVp > 0 ? paneWidthVp : this.activeSharePaneWidthVp();
    this.shareCapturePaneWidthVp = resolvedPaneWidthVp;
    this.shareImagePreviewCtl?.close();
    this.shareImagePreviewCtl = new CustomDialogController({
      builder: ShareImagePreviewDialog({
        itemName: itemName,
        image: previewImage,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        singleScreen: shareSheet,
        widthVp: this.shareCaptureWidthVp,
        paneWidthVp: resolvedPaneWidthVp,
        initialWidthId: this.shareCaptureWidthId,
        initialTheme: this.shareCaptureTheme,
        initialError: initialError,
        onConfirm: (): Promise<void> => {
          const image: ShareImagePreviewImage = this.shareImagePreviewImage;
          const title: string = this.shareImagePreviewTitle;
          return this.shareImage(image, title, VaultRegistry.get());
        },
        onGenerate: async (widthId: string, theme: string): Promise<ShareImagePreviewImage> => {
          this.shareCaptureWidthId = widthId;
          this.shareCaptureTheme = theme;
          this.shareCaptureWidthVp = this.shareLayoutWidthVp(widthId, resolvedPaneWidthVp);
          this.cleanupShareImagePreview();
          const preview: ShareImagePreviewImage = await this.prepareNoteImageShare(
            vaultId, notePath, itemName);
          this.ensureShareImagePreferenceStore();
          if (!(this.shareImagePreferenceStore as ShareImagePreferenceStore).saveTheme(theme)) {
            promptAction.showToast({ message: '本次外观已应用，但未能保存长图偏好' });
          }
          if (!(this.shareImagePreferenceStore as ShareImagePreferenceStore).saveWidth(widthId)) {
            promptAction.showToast({ message: '本次宽度已应用，但未能保存长图偏好' });
          }
          return preview;
        },
        onCancel: (): void => {
          this.cancelShareImageCapture();
          this.cleanupShareImagePreview();
          this.openShareDialog('note', notePath);
        }
      }),
      alignment: shareSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: false,
      customStyle: true
    });
    this.shareImagePreviewCtl.open();
  }

  private cleanupShareImagePreview(): void {
    const sessionId: string = this.shareImagePreviewSessionId;
    this.shareImagePreviewSessionId = '';
    this.shareImagePreviewImage = {
      uri: '', aspectRatio: 1, width: 0, height: 0, theme: 'light', scaled: false, widthId: 'phone'
    };
    if (sessionId.length === 0) {
      return;
    }
    try {
      NoteShareService.removeTree(VaultRegistry.get(), sessionId);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '分享预览临时文件清理失败');
    }
  }

  private async shareImage(previewImage: ShareImagePreviewImage, title: string, registry: VaultRegistry): Promise<void> {
    if (previewImage.uri.length === 0) {
      throw new Error('长图文件无效，请重新生成');
    }
    const shared = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.JPEG,
      uri: previewImage.uri,
      title: title,
      label: 'IMAGE'
    });
    await new systemShare.ShareController(shared).show(registry.abilityContext(), {});
  }

  /**
   * 打开新建（笔记 / 文件夹）对话框。
   * @param initialDir 预选目录：目录行 + 按钮入口传点击的目录；空串 = 目录树头部「＋」入口，
   *        **固定为 vault 根目录**（2026-10-18 用户拍板：移除底部「新建笔记」按钮，头部「＋」
   *        作为根目录创建入口，与文件夹行尾「＋」（指定目录）两级入口一致，不再记忆上次目录）。
   */
  private openCreateNoteDialog(initialDir: string = '', targetPane: string = 'left'): void {
    // 目录选择器的候选：全量目录（不受展开状态影响）
    let dirs: string[] = [];
    try {
      dirs = FileTree.allDirsOf(VaultRegistry.get().accessFor(this.currentVaultId));
    } catch (_error) {
      hilog.warn(0x0001, 'Index', '列目录失败');
      dirs = [];
    }
    this.createNoteCtl = new CustomDialogController({
      builder: CreateNoteDialog({
        vaultId: this.currentVaultId,
        dirs: dirs,
        initialDir: initialDir,
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (rawName: string, createType: string): void => {
          // 2026-10-18 方案 A：对话框内「笔记 / 文件夹」切换，落到不同的创建方法
          if (createType === 'folder') {
            this.doCreateFolder(rawName);
          } else {
            this.doCreateNote(rawName, targetPane);
          }
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
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
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (): void => {
          if (isDir) {
            void this.doDeletePath(relPath);
          } else {
            void this.doTrashFile(relPath);
          }
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
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
    const initial: string = isDir ? name : noteDisplayName(name);
    this.renamePathCtl = new CustomDialogController({
      builder: RenamePathDialog({
        relPath: relPath,
        isDir: isDir,
        initialName: initial,
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (newName: string): void => {
          this.doRenamePath(relPath, isDir, newName);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
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
      const all: string[] = FileTree.allDirsOf(VaultRegistry.get().accessFor(this.currentVaultId));
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
    } catch (_error) {
      hilog.warn(DOMAIN, TAG, '列目录失败');
      dirs = [];
    }
    this.movePathCtl = new CustomDialogController({
      builder: MovePathDialog({
        relPath: relPath,
        isDir: isDir,
        dirs: dirs,
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (destDir: string): void => {
          this.doMovePath(relPath, isDir, destDir);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: true,
      customStyle: true
    });
    this.movePathCtl.open();
  }

  private openRenameDialog(id: string): void {
    this.renameDialogCtl = new CustomDialogController({
      builder: RenameVaultDialog({
        initialName: id,
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (name: string): void => {
          this.doRenameVault(id, name);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: true,
      customStyle: true
    });
    this.renameDialogCtl.open();
  }

  private openDeleteDialog(id: string): void {
    this.deleteDialogCtl = new CustomDialogController({
      builder: DeleteVaultDialog({
        vaultId: id,
        isExternal: this.vaults.some((vault: VaultEntry): boolean =>
          vault.id === id && vault.rootKind === 'external'),
        singleScreen: this.isSingleScreenLayout(),
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onConfirm: (): void => {
          void this.doDeleteVault(id);
        }
      }),
      alignment: this.isSingleScreenLayout() ? DialogAlignment.Bottom : DialogAlignment.Center,
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

  @Builder
  NoteNavigationToggleButton() {
    Row() {
      Icon('menu', Space.s5, $r('app.color.text_secondary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(Color.Transparent)
    .focusable(true)
    .id('workspace-navigation-button')
    .accessibilityText('展开或收起笔记列表')
    .onClick((): void => {
      this.onHamburger();
    })
  }

  @Builder
  FocusModeButton() {
    Row() {
      // L-7/Z2：全局 @Builder 按值实参不随状态刷新，图标名+色必须走 if 分支，不能写成三元实参
      if (this.focused) {
        Icon('exitFocus', Space.s5, $r('app.color.brand'))
      } else {
        Icon('focus', Space.s5, $r('app.color.text_secondary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(this.focused ? $r('app.color.brand_bg') : Color.Transparent)
    .accessibilityText(this.focused ? '退出专注模式' : '进入专注模式')
    .accessibilityTextHint(this.focused ? '恢复目录和参考栏' : '隐藏目录和参考栏，聚焦当前笔记')
    .onClick((): void => {
      this.toggleFocus();
    })
  }

  @Builder
  ReferencePaneButton() {
    Row() {
      // L-7/Z2：全局 @Builder 按值实参不随状态刷新，选中色必须走 if 分支，不能写成三元实参
      if (this.isReferenceShown()) {
        Icon('columns', Space.s5, $r('app.color.brand'))
      } else {
        Icon('columns', Space.s5, $r('app.color.text_secondary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(this.isReferenceShown() ? $r('app.color.brand_bg') : Color.Transparent)
    .accessibilityText(this.isReferenceShown() ? '关闭双栏' : '打开双栏')
    .accessibilityTextHint('显示或收起右侧参考栏')
    .onClick((): void => {
      this.toggleReference();
    })
  }

  @Builder
  WorkspaceLayoutButton() {
    if (this.canToggleFocus()) {
      this.FocusModeButton()
    } else if (!this.isSingleScreenLayout()) {
      this.ReferencePaneButton()
    }
  }

  @Builder
  GitAheadBadge() {
    if (this.gitAheadCommitCount > 0) {
      Text(this.gitAheadBadgeLabel())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.on_brand'))
        .padding({ left: Space.s1, right: Space.s1, top: Space.s1, bottom: Space.s1 })
        .borderRadius(Radius.full)
        .backgroundColor($r('app.color.brand'))
    }
  }

  @Builder
  GitSyncButton() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Row() {
        Icon('sync', Space.s5, $r('app.color.text_secondary'))
      }
      .width(Size.touch)
      .height(Size.touch)
      .justifyContent(FlexAlign.Center)
      .borderRadius(Radius.icon)
      this.GitAheadBadge()
    }
    .width(Size.touch)
    .height(Size.touch)
    .onClick((): void => {
      void this.openGitSyncPage();
    })
    .id('git-sync-button')
    // v1.10 读屏：纯图标按钮补名称与待推送状态
    .accessibilityText('Git 同步')
    .accessibilityTextHint(this.gitAheadCommitCount > 0
      ? '有 ' + this.gitAheadCommitCount.toString() + ' 个提交待推送' : '打开同步页')
  }

  private isPaneModeSelected(pane: string, label: string): boolean {
    const editing: boolean = pane === 'right' ? this.rightEditing : this.smMode === 'edit';
    return label === '编辑' ? editing : !editing;
  }

  private simpleWorkspacePane(): string {
    return this.activePane === 'right' ? 'right' : 'left';
  }

  private simplePreviewEditable(pane: string): boolean {
    if (this.experienceMode !== 'simple' || this.vaultSwitchInProgress) {
      return false;
    }
    const sameNote: boolean = this.currentFilePath.length > 0 &&
      this.currentFilePath === this.rightFilePath;
    return !sameNote || this.activePane === pane;
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

  /** 每栏只保留编辑 / 预览切换；笔记操作统一由顶栏更多菜单承载。 */
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
    if (this.paneFilePath($$.pane).length > 0) {
      Row() {
        Text(this.paneFilePath($$.pane))
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row() {
          Icon('close', Space.s5, $r('app.color.text_secondary'))
        }
        .width(Size.paneClose)
        .height(Size.paneClose)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Radius.full)
        .backgroundColor(this.paneCloseHovered === $$.pane
          ? ($$.pane === 'right' ? $r('app.color.bg_tertiary') : $r('app.color.bg_secondary'))
          : Color.Transparent)
        .focusable(true)
        .enabled($$.pane === 'right' ? this.rightCloseRequestId === 0 : this.leftCloseRequestId === 0)
        .id('pane-close-' + $$.pane)
        .onHover((isHover: boolean): void => {
          this.paneCloseHovered = isHover ? $$.pane : '';
        })
        .onClick((): void => { void this.closePaneNote($$.pane); })
        .accessibilityText('关闭笔记：' + this.noteTitleForPath(this.paneFilePath($$.pane)))
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s4, right: Space.s1 })
      .alignItems(VerticalAlign.Center)
      // v1.30 30.4：「完成编辑」后焦点移到该栏路径行
      .focusable(true)
      // v1.32 32.8：程序化聚焦的非交互元素仅键盘遍历时显示品牌蓝焦点环（原型 [tabindex="-1"]:focus-visible）
      .focusBox({
        strokeWidth: LengthMetrics.vp(2),
        strokeColor: ColorMetrics.resourceColor($r('app.color.brand'))
      })
      .id('pane-title-' + $$.pane)
      .border({ width: { bottom: 1 }, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
  }

  @Builder
  EmptyPaneAction(pane: string, action: string, label: string, icon: string, primary: boolean,
    focusId: string = '') {
    Row({ space: Space.s2 }) {
      Icon(icon, Space.s4, primary ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body2)
        .fontWeight(primary ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(primary ? $r('app.color.on_brand') : $r('app.color.text_primary'))
    }
    .height(Size.touch)
    .padding({ left: Space.s4, right: Space.s4 })
    .borderRadius(Radius.full)
    .backgroundColor(primary ? $r('app.color.brand') : $r('app.color.bg_secondary'))
    .border({ width: 1, color: primary ? $r('app.color.brand') : $r('app.color.line') })
    .margin({ left: Space.s1, right: Space.s1, bottom: Space.s2 })
    .focusable(true)
    .id(focusId)
    .onAppear((): void => {
      if (focusId.length > 0) {
        this.consumeEmptyPaneFocus(pane, focusId);
      }
    })
    .onClick((): void => {
      this.setActivePane(pane, true);
      if (action === 'new') {
        this.openCreateNoteDialog('', pane);
      } else if (action === 'search') {
        this.openQuickSwitcher(pane);
      } else {
        this.openNoteNavigation();
      }
    })
    .accessibilityText(label)
  }

  @Builder
  EmptyPaneRecentNote(pane: string, path: string) {
    Row({ space: Space.s3 }) {
      Icon('note', Space.s5, $r('app.color.text_tertiary'))
      Column({ space: Space.s1 }) {
        Text(this.noteTitleForPath(path))
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.noteFolderForPath(path) +
          (path === (pane === 'right' ? this.currentFilePath : this.rightFilePath)
            ? ' · 另一栏已打开' : ''))
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(Size.paneEmptyRecentRowH)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .focusable(true)
    .onClick((): void => { this.onSelectFile(path, pane, true); })
    .accessibilityText(this.noteTitleForPath(path) + '，' + this.noteFolderForPath(path) +
      (path === (pane === 'right' ? this.currentFilePath : this.rightFilePath)
        ? '，另一栏已打开' : ''))
  }

  @Builder
  EmptyPane(pane: string) {
    Scroll() {
      Column() {
        Column({ space: Space.s3 }) {
          Text('曜石笔记')
            .fontSize(FontSize.caption)
            .letterSpacing(Size.paneEmptyBrandTracking)
            .offset({ x: Size.paneEmptyBrandTracking / 2 })
            .fontColor($r('app.color.text_tertiary'))
          Text() {
            Span(this.currentVaultNoteCount === 0 ? '空白，是最好的开始' : '把空间，留给思考')
            Span('。').letterSpacing(this.paneEmptyPunctHang(this.paneEmptyTitleSize(pane)))
          }
            .fontSize(this.paneEmptyTitleSize(pane))
            .fontWeight(Size.paneEmptyTitleWeight)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .width('100%')
          if (this.currentVaultNoteCount === 0) {
            Text() {
              Span('这个库还没有笔记。新建第一篇，开始写作')
              Span('。').letterSpacing(this.paneEmptyPunctHang(FontSize.body2))
            }
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          } else {
            Text() {
              Span(this.isSingleScreenLayout()
                ? '从文件列表选一篇笔记，或新建一篇' : '从文件列表选一篇，或拖到这一栏打开')
              Span('。').letterSpacing(this.paneEmptyPunctHang(FontSize.body2))
            }
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
          if (this.currentVaultNoteCount === 0) {
            this.EmptyPaneAction(pane, 'new', '新建笔记', 'plus', true, 'pane-empty-new-' + pane)
          } else {
            if (this.paneLastClosedPath(pane).length > 0) {
              Row({ space: Space.s2 }) {
                Icon('restore', Space.s4, $r('app.color.brand'))
                Text('重新打开「' + this.noteTitleForPath(this.paneLastClosedPath(pane)) + '」')
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .height(Size.touch)
              .padding({ left: Space.s4, right: Space.s4 })
              .borderRadius(Radius.full)
              .border({ width: 1, color: $r('app.color.line') })
              .backgroundColor($r('app.color.bg_tertiary'))
              .focusable(true)
              .id('pane-empty-reopen-' + pane)
              .onAppear((): void => {
                this.consumeEmptyPaneFocus(pane, 'pane-empty-reopen-' + pane);
              })
              .onClick((): void => { this.onSelectFile(this.paneLastClosedPath(pane), pane, true); })
              .accessibilityText('重新打开「' + this.noteTitleForPath(this.paneLastClosedPath(pane)) + '」')
            }
            Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center,
              alignItems: ItemAlign.Center }) {
              this.EmptyPaneAction(pane, 'new', '新建笔记', 'plus', true, 'pane-empty-new-' + pane)
              this.EmptyPaneAction(pane, 'search', '搜索笔记', 'search', false)
              if (this.isSingleScreenLayout()) {
                this.EmptyPaneAction(pane, 'files', '文件列表', 'menu', false)
              }
            }
            .width('100%')
          }
          if (this.currentVaultNoteCount > 0 && this.paneRecentPaths(pane).length > 0) {
            Column({ space: Space.s1 }) {
              Text('最近打开')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ left: Space.s3, bottom: Space.s1 })
              ForEach(this.paneRecentPaths(pane), (path: string): void => {
                this.EmptyPaneRecentNote(pane, path)
              }, (path: string): string => path)
            }
            .width('100%')
            .margin({ top: Space.s3 })
            .accessibilityGroup(true)
            .accessibilityText('最近打开')
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: Size.paneEmptyMaxW })
        .alignItems(HorizontalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText(pane === 'right' ? '右栏未打开笔记' : '左栏未打开笔记')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: Space.s4,
        right: Space.s4,
        top: Math.min(this.windowHeightVp * Size.paneEmptyTopRatio, Size.paneEmptyTopMax),
        bottom: Space.s8
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor($r('app.color.bg_card'))
  }

  /** 57.7：导航条避让高度（vp）；布局区不进安全区（AE4），固定内容压条带靠 offset。 */
  private navClearanceVp(): number {
    return px2vp(Math.max(0, this.navIndicatorHeightPx));
  }

  @Builder
  NoteWorkspaceContent() {
    // 57.7：根改 Bottom Stack——内容列（Appbar+正文）铺满布局区（底=安全区下沿 2152），
    // 状态条整条 offset 压进底部手势条条带（AE4：offset 渲染+命中同步位移），
    // 上边界线与文字落到物理下沿；NoteBody 相应多吃一个避让高度。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.Appbar()
        Stack({ alignContent: Alignment.BottomStart }) {
          this.NoteBody()
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')

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
          .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })

          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              this.NoteWorkspaceContent()
            }
            .width('100%')
            .height('100%')
            .translate({ x: this.drawerNavigationWidth() *
              (this.breakpoint === Breakpoint.SM ? this.drawerProgress : this.noteNavigationProgress()) })
            .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })

            // 关闭态立即退让命中测试，视觉透明度仍随导航动画淡出。
            Column() {}
              .width('100%')
              .height('100%')
              .translate({ x: this.drawerNavigationWidth() *
                (this.breakpoint === Breakpoint.SM ? this.drawerProgress : this.noteNavigationProgress()) })
              .backgroundColor($r('app.color.mask'))
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
              .opacity(this.singleScreenNavigationOpen() ? 1 : 0)
              .hitTestBehavior(this.singleScreenNavigationOpen() ? HitTestMode.Block : HitTestMode.None)
              .focusable(false)
              .accessibilityLevel('no')
              .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })
              .onClick((): void => {
                this.closeSingleScreenNavigationFromScrim();
              })
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
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
          .enabled(this.focused ? this.focusNavigationOpen : !this.sidebarCollapsed)
          .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })

          SplitHandle({
            enhanced: true,
            gripCenterOffsetY: (this.appbarHeightVp() - Size.statusbarH) / 2,
            readoutPrimary: this.splitHandlePrimary('nav'),
            readoutWidths: this.splitHandleWidths('nav'),
            readoutStatus: this.splitHandleStatus('nav'),
            dragAllowed: (): boolean => !this.splitDragging,
            railDimmed: this.splitDragging,
            keyboardAdjusted: (deltaVp: number): void => {
              this.adjustSplitByKeyboard('nav', deltaVp);
            },
            keyboardToLimit: (maximum: boolean): void => {
              this.setSplitKeyboardLimit('nav', maximum);
            },
            dragStarted: (): void => { this.startNavigationDrag(false); },
            dragUpdated: (offsetX: number, altPressed: boolean): void => {
              this.updateNavigationDrag(offsetX, false, altPressed);
            },
            dragEnded: (): void => { this.endSplitDrag(); },
            dragCancelled: (): void => { this.cancelNavigationDrag(); },
            resetRequested: (): void => { this.resetSplitLayout(); }
          })
            .width(Space.s4 * this.noteNavigationProgress())
            .margin({ left: -Space.s2 * this.noteNavigationProgress(),
              right: -Space.s2 * this.noteNavigationProgress() })
            .zIndex(4)
            .enabled(this.focused ? this.focusNavigationOpen : !this.sidebarCollapsed)
            .visibility(this.noteNavigationProgress() > 0 ? Visibility.Visible : Visibility.Hidden)
            .id('nav-split-handle')
            .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })

          Column() {
            this.NoteWorkspaceContent()
          }
          .width(this.noteContentWidth())
          .height('100%')
          .animation({ duration: this.workspaceTransitionDuration(), curve: Motion.navCurve })
        }
        .width('100%')
        .height('100%')
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
        enhanced: true,
        readoutPrimary: this.splitHandlePrimary('content'),
        readoutWidths: this.splitHandleWidths('content'),
        readoutStatus: this.splitHandleStatus('content'),
        dragAllowed: (): boolean => !this.splitDragging,
        railDimmed: this.splitDragging,
        keyboardAdjusted: (deltaVp: number): void => {
          this.adjustSplitByKeyboard('content', deltaVp);
        },
        keyboardToLimit: (maximum: boolean): void => {
          this.setSplitKeyboardLimit('content', maximum);
        },
        dragStarted: (): void => { this.startContentDrag(); },
        dragUpdated: (offsetX: number, altPressed: boolean): void => {
          this.updateContentDrag(offsetX, altPressed);
        },
        dragEnded: (): void => { this.endSplitDrag(); },
        dragCancelled: (): void => { this.cancelContentDrag(); },
        resetRequested: (): void => { this.resetSplitLayout(); }
      })
        .width(this.contentHandleVisible() ? Space.s4 : 0)
        .margin(this.contentHandleVisible() ? { left: -Space.s2, right: -Space.s2 } : { left: 0, right: 0 })
        .zIndex(4)
        .enabled(this.contentHandleVisible())
        .visibility(this.contentHandleVisible() ? Visibility.Visible : Visibility.Hidden)
        .id('content-split-handle')

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

  private openShareDialog(scope: ShareLinkScope, path: string, targetVaultId: string = this.currentVaultId,
    vaultNoteCount: number = -1, focusReturnId: string = ''): void {
    const registry: VaultRegistry = VaultRegistry.get();
    const entries: VaultEntry[] = registry.list();
    let vault: VaultEntry | null = null;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === targetVaultId) {
        vault = entries[i];
        break;
      }
    }
    if (vault === null) {
      promptAction.showToast({ message: '这个知识库已不存在' });
      return;
    }
    const notePath: string = vault.id === this.currentVaultId ? this.activeFilePath() : '';
    if (scope === 'note' && notePath.length === 0) {
      promptAction.showToast({ message: '请先打开一篇笔记' });
      return;
    }
    const folderPath: string = this.sharePathForScope('folder', scope, path, notePath);
    const noteName: string = notePath.substring(notePath.lastIndexOf('/') + 1);
    const noteOptions: ShareFormatOption[] = [
      { value: 'image', label: '长图', detail: '整篇笔记合成一张带水印的图片。', icon: 'image' },
      { value: 'file', label: 'Markdown / ZIP', detail: '按本地图片情况生成 Markdown 文件或 ZIP。', icon: 'doc' },
      { value: 'text', label: '文本', detail: '预览并编辑本次分享文本，不写回笔记。', icon: 'message' }
    ];
    if (NotePdfDocumentService.isSupported()) {
      noteOptions.splice(1, 0, {
        value: 'pdf', label: 'PDF 文档',
        detail: 'A4 竖版逐页排版，适合打印与通用阅读。', icon: 'doc'
      });
    }
    const folderOptions: ShareFormatOption[] = [
      { value: 'zip', label: 'ZIP 文件', detail: '保留目录结构，并补齐引用的本地图片。', icon: 'archive' }
    ];
    const vaultOptions: ShareFormatOption[] = [
      { value: 'zip', label: 'ZIP 文件', detail: '打包当前知识库中的可分享文件。', icon: 'archive' }
    ];
    const noteOption: ShareScopeOption = {
      scope: 'note',
      path: notePath,
      label: '笔记',
      title: '分享笔记',
      itemName: noteName,
      description: '当前笔记及其引用的库内图片，不包含链接到的其他笔记。',
      summary: '当前编辑内容',
      notice: '',
      available: notePath.length > 0,
      options: noteOptions
    };
    const folderOption: ShareScopeOption = {
      scope: 'folder',
      path: folderPath,
      label: '文件夹',
      title: '分享文件夹',
      itemName: folderPath.length > 0 ? folderPath : '知识库根目录',
      description: '递归包含所选文件夹中的文件，并补齐笔记引用的库内图片。',
      summary: '递归文件与图片',
      notice: '',
      available: true,
      options: folderOptions
    };
    const vaultOption: ShareScopeOption = {
      scope: 'vault',
      path: '',
      label: '知识库',
      title: '分享知识库',
      itemName: vault.id,
      description: '排除隐藏项、回收站、缓存、草稿、凭据及内部状态。',
      summary: focusReturnId.length > 0 && vaultNoteCount >= 0
        ? vaultNoteCount.toString() + ' 篇笔记' : '当前库的可分享文件',
      notice: '',
      available: true,
      options: vaultOptions
    };
    const folderScopeDistinct: boolean = folderPath.length > 0;
    const scopeOptions: ShareScopeOption[] = focusReturnId.length > 0
      ? [vaultOption]
      : folderScopeDistinct ? [noteOption, folderOption, vaultOption] : [noteOption, vaultOption];
    for (let i: number = 0; i < scopeOptions.length; i++) {
      if (vault.type === 'git' && focusReturnId.length === 0) {
        try {
          const linkResult = ShareLinkService.build(vault, scopeOptions[i].scope, scopeOptions[i].path);
          scopeOptions[i].options.push({
            value: 'link',
            label: '远端网页链接',
            detail: '来自已配置的 Git 远端和跟踪分支。',
            icon: 'share'
          });
          scopeOptions[i].notice = linkResult.accessNotice;
        } catch (error) {
          const err = error as BusinessError;
          const linkNoticeReason: string = err.message ?? '';
          scopeOptions[i].notice = linkNoticeReason.length > 0
            ? '远端链接准备失败：' + linkNoticeReason : '远端链接准备失败；仍可分享本地文件。';
        }
      }
    }

    const shareSheet: boolean = this.isSingleScreenLayout() ||
      (this.windowHeightVp > 0 && this.windowHeightVp < 480);
    let focusRestoreScheduled: boolean = false;
    const restoreShareTriggerFocus = (): void => {
      if (focusReturnId.length === 0 || focusRestoreScheduled) {
        return;
      }
      focusRestoreScheduled = true;
      setTimeout((): void => {
        FocusRequest.safely(this.getUIContext(), focusReturnId);
      }, 0);
    };
    this.shareNoteCtl = new CustomDialogController({
      builder: ShareNoteDialog({
        scopeOptions: scopeOptions,
        initialScope: scope,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        singleScreen: shareSheet,
        onConfirm: (targetScope: ShareLinkScope, targetPath: string, format: string, itemName: string): void => {
          void this.prepareShare(targetScope, targetPath, format, itemName, vault as VaultEntry,
            vaultNoteCount, focusReturnId);
        },
        onDismiss: restoreShareTriggerFocus
      }),
      autoCancel: true,
      cancel: restoreShareTriggerFocus,
      alignment: shareSheet ? DialogAlignment.Bottom : DialogAlignment.Center,
      customStyle: true
    });
    this.shareNoteCtl.open();
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
      if (this.tableEditUndoState !== null) {
        Text('撤销')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.snack_action'))
          .onClick((): void => {
            void this.undoTableEdit();
          })
      } else if (this.undoSnap !== null) {
        Text('撤销')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.snack_action'))
          .onClick(() => {
            void this.undoTrashRestore();
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
        hideScrollBar: true,
        themeOverride: this.shareCapturePdfMode ? 'light' : this.shareCaptureTheme,
        onReadAsset: (relPath: string): string => {
          return this.readVaultAsset(relPath);
        },
        onReady: (): void => {
          this.resolveShareCaptureReady();
        },
        onError: (msg: string): void => {
          hilog.error(DOMAIN, TAG, '分享预览加载错误');
          this.rejectShareCaptureReady(new Error('分享预览加载失败，请重试'));
        }
      })
        .width(this.shareCapturePdfMode ? this.pdfPageWidthVp :
          (this.shareCaptureWidthVp > 0 ? this.shareCaptureWidthVp : '100%'))
        .height(this.shareCapturePdfMode ? this.pdfPageHeightVp : '100%')
    }
    .width('100%')
    .height('100%')
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
            if (this.settingsPrivacyPolicyOpen) {
              this.settingsPrivacyPolicyOpen = false;
            } else if (this.isSingleScreenLayout() && this.settingsDetail &&
              this.settingsReturnView !== 'agent') {
              this.settingsDetail = false;
            } else {
              this.returnFromSettings();
            }
          } else {
            this.leaveSecondaryView();
          }
        })
      } else {
        if (this.topView === 'note') {
          this.NoteNavigationToggleButton()
        } else {
          this.IconButton('menu', $r('app.color.text_secondary'), (): void => {
            this.onHamburger();
          })
        }
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
        if (this.showXiaoyiDialogEntry && this.agentKitSlotBuilder !== null) {
          Row() {
            this.agentKitSlotBuilder.builder(this.xiaoyiDialogClosed, this.xiaoyiNoteHint())
          }
          .margin({ left: Space.s1, right: Space.s1 })
        }
        if (!this.isSingleScreenLayout()) {
          if (GIT_ENTRY_UI_ENABLED && this.currentVaultIsGit()) {
            this.GitSyncButton()
          }
          if (this.activeFilePath().length > 0) {
            this.IconButton('share', $r('app.color.text_secondary'), (): void => {
              this.openShareNoteDialog();
            })
          }
        }
        this.WorkspaceLayoutButton()
        this.MoreMenuButton()
      } else if (this.topView === 'agent') {
        this.IconButton('settings', $r('app.color.text_secondary'), (): void => {
          this.openSettings('agent', 'agent');
        })
      }
    }
    .width('100%')
    .height(this.appbarHeightVp())
    .padding({ left: this.workspaceGutter(), right: this.workspaceGutter() })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  MoreMenuButton() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Row() {
        Icon('more', Space.s5, $r('app.color.text_secondary'))
      }
      .width(Size.touch)
      .height(Size.touch)
      .justifyContent(FlexAlign.Center)
      .borderRadius(Radius.icon)
      if (GIT_ENTRY_UI_ENABLED && this.currentVaultIsGit()) {
        this.GitAheadBadge()
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .borderRadius(Radius.icon)
    .focusable(true)
    .id('workspace-more-button')
    .onClick(() => { this.moreMenuOpen = !this.moreMenuOpen; })
    .accessibilityText('更多菜单')
    .accessibilityTextHint(this.moreMenuOpen ? '收起菜单' : '展开菜单')
    .onAppear((): void => {
      if (this.focusMoreMenuOnAppear) {
        FocusRequest.safely(this.getUIContext(), 'workspace-more-button');
        this.focusMoreMenuOnAppear = false;
      }
    })
    .bindPopup(this.moreMenuOpen, {
      builder: this.MoreMenu(),
      placement: Placement.BottomRight,
      enableArrow: false,
      offset: { x: 0, y: Space.s1 },
      mask: false,
      autoCancel: true,
      popupColor: Color.Transparent,
      onWillDismiss: (action: DismissPopupAction): void => {
        action.dismiss();
        this.moreMenuOpen = false;
        // v1.31 31.6：点外部关闭后把焦点还给「…」
        FocusRequest.safely(this.getUIContext(), 'workspace-more-button');
      }
    })
  }

  @Builder
  MoreMenu() {
    Column() {
      // 31.1 三组：当前笔记 / 编辑模式 / 应用
      this.MobileMoreMenuNoteGroup()
      this.MobileMoreMenuExperienceGroup()
      this.MobileMoreMenuAppGroup()
    }
    // 31.6 外形：定宽 s16×4.25（272，border-box），上下内边距 s1，--r 圆角 + --float-shadow。
    // 不用 constraintSize minWidth，根因与规避方式见本菜单定宽约束说明（faqs-arkui-95）。
    .width(Space.s16 * 4.25)
    .padding({ top: Space.s1, bottom: Space.s1 })
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: Shadow.floatBlur, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 8 })
    // 31.6：Escape 关闭并把焦点还给「…」
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.moreMenuOpen = false;
        FocusRequest.safely(this.getUIContext(), 'workspace-more-button');
        return true;
      }
      return false;
    })
  }

  /** 工作区更多菜单：笔记操作统一作用于当前激活栏，并在双栏时标明栏位。 */
  @Builder
  MobileMoreMenuNoteGroup() {
    Column() {
      Text(this.activeNoteMenuScopeLabel())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s1 })
        .accessibilityText(this.activeNoteMenuScopeLabel())
      this.MobileMoreMenuItem('share', 'share', '分享笔记',
        this.activeFilePath().length > 0, (): void => {
          this.openShareNoteDialog();
        })
      this.MobileMoreMenuItem('backlinks', 'link',
        this.backlinksExpanded && this.backlinksPane === this.activeNotePane() ? '隐藏反链' : '查看反链',
        this.activeFilePath().length > 0, (): void => {
          this.toggleBacklinks(this.activeNotePane());
        })
      if (this.experienceMode === 'professional' && !this.isSingleScreenLayout() &&
        this.activeFilePath().length > 0) {
        this.MobileMoreMenuItem('preview', 'fileReference', '在另一栏预览', true, (): void => {
          this.previewActiveNoteInOtherPane(this.activeNotePane());
        })
      }
      if (this.shouldShowPreviewFollowToggle(this.activeNotePane())) {
        this.MobileMoreMenuItem('follow', 'follow',
          '跟随编辑：' + (this.followPreviewEnabled ? '开' : '关'), true, (): void => {
            this.setPreviewFollowEnabled(!this.followPreviewEnabled);
          })
      }
      if (this.experienceMode === 'professional' && this.currentFilePath.length > 0 &&
        this.rightFilePath.length > 0 && this.currentFilePath !== this.rightFilePath) {
        this.MobileMoreMenuItem('switch', 'swap',
          '切换到笔记：' + (this.activeNotePane() === 'left'
            ? this.paneNoteTitle(this.rightFilePath)
            : this.paneNoteTitle(this.currentFilePath)),
          true, (): void => {
            this.toggleActivePane();
          })
      }
    }
    .width('100%')
    .padding({ top: Space.s1, bottom: Space.s1, left: Space.s2, right: Space.s2 })
  }

  /** v1.31 31.3：组二「编辑模式」——笔线稿 + 标题与简单/专业分段同行；选中 --blue-soft 底 + --blue 字 + 600 字重 */
  @Builder
  MobileMoreMenuExperienceGroup() {
    Row() {
      Row({ space: Space.s3 }) {
        Icon('rename', Space.s5, $r('app.color.text_primary'))
        Text('编辑模式')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
      }
      Row({ space: Space.s1 }) {
        this.MobileMoreSegButton('simple', '简单')
        this.MobileMoreSegButton('professional', '专业')
      }
      .padding(Space.s1)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_secondary'))
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .padding({ top: Space.s2, bottom: Space.s2, left: Space.s5, right: Space.s2 })
    .border({ width: { top: 1 }, color: $r('app.color.line') })
  }

  /** v1.31 31.1：组三「应用」——同步到 Git（仅 Git 库）→ 设置与关于（设置始终在末尾） */
  @Builder
  MobileMoreMenuAppGroup() {
    Column() {
      if (GIT_ENTRY_UI_ENABLED && this.currentVaultIsGit()) {
        this.MobileMoreGitSyncItem()
      }
      // v1.58 58.3：写作统计在「应用」组、设置与关于之前；行尾是连写缓存值。
      if (this.statsEnabled) {
        this.MobileMoreStatsItem()
      }
      // v1.65 65.1：屏保 / 台历常驻入口；设置与关于仍保持组末位。
      this.MobileMoreMenuItem('screenSaver', 'screenSaver', '屏保 / 台历', true, (): void => {
        this.openScreenSaver();
      })
      this.MobileMoreMenuItem('settings', 'settings', '设置与关于', true, (): void => {
        this.openSettings('note', 'general');
      })
    }
    .width('100%')
    .padding({ top: Space.s1, bottom: Space.s1, left: Space.s2, right: Space.s2 })
    .border({ width: { top: 1 }, color: $r('app.color.line') })
  }

  /** v1.31 31.2：单屏菜单图标行——20 线稿 + body 文本 + 48 行高 + hover --nav 底；文本过长省略；31.5 禁用 40% */
  @Builder
  MobileMoreMenuItem(action: string, icon: string, label: string, isEnabled: boolean, onTap: () => void) {
    Row({ space: Space.s3 }) {
      Icon(icon, Space.s5, $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body1)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .backgroundColor(this.mobileMoreHoveredAction === action
      ? $r('app.color.bg_secondary') : Color.Transparent)
    .opacity(isEnabled ? 1 : 0.4)
    .enabled(isEnabled)
    .focusable(true)
    .onHover((isHover: boolean): void => {
      this.mobileMoreHoveredAction = isHover && isEnabled ? action : '';
    })
    .onClick((): void => {
      this.moreMenuOpen = false;
      onTap();
    })
    .accessibilityText(label)
  }

  /** v1.58 58.3：单屏「⋯」应用组的「写作统计」行，行尾 muted 小字显示连写天数。 */
  @Builder
  MobileMoreStatsItem() {
    Row({ space: Space.s3 }) {
      Icon('flame', Space.s5, $r('app.color.text_secondary'))
      Text('写作统计')
        .fontSize(FontSize.body1)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.vaultStatsScanning || this.vaultStatsFailed
        ? '…' : '连写 ' + this.vaultStatsModel.streakDays.toString() + ' 天')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .backgroundColor(this.mobileMoreHoveredAction === 'stats'
      ? $r('app.color.bg_secondary') : Color.Transparent)
    .focusable(true)
    .onHover((isHover: boolean): void => {
      this.mobileMoreHoveredAction = isHover ? 'stats' : '';
    })
    .onClick((): void => {
      this.moreMenuOpen = false;
      void this.openVaultStats('note', 'workspace-more-button');
    })
    .accessibilityText('写作统计')
  }

  /** v1.31 31.3：分段按钮——选择后立即生效并关闭菜单（沿用 v1.7 行为） */
  @Builder
  MobileMoreSegButton(mode: EditorExperienceMode, label: string) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontWeight(this.experienceMode === mode ? 600 : 400)
      .fontColor(this.experienceMode === mode ? $r('app.color.brand') : $r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      .height(Space.s10)
      .padding({ left: Space.s4, right: Space.s4 })
      .borderRadius(Radius.full)
      .backgroundColor(this.experienceMode === mode ? $r('app.color.brand_bg') : Color.Transparent)
      .focusable(true)
      .accessibilityText(label + (this.experienceMode === mode ? '，已选中' : ''))
      .onClick((): void => {
        this.moreMenuOpen = false;
        void this.selectEditorExperience(mode);
      })
  }

  /** v1.31 31.4：同步到 Git——待推送为 --blue 底圆形计数徽标（与顶栏角标一致），读屏「N 个提交待推送」 */
  @Builder
  MobileMoreGitSyncItem() {
    Row({ space: Space.s3 }) {
      Icon('sync', Space.s5, $r('app.color.text_secondary'))
      Text('同步到 Git')
        .fontSize(FontSize.body1)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.gitAheadCommitCount > 0) {
        Text(this.gitAheadBadgeLabel())
          .fontSize(FontSize.caption)
          .fontWeight(Weight.semibold)
          .lineHeight(Space.s5)
          .fontColor($r('app.color.on_brand'))
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: Space.s5 })
          .padding({ left: Space.s1, right: Space.s1 })
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.brand'))
          .accessibilityText(this.gitAheadCommitCount.toString() + ' 个提交待推送')
      }
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .backgroundColor(this.mobileMoreHoveredAction === 'sync'
      ? $r('app.color.bg_secondary') : Color.Transparent)
    .focusable(true)
    .onHover((isHover: boolean): void => {
      this.mobileMoreHoveredAction = isHover ? 'sync' : '';
    })
    .onClick((): void => {
      this.moreMenuOpen = false;
      void this.openGitSyncPage();
    })
    .accessibilityText('同步到 Git')
    .accessibilityTextHint(this.gitAheadCommitCount > 0
      ? '有 ' + this.gitAheadCommitCount.toString() + ' 个提交待推送' : '打开 Git 同步页')
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
        this.switchVaultFromNavigation(id);
      },
      onManageVaults: (): void => {
        this.closeNoteNavigation();
        void this.openVaultManager('note');
      },
      onOpenStats: (): void => {
        this.closeNoteNavigation();
        void this.openVaultStats('note', 'vault-stats-streak-chip');
      },
      statsStreakDays: this.vaultStatsModel.streakDays,
      statsTotalDays: this.vaultStatsModel.totalDays,
      statsScanning: this.vaultStatsScanning || this.vaultStatsFailed,
      statsWeekFlags: this.statsWeekFlags(),
      statsTodayIndex: this.statsTodayIndex(),
      statsEnabled: this.statsEnabled,
      onOpenSearch: (): void => {
        this.closeNoteNavigation();
        this.openQuickSwitcher();
      },
      onImportVault: (): void => {
        void this.openImportVaultDialog('vault-switcher-trigger');
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
        void this.doRestoreFromTrash(relPath);
      },
      onPurgeTrash: (relPath: string): void => {
        this.openPurgeTrashDialog(relPath);
      },
      onSelectFile: (relPath: string): void => { this.onSelectFile(relPath); },
      onSidebarTabChange: (tab: string): void => { this.setSidebarTab(tab); },
      onSelectChapter: (index: number): void => { this.selectChapter(index); },
      onOpenOtherPane: (relPath: string): void => { this.openFileInOtherPane(relPath); }
    })
  }

  @Builder
  LeftWorkspacePane(showHingeWarning: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.EditorPane(showHingeWarning)
      }
      .width('100%')
      .height('100%')
      .visibility(this.experienceMode === 'professional' && this.smMode === 'edit'
        ? Visibility.Visible : Visibility.Hidden)
      Column() {
        this.PreviewPane()
      }
      .width('100%')
      .height('100%')
      .visibility(this.experienceMode === 'simple' || this.smMode === 'preview'
        ? Visibility.Visible : Visibility.Hidden)
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
    // v1.10 读屏：kind === 'task' 只画图标，没有可见文字，统一用 label 当名称
    .accessibilityText(label)
  }

  @Builder
  ImageFormatAction(pane: string) {
    Row() {
      // L-7/Z2：全局 @Builder 按值实参不随状态刷新，忙碌色必须走 if 分支，不能写成三元实参
      if (this.isImagePickerBusy(pane)) {
        Icon('image', Space.s5, $r('app.color.text_tertiary'))
      } else {
        Icon('image', Space.s5, $r('app.color.text_primary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane) && !this.isImagePickerBusy(pane))
    .onClick((): void => { void this.pickImageForCurrentNote(pane); })
    .accessibilityText(this.isImagePickerBusy(pane) ? '正在选择图片' : '插入图片')
  }

  @Builder
  TableGridCell(pane: string, rows: number, columns: number, selected: boolean) {
    Row() {
      Text(`${rows}×${columns}`)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_primary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.control)
    .backgroundColor(selected ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
    .focusable(true)
    .id(this.tableGridCellFocusId(pane, rows, columns))
    .enabled(this.isPaneEditable(pane))
    .onAppear((): void => {
      if (selected && this.tableGridOpen && this.tableGridPane === pane) {
        FocusRequest.safely(this.getUIContext(), this.tableGridCellFocusId(pane, rows, columns));
      }
    })
    .onKeyEvent((event: KeyEvent): boolean => {
      return this.onTableGridCellKey(pane, rows, columns, event);
    })
    .onClick((): void => {
      this.insertTableFromGrid(pane, rows, columns);
    })
    .accessibilityText(`插入 ${rows} 行 ${columns} 列表格`)
  }

  @Builder
  TableGridPicker(pane: string) {
    Column({ space: Space.s2 }) {
      Text('选择表格大小')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Scroll() {
        Column({ space: Space.s1 }) {
          ForEach(this.tableGridRowOptions, (rows: number): void => {
            Row({ space: Space.s1 }) {
              ForEach(this.tableGridColumnOptions, (columns: number): void => {
                this.TableGridCell(pane, rows, columns,
                  this.tableGridFocusedRows === rows && this.tableGridFocusedColumns === columns)
              }, (columns: number): string => String(columns))
            }
            .width('100%')
          }, (rows: number): string => String(rows))
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(Size.touch, this.formatMenuMaxHeight - Size.touch * 2) })
      .scrollBar(BarState.Auto)
    }
    .width(Size.touch * 6 + Space.s1 * 5 + Space.s5 * 2)
    .constraintSize({ maxHeight: this.formatMenuMaxHeight })
    .padding(Space.s5)
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
  }

  @Builder
  TableInsertAction(pane: string) {
    Row() {
      Icon('plus', Space.s5, $r('app.color.text_primary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane))
    .onClick((): void => { this.toggleTableGrid(pane); })
    .bindPopup(this.tableGridOpen && this.tableGridPane === pane, {
      builder: this.TableGridPicker(pane),
      // v1.46 46.9：格式栏停靠栏顶后，表格网格向下弹（原 Placement.Top 会顶出栏外）
      placement: Placement.Bottom,
      enableArrow: false,
      mask: false,
      autoCancel: true,
      popupColor: Color.Transparent
    })
    .accessibilityText('插入表格')
  }

  /**
   * Aa 面板避让系统选区 UI（faqs-arkui-669 思路）：开面板时清当前栏位 Web 的 DOM 选区，
   * 隐藏与面板重叠的选区手柄/胶囊菜单；Web 侧保留编辑选区（简单模式 savedEditableSelection、
   * 专业模式 CodeMirror state），关面板时还原。
   */
  private suppressPaneSelectionUi(pane: string): void {
    if (this.experienceMode === 'simple') {
      this.previewBridgeForPane(pane).suppressSelectionUI();
    } else {
      this.editorBridgeForPane(pane).suppressSelectionUI();
    }
    this.formatSelectionSuppressedPane = pane;
    this.formatSelectionSuppressedMode = this.experienceMode;
  }

  private applyFormatHistoryAction(action: PreviewEditHistoryAction): void {
    const pane: string = this.formatMenuPane;
    if (!this.isPaneEditable(pane) || this.currentVaultId !== this.formatMenuSourceVaultId ||
      this.paneFilePath(pane) !== this.formatMenuSourcePath) {
      this.closeFormatMenu();
      return;
    }
    this.previewBridgeForPane(pane).editHistory(action);
  }

  @Builder
  FormatHistoryButton(action: PreviewEditHistoryAction, label: string) {
    Row({ space: Space.s2 }) {
      Icon(action, Space.s4, $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.control)
    .onClick((): void => { this.applyFormatHistoryAction(action); })
    .accessibilityText(label)
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
          Row({ space: Space.s2 }) {
            this.FormatHistoryButton('undo', '撤销')
            this.FormatHistoryButton('redo', '重做')
          }
          .width('100%')
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4, left: Space.s5, right: Space.s5 })
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

  /** 关闭 Aa 面板后按开面板时记录的栏位/模式还原选区 UI；未压制时是空操作 */
  private restoreSuppressedPaneSelectionUi(): void {
    const pane: string = this.formatSelectionSuppressedPane;
    if (pane.length === 0) {
      return;
    }
    const mode: string = this.formatSelectionSuppressedMode;
    this.formatSelectionSuppressedPane = '';
    this.formatSelectionSuppressedMode = '';
    if (mode === 'simple') {
      this.previewBridgeForPane(pane).restoreSelectionUI();
    } else {
      this.editorBridgeForPane(pane).restoreSelectionUI();
    }
  }

  private toggleFormatMenu(pane: string): void {
    if (this.formatMenuOpen && this.formatMenuPane === pane) {
      this.closeFormatMenu();
      return;
    }
    if (this.formatMenuOpen) {
      // 面板开着但切换了栏位：先按旧栏位还原选区 UI，再压制新栏位
      this.restoreSuppressedPaneSelectionUi();
      this.formatMenuOpen = false;
    }
    if (!this.isPaneEditable(pane)) {
      return;
    }
    this.setActivePane(pane);
    this.blockToolbarOpen = false;
    this.formatMenuPane = pane;
    this.formatMenuSourceVaultId = this.currentVaultId;
    this.formatMenuSourcePath = this.paneFilePath(pane);
    this.formatMenuWidth = Size.formatMenuW;
    this.formatMenuMaxHeight =
      Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2 + Size.touch + Space.s2;
    this.formatMenuOpen = true;
    this.suppressPaneSelectionUi(pane);
    this.updateFormatPopupLayout(pane);
  }

  @Builder
  private panelContent(pane: string) {
    BlockPropertyPanel({
      sheetSide: pane,
      blockPanelPane: this.blockPanelPane,
      blockPanelSourceVaultId: this.blockPanelSourceVaultId,
      blockPanelSourcePath: this.blockPanelSourcePath,
      blockPanelMaxHeight: this.blockPanelMaxHeight,
      blockSourceEditing: this.blockSourceEditing,
      currentVaultId: this.currentVaultId,
      leftOpenRequestId: this.leftOpenRequestId,
      rightOpenRequestId: this.rightOpenRequestId,
      pushedAnchor: this.pushedAnchor,
      pushedAnchorSeq: this.pushedAnchorSeq,
      pushedAnchorMode: this.pushedAnchorMode,
      onCloseRequest: (restoreFocus: boolean): void => { this.closeBlockPropertyPanel(restoreFocus); },
      onContentActionClose: (): void => { this.closeBlockPanelForContentAction(); },
      onAnchorChange: (anchor: PreviewBlockAnchor): void => {
        if (this.blockPanelAnchor !== anchor) {
          this.blockPanelAnchor = anchor;
        }
      },
      onTitleChange: (title: string): void => { this.blockPanelTitle = title; },
      onSourceEditingChange: (editing: boolean): void => { this.blockSourceEditing = editing; },
      onDirtyChange: (pane: string, dirty: boolean): void => {
        if (pane === 'right') {
          this.rightEditorDirty = dirty;
        } else {
          this.editorDirty = dirty;
        }
      },
      isDirty: (pane: string): boolean => pane === 'right' ? this.rightEditorDirty : this.editorDirty,
      isCurrentTarget: (pane: string, vaultId: string, path: string, requestId: number, documentRevision: number): boolean =>
        this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, documentRevision),
      requestRelayout: (pane: string): void => { this.updateBlockPropertyPanelLayout(pane); },
      editorBridgeFor: (pane: string): EditorBridge => this.editorBridgeForPane(pane),
      previewBridgeFor: (pane: string): PreviewBridge => this.previewBridgeForPane(pane),
      scheduleSaveFor: (pane: string): void => {
        if (pane === 'right') {
          this.scheduleRightSave();
        } else {
          this.scheduleSave();
        }
      },
      flushSimplePreview: (): Promise<string> => this.flushSimplePreviewChanges(),
      paneFileFor: (pane: string): string => this.paneFilePath(pane),
      onResetSaveFeedback: (): void => { this.resetSaveFeedback(); },
      recordFailure: (operation: RecentErrorOperation, phase: RecentErrorPhase, category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep, code?: number, message?: string): void =>
        this.recordBackgroundFailure(operation, phase, category, outcome, nextStep, code, message),
      isImagePickerBusyFor: (pane: string): boolean => pane === 'right' ? this.rightImagePickerBusy : this.imagePickerBusy,
      pickImage: (pane: string, replaceSelectedImage: boolean, context: PanelImageReplaceContext | null): void => {
        void this.pickImageForCurrentNote(pane, replaceSelectedImage, context);
      },
      applyTableOp: (pane: string, type: string, side: string): void => { this.applyTableStructureOperation(pane, type, side); },
      openNoteInOtherPane: (relPath: string): void => { this.openFileInOtherPane(relPath); }
    })
  }

  @Builder
  PreviewBlockPanel(pane: string) {
    if (pane === 'right') {
      Blank()
        .width(Math.max(Space.s1, this.blockPanelAnchorGeometry(pane)[2]))
        .height(Math.max(Space.s1, this.blockPanelAnchorGeometry(pane)[3]))
        .position({
          x: this.blockPanelAnchorGeometry(pane)[0],
          y: this.blockPanelAnchorGeometry(pane)[1]
        })
        .hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.rightBlockPanelOpen, this.panelContent('right'), this.blockPanelSheetOptions())
    } else {
      Blank()
        .width(Math.max(Space.s1, this.blockPanelAnchorGeometry(pane)[2]))
        .height(Math.max(Space.s1, this.blockPanelAnchorGeometry(pane)[3]))
        .position({
          x: this.blockPanelAnchorGeometry(pane)[0],
          y: this.blockPanelAnchorGeometry(pane)[1]
        })
        .hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.leftBlockPanelOpen, this.panelContent('left'), this.blockPanelSheetOptions())
    }
  }

  @Builder
  PreviewBlockToolbar(pane: string) {
    if (this.hasBlockToolbarForPane(pane)) {
      Blank()
        .width(this.blockToolbarAnchorGeometry(pane)[2])
        .height(this.blockToolbarAnchorGeometry(pane)[3])
        .position({
          x: this.blockToolbarAnchorGeometry(pane)[0],
          y: this.blockToolbarAnchorGeometry(pane)[1]
        })
        .hitTestBehavior(HitTestMode.None)
        .bindPopup(this.blockToolbarOpen && this.blockToolbarPane === pane, {
          builder: this.BlockToolbarContent(),
          placement: this.blockToolbarPlacement,
          enableArrow: false,
          offset: { x: this.blockToolbarOffsetX, y: this.blockToolbarOffsetY },
          mask: false,
          autoCancel: true,
          popupColor: Color.Transparent,
          onWillDismiss: (action: DismissPopupAction): void => {
            action.dismiss();
            this.blockToolbarOpen = false;
          }
        })
    }
  }

  private openBlockPropertyPanel(pane: string, tappedAnchor: PreviewBlockAnchor | null = null): void {
    if (!this.hasBlockPropertyPanelForPane(pane, tappedAnchor)) {
      return;
    }
    const anchor: PreviewBlockAnchor | null = tappedAnchor !== null
      ? tappedAnchor : pane === 'right' ? this.rightBlockAnchor : this.leftBlockAnchor;
    if (anchor === null) {
      return;
    }
    this.setActivePane(pane);
    this.blockToolbarOpen = false;
    this.closeFormatMenu();
    this.blockPanelPane = pane;
    this.blockPanelAnchor = anchor;
    this.pushedAnchor = anchor;
    this.pushedAnchorMode = 'open';
    this.pushedAnchorSeq++;
    this.blockPanelTitle = blockPanelTitleFor(anchor);
    this.blockPanelSourceVaultId = this.currentVaultId;
    this.blockPanelSourcePath = this.paneFilePath(pane);
    this.blockPanelRestoreFocus = true;
    this.blockPanelPendingAction = false;
    this.blockSourceEditing = false;
    this.blockPanelWidth = Size.blockPanelW;
    this.blockPanelMaxHeight = Size.menuMaxH;
    this.leftBlockPanelOpen = pane === 'left';
    this.rightBlockPanelOpen = pane === 'right';
    this.updateBlockPropertyPanelLayout(pane);
  }

  /**
   * v1.32 32.2：专业模式格式栏停靠 —— 与 v1.30 简单模式停靠栏同形（v2 规则
   * `.window:not(.simple-mode) …>.edit-tools`）：该栏顶部整行（内容区上方）、底部细线、
   * bg_card 底、无阴影圆角；宽屏按钮靠左（左内边距 s5）、单屏居中（s3）；无「完成编辑」按钮——
   * 专业模式走 PaneHead 编辑/预览切换。内容区经 layoutWeight 收缩，源码末行不被遮挡。
   * 仅编辑状态显示，预览时隐藏（沿用既有规则）。
   * v1.46 46.9：停靠位从栏底移到栏顶 —— OFFSET_WITH_CARET 只保证光标可见，
   * 栏底停靠被软键盘盖住（XT2 真机实测），栏顶不依赖窗口底部避让空间。
   */
  @Builder
  ProfFormatDock(pane: string) {
    Row() {
      Scroll() {
        Row({ space: Space.s1 }) {
          this.FormatActionsRow(pane, Space.s1)
        }
        .constraintSize({ minWidth: '100%' })
        .justifyContent(this.isSingleScreenLayout() ? FlexAlign.Center : FlexAlign.Start)
        .padding({
          left: this.isSingleScreenLayout() ? Space.s3 : Space.s5,
          right: Space.s3
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height(Size.touch + Space.s1 * 2)
    .padding({
      top: Space.s1,
      bottom: Space.s1
    })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.recordPaneWidth(pane, newArea.width);
      }
    })
  }

  /** v1.30 30.4：「完成编辑」—— 收起软键盘并结束编辑焦点，读屏名「完成编辑」 */
  @Builder
  SimpleDoneAction(pane: string) {
    Row() {
      Icon('keyboardDone', Space.s5, $r('app.color.brand'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .margin({ left: Space.s2 })
    .onClick((): void => { this.finishSimpleEditingFor(pane); })
    .accessibilityText('完成编辑')
  }

  /**
   * v1.30 30.2/30.3：简单模式停靠格式栏 —— 该栏顶部整行（内容区上方）：通栏宽、
   * 底部分隔线、bg_card 底、无阴影圆角；宽屏按钮靠左、完成编辑靠右；单屏按钮居中、
   * 完成编辑在末尾；按钮超出横向滑动。内容区经 layoutWeight 自动收缩，末行不被遮挡。
   * v1.46 46.9：停靠位从栏底移到栏顶 —— OFFSET_WITH_CARET 下栏底停靠被软键盘盖住。
   */
  @Builder
  SimpleFormatDock(pane: string) {
    Row() {
      Scroll() {
        Row({ space: Space.s1 }) {
          this.FormatActionsRow(pane, Space.s1)
          if (this.isSingleScreenLayout()) {
            this.SimpleDoneAction(pane)
          }
        }
        .constraintSize({ minWidth: '100%' })
        .justifyContent(this.isSingleScreenLayout() ? FlexAlign.Center : FlexAlign.Start)
        .padding({
          left: this.isSingleScreenLayout() ? Space.s3 : Space.s5,
          right: Space.s3
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      if (!this.isSingleScreenLayout()) {
        this.SimpleDoneAction(pane)
      }
    }
    .width('100%')
    .height(Size.touch + Space.s1 * 2)
    .padding({
      top: Space.s1,
      bottom: Space.s1,
      right: this.isSingleScreenLayout() ? 0 : Space.s3
    })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.recordPaneWidth(pane, newArea.width);
      }
    })
  }

  @Builder
  RightWorkspacePane() {
    Column() {
      if (this.experienceMode === 'professional' && this.rightFilePath.length > 0) {
        this.PaneHead({ pane: 'right' })
      }
      this.PaneTitle({ pane: 'right' })
      if (this.rightFilePath.length > 0 && !this.rightEditing &&
        this.backlinksExpanded && this.backlinksPane === 'right') {
        this.BacklinkPanel()
      }
      // v1.46 46.9：格式栏停靠内容区顶部 —— OFFSET_WITH_CARET 只保证光标可见，栏底停靠会被键盘盖住
      if (this.experienceMode === 'simple' && this.rightFilePath.length > 0 &&
        this.simpleFormatBarVisible('right')) {
        this.SimpleFormatDock('right')
      }
      // v1.32 32.2：专业模式停靠格式栏 —— 仅源码编辑时出现，预览时隐藏
      if (this.experienceMode === 'professional' && this.rightEditing &&
        this.rightFilePath.length > 0) {
        this.ProfFormatDock('right')
      }
      Stack({ alignContent: Alignment.Bottom }) {
        Stack() {
          EditorWebView({
            bridge: this.rightEditorBridge,
            showLineNumbers: this.showLineNumbers,
            experienceMode: this.experienceMode,
            onReadAsset: (vaultId: string, relPath: string): string => {
              return this.readVaultAssetFor(vaultId, relPath);
            },
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
              if (!this.workspaceSessionRestoreStarted) {
                void this.initializeWorkspaceSession();
              } else if (this.workspaceInitialRenderReady) {
                void this.readRightAndPush(this.rightFilePath);
              }
            },
            onError: (msg: string): void => {
              hilog.error(DOMAIN, TAG, '右栏编辑器 Web 加载失败');
              this.handleInitialWorkspaceSurfaceError('right', 'edit');
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.experienceMode === 'professional' && this.rightEditing
              ? Visibility.Visible : Visibility.Hidden)
          PreviewWebView({
            bridge: this.rightPreviewBridge,
            editable: this.simplePreviewEditable('right'),
            // v1.30 30.5：该栏编辑聚焦时隐藏缩放控件，结束编辑恢复
            zoomControlsVisible: this.rightFilePath.length > 0 &&
              (this.experienceMode === 'simple' ? !this.rightSimpleTextFocus : !this.rightEditing),
            componentId: 'note-right-preview-web',
            onReadAsset: (relPath: string): string => { return this.readVaultAsset(relPath); },
            onScrollPositionChange: (top: number): void => {
              this.updateWorkspaceScroll('right', 'preview', top);
            },
            onReady: (): void => {
              if (!this.workspaceSessionRestoreStarted) {
                void this.initializeWorkspaceSession();
              }
            },
            onWikiLinkClick: (target: string): void => { void this.handleWikiLinkClick(target, 'right'); },
            onEditableContentChange: (content: string): void => {
              this.handleSimplePreviewEdit('right', content);
            },
            onCompositionChange: (composing: boolean): void => {
              this.onRightCompositionChange(composing);
            },
            onSimpleTextFocusChange: (focused: boolean): void => {
              this.setSimpleTextFocus('right', focused);
            },
            onCodeBlockEdit: (request: PreviewCodeEditRequest): void => {
              void this.handlePreviewCodeBlockEdit('right', request);
            },
            onTableActionMessage: (message: string): void => {
              promptAction.showToast({ message: message });
            },
            onCodeBlockEditingChange: (editing: boolean): void => {
              this.onCodeBlockEditingChange('right', editing);
            },
            onCopyCodeBlockContent: (content: string): void => {
              void this.copyCodeTextToPasteboard(content);
            },
            onCodeBlockCopyFailed: (): void => {
              promptAction.showToast({ message: '代码块已变化，未能复制' });
            },
            onSimpleFormatUnsupported: (): void => {
              promptAction.showToast({ message: '表格单元格仅支持加粗和斜体' });
            },
            onLockedContentTap: (anchor: PreviewBlockAnchor | null): void => {
              this.openBlockPropertyPanel('right', anchor);
            },
            onError: (msg: string): void => {
              hilog.error(DOMAIN, TAG, '右栏预览 Web 失败');
              this.recordBackgroundFailure('editor_preview', 'bridge', 'unknown', 'status_unknown', 'retry');
              this.handleInitialWorkspaceSurfaceError('right', 'preview');
            }
          })
            .width('100%')
            .height('100%')
            .visibility(this.experienceMode === 'simple' || !this.rightEditing
              ? Visibility.Visible : Visibility.Hidden)
        this.PreviewBlockPanel('right')
        this.PreviewBlockToolbar('right')
          if (this.rightFilePath.length === 0) {
            this.EmptyPane('right')
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.recordBlockToolbarPaneArea('right', newArea);
        })
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
      if (this.experienceMode === 'professional' && this.currentFilePath.length > 0) {
        this.PaneHead({ pane: 'left' })
      }
      this.PaneTitle({ pane: 'left' })
      // v1.32 32.2 / v1.46 46.9：专业模式停靠格式栏 —— 仅源码编辑时出现，停靠内容区顶部
      if (this.experienceMode === 'professional' && this.smMode === 'edit' &&
        this.currentFilePath.length > 0) {
        this.ProfFormatDock('left')
      }

      Stack({ alignContent: Alignment.Bottom }) {
        Stack() {
        // M0.5 spike：CodeMirror 6 跑在 Web 组件里（web/mdeditor → rawfile/mdeditor/index.html）。
        // 内容由本页在「选中文件 / 切库」时读好下发；组件本身不碰文件 IO（硬约束 14）。
        EditorWebView({
          bridge: this.editorBridge,
          showLineNumbers: this.showLineNumbers,
          experienceMode: this.experienceMode,
          onReadAsset: (vaultId: string, relPath: string): string => {
            return this.readVaultAssetFor(vaultId, relPath);
          },
          onChange: (len: number): void => {
            // 编辑中：记长度（观察击键是否过桥正常）+ 触发防抖自动保存（M2 2.3）
            this.resetSaveFeedback();
            WorkspaceEditGuard.mark('left', this.currentVaultId, this.currentFilePath);
            this.editorDirty = true;
            if (len !== this.editorLen) {
              this.editorLen = len;
            }
            this.scheduleSave();
            if (!this.leftCodePreviewEditing && !this.leftCodeEditPending) {
              this.schedulePreviewUpdate();
            }
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
            } else if (this.workspaceInitialRenderReady) {
              void this.readAndPush(this.currentFilePath, false);
            }
          },
          onError: (msg: string): void => {
            hilog.error(DOMAIN, TAG, '编辑器 Web 加载失败');
            this.handleInitialWorkspaceSurfaceError('left', 'edit');
          }
        })
          .width('100%')
          .height('100%')
          .visibility(this.experienceMode === 'professional' && this.smMode === 'edit'
            ? Visibility.Visible : Visibility.Hidden)

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
          this.EmptyPane('left')
        }
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
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
      if (this.experienceMode === 'professional' && this.currentFilePath.length > 0) {
        this.PaneHead({ pane: 'left' })
      }
      this.PaneTitle({ pane: 'left' })
      if (this.currentFilePath.length > 0 && this.backlinksExpanded && this.backlinksPane === 'left') {
        this.BacklinkPanel()
      }
      // v1.30 30.1/30.2 / v1.46 46.9：简单模式停靠格式栏 —— 仅编辑聚焦时出现，停靠内容区顶部
      if (this.experienceMode === 'simple' && this.currentFilePath.length > 0 &&
        this.simpleFormatBarVisible('left')) {
        this.SimpleFormatDock('left')
      }
      Stack() {
        PreviewWebView({
          bridge: this.previewBridge,
          editable: this.simplePreviewEditable('left'),
          // v1.30 30.5：该栏编辑聚焦时隐藏缩放控件，结束编辑恢复
          zoomControlsVisible: this.currentFilePath.length > 0 &&
            (this.experienceMode === 'simple' ? !this.leftSimpleTextFocus : this.smMode === 'preview'),
          componentId: 'note-left-preview-web',
          onReadAsset: (relPath: string): string => {
            return this.readVaultAsset(relPath);
          },
          onScrollPositionChange: (top: number): void => {
            this.updateWorkspaceScroll('left', 'preview', top);
          },
          onReady: (): void => {
            if (!this.workspaceSessionRestoreStarted) {
              void this.initializeWorkspaceSession();
            }
          },
          onWikiLinkClick: (target: string): void => {
            void this.handleWikiLinkClick(target);
          },
          onEditableContentChange: (content: string): void => {
            this.handleSimplePreviewEdit('left', content);
          },
          onCompositionChange: (composing: boolean): void => {
            this.onLeftCompositionChange(composing);
          },
          onSimpleTextFocusChange: (focused: boolean): void => {
            this.setSimpleTextFocus('left', focused);
          },
          onCodeBlockEdit: (request: PreviewCodeEditRequest): void => {
            void this.handlePreviewCodeBlockEdit('left', request);
          },
          onTableActionMessage: (message: string): void => {
            promptAction.showToast({ message: message });
          },
          onCodeBlockEditingChange: (editing: boolean): void => {
            this.onCodeBlockEditingChange('left', editing);
          },
          onCopyCodeBlockContent: (content: string): void => {
            void this.copyCodeTextToPasteboard(content);
          },
          onCodeBlockCopyFailed: (): void => {
            promptAction.showToast({ message: '代码块已变化，未能复制' });
          },
          onSimpleFormatUnsupported: (): void => {
            promptAction.showToast({ message: '表格单元格仅支持加粗和斜体' });
          },
          onLockedContentTap: (anchor: PreviewBlockAnchor | null): void => {
            this.openBlockPropertyPanel('left', anchor);
          },
          onError: (msg: string): void => {
            hilog.error(DOMAIN, TAG, '预览 Web 失败');
            this.recordBackgroundFailure('editor_preview', 'bridge', 'unknown', 'status_unknown', 'retry');
            this.handleInitialWorkspaceSurfaceError('left', 'preview');
          }
        })
          .width('100%')
          .height('100%')
        this.PreviewBlockPanel('left')
        this.PreviewBlockToolbar('left')
        if (this.currentFilePath.length === 0) {
          this.EmptyPane('left')
        }
      }
      .layoutWeight(1)
      .width('100%')
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.recordBlockToolbarPaneArea('left', newArea);
      })
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
      shareSummaries: this.vaultManagerShareSummaries,
      onSetCurrent: (id: string): void => {
        this.doSwitchVault(id);
      },
      onShare: (id: string, focusId: string): void => {
        this.openShareVaultFromManager(id, focusId);
      },
      onRename: (id: string): void => {
        this.openRenameDialog(id);
      },
      onDelete: (id: string): void => {
        this.openDeleteDialog(id);
      },
      onCreate: (): void => {
        this.openCreateDialog();
      },
      onImportVault: (): void => {
        void this.openImportVaultDialog('vault-manager-import-button');
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
      currentVaultNoteCount: this.currentVaultNoteCount,
      vaults: this.vaults,
      showLineNumbers: this.showLineNumbers,
      showXiaoyiDialogEntry: this.showXiaoyiDialogEntry,
      statsEnabled: this.statsEnabled,
      screenSaverIntervalMs: this.screenSaverIntervalMs,
      experienceMode: this.experienceMode,
      selectedCategory: this.settingsCategory,
      showCategoryList: this.isSingleScreenLayout() && !this.settingsDetail,
      showPrivacyPolicy: this.settingsPrivacyPolicyOpen,
      onSelectCategory: (category: string): void => {
        this.settingsCategory = category;
        if (category !== 'about') {
          this.settingsPrivacyPolicyOpen = false;
        }
        if (this.isSingleScreenLayout()) {
          this.settingsDetail = true;
        }
      },
      onOpenPrivacyPolicy: (): void => { this.settingsPrivacyPolicyOpen = true; },
      onClosePrivacyPolicy: (): void => { this.settingsPrivacyPolicyOpen = false; },
      onOpenHistory: (): void => { this.topView = 'history'; },
      onExportCurrentVault: (focusId: string): void => {
        this.openShareVaultFromManager(this.currentVaultId, focusId);
      },
      onResetSplit: (): void => { this.resetSplitLayout(); },
      onShowLineNumbersChange: (show: boolean): void => { this.setShowLineNumbers(show); },
      onShowXiaoyiDialogEntryChange: (show: boolean): void => { this.setShowXiaoyiDialogEntry(show); },
      onStatsEnabledChange: (enabled: boolean): void => { this.setStatsEnabled(enabled); },
      onScreenSaverIntervalChange: (ms: number): void => { this.setScreenSaverInterval(ms); },
      onExperienceModeChange: (mode: EditorExperienceMode): void => { void this.selectEditorExperience(mode); }
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
      onOpenStats: (): void => {
        void this.openVaultStats('agent', 'agent-stats-streak-chip');
      },
      statsStreakDays: this.vaultStatsModel.streakDays,
      statsTotalDays: this.vaultStatsModel.totalDays,
      statsScanning: this.vaultStatsScanning || this.vaultStatsFailed,
      statsWeekFlags: this.statsWeekFlags(),
      statsTodayIndex: this.statsTodayIndex(),
      statsEnabled: this.statsEnabled,
      onImportVault: (): void => { void this.openImportVaultDialog('vault-switcher-trigger'); },
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
      this.SaveFeedback()
      Blank()
      Text((this.activePane === 'right' ? this.rightEditorLen : Math.max(0, this.editorLen)).toString() + ' 字')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(0)
    }
    .width('100%')
    .height(Size.statusbarH)
    .padding({ left: Space.s3, right: Space.s3 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    // 57.7：整条 offset 压进底部手势条条带——边界线到 2152、条底贴物理下沿（2232）。
    // 键盘弹出时导航条避让高度动态归零（EntryAbility avoidAreaChange），offset 同步收回。
    .offset({ y: this.navClearanceVp() })
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
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
      }
      .opacity(this.saveFeedbackOpacity)
      .animation({ duration: Motion.durBase, curve: Curve.EaseInOut })
      .hitTestBehavior(HitTestMode.None)
    }
  }
}

