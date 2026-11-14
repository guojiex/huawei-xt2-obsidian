/**
 * 分享域子组件（v1.68 拆分，原 pages/Index.ets 分享族整体迁入，行为零变化）：
 * - 分享入口（笔记 / 文件夹 / 知识库）弹窗与各格式预览的编排；
 * - 长图 / PDF 隐藏捕获层（shareCapture*）与分段旧帧校验；
 * - 系统分享接收（v1.56 ShareIngest）保存确认层；
 * - 父组件（Index）经 onApiReady 持有 ShareFlowApi，原调用点转发到本组件。
 * 父级能力（布局宽度 / 编辑器桥 / 读库资产 / 库切换收尾等）以同名回调成员下行，
 * 迁入方法体保持与拆分前一致。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { EditorBridge } from './EditorWebView';
import { PreviewBridge, PreviewCaptureResult, PreviewWebView } from './PreviewWebView';
import { ShareFormatOption, ShareNoteDialog, ShareScopeOption } from './ShareNoteDialog';
import { ShareImagePreviewDialog, ShareImagePreviewImage } from './ShareImagePreviewDialog';
import { ShareFilePreviewDialog } from './ShareFilePreviewDialog';
import { ShareTextPreviewDialog } from './ShareTextPreviewDialog';
import { SaveShareDialog } from './SaveShareDialog';
import { FocusRequest } from '../common/FocusRequest';
import { noteDisplayName } from '../common/NoteDisplayName';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { ShareIngestDraft, ShareIngestPayload, ShareIngestService } from '../model/ShareIngestService';
import { SharePdfPreviewFlow, SharePdfPreviewRequest } from '../model/SharePdfPreviewFlow';
import { NoteShareService, PreparedNoteShare } from '../model/NoteShareService';
import { NoteImageShareGeometry, NoteImageShareService } from '../model/NoteImageShareService';
import { NotePdfDocumentService } from '../model/NotePdfDocumentService';
import { NoteTextSharePreview, NoteTextShareService } from '../model/NoteTextShareService';
import { NoteService } from '../model/NoteService';
import { PreparedArchiveShare, ShareArchiveService, ShareSnapshot } from '../model/ShareArchiveService';
import { ShareLinkScope, ShareLinkService } from '../model/ShareLinkService';
import { ShareImagePreferenceStore } from '../model/ShareImagePreferenceStore';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';

const DOMAIN: number = 0x0000;
const TAG: string = 'ShareFlowPanel';

/** 53.10：带旧帧校验的分段快照结果（快照本体 + 用于下一段比对的像素缓冲）。 */
interface ShareSegmentCapture {
  snapshot: image.PixelMap;
  buffer: ArrayBuffer;
}

/** 分享域对外 API（Index 经 onApiReady 回传持有；原 Index 内部直调入口全部经此转发）。 */
export interface ShareFlowApi {
  openShareNoteDialog: () => void;
  openSharePath: (relPath: string, isDir: boolean) => void;
  openShareVaultFromManager: (vaultId: string, focusId: string) => void;
  consumeIncomingShare: () => void;
}

@Component
export struct ShareFlowPanel {
  // ---- 父组件下行数据（Index 持真源） ----
  @Prop currentVaultId: string = '';
  @Prop topView: string = 'note';
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  // ---- 父能力回调（Index 持真源；与原 Index 方法同名，迁入方法体不变） ----
  onApiReady: (api: ShareFlowApi) => void = (_api: ShareFlowApi): void => {};
  activeFilePath: () => string = (): string => '';
  editorBridgeForPath: (path: string) => EditorBridge = (_path: string): EditorBridge => new EditorBridge();
  isSingleScreenLayout: () => boolean = (): boolean => false;
  activeSharePaneWidthVp: () => number = (): number => 0;
  shareLayoutWidthVp: (widthId: string, paneWidthVp: number) => number =
    (_widthId: string, paneWidthVp: number): number => paneWidthVp;
  readVaultAsset: (relPath: string) => string = (_relPath: string): string => '';
  saveShareNoteToVault: (vaultId: string, target: string) => Promise<boolean> =
    async (_vaultId: string, _target: string): Promise<boolean> => false;
  refreshVaultManagerShareSummaries: () => void = (): void => {};
  // ---- 对话框 controller（随迁，其 builder 闭包引用的状态一并同文件） ----
  private shareNoteCtl: CustomDialogController | null = null;
  private shareImagePreviewCtl: CustomDialogController | null = null;
  private shareFilePreviewCtl: CustomDialogController | null = null;
  private shareTextPreviewCtl: CustomDialogController | null = null;
  /** v1.56 56.3：接收系统分享的保存确认层 controller（每次拉起重建） */
  private saveShareCtl: CustomDialogController | null = null;
  /** 53.7：PDF 分页预览流程（会话状态与弹窗编排拆至 model/SharePdfPreviewFlow） */
  private sharePdfPreviewFlow: SharePdfPreviewFlow = new SharePdfPreviewFlow();
  private shareImagePreferenceStore: ShareImagePreferenceStore | null = null;
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
    this.ensureShareImagePreferenceStore();
    this.shareCaptureTheme = (this.shareImagePreferenceStore as ShareImagePreferenceStore).loadTheme();
    this.shareCaptureWidthId = (this.shareImagePreferenceStore as ShareImagePreferenceStore).loadWidth();
    // v1.56 56.4：冷启动分享——EntryAbility 的载荷可能早于页面挂载就已写进 AppStorage
    //（@Watch 不触发），这里兜底消费一次（原 Index aboutToAppear 的兜底随拆分迁入；
    // 子组件挂载先于任何用户交互，语义不变）。
    const raw: string = AppStorage.get<string>(ShareIngestService.STORAGE_KEY) ?? '';
    if (raw.length > 0) {
      setTimeout((): void => {
        this.consumeIncomingShare();
      }, 0);
    }
    const api: ShareFlowApi = {
      openShareNoteDialog: (): void => {
        this.openShareNoteDialog();
      },
      openSharePath: (relPath: string, isDir: boolean): void => {
        this.openSharePath(relPath, isDir);
      },
      openShareVaultFromManager: (vaultId: string, focusId: string): void => {
        this.openShareVaultFromManager(vaultId, focusId);
      },
      consumeIncomingShare: (): void => {
        this.consumeIncomingShare();
      }
    };
    this.onApiReady(api);
  }

  private ensureShareImagePreferenceStore(): void {
    if (this.shareImagePreferenceStore === null) {
      this.shareImagePreferenceStore = new ShareImagePreferenceStore(VaultRegistry.get().abilityContext());
    }
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
   * 2026-11-14 拆分：switchVault / 打开 / revealPath / 刷新树 / 收抽屉属父级工作区
   * 操作，收进 saveShareNoteToVault 回调（父持真源；@Prop 传播异步，切换成败不能
   * 在子组件读 currentVaultId 判定），回调返回 false = 库切换未完成。
   */
  private async saveSharedNote(vaultId: string, rawName: string, content: string): Promise<void> {
    const registry: VaultRegistry = VaultRegistry.get();
    const rel: string = NoteService.normalizeRelPath(rawName);
    if (rel.indexOf('/') >= 0) {
      throw new Error('保存位置固定在库根，标题不能包含 /');
    }
    const target: string = NoteService.previewCreatePath(registry, vaultId, rel);
    await NoteService.createNoteWithContent(registry, vaultId, target, content);
    const opened: boolean = await this.saveShareNoteToVault(vaultId, target);
    if (!opened) {
      promptAction.showToast({ message: '已保存到 ' + vaultId + '/' + target + '，但切换知识库未完成' });
      return;
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
      await new Promise<void>((resolve: () => void): void => {
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

  build() {
    // 长图捕获层：被父级不透明工作区完全遮住，挂载/卸载不再闪到笔记页；
    // 组件截图只截目标自身内容，遮住它的兄弟节点不会进入快照（见 api_notes.md）。
    if (this.shareCaptureActive) {
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
  }
}
