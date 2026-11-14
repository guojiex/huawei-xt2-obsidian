/**
 * BlockPropertyPanel —— 预览块属性面板（链接/双链/图片/公式/提示块/属性/脚注/块ID + 源码抽屉）。
 * 从 Index.ets 拆出（v1.7 重构）：内容状态与加载/保存流程在子组件内，
 * 打开/关闭、几何布局与 sheet 挂载留在 Index。
 */
import { promptAction } from '@kit.ArkUI';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { pasteboard } from '@kit.BasicServicesKit';
import { WorkspaceEditGuard } from '../model/WorkspaceEditGuard';
import { MarkdownImageParts, MarkdownInlineParser, MarkdownLinkParts } from '../model/MarkdownInlineParser';
import {
  CalloutSourceModel,
  FootnoteSourceModel,
  FootnoteSourceRange,
  FormulaSourceModel,
  FrontmatterPropertyModel,
  FrontmatterSourceModel,
  MarkdownComplexBlockEdit
} from '../model/MarkdownComplexBlockEdit';
import { WikiLinkParser, WikiLinkReference, WikiLinkResolution } from '../model/WikiLinkParser';
import { WikiLinkService } from '../model/WikiLinkService';
import { VaultRegistry } from '../model/VaultRegistry';
import { NoteShareService } from '../model/NoteShareService';
import { noteDisplayNameOfPath } from '../common/NoteDisplayName';
import { PreviewFollowAnchor } from '../model/PreviewFollowPolicy';
import { EditorBridge } from '../components/EditorWebView';
import {
  FormulaPreviewWeb,
  isSameBlockPanelTarget,
  PreviewBlockAnchor,
  PreviewBlockInlineItem,
  PreviewBridge
} from '../components/PreviewWebView';
import {
  RecentErrorCategory,
  RecentErrorNextStep,
  RecentErrorOperation,
  RecentErrorOutcome,
  RecentErrorPhase
} from '../model/RecentErrorStore';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { Icon } from '../common/Icons';

@Component
export struct BlockPropertyPanel {
  /** 本实例挂在哪一侧 sheet（left/right）；仅与 blockPanelPane 匹配的实例处理打开推送。 */
  sheetSide: string = 'left';
  // ---- 父组件下行（Index 持有真源） ----
  @Prop blockPanelPane: string = 'left';
  @Prop blockPanelSourceVaultId: string = '';
  @Prop blockPanelSourcePath: string = '';
  @Prop blockPanelMaxHeight: number = Size.menuMaxH;
  @Prop blockSourceEditing: boolean = false;
  @Prop currentVaultId: string = '';
  @Prop leftOpenRequestId: number = 0;
  @Prop rightOpenRequestId: number = 0;
  @Prop pushedAnchor: PreviewBlockAnchor | null = null;
  @Prop @Watch('onPushedAnchorSeqChange') pushedAnchorSeq: number = 0;
  @Prop pushedAnchorMode: string = 'open';
  // ---- 面板内容状态（本组件持有真源） ----
  @State blockPanelAnchor: PreviewBlockAnchor | null = null;
  @State blockPanelInlineItems: PreviewBlockInlineItem[] = [];
  @State tableInsertRowSide: string = 'down';
  @State tableInsertColumnSide: string = 'right';
  @State blockPanelLinkReady: boolean = false;
  @State blockPanelLinkLabel: string = '';
  @State blockPanelLinkDestination: string = '';
  @State blockPanelLinkParts: MarkdownLinkParts | null = null;
  @State blockPanelLinkMessage: string = '';
  private blockPanelLinkRaw: string = '';
  @State blockPanelWikiReady: boolean = false;
  @State blockPanelWikiTarget: string = '';
  @State blockPanelWikiAlias: string = '';
  @State blockPanelWikiMessage: string = '';
  @State blockPanelWikiFiles: string[] = [];
  @State blockPanelWikiResolutionStatus: string = '';
  @State blockPanelWikiResolutionPath: string = '';
  private blockPanelWikiRaw: string = '';
  @State blockPanelImageReady: boolean = false;
  @State blockPanelImageAlt: string = '';
  @State blockPanelImageDestination: string = '';
  @State blockPanelImageWidth: string = '';
  @State blockPanelImageMessage: string = '';
  private blockPanelImageRaw: string = '';
  private blockPanelImageParts: MarkdownImageParts | null = null;
  @State blockPanelFormulaReady: boolean = false;
  @State blockPanelFormulaValue: string = '';
  @State blockPanelFormulaMessage: string = '';
  private blockPanelFormulaRaw: string = '';
  private blockPanelFormulaModel: FormulaSourceModel | null = null;
  @State blockPanelCalloutReady: boolean = false;
  @State blockPanelCalloutTitle: string = '';
  @State blockPanelCalloutFold: string = '';
  @State blockPanelCalloutMessage: string = '';
  @State blockPanelCalloutSaving: boolean = false;
  private blockPanelCalloutRaw: string = '';
  private blockPanelCalloutModel: CalloutSourceModel | null = null;
  private blockPanelCalloutSaveTail: Promise<void> = Promise.resolve();
  @State blockPanelFrontmatterReady: boolean = false;
  @State blockPanelFrontmatterEntries: FrontmatterPropertyModel[] = [];
  @State blockPanelFrontmatterMessage: string = '';
  @State blockPanelFrontmatterNewKey: string = '';
  @State blockPanelFrontmatterNewValue: string = '';
  @State blockPanelFrontmatterDateKey: string = '';
  @State blockPanelFrontmatterDateDraft: string = '';
  @State blockPanelFrontmatterSaving: boolean = false;
  private blockPanelFrontmatterRaw: string = '';
  private blockPanelFrontmatterModel: FrontmatterSourceModel | null = null;
  private blockPanelFrontmatterSaveTail: Promise<void> = Promise.resolve();
  @State blockPanelFootnoteReady: boolean = false;
  @State blockPanelFootnoteEditable: boolean = false;
  @State blockPanelFootnoteHasDefinition: boolean = false;
  @State blockPanelFootnoteBody: string = '';
  @State blockPanelFootnoteMessage: string = '';
  @State blockPanelFootnoteSaving: boolean = false;
  @State blockPanelFootnoteJumpFrom: number = -1;
  private blockPanelFootnoteLabel: string = '';
  private blockPanelFootnoteSourceSnapshot: string = '';
  private blockPanelFootnoteDefinitionFrom: number = -1;
  private blockPanelFootnoteDefinitionTo: number = -1;
  private blockPanelFootnoteDefinitionRaw: string = '';
  private blockPanelFootnoteModel: FootnoteSourceModel | null = null;
  @State blockPanelBlockIdReady: boolean = false;
  @State blockPanelBlockId: string = '';
  @State blockPanelBlockIdMessage: string = '';
  @State blockPanelLanguagePickerOpen: boolean = false;
  @State blockSourceDraft: string = '';
  @State blockSourceBlockType: string = '';
  private blockSourceSnapshot: string = '';
  private blockSourceFrom: number = 0;
  private blockSourceTo: number = 0;
  private blockSourceDocumentRevision: number = 0;
  private blockSourceOpenRequestId: number = 0;
  // ---- 父组件上行回调 ----
  onCloseRequest: (restoreFocus: boolean) => void = (restoreFocus: boolean): void => {};
  onContentActionClose: () => void = (): void => {};
  onAnchorChange: (anchor: PreviewBlockAnchor) => void = (anchor: PreviewBlockAnchor): void => {};
  onTitleChange: (title: string) => void = (title: string): void => {};
  onSourceEditingChange: (editing: boolean) => void = (editing: boolean): void => {};
  onDirtyChange: (pane: string, dirty: boolean) => void = (pane: string, dirty: boolean): void => {};
  isDirty: (pane: string) => boolean = (pane: string): boolean => false;
  isCurrentTarget: (pane: string, vaultId: string, path: string, requestId: number, documentRevision: number) => boolean = (pane: string, vaultId: string, path: string, requestId: number, documentRevision: number): boolean => false;
  requestRelayout: (pane: string) => void = (pane: string): void => {};
  editorBridgeFor: (pane: string) => EditorBridge = (pane: string): EditorBridge => new EditorBridge();
  previewBridgeFor: (pane: string) => PreviewBridge = (pane: string): PreviewBridge => new PreviewBridge();
  scheduleSaveFor: (pane: string) => void = (pane: string): void => {};
  flushSimplePreview: () => Promise<string> = (): Promise<string> => Promise.resolve('');
  paneFileFor: (pane: string) => string = (pane: string): string => '';
  onResetSaveFeedback: () => void = (): void => {};
  recordFailure: (operation: RecentErrorOperation, phase: RecentErrorPhase, category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep, code?: number, message?: string) => void = (operation: RecentErrorOperation, phase: RecentErrorPhase, category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep, code?: number, message?: string): void => {};
  isImagePickerBusyFor: (pane: string) => boolean = (pane: string): boolean => false;
  pickImage: (pane: string, replaceSelectedImage: boolean, context: PanelImageReplaceContext | null) => void = (pane: string, replaceSelectedImage: boolean, context: PanelImageReplaceContext | null): void => {};
  applyTableOp: (pane: string, type: string, side: string) => void = (pane: string, type: string, side: string): void => {};
  openNoteInOtherPane: (relPath: string) => void = (relPath: string): void => {};
  // ---- 打开/合并推送处理 ----
  aboutToAppear(): void {
    this.handleAnchorPush();
  }

  private onPushedAnchorSeqChange(): void {
    this.handleAnchorPush();
  }

  private handleAnchorPush(): void {
    if (this.sheetSide !== this.blockPanelPane) {
      return;
    }
    const pushed: PreviewBlockAnchor | null = this.pushedAnchor;
    if (pushed === null) {
      return;
    }
    if (this.pushedAnchorMode === 'open') {
      this.applyOpenPush(pushed);
    } else {
      this.applyMergePush(pushed);
    }
  }

  private applyOpenPush(anchor: PreviewBlockAnchor): void {
    this.blockPanelAnchor = anchor;
    this.blockPanelInlineItems = anchor.inlineItems;
    this.blockPanelLinkReady = anchor.tapType !== 'link';
    this.blockPanelLinkLabel = '';
    this.blockPanelLinkDestination = '';
    this.blockPanelLinkParts = null;
    this.blockPanelLinkMessage = anchor.tapType === 'link' ? '正在读取链接…' : '';
    this.blockPanelLinkRaw = '';
    this.blockPanelWikiReady = false;
    this.blockPanelWikiTarget = '';
    this.blockPanelWikiAlias = '';
    this.blockPanelWikiMessage = anchor.tapType === 'wikilink' ? '正在读取双链…' : '';
    this.blockPanelWikiFiles = [];
    this.blockPanelWikiResolutionStatus = '';
    this.blockPanelWikiResolutionPath = '';
    this.blockPanelWikiRaw = '';
    this.blockPanelImageReady = false;
    this.blockPanelImageAlt = '';
    this.blockPanelImageDestination = '';
    this.blockPanelImageWidth = '';
    this.blockPanelImageMessage = anchor.tapType === 'image' ? '正在读取图片…' : '';
    this.blockPanelImageRaw = '';
    this.blockPanelImageParts = null;
    this.blockPanelFormulaReady = false;
    this.blockPanelFormulaValue = '';
    this.blockPanelFormulaMessage = anchor.tapType === 'mathInline' || anchor.type === 'formula'
      ? '正在读取公式…' : '';
    this.blockPanelFormulaRaw = '';
    this.blockPanelFormulaModel = null;
    this.blockPanelCalloutReady = false;
    this.blockPanelCalloutTitle = '';
    this.blockPanelCalloutFold = '';
    this.blockPanelCalloutMessage = anchor.type === 'callout' ? '正在读取提示块…' : '';
    this.blockPanelCalloutSaving = false;
    this.blockPanelCalloutRaw = '';
    this.blockPanelCalloutModel = null;
    this.blockPanelCalloutSaveTail = Promise.resolve();
    this.blockPanelFrontmatterReady = false;
    this.blockPanelFrontmatterEntries = [];
    this.blockPanelFrontmatterMessage = anchor.type === 'frontmatter' ? '正在读取属性…' : '';
    this.blockPanelFrontmatterNewKey = '';
    this.blockPanelFrontmatterNewValue = '';
    this.blockPanelFrontmatterDateKey = '';
    this.blockPanelFrontmatterDateDraft = '';
    this.blockPanelFrontmatterSaving = false;
    this.blockPanelFrontmatterRaw = '';
    this.blockPanelFrontmatterModel = null;
    this.blockPanelFrontmatterSaveTail = Promise.resolve();
    this.blockPanelFootnoteReady = false;
    this.blockPanelFootnoteEditable = false;
    this.blockPanelFootnoteHasDefinition = false;
    this.blockPanelFootnoteBody = '';
    this.blockPanelFootnoteMessage = anchor.tapType === 'footnoteRef' ||
      anchor.type === 'footnoteDefinition' ? '正在读取脚注…' : '';
    this.blockPanelFootnoteSaving = false;
    this.blockPanelFootnoteJumpFrom = -1;
    this.blockPanelFootnoteLabel = '';
    this.blockPanelFootnoteSourceSnapshot = '';
    this.blockPanelFootnoteDefinitionFrom = -1;
    this.blockPanelFootnoteDefinitionTo = -1;
    this.blockPanelFootnoteDefinitionRaw = '';
    this.blockPanelFootnoteModel = null;
    this.blockPanelBlockIdReady = false;
    this.blockPanelBlockId = '';
    this.blockPanelBlockIdMessage = '';
    this.blockPanelLanguagePickerOpen = false;
    this.blockSourceDraft = '';
    this.blockSourceBlockType = '';
    if (anchor.tapType === 'link') {
      void this.loadBlockPanelLink();
    } else if (anchor.tapType === 'wikilink') {
      void this.loadBlockPanelWikiLink();
    } else if (anchor.tapType === 'image') {
      void this.loadBlockPanelImage();
    } else if (anchor.tapType === 'mathInline' || anchor.type === 'formula') {
      void this.loadBlockPanelFormula();
    } else if (anchor.type === 'callout') {
      void this.loadBlockPanelCallout();
    } else if (anchor.type === 'frontmatter') {
      void this.loadBlockPanelFrontmatter();
    } else if (anchor.tapType === 'footnoteRef' || anchor.type === 'footnoteDefinition') {
      void this.loadBlockPanelFootnote();
    } else if (anchor.type === 'paragraph' && anchor.tapType === '' && anchor.inlineIndex < 0) {
      void this.loadBlockPanelBlockId();
    }
  }

  private applyMergePush(anchor: PreviewBlockAnchor): void {
    this.blockPanelAnchor = anchor;
    this.blockPanelInlineItems = anchor.inlineItems;
  }
  // ---- 父组件方法同名委托（搬运代码零改动） ----
  private closeBlockPropertyPanel(restoreFocus: boolean = true): void {
    this.onCloseRequest(restoreFocus);
  }

  private closeBlockPanelForContentAction(): void {
    this.onContentActionClose();
  }

  private isCurrentBlockSourceTarget(pane: string, vaultId: string, path: string, requestId: number,
    documentRevision: number): boolean {
    return this.isCurrentTarget(pane, vaultId, path, requestId, documentRevision);
  }

  private updateBlockPropertyPanelLayout(pane: string): void {
    if (this.blockPanelAnchor !== null) {
      this.onAnchorChange(this.blockPanelAnchor);
    }
    this.requestRelayout(pane);
  }

  private resetSaveFeedback(): void {
    this.onResetSaveFeedback();
  }

  private recordBackgroundFailure(operation: RecentErrorOperation, phase: RecentErrorPhase,
    category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep,
    code?: number, message?: string): void {
    this.recordFailure(operation, phase, category, outcome, nextStep, code, message);
  }

  private isImagePickerBusy(pane: string): boolean {
    return this.isImagePickerBusyFor(pane);
  }

  private pickImageForCurrentNote(pane: string, replaceSelectedImage: boolean = false): void {
    this.pickImage(pane, replaceSelectedImage, replaceSelectedImage ? this.imageReplaceContext() : null);
  }

  private applyTableStructureOperation(pane: string, type: string, side: string): void {
    this.applyTableOp(pane, type, side);
  }

  private flushSimplePreviewChanges(): Promise<string> {
    return this.flushSimplePreview();
  }

  private openFileInOtherPane(relPath: string): void {
    this.openNoteInOtherPane(relPath);
  }

  private paneFilePath(pane: string): string {
    return this.paneFileFor(pane);
  }

  private scheduleSave(): void {
    this.scheduleSaveFor('left');
  }

  private scheduleRightSave(): void {
    this.scheduleSaveFor('right');
  }

  private editorBridgeForPane(pane: string): EditorBridge {
    return this.editorBridgeFor(pane);
  }

  private previewBridgeForPane(pane: string): PreviewBridge {
    return this.previewBridgeFor(pane);
  }

  private blockPanelTitleFor(anchor: PreviewBlockAnchor): string {
    return blockPanelTitleFor(anchor);
  }

  private isSameBlockPanelTarget(current: PreviewBlockAnchor | null, expected: PreviewBlockAnchor): boolean {
    return isSameBlockPanelTarget(current, expected);
  }

  private imageReplaceContext(): PanelImageReplaceContext | null {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const parts: MarkdownImageParts | null = this.blockPanelImageParts;
    if (anchor === null || parts === null) {
      return null;
    }
    return {
      anchor: anchor,
      raw: this.blockPanelImageRaw,
      parts: parts,
      replaceInlineSource: (raw: string, replacement: string, failToast: string): Promise<boolean> =>
        this.replaceBlockPanelInlineSource(raw, replacement, failToast),
      onImageReplaced: (replacement: string): void => this.applyImageReplacement(replacement)
    };
  }

  private applyImageReplacement(replacement: string): void {
    this.blockPanelImageRaw = replacement;
    this.blockPanelImageParts = MarkdownInlineParser.parseImage(replacement);
    if (this.blockPanelImageParts !== null) {
      this.blockPanelImageAlt = this.blockPanelImageParts.alt;
      this.blockPanelImageDestination = this.blockPanelImageParts.destination;
      this.blockPanelImageWidth = this.blockPanelImageParts.width;
    }
  }

  private openBlockInlineItem(item: PreviewBlockInlineItem): void {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null || !this.blockPanelInlineItems.some((candidate: PreviewBlockInlineItem): boolean =>
      candidate.index === item.index && candidate.from === item.from && candidate.to === item.to &&
      candidate.type === item.type)) {
      return;
    }
    const itemAnchor: PreviewBlockAnchor = {
      type: anchor.type,
      tapType: item.type,
      from: anchor.from,
      to: anchor.to,
      inlineItems: this.blockPanelInlineItems,
      inlineSafe: anchor.inlineSafe,
      inlineIndex: item.index,
      itemFrom: item.from,
      itemTo: item.to,
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
    this.blockPanelAnchor = itemAnchor;
    this.onTitleChange(this.blockPanelTitleFor(itemAnchor));
    this.updateBlockPropertyPanelLayout(this.blockPanelPane);
    this.blockPanelLinkReady = itemAnchor.tapType !== 'link';
    this.blockPanelLinkLabel = '';
    this.blockPanelLinkDestination = '';
    this.blockPanelLinkParts = null;
    this.blockPanelLinkMessage = itemAnchor.tapType === 'link' ? '正在读取链接…' : '';
    this.blockPanelLinkRaw = '';
    this.blockPanelWikiReady = false;
    this.blockPanelWikiTarget = '';
    this.blockPanelWikiAlias = '';
    this.blockPanelWikiMessage = itemAnchor.tapType === 'wikilink' ? '正在读取双链…' : '';
    this.blockPanelWikiFiles = [];
    this.blockPanelWikiResolutionStatus = '';
    this.blockPanelWikiResolutionPath = '';
    this.blockPanelWikiRaw = '';
    this.blockPanelImageReady = false;
    this.blockPanelImageAlt = '';
    this.blockPanelImageDestination = '';
    this.blockPanelImageWidth = '';
    this.blockPanelImageMessage = itemAnchor.tapType === 'image' ? '正在读取图片…' : '';
    this.blockPanelImageRaw = '';
    this.blockPanelImageParts = null;
    this.blockPanelFormulaReady = false;
    this.blockPanelFormulaValue = '';
    this.blockPanelFormulaMessage = itemAnchor.tapType === 'mathInline' ? '正在读取公式…' : '';
    this.blockPanelFormulaRaw = '';
    this.blockPanelFormulaModel = null;
    this.blockPanelFootnoteReady = false;
    this.blockPanelFootnoteEditable = false;
    this.blockPanelFootnoteHasDefinition = false;
    this.blockPanelFootnoteBody = '';
    this.blockPanelFootnoteMessage = itemAnchor.tapType === 'footnoteRef' ? '正在读取脚注…' : '';
    this.blockPanelFootnoteSaving = false;
    this.blockPanelFootnoteJumpFrom = -1;
    this.blockPanelFootnoteLabel = '';
    this.blockPanelFootnoteSourceSnapshot = '';
    this.blockPanelFootnoteDefinitionFrom = -1;
    this.blockPanelFootnoteDefinitionTo = -1;
    this.blockPanelFootnoteDefinitionRaw = '';
    this.blockPanelFootnoteModel = null;
    if (itemAnchor.tapType === 'link') {
      void this.loadBlockPanelLink();
    } else if (itemAnchor.tapType === 'wikilink') {
      void this.loadBlockPanelWikiLink();
    } else if (itemAnchor.tapType === 'image') {
      void this.loadBlockPanelImage();
    } else if (itemAnchor.tapType === 'mathInline') {
      void this.loadBlockPanelFormula();
    } else if (itemAnchor.tapType === 'footnoteRef') {
      void this.loadBlockPanelFootnote();
    }
  }

  private codeLanguageLabel(language: string): string {
    return language.length > 0 ? language : '纯文本';
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

  private async readBlockPanelParagraphSource(anchor: PreviewBlockAnchor): Promise<string | null> {
    if (anchor.type !== 'paragraph' || anchor.tapType !== '' || anchor.inlineIndex >= 0) {
      return null;
    }
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    try {
      const flushError: string = await this.flushSimplePreviewChanges();
      if (flushError.length > 0) {
        return null;
      }
      const bridge: EditorBridge = this.editorBridgeForPane(pane);
      const documentRevision: number = bridge.currentDocumentRevision;
      if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, documentRevision) ||
        !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
        this.blockPanelAnchor?.type !== 'paragraph') {
        return null;
      }
      const source: string = await bridge.getContent();
      if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, documentRevision) ||
        !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
        this.blockPanelAnchor?.type !== 'paragraph' ||
        !Number.isInteger(anchor.from) || !Number.isInteger(anchor.to) ||
        anchor.from < 0 || anchor.to <= anchor.from || anchor.to > source.length) {
        return null;
      }
      return source.slice(anchor.from, anchor.to);
    } catch {
      return null;
    }
  }

  private async loadBlockPanelBlockId(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null || anchor.type !== 'paragraph' || anchor.tapType !== '' || anchor.inlineIndex >= 0) {
      return;
    }
    this.blockPanelBlockIdReady = false;
    this.blockPanelBlockId = '';
    this.blockPanelBlockIdMessage = '正在读取块 ID…';
    const raw: string | null = await this.readBlockPanelParagraphSource(anchor);
    if (!this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
      this.blockPanelAnchor?.type !== 'paragraph') {
      return;
    }
    if (raw === null) {
      this.blockPanelBlockIdMessage = '无法读取本段，请重新打开面板';
      return;
    }
    this.blockPanelBlockId = MarkdownComplexBlockEdit.parseBlockId(raw) ?? '';
    this.blockPanelBlockIdReady = true;
    this.blockPanelBlockIdMessage = '';
  }

  private async copyBlockLink(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null) {
      return;
    }
    const raw: string | null = await this.readBlockPanelParagraphSource(anchor);
    if (raw === null) {
      promptAction.showToast({ message: '无法读取本段，请重新打开面板' });
      return;
    }
    const blockId: string | null = MarkdownComplexBlockEdit.parseBlockId(raw);
    this.blockPanelBlockId = blockId ?? '';
    this.blockPanelBlockIdReady = true;
    this.blockPanelBlockIdMessage = '';
    if (blockId === null) {
      promptAction.showToast({ message: '本段尚无块 ID，请先生成 ID' });
      return;
    }
    await this.copyTextToPasteboard(`[[#^${blockId}]]`, '块链接');
  }

  private copyCodeBlockFromPanel(): void {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null || anchor.type !== 'code') {
      return;
    }
    this.previewBridgeForPane(this.blockPanelPane).copyCodeBlock(anchor.from, anchor.to);
  }

  private async changeBlockCodeLanguage(language: string): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.type !== 'code' || !anchor.codeEditable || !anchor.codeLanguageSelectable ||
      anchor.codeLanguages.indexOf(language) < 0 ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    this.blockPanelLanguagePickerOpen = false;
    if (language === anchor.codeLanguage) {
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      promptAction.showToast({ message: '无法同步当前笔记，未修改代码语言' });
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null ||
      latestAnchor.type !== 'code' || !latestAnchor.codeLanguageSelectable) {
      promptAction.showToast({ message: '代码块已变化，请重新打开面板' });
      return;
    }
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      promptAction.showToast({ message: '读取代码语言失败；笔记未修改。请关闭面板后重新打开再试。' });
      return;
    }
    const from: number = latestAnchor.codeLanguageFrom;
    const to: number = latestAnchor.codeLanguageTo;
    const expected: string = latestAnchor.codeLanguage;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) || from < latestAnchor.from ||
      to < from || to > latestAnchor.to || source.slice(from, to) !== expected) {
      promptAction.showToast({ message: '代码块已变化，请重新打开面板' });
      return;
    }

    const wasDirty: boolean = this.isDirty(pane);
    const wasUnsaved: boolean = WorkspaceEditGuard.isUnsaved(vaultId, path);
    WorkspaceEditGuard.mark(pane, vaultId, path);
    this.onDirtyChange(pane, true);
    let applied: boolean = false;
    try {
      applied = await editor.replaceBlockSource(from, to, expected, language, revision);
    } catch {
      promptAction.showToast({ message: '代码语言修改未完成；当前源码仍保留。请重新打开面板后重试。' });
    }
    if (!applied) {
      if (!wasDirty && !wasUnsaved &&
        this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision)) {
        WorkspaceEditGuard.clear(pane, vaultId, path);
        this.onDirtyChange(pane, false);
      }
      promptAction.showToast({ message: '代码块已变化，未修改语言' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    if (pane === 'right') {
      this.scheduleRightSave();
    } else {
      this.scheduleSave();
    }
    this.blockPanelAnchor = {
      type: latestAnchor.type,
      tapType: latestAnchor.tapType,
      from: latestAnchor.from,
      to: latestAnchor.to + language.length - expected.length,
      inlineItems: latestAnchor.inlineItems,
      inlineSafe: latestAnchor.inlineSafe,
      inlineIndex: latestAnchor.inlineIndex,
      itemFrom: latestAnchor.itemFrom,
      itemTo: latestAnchor.itemTo,
      codeLanguage: language,
      codeLanguageFrom: from,
      codeLanguageTo: from + language.length,
      codeLanguageSelectable: true,
      codeLanguages: latestAnchor.codeLanguages,
      codeEditable: latestAnchor.codeEditable,
      tableRow: latestAnchor.tableRow,
      tableColumn: latestAnchor.tableColumn,
      tableRows: latestAnchor.tableRows,
      tableColumns: latestAnchor.tableColumns,
      tableStructureEditable: latestAnchor.tableStructureEditable,
      x: latestAnchor.x,
      y: latestAnchor.y,
      width: latestAnchor.width,
      height: latestAnchor.height
    };
    this.updateBlockPropertyPanelLayout(pane);
  }

  private blockPanelInlineItemLabel(item: PreviewBlockInlineItem): string {
    let ordinal: number = 0;
    for (const candidate of this.blockPanelInlineItems) {
      if (candidate.type === item.type) {
        ordinal++;
      }
      if (candidate.index === item.index) {
        break;
      }
    }
    let label: string = '链接';
    if (item.type === 'image') {
      label = '图片';
    } else if (item.type === 'inlinecode') {
      label = '行内代码';
    } else if (item.type === 'mathInline') {
      label = '行内公式';
    } else if (item.type === 'wikilink') {
      label = '双链';
    }
    return `${label} ${ordinal}`;
  }

  private async loadBlockPanelFormula(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || (anchor.tapType !== 'mathInline' && anchor.type !== 'formula') ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelFormulaMessage = '无法同步当前笔记，请关闭面板后重试';
      this.blockPanelFormulaReady = true;
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelFormulaMessage = '读取公式失败，请关闭面板后重试';
      this.blockPanelFormulaReady = true;
      return;
    }
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null) {
      return;
    }
    const inline: boolean = latestAnchor.tapType === 'mathInline';
    const from: number = inline ? latestAnchor.itemFrom : latestAnchor.from;
    const to: number = inline ? latestAnchor.itemTo : latestAnchor.to;
    if (from < latestAnchor.from || to > latestAnchor.to || to <= from || to > source.length) {
      this.blockPanelFormulaMessage = '公式范围无效，请以源码编辑此项';
      this.blockPanelFormulaReady = true;
      return;
    }
    const raw: string = source.slice(from, to);
    const model: FormulaSourceModel | null = MarkdownComplexBlockEdit.parseFormula(raw, inline);
    if (model === null) {
      this.blockPanelFormulaMessage = '此公式写法暂不支持结构化编辑';
      this.blockPanelFormulaReady = true;
      return;
    }
    this.blockPanelFormulaRaw = raw;
    this.blockPanelFormulaModel = model;
    this.blockPanelFormulaValue = model.expression;
    this.blockPanelFormulaMessage = '';
    this.blockPanelFormulaReady = true;
  }

  private async saveBlockPanelFormula(): Promise<void> {
    const model: FormulaSourceModel | null = this.blockPanelFormulaModel;
    if (!this.blockPanelFormulaReady || model === null || this.blockPanelFormulaRaw.length === 0) {
      return;
    }
    const replacement: string | null = MarkdownComplexBlockEdit.serializeFormula(
      model, this.blockPanelFormulaValue);
    if (replacement === null) {
      this.blockPanelFormulaMessage = model.inline && this.blockPanelFormulaValue.includes('$')
        ? '行内公式不能包含 $' : '公式不能为空';
      return;
    }
    if (!await this.replaceBlockPanelInlineSource(
      this.blockPanelFormulaRaw, replacement, '修改公式失败，请重试')) {
      this.blockPanelFormulaMessage = '公式已变化或保存失败，请重新打开面板';
      return;
    }
    this.blockPanelFormulaRaw = replacement;
    this.blockPanelFormulaModel = MarkdownComplexBlockEdit.parseFormula(replacement, model.inline);
    this.blockPanelFormulaMessage = '';
  }

  private async loadBlockPanelFootnote(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    this.blockPanelFootnoteReady = false;
    this.blockPanelFootnoteEditable = false;
    this.blockPanelFootnoteHasDefinition = false;
    this.blockPanelFootnoteJumpFrom = -1;
    if (anchor === null || (anchor.tapType !== 'footnoteRef' && anchor.type !== 'footnoteDefinition') ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelFootnoteReady = true;
      this.blockPanelFootnoteMessage = '脚注已变化，请重新打开面板';
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelFootnoteReady = true;
      this.blockPanelFootnoteMessage = '无法同步当前笔记，请关闭面板后重试';
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelFootnoteReady = true;
      this.blockPanelFootnoteMessage = '读取脚注失败，请关闭面板后重试';
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor)) {
      return;
    }

    let label: string | null = null;
    if (anchor.tapType === 'footnoteRef') {
      if (anchor.itemFrom >= anchor.from && anchor.itemTo <= anchor.to &&
        anchor.itemTo <= source.length) {
        label = MarkdownComplexBlockEdit.parseFootnoteReference(
          source.slice(anchor.itemFrom, anchor.itemTo));
      }
    } else {
      const definitions: FootnoteSourceRange[] = MarkdownComplexBlockEdit.findFootnoteDefinitions(source, '');
      for (const definition of definitions) {
        if (definition.from === anchor.from) {
          label = definition.label;
          break;
        }
      }
    }
    if (label === null) {
      this.blockPanelFootnoteReady = true;
      this.blockPanelFootnoteMessage = '脚注范围无效，请以源码编辑';
      return;
    }

    const definitions: FootnoteSourceRange[] =
      MarkdownComplexBlockEdit.findFootnoteDefinitions(source, label);
    this.blockPanelFootnoteLabel = label;
    this.blockPanelFootnoteSourceSnapshot = source;
    this.blockPanelFootnoteReady = true;
    this.blockPanelFootnoteHasDefinition = definitions.length > 0;
    if (definitions.length > 1) {
      this.blockPanelFootnoteMessage = '存在多个同名定义，无法安全编辑，请以源码编辑';
      return;
    }
    if (definitions.length === 0) {
      if (anchor.tapType !== 'footnoteRef') {
        this.blockPanelFootnoteMessage = '脚注定义无法解析，请以源码编辑';
        return;
      }
      this.blockPanelFootnoteEditable = true;
      this.blockPanelFootnoteBody = '';
      this.blockPanelFootnoteMessage = '当前引用缺少定义；应用正文时会在文末创建定义';
      return;
    }

    const definition: FootnoteSourceRange = definitions[0];
    const model: FootnoteSourceModel | null =
      MarkdownComplexBlockEdit.parseFootnoteDefinition(definition.source);
    if (model === null) {
      this.blockPanelFootnoteMessage = '此脚注定义写法暂不支持结构化编辑，请以源码编辑';
      return;
    }
    this.blockPanelFootnoteEditable = true;
    this.blockPanelFootnoteBody = model.body;
    this.blockPanelFootnoteDefinitionFrom = definition.from;
    this.blockPanelFootnoteDefinitionTo = definition.to;
    this.blockPanelFootnoteDefinitionRaw = definition.source;
    this.blockPanelFootnoteModel = model;
    if (anchor.tapType === 'footnoteRef') {
      this.blockPanelFootnoteJumpFrom = definition.from;
    } else {
      const reference: FootnoteSourceRange | null =
        MarkdownComplexBlockEdit.findFootnoteReference(source, label);
      this.blockPanelFootnoteJumpFrom = reference === null ? -1 : reference.from;
    }
    this.blockPanelFootnoteMessage = '';
  }

  private async saveBlockPanelFootnote(): Promise<void> {
    if (!this.blockPanelFootnoteReady || !this.blockPanelFootnoteEditable ||
      this.blockPanelFootnoteSaving) {
      return;
    }
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    let replacement: string | null = null;
    let from: number = this.blockPanelFootnoteDefinitionFrom;
    let to: number = this.blockPanelFootnoteDefinitionTo;
    let expectedSource: string = this.blockPanelFootnoteDefinitionRaw;
    let appendedPrefix: string = '';
    if (this.blockPanelFootnoteHasDefinition) {
      const model: FootnoteSourceModel | null = this.blockPanelFootnoteModel;
      if (model === null) {
        this.blockPanelFootnoteMessage = '脚注定义无法解析，请以源码编辑';
        return;
      }
      replacement = MarkdownComplexBlockEdit.serializeFootnoteDefinition(model, this.blockPanelFootnoteBody);
    } else {
      const source: string = this.blockPanelFootnoteSourceSnapshot;
      const lineEnding: string = MarkdownComplexBlockEdit.sourceLineEnding(source);
      appendedPrefix = source.length === 0 ? '' : source.endsWith(lineEnding + lineEnding)
        ? '' : source.endsWith(lineEnding) ? lineEnding : lineEnding + lineEnding;
      const definition: string | null = MarkdownComplexBlockEdit.createFootnoteDefinition(
        this.blockPanelFootnoteLabel, this.blockPanelFootnoteBody, lineEnding, lineEnding);
      replacement = definition === null ? null : appendedPrefix + definition;
      from = source.length;
      to = source.length;
      expectedSource = '';
    }
    if (replacement === null) {
      this.blockPanelFootnoteMessage = this.blockPanelFootnoteBody.trim().length === 0
        ? '脚注正文不能为空' : '脚注正文格式暂不支持';
      return;
    }
    this.blockPanelFootnoteSaving = true;
    try {
      const flushError: string = await this.flushSimplePreviewChanges();
      if (flushError.length > 0) {
        this.blockPanelFootnoteMessage = '无法同步当前笔记，未修改脚注';
        return;
      }
      const revision: number = editor.currentDocumentRevision;
      let source: string = '';
      try {
        source = await editor.getContent();
      } catch {
        this.blockPanelFootnoteMessage = '读取当前笔记失败，未修改脚注';
        return;
      }
      if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
        !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
        source !== this.blockPanelFootnoteSourceSnapshot ||
        from < 0 || to < from || to > source.length || source.slice(from, to) !== expectedSource) {
        this.blockPanelFootnoteMessage = '笔记内容已变化，未修改脚注；请重新打开面板';
        return;
      }
      if (replacement === expectedSource) {
        this.blockPanelFootnoteMessage = '';
        return;
      }

      const wasDirty: boolean = this.isDirty(pane);
      const wasUnsaved: boolean = WorkspaceEditGuard.isUnsaved(vaultId, path);
      WorkspaceEditGuard.mark(pane, vaultId, path);
      this.onDirtyChange(pane, true);
      let applied: boolean = false;
      try {
        applied = await editor.replaceBlockSource(from, to, expectedSource, replacement, revision, 'input', false);
      } catch {}
      if (!applied) {
        if (!wasDirty && !wasUnsaved &&
          this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision)) {
          WorkspaceEditGuard.clear(pane, vaultId, path);
          this.onDirtyChange(pane, false);
        }
        this.blockPanelFootnoteMessage = '脚注已变化或保存失败，未修改内容';
        return;
      }
      if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
        return;
      }
      const updatedSource: string = source.slice(0, from) + replacement + source.slice(to);
      this.blockPanelFootnoteSourceSnapshot = updatedSource;
      this.blockPanelFootnoteHasDefinition = true;
      if (expectedSource.length === 0) {
        this.blockPanelFootnoteDefinitionFrom = from + appendedPrefix.length;
        this.blockPanelFootnoteDefinitionTo = this.blockPanelFootnoteDefinitionFrom + replacement.length - appendedPrefix.length;
        this.blockPanelFootnoteDefinitionRaw = replacement.slice(appendedPrefix.length);
      } else {
        this.blockPanelFootnoteDefinitionTo = from + replacement.length;
        this.blockPanelFootnoteDefinitionRaw = replacement;
      }
      this.blockPanelFootnoteModel = MarkdownComplexBlockEdit.parseFootnoteDefinition(
        this.blockPanelFootnoteDefinitionRaw);
      this.blockPanelFootnoteJumpFrom = this.blockPanelAnchor?.tapType === 'footnoteRef'
        ? this.blockPanelFootnoteDefinitionFrom
        : MarkdownComplexBlockEdit.findFootnoteReference(updatedSource, this.blockPanelFootnoteLabel)?.from ?? -1;
      this.blockPanelFootnoteMessage = '';
      if (pane === 'right') {
        this.scheduleRightSave();
      } else {
        this.scheduleSave();
      }
    } finally {
      this.blockPanelFootnoteSaving = false;
    }
  }

  private async jumpBlockPanelFootnote(): Promise<void> {
    const from: number = this.blockPanelFootnoteJumpFrom;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (from < 0 || !this.isCurrentBlockSourceTarget(
      pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelFootnoteMessage = '无法同步当前笔记，暂时不能跳转';
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelFootnoteMessage = '读取当前笔记失败，暂时不能跳转';
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      source !== this.blockPanelFootnoteSourceSnapshot || from > source.length) {
      this.blockPanelFootnoteMessage = '笔记内容已变化，请重新打开面板后跳转';
      return;
    }
    let line: number = 1;
    for (let index = 0; index < from; index++) {
      if (source[index] === '\n') {
        line++;
      }
    }
    const target: PreviewFollowAnchor = {
      line, lineProgress: 0, viewportRatio: 0.2, atStart: false, atEnd: false
    };
    this.previewBridgeForPane(pane).scrollToSourceLine(target);
  }

  private async loadBlockPanelFrontmatter(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.type !== 'frontmatter' || anchor.from !== 0 ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelFrontmatterReady = true;
      this.blockPanelFrontmatterMessage = '属性区间已变化，请重新打开面板';
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelFrontmatterReady = true;
      this.blockPanelFrontmatterMessage = '无法同步当前笔记，请关闭面板后重试';
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelFrontmatterReady = true;
      this.blockPanelFrontmatterMessage = '读取属性失败，请关闭面板后重试';
      return;
    }
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null ||
      latestAnchor.from !== 0 || latestAnchor.to <= 0 || latestAnchor.to > source.length) {
      this.blockPanelFrontmatterReady = true;
      this.blockPanelFrontmatterMessage = '属性区间已变化，请重新打开面板';
      return;
    }
    const raw: string = source.slice(latestAnchor.from, latestAnchor.to);
    const model: FrontmatterSourceModel | null = MarkdownComplexBlockEdit.parseFrontmatter(raw);
    this.blockPanelFrontmatterRaw = raw;
    this.blockPanelFrontmatterModel = model;
    this.blockPanelFrontmatterReady = true;
    this.blockPanelFrontmatterMessage = model === null
      ? '文档头不是可安全编辑的 YAML，请以源码编辑' : '';
    this.blockPanelFrontmatterEntries = model === null ? [] : model.properties;
  }

  private saveBlockPanelFrontmatterProperty(
    action: string, key: string, value: string
  ): Promise<boolean> {
    const task: Promise<boolean> = this.blockPanelFrontmatterSaveTail.then(async (): Promise<boolean> => {
      return await this.applyBlockPanelFrontmatterProperty(action, key, value);
    });
    this.blockPanelFrontmatterSaveTail = task.then((): void => {}, (): void => {});
    return task;
  }

  private async applyBlockPanelFrontmatterProperty(
    action: string, key: string, value: string
  ): Promise<boolean> {
    if (!this.blockPanelFrontmatterReady || this.blockPanelFrontmatterModel === null ||
      this.blockPanelFrontmatterSaving) {
      return false;
    }
    let replacement: string | null = null;
    if (action === 'set') {
      replacement = MarkdownComplexBlockEdit.setFrontmatterProperty(
        this.blockPanelFrontmatterRaw, key, value);
    } else if (action === 'remove') {
      replacement = MarkdownComplexBlockEdit.removeFrontmatterProperty(
        this.blockPanelFrontmatterRaw, key);
    } else if (action === 'add') {
      replacement = MarkdownComplexBlockEdit.addFrontmatterProperty(
        this.blockPanelFrontmatterRaw, key, value);
    }
    if (replacement === null) {
      this.blockPanelFrontmatterMessage = action === 'add'
        ? '属性名无效或已存在，值无法安全写入'
        : '属性已变化或值无效，未修改';
      return false;
    }
    if (replacement === this.blockPanelFrontmatterRaw) {
      this.blockPanelFrontmatterMessage = '';
      return true;
    }

    this.blockPanelFrontmatterSaving = true;
    try {
      if (!await this.replaceBlockPanelInlineSource(
        this.blockPanelFrontmatterRaw, replacement, '修改属性失败，请重试')) {
        this.blockPanelFrontmatterMessage = '属性已变化或保存失败，请重新打开面板';
        return false;
      }
      const model: FrontmatterSourceModel | null = MarkdownComplexBlockEdit.parseFrontmatter(replacement);
      if (model === null) {
        this.blockPanelFrontmatterModel = null;
        this.blockPanelFrontmatterEntries = [];
        this.blockPanelFrontmatterMessage = '属性写回后无法解析，请以源码编辑';
        return false;
      }
      this.blockPanelFrontmatterRaw = replacement;
      this.blockPanelFrontmatterModel = model;
      this.blockPanelFrontmatterEntries = model.properties;
      this.blockPanelFrontmatterMessage = '';
      this.blockPanelFrontmatterDateKey = '';
      if (action === 'add') {
        this.blockPanelFrontmatterNewKey = '';
        this.blockPanelFrontmatterNewValue = '';
      }
      return true;
    } finally {
      this.blockPanelFrontmatterSaving = false;
    }
  }

  private updateBlockPanelFrontmatterDraft(key: string, value: string): void {
    const entries: FrontmatterPropertyModel[] = [];
    for (const entry of this.blockPanelFrontmatterEntries) {
      if (entry.key === key) {
        entry.text = value;
      }
      entries.push(entry);
    }
    this.blockPanelFrontmatterEntries = entries;
  }

  private blockPanelFrontmatterDate(): Date {
    const parts: RegExpExecArray | null =
      /^(\d{4})-(\d{2})-(\d{2})$/.exec(this.blockPanelFrontmatterDateDraft);
    if (parts === null) {
      return new Date();
    }
    return new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]));
  }

  private blockPanelFrontmatterDateSelectable(value: string): boolean {
    const parts: RegExpExecArray | null = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (parts === null) {
      return false;
    }
    const date: number = Number(parts[1]) * 10000 + Number(parts[2]) * 100 + Number(parts[3]);
    return date >= 19000131 && date <= 21001231;
  }

  private beginBlockPanelFrontmatterDate(key: string): void {
    for (const entry of this.blockPanelFrontmatterEntries) {
      if (entry.key !== key) {
        continue;
      }
      if (!this.blockPanelFrontmatterDateSelectable(entry.text)) {
        this.blockPanelFrontmatterMessage = '该日期超出系统选择范围，请以源码编辑';
        return;
      }
      this.blockPanelFrontmatterDateKey = key;
      this.blockPanelFrontmatterDateDraft = entry.text;
      this.blockPanelFrontmatterMessage = '';
      return;
    }
  }

  private cancelBlockPanelFrontmatterDate(): void {
    this.blockPanelFrontmatterDateKey = '';
    this.blockPanelFrontmatterDateDraft = '';
  }

  private blockPanelFrontmatterDateValue(value: Date): string {
    const year: string = String(value.getFullYear());
    const month: string = String(value.getMonth() + 1).padStart(2, '0');
    const day: string = String(value.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }

  private async finishBlockPanelFrontmatterDate(): Promise<void> {
    const key: string = this.blockPanelFrontmatterDateKey;
    if (key.length === 0) {
      return;
    }
    if (await this.saveBlockPanelFrontmatterProperty('set', key, this.blockPanelFrontmatterDateDraft)) {
      this.cancelBlockPanelFrontmatterDate();
    }
  }

  private blockPanelCalloutTypeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    const model: CalloutSourceModel | null = this.blockPanelCalloutModel;
    const types: string[] = MarkdownComplexBlockEdit.calloutTypes();
    const labels: string[] = MarkdownComplexBlockEdit.calloutLabels();
    if (model !== null && !types.includes(model.type)) {
      options.push({ value: `保留：${model.type}` });
    }
    for (let index = 0; index < types.length; index++) {
      options.push({ value: labels[index] });
    }
    return options;
  }

  private blockPanelCalloutTypeIndex(): number {
    const model: CalloutSourceModel | null = this.blockPanelCalloutModel;
    if (model === null) {
      return -1;
    }
    const types: string[] = MarkdownComplexBlockEdit.calloutTypes();
    const index: number = types.indexOf(model.type);
    return index < 0 ? 0 : index + (types.includes(model.type) ? 0 : 1);
  }

  private blockPanelCalloutTypeValue(): string {
    const options: SelectOption[] = this.blockPanelCalloutTypeOptions();
    const index: number = this.blockPanelCalloutTypeIndex();
    return index >= 0 && index < options.length ? options[index].value as string : '';
  }

  private blockPanelCalloutFoldOptions(): SelectOption[] {
    return [{ value: '不折叠' }, { value: '默认展开' }, { value: '默认收起' }];
  }

  private blockPanelCalloutFoldValue(): string {
    const options: SelectOption[] = this.blockPanelCalloutFoldOptions();
    return options[this.blockPanelCalloutFoldIndex()].value as string;
  }

  private blockPanelCalloutFoldIndex(): number {
    if (this.blockPanelCalloutFold === '+') {
      return 1;
    }
    return this.blockPanelCalloutFold === '-' ? 2 : 0;
  }

  private async saveBlockPanelCalloutType(index: number): Promise<void> {
    const model: CalloutSourceModel | null = this.blockPanelCalloutModel;
    const types: string[] = MarkdownComplexBlockEdit.calloutTypes();
    const offset: number = model !== null && !types.includes(model.type) ? 1 : 0;
    if (model === null || index < 0 || index >= types.length + offset) {
      return;
    }
    if (this.blockPanelCalloutTitle !== model.title) {
      if (!await this.saveBlockPanelCalloutField('title', this.blockPanelCalloutTitle)) {
        return;
      }
    }
    const latest: CalloutSourceModel | null = this.blockPanelCalloutModel;
    const type: string = offset > 0 && index === 0 ? latest?.type ?? '' : types[index - offset];
    if (type.length > 0) {
      await this.saveBlockPanelCalloutField('type', type);
    }
  }

  private async saveBlockPanelCalloutFold(index: number): Promise<void> {
    if (this.blockPanelCalloutModel === null || index < 0 || index > 2) {
      return;
    }
    if (this.blockPanelCalloutTitle !== this.blockPanelCalloutModel.title) {
      if (!await this.saveBlockPanelCalloutField('title', this.blockPanelCalloutTitle)) {
        return;
      }
    }
    await this.saveBlockPanelCalloutField('fold', index === 1 ? '+' : index === 2 ? '-' : '');
  }

  private saveBlockPanelCalloutField(field: string, value: string): Promise<boolean> {
    const task: Promise<boolean> = this.blockPanelCalloutSaveTail.then(async (): Promise<boolean> => {
      return await this.applyBlockPanelCalloutField(field, value);
    });
    this.blockPanelCalloutSaveTail = task.then((): void => {}, (): void => {});
    return task;
  }

  private async applyBlockPanelCalloutField(field: string, value: string): Promise<boolean> {
    const model: CalloutSourceModel | null = this.blockPanelCalloutModel;
    if (!this.blockPanelCalloutReady || model === null || this.blockPanelCalloutSaving) {
      return false;
    }
    const replacement: string | null = MarkdownComplexBlockEdit.serializeCallout(model, field, value);
    if (replacement === null) {
      this.blockPanelCalloutMessage = '此提示块内容暂不支持该设置';
      return false;
    }
    if (replacement === this.blockPanelCalloutRaw) {
      this.blockPanelCalloutMessage = '';
      return true;
    }
    this.blockPanelCalloutSaving = true;
    try {
      if (!await this.replaceBlockPanelInlineSource(
        this.blockPanelCalloutRaw, replacement, '修改提示块失败，请重试')) {
        this.blockPanelCalloutMessage = '提示块已变化或保存失败，请重新打开面板';
        return false;
      }
      const updated: CalloutSourceModel | null = MarkdownComplexBlockEdit.parseCallout(replacement);
      if (updated === null) {
        this.blockPanelCalloutMessage = '提示块解析失败，请以源码编辑';
        return false;
      }
      this.blockPanelCalloutRaw = replacement;
      this.blockPanelCalloutModel = updated;
      this.blockPanelCalloutTitle = updated.title;
      this.blockPanelCalloutFold = updated.fold;
      this.blockPanelCalloutMessage = '';
      return true;
    } finally {
      this.blockPanelCalloutSaving = false;
    }
  }

  private async loadBlockPanelCallout(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.type !== 'callout' ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelCalloutReady = true;
      this.blockPanelCalloutMessage = '提示块已变化，请重新打开面板';
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelCalloutReady = true;
      this.blockPanelCalloutMessage = '无法同步当前笔记，请关闭面板后重试';
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelCalloutReady = true;
      this.blockPanelCalloutMessage = '读取提示块失败，请关闭面板后重试';
      return;
    }
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null ||
      latestAnchor.from < 0 || latestAnchor.to <= latestAnchor.from || latestAnchor.to > source.length) {
      this.blockPanelCalloutReady = true;
      this.blockPanelCalloutMessage = '提示块已变化，请重新打开面板';
      return;
    }
    const raw: string = source.slice(latestAnchor.from, latestAnchor.to);
    const model: CalloutSourceModel | null = MarkdownComplexBlockEdit.parseCallout(raw);
    this.blockPanelCalloutReady = true;
    if (model === null) {
      this.blockPanelCalloutMessage = '此提示块写法暂不支持结构化编辑';
      return;
    }
    this.blockPanelCalloutRaw = raw;
    this.blockPanelCalloutModel = model;
    this.blockPanelCalloutTitle = model.title;
    this.blockPanelCalloutFold = model.fold;
    this.blockPanelCalloutMessage = '';
  }

  private async loadBlockPanelLink(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.tapType !== 'link' || anchor.inlineIndex < 0 ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelLinkReady = true;
      this.blockPanelLinkMessage = '链接已变化，请重新打开面板';
      return;
    }

    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelLinkReady = true;
      this.blockPanelLinkMessage = '无法同步当前笔记，请关闭面板后重试';
      promptAction.showToast({ message: '无法同步当前笔记，链接暂时不能编辑' });
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null) {
      return;
    }

    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelLinkReady = true;
      this.blockPanelLinkMessage = '读取链接源码失败；笔记未修改。请关闭面板后重新打开再试。';
      promptAction.showToast({ message: '读取链接源码失败；笔记未修改，请重新打开面板重试' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor)) {
      return;
    }
    const from: number = latestAnchor.itemFrom;
    const to: number = latestAnchor.itemTo;
    if (from < latestAnchor.from || to > latestAnchor.to || to > source.length || to <= from) {
      this.blockPanelLinkReady = true;
      this.blockPanelLinkMessage = '链接范围无效，请以源码编辑此项';
      return;
    }

    const raw: string = source.slice(from, to);
    const parts: MarkdownLinkParts | null = MarkdownInlineParser.parseLink(raw);
    this.blockPanelLinkRaw = raw;
    this.blockPanelLinkParts = parts;
    if (parts !== null) {
      this.blockPanelLinkLabel = parts.label;
      this.blockPanelLinkDestination = parts.destination;
      this.blockPanelLinkMessage = '';
    } else {
      this.blockPanelLinkMessage = '此链接写法暂不支持结构化编辑';
    }
    this.blockPanelLinkReady = true;
  }

  private async loadBlockPanelImage(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.tapType !== 'image' ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelImageReady = true;
      this.blockPanelImageMessage = '图片已变化，请重新打开面板';
      return;
    }

    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelImageReady = true;
      this.blockPanelImageMessage = '无法同步当前笔记，请关闭面板后重试';
      promptAction.showToast({ message: '无法同步当前笔记，图片暂时不能编辑' });
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null) {
      return;
    }

    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelImageReady = true;
      this.blockPanelImageMessage = '读取图片源码失败；笔记未修改。请关闭面板后重新打开再试。';
      promptAction.showToast({ message: '读取图片源码失败；笔记未修改，请重新打开面板重试' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor)) {
      return;
    }
    const from: number = latestAnchor.inlineIndex >= 0 ? latestAnchor.itemFrom : latestAnchor.from;
    const to: number = latestAnchor.inlineIndex >= 0 ? latestAnchor.itemTo : latestAnchor.to;
    if (from < latestAnchor.from || to > latestAnchor.to || to > source.length || to <= from) {
      this.blockPanelImageReady = true;
      this.blockPanelImageMessage = '图片范围无效，请以源码编辑此项';
      return;
    }

    const raw: string = source.slice(from, to);
    const parts: MarkdownImageParts | null = MarkdownInlineParser.parseImage(raw);
    this.blockPanelImageRaw = raw;
    this.blockPanelImageParts = parts;
    if (parts === null) {
      this.blockPanelImageMessage = '此图片写法暂不支持结构化编辑';
    } else {
      this.blockPanelImageAlt = parts.alt;
      this.blockPanelImageDestination = parts.destination;
      this.blockPanelImageWidth = parts.width;
      this.blockPanelImageMessage = '';
    }
    this.blockPanelImageReady = true;
  }

  private async replaceBlockPanelInlineSource(expectedSource: string, replacement: string,
    failureMessage: string): Promise<boolean> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || (anchor.inlineIndex < 0 && anchor.tapType !== 'image' &&
      anchor.type !== 'formula' && anchor.type !== 'callout' && anchor.type !== 'frontmatter') ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return false;
    }
    if (expectedSource === replacement) {
      return true;
    }

    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      promptAction.showToast({ message: '无法同步当前笔记，未修改内容' });
      return false;
    }
    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null) {
      promptAction.showToast({ message: '这一项已经变化，请重新打开面板' });
      return false;
    }

    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      promptAction.showToast({ message: '读取块内容失败；笔记未修改。请重新打开面板后再试。' });
      return false;
    }
    const from: number = latestAnchor.inlineIndex >= 0 ? latestAnchor.itemFrom : latestAnchor.from;
    const to: number = latestAnchor.inlineIndex >= 0 ? latestAnchor.itemTo : latestAnchor.to;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
      from < latestAnchor.from || to > latestAnchor.to || to > source.length || to <= from ||
      source.slice(from, to) !== expectedSource) {
      promptAction.showToast({ message: '这一项已经变化，请重新打开面板' });
      return false;
    }

    const wasDirty: boolean = this.isDirty(pane);
    const wasUnsaved: boolean = WorkspaceEditGuard.isUnsaved(vaultId, path);
    WorkspaceEditGuard.mark(pane, vaultId, path);
    this.onDirtyChange(pane, true);
    let applied: boolean = false;
    try {
      applied = await editor.replaceBlockSource(from, to, expectedSource, replacement, revision, 'input', false);
    } catch {}
    if (!applied) {
      if (!wasDirty && !wasUnsaved &&
        this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision)) {
        WorkspaceEditGuard.clear(pane, vaultId, path);
        this.onDirtyChange(pane, false);
      }
      promptAction.showToast({ message: failureMessage });
      return false;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return true;
    }
    if (pane === 'right') {
      this.scheduleRightSave();
    } else {
      this.scheduleSave();
    }
    this.updateBlockPanelInlineAnchor(latestAnchor, from, to, replacement.length);
    return true;
  }

  private updateBlockPanelInlineAnchor(anchor: PreviewBlockAnchor, from: number, to: number,
    replacementLength: number): void {
    const delta: number = replacementLength - (to - from);
    const items: PreviewBlockInlineItem[] = [];
    for (const item of anchor.inlineItems) {
      if ((anchor.inlineIndex >= 0 && item.index === anchor.inlineIndex) ||
        (anchor.inlineIndex < 0 && item.from === from && item.to === to)) {
        items.push({ index: item.index, type: item.type, from: item.from, to: item.to + delta });
      } else if (item.from >= to) {
        items.push({ index: item.index, type: item.type, from: item.from + delta, to: item.to + delta });
      } else {
        items.push({ index: item.index, type: item.type, from: item.from, to: item.to });
      }
    }
    this.blockPanelInlineItems = items;
    this.blockPanelAnchor = {
      type: anchor.type,
      tapType: anchor.tapType,
      from: anchor.from,
      to: anchor.to + delta,
      inlineItems: items,
      inlineSafe: anchor.inlineSafe,
      inlineIndex: anchor.inlineIndex,
      itemFrom: anchor.inlineIndex >= 0 ? anchor.itemFrom : -1,
      itemTo: anchor.inlineIndex >= 0 ? anchor.itemTo + delta : -1,
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
    this.updateBlockPropertyPanelLayout(this.blockPanelPane);
  }

  private async saveBlockPanelLinkField(field: string): Promise<void> {
    const parts: MarkdownLinkParts | null = this.blockPanelLinkParts;
    if (parts === null || !this.blockPanelLinkReady) {
      return;
    }
    let replacement: string | null = null;
    if (field === 'label') {
      const label: string = this.blockPanelLinkLabel.trim().length > 0
        ? this.blockPanelLinkLabel.trim() : parts.destination;
      replacement = MarkdownInlineParser.replaceLabel(this.blockPanelLinkRaw, parts, label);
    } else if (field === 'destination') {
      replacement = MarkdownInlineParser.replaceDestination(
        this.blockPanelLinkRaw, parts, this.blockPanelLinkDestination);
      if (replacement === null) {
        promptAction.showToast({ message: '地址不能为空或包含空格，未修改链接' });
        return;
      }
    }
    if (replacement === null) {
      return;
    }
    if (!await this.replaceBlockPanelInlineSource(this.blockPanelLinkRaw, replacement, '修改链接失败，请重试')) {
      return;
    }
    this.blockPanelLinkRaw = replacement;
    this.blockPanelLinkParts = MarkdownInlineParser.parseLink(replacement);
    if (this.blockPanelLinkParts !== null) {
      this.blockPanelLinkLabel = this.blockPanelLinkParts.label;
      this.blockPanelLinkDestination = this.blockPanelLinkParts.destination;
    }
  }

  private async unlinkBlockPanelLink(): Promise<void> {
    const parts: MarkdownLinkParts | null = this.blockPanelLinkParts;
    if (parts === null) {
      return;
    }
    const applied: boolean = await this.replaceBlockPanelInlineSource(
      this.blockPanelLinkRaw, parts.label, '取消链接失败，请重试');
    if (applied) {
      this.closeBlockPropertyPanel();
    }
  }

  private async loadBlockPanelWikiLink(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.tapType !== 'wikilink' || anchor.inlineIndex < 0 ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '双链已变化，请重新打开面板';
      return;
    }

    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '无法同步当前笔记，请关闭面板后重试';
      promptAction.showToast({ message: '无法同步当前笔记，双链暂时不能编辑' });
      return;
    }
    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null) {
      return;
    }

    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '读取双链源码失败；笔记未修改。请关闭面板后重新打开再试。';
      promptAction.showToast({ message: '读取双链源码失败；笔记未修改，请重新打开面板重试' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor)) {
      return;
    }
    const from: number = latestAnchor.itemFrom;
    const to: number = latestAnchor.itemTo;
    if (from < latestAnchor.from || to > latestAnchor.to || to > source.length || to <= from) {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '双链范围无效，请以源码编辑此项';
      return;
    }

    const raw: string = source.slice(from, to);
    const references: WikiLinkReference[] = WikiLinkParser.parse(raw);
    if (references.length !== 1 || references[0].start !== 0 || references[0].end !== raw.length) {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '此双链写法暂不支持结构化编辑';
      return;
    }
    let files: string[] = [];
    try {
      files = WikiLinkService.files(VaultRegistry.get(), vaultId);
    } catch {
      this.blockPanelWikiReady = true;
      this.blockPanelWikiMessage = '读取当前库笔记列表失败；双链未修改。请关闭面板后重试。';
      promptAction.showToast({ message: '读取当前库笔记列表失败；双链未修改，请关闭面板后重试' });
      return;
    }

    const reference: WikiLinkReference = references[0];
    const resolution: WikiLinkResolution = WikiLinkService.resolve(reference.target, path, files);
    this.blockPanelWikiRaw = raw;
    this.blockPanelWikiTarget = reference.target;
    this.blockPanelWikiAlias = reference.alias;
    this.blockPanelWikiFiles = files;
    this.blockPanelWikiResolutionStatus = resolution.status;
    this.blockPanelWikiResolutionPath = resolution.path;
    this.blockPanelWikiMessage = this.blockPanelWikiResolutionMessage(reference.target, resolution.status);
    this.blockPanelWikiReady = true;
  }

  private blockPanelWikiResolutionMessage(target: string, status: string): string {
    if (status === 'resolved') {
      return '';
    }
    if (status === 'missing') {
      return '目标笔记还没有创建；仍可修改显示文字或重新选择目标笔记。';
    }
    if (target.indexOf('#') >= 0) {
      return '标题锚点暂不支持跳转；可改显示文字或重新选择目标笔记。';
    }
    return '目标不唯一或路径无效，请重新选择目标。';
  }

  private blockPanelWikiSelectOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const path of this.blockPanelWikiFiles) {
      options.push({ value: WikiLinkParser.pathToTarget(path) });
    }
    return options;
  }

  private blockPanelWikiSelectedIndex(): number {
    if (this.blockPanelWikiResolutionStatus !== 'resolved') {
      return -1;
    }
    const target: string = WikiLinkParser.pathToTarget(this.blockPanelWikiResolutionPath);
    const options: SelectOption[] = this.blockPanelWikiSelectOptions();
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === target) {
        return i;
      }
    }
    return -1;
  }

  private blockPanelWikiSelectValue(): string {
    if (!this.blockPanelWikiReady) {
      return '正在读取双链…';
    }
    if (this.blockPanelWikiResolutionStatus === 'resolved') {
      return WikiLinkParser.pathToTarget(this.blockPanelWikiResolutionPath);
    }
    if (this.blockPanelWikiTarget.length === 0) {
      return '重新选择目标';
    }
    if (this.blockPanelWikiResolutionStatus === 'missing') {
      return `${this.blockPanelWikiTarget}（未创建）`;
    }
    if (this.blockPanelWikiTarget.indexOf('#') >= 0) {
      return `${this.blockPanelWikiTarget}（暂不支持标题锚点）`;
    }
    return `${this.blockPanelWikiTarget}（无法解析）`;
  }

  private async saveBlockPanelWikiField(field: string, value: string): Promise<void> {
    if (!this.blockPanelWikiReady || this.blockPanelWikiRaw.length === 0 ||
      (field !== 'target' && field !== 'alias')) {
      return;
    }
    let target: string = this.blockPanelWikiTarget;
    let alias: string = this.blockPanelWikiAlias;
    if (field === 'target') {
      const options: SelectOption[] = this.blockPanelWikiSelectOptions();
      if (!options.some((option: SelectOption): boolean => option.value === value)) {
        return;
      }
      target = value;
    } else {
      alias = value.trim();
      if (alias.indexOf(']]') >= 0 || alias.indexOf('\n') >= 0 || alias.indexOf('\r') >= 0) {
        promptAction.showToast({ message: '显示文字不能包含换行或 ]]' });
        return;
      }
    }
    const replacement: string = `[[${target}${alias.length > 0 ? `|${alias}` : ''}]]`;
    if (!await this.replaceBlockPanelInlineSource(this.blockPanelWikiRaw, replacement, '修改双链失败，请重试')) {
      return;
    }
    this.blockPanelWikiRaw = replacement;
    this.blockPanelWikiTarget = target;
    this.blockPanelWikiAlias = alias;
    const resolution: WikiLinkResolution = WikiLinkService.resolve(
      target, this.blockPanelSourcePath, this.blockPanelWikiFiles);
    this.blockPanelWikiResolutionStatus = resolution.status;
    this.blockPanelWikiResolutionPath = resolution.path;
    this.blockPanelWikiMessage = this.blockPanelWikiResolutionMessage(target, resolution.status);
  }

  private blockPanelWikiDisplayText(): string {
    if (this.blockPanelWikiAlias.length > 0) {
      return this.blockPanelWikiAlias;
    }
    return noteDisplayNameOfPath(this.blockPanelWikiTarget);
  }

  private async unlinkBlockPanelWiki(): Promise<void> {
    if (this.blockPanelWikiRaw.length === 0) {
      return;
    }
    const applied: boolean = await this.replaceBlockPanelInlineSource(
      this.blockPanelWikiRaw, this.blockPanelWikiDisplayText(), '移除双链失败，请重试');
    if (applied) {
      this.closeBlockPropertyPanel();
    }
  }

  private blockPanelImageRemote(): boolean {
    const parts: MarkdownImageParts | null = this.blockPanelImageParts;
    return parts !== null && NoteShareService.isRemoteImage(parts.destination);
  }

  private blockPanelImageWidthOptions(): SelectOption[] {
    return [
      { value: '原始' },
      { value: '小 · 240 px' },
      { value: '中 · 360 px' },
      { value: '大 · 480 px' }
    ];
  }

  private blockPanelImageWidthIndex(): number {
    switch (this.blockPanelImageWidth) {
      case '':
        return 0;
      case '240':
        return 1;
      case '360':
        return 2;
      case '480':
        return 3;
      default:
        return -1;
    }
  }

  private blockPanelImageWidthValue(): string {
    if (this.blockPanelImageWidth.length === 0) {
      return '原始';
    }
    const selected: number = this.blockPanelImageWidthIndex();
    if (selected >= 0) {
      return this.blockPanelImageWidthOptions()[selected].value as string;
    }
    return '当前 ' + this.blockPanelImageWidth + ' px';
  }

  private blockPanelImageWidthForIndex(index: number): string {
    switch (index) {
      case 0:
        return '';
      case 1:
        return '240';
      case 2:
        return '360';
      case 3:
        return '480';
      default:
        return '';
    }
  }

  private async saveBlockPanelImageField(field: string, value: string): Promise<void> {
    const parts: MarkdownImageParts | null = this.blockPanelImageParts;
    if (!this.blockPanelImageReady || parts === null ||
      (field !== 'alt' && field !== 'width' && field !== 'destination')) {
      return;
    }
    let replacement: string | null = null;
    if (field === 'alt') {
      replacement = MarkdownInlineParser.replaceImageAlt(this.blockPanelImageRaw, parts, value);
    } else if (field === 'width') {
      replacement = MarkdownInlineParser.replaceImageWidth(this.blockPanelImageRaw, parts, value);
      if (replacement === null) {
        promptAction.showToast({ message: '图片宽度选项无效，未修改' });
        return;
      }
    } else {
      if (!this.blockPanelImageRemote()) {
        return;
      }
      replacement = MarkdownInlineParser.replaceImageDestination(
        this.blockPanelImageRaw, parts, value);
      if (replacement === null) {
        promptAction.showToast({ message: '图片地址不能为空或包含空格，未修改' });
        return;
      }
    }
    if (!await this.replaceBlockPanelInlineSource(
      this.blockPanelImageRaw, replacement, '修改图片失败，请重试')) {
      return;
    }
    this.blockPanelImageRaw = replacement;
    this.blockPanelImageParts = MarkdownInlineParser.parseImage(replacement);
    if (this.blockPanelImageParts !== null) {
      this.blockPanelImageAlt = this.blockPanelImageParts.alt;
      this.blockPanelImageDestination = this.blockPanelImageParts.destination;
      this.blockPanelImageWidth = this.blockPanelImageParts.width;
    }
  }

  private async deleteBlockPanelImage(): Promise<void> {
    if (this.blockPanelImageParts === null || this.blockPanelImageRaw.length === 0) {
      return;
    }
    const applied: boolean = await this.replaceBlockPanelInlineSource(
      this.blockPanelImageRaw, '', '删除图片失败，请重试');
    if (applied) {
      this.closeBlockPropertyPanel();
    }
  }

  private openBlockPanelWikiTarget(): void {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    if (anchor === null || anchor.tapType !== 'wikilink' || !this.blockPanelWikiReady ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId,
        this.editorBridgeForPane(pane).currentDocumentRevision)) {
      return;
    }
    const resolution: WikiLinkResolution = WikiLinkService.resolve(
      this.blockPanelWikiTarget, path, this.blockPanelWikiFiles);
    if (resolution.status !== 'resolved') {
      return;
    }
    this.closeBlockPropertyPanel(false);
    this.openFileInOtherPane(resolution.path);
  }

  private async convertInlineCodeToPlainText(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    const editor: EditorBridge = this.editorBridgeForPane(pane);
    if (anchor === null || anchor.tapType !== 'inlinecode' || anchor.inlineIndex < 0 ||
      !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      promptAction.showToast({ message: '无法同步当前笔记，未转换行内代码' });
      return;
    }

    const revision: number = editor.currentDocumentRevision;
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) || latestAnchor === null ||
      latestAnchor.tapType !== 'inlinecode' || latestAnchor.inlineIndex < 0) {
      promptAction.showToast({ message: '行内代码已变化，请重新打开面板' });
      return;
    }

    let source: string = '';
    try {
      source = await editor.getContent();
    } catch {
      promptAction.showToast({ message: '读取行内代码源码失败；内容未转换。请重新打开面板后再试。' });
      return;
    }
    const from: number = latestAnchor.itemFrom;
    const to: number = latestAnchor.itemTo;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision) ||
      !this.isSameBlockPanelTarget(this.blockPanelAnchor, anchor) ||
      from < latestAnchor.from || to > latestAnchor.to || to > source.length || to <= from) {
      promptAction.showToast({ message: '行内代码已变化，请重新打开面板' });
      return;
    }

    const expected: string = source.slice(from, to);
    const openingMatch = /^`+/.exec(expected);
    const closingMatch = /`+$/.exec(expected);
    const opening: string = openingMatch === null ? '' : openingMatch[0];
    const closing: string = closingMatch === null ? '' : closingMatch[0];
    if (opening.length === 0 || opening.length !== closing.length || expected.length <= opening.length * 2) {
      promptAction.showToast({ message: '行内代码格式已变化，未转换' });
      return;
    }
    const replacement: string = expected.slice(opening.length, expected.length - closing.length);
    const wasDirty: boolean = this.isDirty(pane);
    const wasUnsaved: boolean = WorkspaceEditGuard.isUnsaved(vaultId, path);
    WorkspaceEditGuard.mark(pane, vaultId, path);
    this.onDirtyChange(pane, true);

    let applied: boolean = false;
    let requestFailed: boolean = false;
    try {
      applied = await editor.replaceBlockSource(from, to, expected, replacement, revision, 'input', false);
    } catch {
      requestFailed = true;
    }
    if (!applied) {
      if (!wasDirty && !wasUnsaved &&
        this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, revision)) {
        WorkspaceEditGuard.clear(pane, vaultId, path);
        this.onDirtyChange(pane, false);
      }
      promptAction.showToast({ message: requestFailed
        ? '转为纯文本失败，请重试' : '行内代码已变化，未转换' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, editor.currentDocumentRevision)) {
      return;
    }
    if (pane === 'right') {
      this.scheduleRightSave();
    } else {
      this.scheduleSave();
    }
    this.closeBlockPropertyPanel(false);
  }

  private blockSourceActionLabel(): string {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor !== null && anchor.type === 'paragraph') {
      return anchor.inlineIndex < 0 ? '以源码编辑这一段' : '以源码编辑这一项';
    }
    return '以源码编辑此块';
  }

  private blockSourceDescription(): string {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor !== null && anchor.type === 'paragraph') {
      return anchor.inlineIndex < 0
        ? '只显示这一段的 Markdown，保存后只替换这一段'
        : '只显示这一项的 Markdown，保存后只替换这一项';
    }
    return '只显示这一块的 Markdown，保存后只替换这一块';
  }

  private async openBlockSourceDrawer(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId;
    if (anchor === null || !this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId,
      this.editorBridgeForPane(pane).currentDocumentRevision)) {
      return;
    }
    const sourceFrom: number = anchor.inlineIndex >= 0 ? anchor.itemFrom : anchor.from;
    const sourceTo: number = anchor.inlineIndex >= 0 ? anchor.itemTo : anchor.to;
    const flushError: string = await this.flushSimplePreviewChanges();
    if (flushError.length > 0) {
      promptAction.showToast({ message: '无法同步当前笔记，未打开块源码' });
      return;
    }
    const bridge: EditorBridge = this.editorBridgeForPane(pane);
    const documentRevision: number = bridge.currentDocumentRevision;
    const currentAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, documentRevision) ||
      !this.isSameBlockPanelTarget(currentAnchor, anchor)) {
      return;
    }
    let source: string = '';
    try {
      source = await bridge.getContent();
    } catch {
      promptAction.showToast({ message: '读取块源码失败；笔记未修改。请重新打开面板后再试。' });
      return;
    }
    const latestAnchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, documentRevision) ||
      !this.isSameBlockPanelTarget(latestAnchor, anchor) ||
      !Number.isInteger(sourceFrom) || !Number.isInteger(sourceTo) ||
      sourceFrom < anchor.from || sourceTo > anchor.to || sourceTo <= sourceFrom ||
      sourceTo > source.length) {
      promptAction.showToast({ message: '块内容已变化，请重新打开面板' });
      return;
    }
    const snapshot: string = source.slice(sourceFrom, sourceTo);
    if (snapshot.length === 0) {
      promptAction.showToast({ message: '未能读取块源码，请重新打开面板' });
      return;
    }
    this.blockSourceFrom = sourceFrom;
    this.blockSourceTo = sourceTo;
    this.blockSourceSnapshot = snapshot;
    this.blockSourceDraft = snapshot;
    this.blockSourceBlockType = this.blockPanelTitleFor(anchor);
    this.blockSourceDocumentRevision = documentRevision;
    this.blockSourceOpenRequestId = requestId;
    this.onTitleChange('以源码编辑');
    this.onSourceEditingChange(true);
    this.updateBlockPropertyPanelLayout(pane);
  }

  private resetBlockSourceEditor(): void {
    this.onSourceEditingChange(false);
    this.blockSourceDraft = '';
    this.blockSourceBlockType = '';
    this.blockSourceSnapshot = '';
    this.blockSourceFrom = 0;
    this.blockSourceTo = 0;
    this.blockSourceDocumentRevision = 0;
    this.blockSourceOpenRequestId = 0;
  }

  private cancelBlockSourceDrawer(): void {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    this.resetBlockSourceEditor();
    if (anchor !== null) {
      this.onTitleChange(this.blockPanelTitleFor(anchor));
    }
    this.updateBlockPropertyPanelLayout(this.blockPanelPane);
  }

  private onBlockSourceEditorKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.cancelBlockSourceDrawer();
      event.stopPropagation();
      return true;
    }
    const ctrlPressed: boolean = event.getModifierKeyState !== undefined &&
      event.getModifierKeyState(['Ctrl']);
    if (event.keyCode === KeyCode.KEYCODE_ENTER && (ctrlPressed || event.metaKey === 1)) {
      void this.saveBlockSourceDrawer();
      event.stopPropagation();
      return true;
    }
    return false;
  }

  private async saveBlockSourceDrawer(): Promise<void> {
    const pane: string = this.blockPanelPane;
    const vaultId: string = this.blockPanelSourceVaultId;
    const path: string = this.blockPanelSourcePath;
    const requestId: number = this.blockSourceOpenRequestId;
    const bridge: EditorBridge = this.editorBridgeForPane(pane);
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId,
      this.blockSourceDocumentRevision)) {
      promptAction.showToast({ message: '当前笔记已变化，请重新打开块源码' });
      return;
    }
    const wasDirty: boolean = this.isDirty(pane);
    const wasUnsaved: boolean = WorkspaceEditGuard.isUnsaved(vaultId, path);
    this.resetSaveFeedback();
    WorkspaceEditGuard.mark(pane, vaultId, path);
    this.onDirtyChange(pane, true);
    let applied: boolean = false;
    let requestFailed: boolean = false;
    try {
      applied = await bridge.replaceBlockSource(this.blockSourceFrom, this.blockSourceTo,
        this.blockSourceSnapshot, this.blockSourceDraft, this.blockSourceDocumentRevision);
    } catch {
      requestFailed = true;
    }
    if (!applied) {
      if (requestFailed) {
        if (this.currentVaultId === vaultId && this.paneFilePath(pane) === path &&
          (pane === 'right' ? this.rightOpenRequestId : this.leftOpenRequestId) === requestId) {
          if (pane === 'right') {
            this.scheduleRightSave();
          } else {
            this.scheduleSave();
          }
        }
        promptAction.showToast({ message: '块源码应用失败；笔记内容仍保留在编辑区。请检查后重试保存。' });
        return;
      }
      if (!wasDirty && !wasUnsaved &&
        this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId, this.blockSourceDocumentRevision)) {
        WorkspaceEditGuard.clear(pane, vaultId, path);
        this.onDirtyChange(pane, false);
      }
      promptAction.showToast({ message: requestFailed
        ? '块源码应用失败；笔记内容仍保留在编辑区。请检查后重试保存。'
        : '块内容已变化；本次修改未应用。请重新打开块源码后再编辑。' });
      return;
    }
    if (!this.isCurrentBlockSourceTarget(pane, vaultId, path, requestId,
      this.blockSourceDocumentRevision)) {
      return;
    }
    if (pane === 'right') {
      this.scheduleRightSave();
    } else {
      this.scheduleSave();
    }
    this.closeBlockPropertyPanel(false);
  }

  private blockPanelActionLabel(): string {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor === null) {
      return '';
    }
    switch (anchor.tapType) {
      case 'image':
        return '查看大图';
      case 'link':
        return '打开链接';
      case 'wikilink':
        return this.blockPanelWikiReady && this.blockPanelWikiResolutionStatus === 'resolved'
          ? '打开目标笔记' : '';
      case 'inlinecode':
        return '转为纯文本';
      default:
        return '';
    }
  }

  private async performBlockPanelAction(): Promise<void> {
    const anchor: PreviewBlockAnchor | null = this.blockPanelAnchor;
    if (anchor !== null && anchor.tapType === 'inlinecode') {
      await this.convertInlineCodeToPlainText();
      return;
    }
    if (anchor !== null && anchor.tapType === 'wikilink') {
      this.openBlockPanelWikiTarget();
      return;
    }
    this.closeBlockPanelForContentAction();
  }
  private onBlockPropertyPanelKey(event: KeyEvent): void {
    if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.closeBlockPropertyPanel();
    }
  }

  @Builder
  BlockPanelBlockIdAction() {
    if (this.blockPanelBlockIdMessage.length > 0) {
      Text(this.blockPanelBlockIdMessage)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
    } else if (this.blockPanelBlockIdReady) {
      Column({ space: Space.s1 }) {
        Row() {
          Text(this.blockPanelBlockId.length > 0 ? '复制块链接' : '复制指向本段的链接')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .focusable(true)
        .accessibilityText(this.blockPanelBlockId.length > 0
          ? `复制块链接 [[#^${this.blockPanelBlockId}]]`
          : '复制指向本段的链接，需要先生成 ID')
        .onClick((): void => { void this.copyBlockLink(); })
        if (this.blockPanelBlockId.length === 0) {
          Text('需要先生成 ID；本操作不会自动生成。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: Space.s3, right: Space.s3 })
        }
      }
      .width('100%')
    }
  }

  @Builder
  TableDirectionOption(axis: string, side: string, label: string, selected: boolean) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontColor(selected ? $r('app.color.brand') : $r('app.color.text_primary'))
      .width(Size.touch * 1.5)
      .height(Size.touch)
      .textAlign(TextAlign.Center)
      .backgroundColor(selected ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
      .borderRadius(Radius.control)
      .focusable(true)
      .onClick((): void => {
        if (axis === 'row') {
          this.tableInsertRowSide = side;
        } else {
          this.tableInsertColumnSide = side;
        }
      })
      .accessibilityText(`${axis === 'row' ? '行' : '列'}插入方向：${label}`)
  }

  @Builder
  TableStructurePanelAction(label: string, icon: string, type: string, side: string, enabled: boolean) {
    Row({ space: Space.s2 }) {
      Icon(icon, Space.s5, $r('app.color.text_primary'))
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .backgroundColor($r('app.color.bg_secondary'))
    .borderRadius(Radius.control)
    .enabled(enabled)
    .focusable(true)
    .onClick((): void => {
      this.applyTableStructureOperation(this.blockPanelPane, type, side);
    })
    .accessibilityText(label)
  }

  @Builder
  TableStructurePanel() {
    if (this.blockPanelAnchor !== null && this.blockPanelAnchor.tableStructureEditable) {
      Column({ space: Space.s2 }) {
        Text('插入行')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Row({ space: Space.s2 }) {
          this.TableDirectionOption('row', 'up', '上方',
            this.tableInsertRowSide === 'up')
          this.TableDirectionOption('row', 'down', '下方',
            this.tableInsertRowSide === 'down')
        }
        .width('100%')
        this.TableStructurePanelAction('插入行', 'plus', 'insertRow', this.tableInsertRowSide,
          this.blockPanelAnchor.tableRow > 0 || this.tableInsertRowSide === 'down')
        if (this.blockPanelAnchor.tableRow === 0 && this.tableInsertRowSide === 'up') {
          Text('表头上方不能插入行')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        Text('插入列')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: Space.s2 })
        Row({ space: Space.s2 }) {
          this.TableDirectionOption('column', 'left', '左侧',
            this.tableInsertColumnSide === 'left')
          this.TableDirectionOption('column', 'right', '右侧',
            this.tableInsertColumnSide === 'right')
        }
        .width('100%')
        this.TableStructurePanelAction('插入列', 'plus', 'insertColumn', this.tableInsertColumnSide, true)

        Text('删除')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: Space.s2 })
        this.TableStructurePanelAction('删除当前行', 'trash', 'deleteRow', 'down',
          this.blockPanelAnchor.tableRow > 0)
        if (this.blockPanelAnchor.tableRow === 0) {
          Text('表头行不能删除')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        this.TableStructurePanelAction('删除当前列', 'trash', 'deleteColumn', 'left',
          this.blockPanelAnchor.tableColumns > 1)
        if (this.blockPanelAnchor.tableColumns <= 1) {
          Text('至少保留一列')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
    }
  }


  build() {
    if (this.blockSourceEditing) {
      Column() {
        Text(this.blockSourceBlockType)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Text(this.blockSourceDescription())
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
        TextArea({ text: this.blockSourceDraft })
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('monospace')
          .backgroundColor($r('app.color.bg_secondary'))
          .width('100%')
          .layoutWeight(1)
          .constraintSize({ minHeight: Size.touch * 4 })
          .onChange((value: string): void => { this.blockSourceDraft = value; })
          .onKeyEvent((event: KeyEvent): boolean => { return this.onBlockSourceEditorKey(event); })
          .accessibilityText('块源码')
        Row({ space: Space.s2 }) {
          Button('取消')
            .onClick((): void => { this.cancelBlockSourceDrawer(); })
          Button('保存')
            .onClick((): void => { void this.saveBlockSourceDrawer(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.blockPanelMaxHeight })
      .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
      .onKeyEvent((event: KeyEvent): void => { this.onBlockPropertyPanelKey(event); })
    } else {
      Column() {
        Scroll() {
          Column() {
            if (this.blockPanelAnchor !== null &&
              (this.blockPanelAnchor.type === 'html' || this.blockPanelAnchor.type === 'directive' ||
              this.blockPanelAnchor.type === 'mixed' ||
              (this.blockPanelAnchor.type === 'paragraph' && !this.blockPanelAnchor.inlineSafe))) {
              Text('此内容请在专业模式编辑')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.type === 'table') {
              this.TableStructurePanel()
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.type === 'paragraph' &&
              this.blockPanelAnchor.tapType === '' && this.blockPanelAnchor.inlineIndex < 0) {
              if (this.blockPanelInlineItems.length > 0) {
                ForEach(this.blockPanelInlineItems, (item: PreviewBlockInlineItem): void => {
                  Row({ space: Space.s2 }) {
                    Text(this.blockPanelInlineItemLabel(item))
                      .fontSize(FontSize.body2)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                    Icon('chevronRight', Space.s4, $r('app.color.text_tertiary'))
                  }
                  .width('100%')
                  .height(Size.touch)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .focusable(true)
                  .accessibilityText(this.blockPanelInlineItemLabel(item))
                  .onClick((): void => { this.openBlockInlineItem(item); })
                }, (item: PreviewBlockInlineItem): string => String(item.index))
              }
              this.BlockPanelBlockIdAction()
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.type === 'callout') {
              if (this.blockPanelCalloutReady && this.blockPanelCalloutModel !== null) {
                if (this.blockPanelCalloutModel.knownType) {
                  Column({ space: Space.s1 }) {
                    Text('类型')
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_secondary'))
                      .width('100%')
                    Select(this.blockPanelCalloutTypeOptions())
                      .selected(this.blockPanelCalloutTypeIndex())
                      .value(this.blockPanelCalloutTypeValue())
                      .fontColor($r('app.color.text_primary'))
                      .width('100%')
                      .onSelect((index: number, _value: string): void => {
                        void this.saveBlockPanelCalloutType(index);
                      })
                  }
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                } else {
                  Text(`类型 · 保留：${this.blockPanelCalloutModel.type}`)
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .height(Size.touch)
                    .padding({ left: Space.s3, right: Space.s3 })
                }
                Column({ space: Space.s1 }) {
                  Text('标题')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  TextInput({ text: this.blockPanelCalloutTitle, placeholder: '留空则使用默认标题' })
                    .height(Size.buttonH)
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .placeholderColor($r('app.color.text_tertiary'))
                    .padding({ left: Space.s2, right: Space.s2 })
                    .backgroundColor($r('app.color.bg_secondary'))
                    .borderRadius(Radius.control)
                    .width('100%')
                    .onChange((value: string): void => { this.blockPanelCalloutTitle = value; })
                    .onSubmit((): void => {
                      void this.saveBlockPanelCalloutField('title', this.blockPanelCalloutTitle);
                    })
                    .onBlur((): void => {
                      void this.saveBlockPanelCalloutField('title', this.blockPanelCalloutTitle);
                    })
                    .accessibilityText('提示块标题')
                }
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                if (this.blockPanelCalloutModel.knownType) {
                  Column({ space: Space.s1 }) {
                    Text('折叠')
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_secondary'))
                      .width('100%')
                    Select(this.blockPanelCalloutFoldOptions())
                      .selected(this.blockPanelCalloutFoldIndex())
                      .value(this.blockPanelCalloutFoldValue())
                      .fontColor($r('app.color.text_primary'))
                      .width('100%')
                      .onSelect((index: number, _value: string): void => {
                        void this.saveBlockPanelCalloutFold(index);
                      })
                  }
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                }
              } else {
                Text(this.blockPanelCalloutMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              }
              if (this.blockPanelCalloutMessage.length > 0 && this.blockPanelCalloutModel !== null) {
                Text(this.blockPanelCalloutMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s2 })
              }
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.type === 'frontmatter') {
              if (!this.blockPanelFrontmatterReady || this.blockPanelFrontmatterModel === null) {
                Text(this.blockPanelFrontmatterMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              } else {
                ForEach(this.blockPanelFrontmatterEntries, (entry: FrontmatterPropertyModel): void => {
                  Column({ space: Space.s1 }) {
                    Row({ space: Space.s1 }) {
                      Column({ space: Space.s1 }) {
                        Text(entry.key)
                          .fontSize(FontSize.body2)
                          .fontColor($r('app.color.text_primary'))
                        Text(entry.key === 'tags' ? '标签' : entry.key === 'aliases'
                          ? '别名' : entry.kind === 'list' ? '列表' : entry.kind === 'date'
                          ? '日期' : entry.kind === 'bool' ? '复选框' : entry.kind === 'text'
                          ? '文本' : '保留原值')
                          .fontSize(FontSize.caption)
                          .fontColor($r('app.color.text_tertiary'))
                      }
                      .layoutWeight(1)
                      Button('移除')
                        .enabled(!this.blockPanelFrontmatterSaving)
                        .onClick((): void => {
                          void this.saveBlockPanelFrontmatterProperty('remove', entry.key, '');
                        })
                    }
                    .width('100%')
                    if (entry.kind === 'complex') {
                      Text('嵌套或未知结构保持原值，请以源码编辑')
                        .fontSize(FontSize.caption)
                        .fontColor($r('app.color.text_tertiary'))
                        .width('100%')
                    } else if (entry.kind === 'bool') {
                      Row({ space: Space.s2 }) {
                        Text(entry.text === 'true' ? '开启' : '关闭')
                          .fontSize(FontSize.body2)
                          .fontColor($r('app.color.text_secondary'))
                          .layoutWeight(1)
                        Checkbox({ name: entry.key })
                          .select(entry.text === 'true')
                          .onChange((checked: boolean): void => {
                            void this.saveBlockPanelFrontmatterProperty(
                              'set', entry.key, checked ? 'true' : 'false');
                          })
                          .accessibilityText(`${entry.key} ${entry.text === 'true' ? '开启' : '关闭'}`)
                      }
                      .width('100%')
                      .height(Size.touch)
                    } else if (entry.kind === 'date') {
                      Row({ space: Space.s2 }) {
                        Text(entry.text)
                          .fontSize(FontSize.body2)
                          .fontColor($r('app.color.text_primary'))
                          .layoutWeight(1)
                        if (this.blockPanelFrontmatterDateSelectable(entry.text)) {
                          Button(this.blockPanelFrontmatterDateKey === entry.key ? '已选择' : '选择日期')
                            .enabled(!this.blockPanelFrontmatterSaving)
                            .onClick((): void => { this.beginBlockPanelFrontmatterDate(entry.key); })
                        } else {
                          Text('超出选择范围')
                            .fontSize(FontSize.caption)
                            .fontColor($r('app.color.text_tertiary'))
                        }
                      }
                      .width('100%')
                      if (this.blockPanelFrontmatterDateKey === entry.key) {
                        DatePicker({
                          start: new Date(1900, 0, 31),
                          end: new Date(2100, 11, 31),
                          selected: this.blockPanelFrontmatterDate()
                        })
                          .onDateChange((value: Date): void => {
                            this.blockPanelFrontmatterDateDraft =
                              this.blockPanelFrontmatterDateValue(value);
                          })
                        Row({ space: Space.s2 }) {
                          Text(this.blockPanelFrontmatterDateDraft)
                            .fontSize(FontSize.body2)
                            .fontColor($r('app.color.text_secondary'))
                            .layoutWeight(1)
                          Button('取消')
                            .onClick((): void => { this.cancelBlockPanelFrontmatterDate(); })
                          Button('保存')
                            .enabled(!this.blockPanelFrontmatterSaving)
                            .onClick((): void => { void this.finishBlockPanelFrontmatterDate(); })
                        }
                        .width('100%')
                      }
                    } else {
                      Row({ space: Space.s1 }) {
                        TextInput({
                          text: entry.text,
                          placeholder: entry.kind === 'list' ? '用顿号或逗号分隔' : '属性值'
                        })
                          .height(Size.buttonH)
                          .fontSize(FontSize.body2)
                          .fontColor($r('app.color.text_primary'))
                          .placeholderColor($r('app.color.text_tertiary'))
                          .padding({ left: Space.s2, right: Space.s2 })
                          .backgroundColor($r('app.color.bg_secondary'))
                          .borderRadius(Radius.control)
                          .layoutWeight(1)
                          .onChange((value: string): void => {
                            this.updateBlockPanelFrontmatterDraft(entry.key, value);
                          })
                          .onSubmit((): void => {
                            void this.saveBlockPanelFrontmatterProperty('set', entry.key, entry.text);
                          })
                          .accessibilityText(`${entry.key} ${entry.kind === 'list' ? '列表' : '文本'}`)
                        Button('保存')
                          .enabled(!this.blockPanelFrontmatterSaving)
                          .onClick((): void => {
                            void this.saveBlockPanelFrontmatterProperty('set', entry.key, entry.text);
                          })
                      }
                      .width('100%')
                    }
                  }
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                }, (entry: FrontmatterPropertyModel): string => entry.key)
                if (this.blockPanelFrontmatterEntries.length === 0) {
                  Text('暂无属性')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                }
                Column({ space: Space.s1 }) {
                  Text('添加属性')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                  TextInput({ text: this.blockPanelFrontmatterNewKey, placeholder: '名称' })
                    .height(Size.buttonH)
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .placeholderColor($r('app.color.text_tertiary'))
                    .padding({ left: Space.s2, right: Space.s2 })
                    .backgroundColor($r('app.color.bg_secondary'))
                    .borderRadius(Radius.control)
                    .width('100%')
                    .onChange((value: string): void => { this.blockPanelFrontmatterNewKey = value; })
                    .accessibilityText('新属性名称')
                  Row({ space: Space.s1 }) {
                    TextInput({
                      text: this.blockPanelFrontmatterNewValue,
                      placeholder: '值；a、b 表示列表'
                    })
                      .height(Size.buttonH)
                      .fontSize(FontSize.body2)
                      .fontColor($r('app.color.text_primary'))
                      .placeholderColor($r('app.color.text_tertiary'))
                      .padding({ left: Space.s2, right: Space.s2 })
                      .backgroundColor($r('app.color.bg_secondary'))
                      .borderRadius(Radius.control)
                      .layoutWeight(1)
                      .onChange((value: string): void => { this.blockPanelFrontmatterNewValue = value; })
                      .accessibilityText('新属性值')
                    Button('添加')
                      .enabled(!this.blockPanelFrontmatterSaving)
                      .onClick((): void => {
                        void this.saveBlockPanelFrontmatterProperty(
                          'add', this.blockPanelFrontmatterNewKey, this.blockPanelFrontmatterNewValue);
                      })
                  }
                  .width('100%')
                  Text('只改动当前属性；其他行、注释与嵌套结构保持原样。')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                }
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s2 })
                if (this.blockPanelFrontmatterMessage.length > 0) {
                  Text(this.blockPanelFrontmatterMessage)
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s2 })
                }
              }
            } else if (this.blockPanelAnchor !== null &&
              (this.blockPanelAnchor.tapType === 'footnoteRef' ||
              this.blockPanelAnchor.type === 'footnoteDefinition')) {
              if (!this.blockPanelFootnoteReady) {
                Text(this.blockPanelFootnoteMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              } else {
                if (this.blockPanelFootnoteMessage.length > 0) {
                  Text(this.blockPanelFootnoteMessage)
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                }
                if (this.blockPanelFootnoteEditable) {
                  Text('脚注正文')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, top: Space.s2 })
                  TextArea({ text: this.blockPanelFootnoteBody })
                    .height(Size.touch * 4)
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .fontFamily('monospace')
                    .backgroundColor($r('app.color.bg_secondary'))
                    .onChange((value: string): void => {
                      if (!this.blockPanelFootnoteSaving) {
                        this.blockPanelFootnoteBody = value;
                      }
                    })
                    .accessibilityText('脚注正文')
                  Button('应用')
                    .enabled(!this.blockPanelFootnoteSaving)
                    .onClick((): void => { void this.saveBlockPanelFootnote(); })
                }
                if (this.blockPanelFootnoteJumpFrom >= 0) {
                  Button(this.blockPanelAnchor.tapType === 'footnoteRef' ? '跳到定义处' : '跳回引用处')
                    .onClick((): void => { void this.jumpBlockPanelFootnote(); })
                }
              }
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.tapType === 'link') {
              Row() {
                Column({ space: Space.s1 }) {
                  Text(this.blockPanelActionLabel())
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                  if (this.blockPanelLinkParts !== null) {
                    Text(this.blockPanelLinkParts.destination)
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_secondary'))
                      .width('100%')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              .constraintSize({ minHeight: Size.touch })
              .focusable(true)
              .accessibilityText(this.blockPanelActionLabel())
              .onClick((): void => { void this.performBlockPanelAction(); })
              if (this.blockPanelLinkReady && this.blockPanelLinkParts !== null) {
                this.BlockPanelLinkField('显示文字', 'label', this.blockPanelLinkLabel, '链接上显示的文字')
                this.BlockPanelLinkField('地址', 'destination', this.blockPanelLinkDestination, '链接地址')
                Row() {
                  Text('取消链接')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText('取消链接，保留显示文字')
                .onClick((): void => { void this.unlinkBlockPanelLink(); })
              } else {
                Text(this.blockPanelLinkMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              }
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.tapType === 'wikilink') {
              if (this.blockPanelActionLabel().length > 0) {
                Row() {
                  Text(this.blockPanelActionLabel())
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText(this.blockPanelActionLabel())
                .onClick((): void => { void this.performBlockPanelAction(); })
              }
              if (this.blockPanelWikiReady) {
                if (this.blockPanelWikiMessage.length > 0) {
                  Text(this.blockPanelWikiMessage)
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                }
                Column({ space: Space.s1 }) {
                  Text('重新选择目标')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  if (this.blockPanelWikiFiles.length > 0) {
                    Select(this.blockPanelWikiSelectOptions())
                      .selected(this.blockPanelWikiSelectedIndex())
                      .value(this.blockPanelWikiSelectValue())
                      .fontColor($r('app.color.text_primary'))
                      .width('100%')
                      .onSelect((index: number, value: string): void => {
                        void this.saveBlockPanelWikiField('target', value);
                      })
                  } else {
                    Text(this.blockPanelWikiSelectValue())
                      .fontSize(FontSize.body2)
                      .fontColor($r('app.color.text_tertiary'))
                      .width('100%')
                  }
                }
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                this.BlockPanelWikiAliasField()
                Row() {
                  Text('移除双链')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText('移除双链，保留显示文字')
                .onClick((): void => { void this.unlinkBlockPanelWiki(); })
              } else {
                Text(this.blockPanelWikiMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              }
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.tapType === 'image') {
              if (this.blockPanelActionLabel().length > 0) {
                Row() {
                  Text(this.blockPanelActionLabel())
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText('查看大图')
                .onClick((): void => { void this.performBlockPanelAction(); })
              }
              if (this.blockPanelImageReady && this.blockPanelImageParts !== null) {
                this.BlockPanelImageField('alt', '替代文字', this.blockPanelImageAlt, '描述图片内容')
                if (this.blockPanelImageRemote()) {
                  this.BlockPanelImageField(
                    'destination', '图片地址', this.blockPanelImageDestination, 'https://…');
                  Text('外链图片只修改地址，不下载或转为本地附件')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                    .padding({ left: Space.s3, right: Space.s3, bottom: Space.s2 })
                }
                Column({ space: Space.s1 }) {
                  Text('显示宽度')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                  Select(this.blockPanelImageWidthOptions())
                    .selected(this.blockPanelImageWidthIndex())
                    .value(this.blockPanelImageWidthValue())
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                    .onSelect((index: number, value: string): void => {
                      void this.saveBlockPanelImageField('width', this.blockPanelImageWidthForIndex(index));
                    })
                  Text(this.blockPanelImageWidthIndex() < 0
                    ? '当前宽度 ' + this.blockPanelImageWidth + ' px'
                    : '按 Markdown 写作 ![替代文字|宽度](路径)')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                }
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                if (!this.blockPanelImageRemote()) {
                  Row() {
                    Text('替换图片')
                      .fontSize(FontSize.body2)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                    Text('从图库选择')
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .width('100%')
                  .height(Size.touch)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .focusable(true)
                  .enabled(!this.isImagePickerBusy(this.blockPanelPane))
                  .accessibilityText('替换图片，从图库选择')
                  .onClick((): void => { void this.pickImageForCurrentNote(this.blockPanelPane, true); })
                }
                Row() {
                  Text('删除图片')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.danger'))
                    .layoutWeight(1)
                  Text('仅移除引用')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText('删除图片引用，保留附件文件')
                .onClick((): void => { void this.deleteBlockPanelImage(); })
              } else {
                Text(this.blockPanelImageMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              }
            } else if (this.blockPanelAnchor !== null &&
              (this.blockPanelAnchor.tapType === 'mathInline' || this.blockPanelAnchor.type === 'formula')) {
              Text('LaTeX')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: Space.s3, right: Space.s3, top: Space.s2 })
              TextArea({ text: this.blockPanelFormulaValue })
                .height(Size.touch * 2)
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_primary'))
                .fontFamily('monospace')
                .backgroundColor($r('app.color.bg_secondary'))
                .onChange((value: string): void => { this.blockPanelFormulaValue = value; })
                .accessibilityText('LaTeX 公式')
              FormulaPreviewWeb({
                expression: this.blockPanelFormulaValue,
                displayMode: !this.blockPanelFormulaModel?.inline,
                onError: (): void => {
                  this.recordBackgroundFailure('editor_preview', 'bridge', 'unknown', 'status_unknown', 'retry');
                }
              })
                .width('100%')
                .height(Size.touch * 3)
                .accessibilityText('公式实时预览')
              if (this.blockPanelFormulaMessage.length > 0) {
                Text(this.blockPanelFormulaMessage)
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3 })
              }
              Button('应用')
                .onClick((): void => { void this.saveBlockPanelFormula(); })
            } else if (this.blockPanelActionLabel().length > 0) {
              Row() {
                Text(this.blockPanelActionLabel())
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
              }
              .width('100%')
              .height(Size.touch)
              .padding({ left: Space.s3, right: Space.s3 })
              .focusable(true)
              .accessibilityText(this.blockPanelActionLabel())
              .onClick((): void => { void this.performBlockPanelAction(); })
            } else if (this.blockPanelAnchor !== null && this.blockPanelAnchor.type === 'code') {
              Row() {
                Text('复制代码')
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
              }
              .width('100%')
              .height(Size.touch)
              .padding({ left: Space.s3, right: Space.s3 })
              .focusable(true)
              .accessibilityText('复制代码')
              .onClick((): void => { this.copyCodeBlockFromPanel(); })
              if (this.blockPanelAnchor.codeEditable && this.blockPanelAnchor.codeLanguageSelectable) {
                Row() {
                  Text('语言')
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                  Text(`${this.codeLanguageLabel(this.blockPanelAnchor.codeLanguage)} ▾`)
                    .fontSize(FontSize.body2)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                .height(Size.touch)
                .padding({ left: Space.s3, right: Space.s3 })
                .focusable(true)
                .accessibilityText(`代码语言：${this.codeLanguageLabel(this.blockPanelAnchor.codeLanguage)}`)
                .onClick((): void => {
                  this.blockPanelLanguagePickerOpen = !this.blockPanelLanguagePickerOpen;
                })
                if (this.blockPanelLanguagePickerOpen) {
                  ForEach(this.blockPanelAnchor.codeLanguages, (language: string): void => {
                    Row() {
                      Text(this.codeLanguageLabel(language))
                        .fontSize(FontSize.body2)
                        .fontColor(language === this.blockPanelAnchor?.codeLanguage
                          ? $r('app.color.brand') : $r('app.color.text_primary'))
                        .layoutWeight(1)
                    }
                    .width('100%')
                    .height(Size.touch)
                    .padding({ left: Space.s3, right: Space.s3 })
                    .focusable(true)
                    .accessibilityText(`选择代码语言：${this.codeLanguageLabel(language)}`)
                    .onClick((): void => { void this.changeBlockCodeLanguage(language); })
                  }, (language: string): string => language)
                }
              } else if (this.blockPanelAnchor.codeLanguage.length > 0) {
                Text(`保留：${this.blockPanelAnchor.codeLanguage}`)
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .height(Size.touch)
                  .padding({ left: Space.s3, right: Space.s3 })
              }
            } else {
              Row() {
                Text('暂无可用属性')
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_tertiary'))
                  .layoutWeight(1)
              }
              .width('100%')
              .height(Size.touch)
              .padding({ left: Space.s3, right: Space.s3 })
            }
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({
          maxHeight: Math.max(Space.s1, this.blockPanelMaxHeight - Size.touch - Space.s4)
        })

        Row() {
          Text(this.blockSourceActionLabel())
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .accessibilityText(this.blockSourceActionLabel())
        .onClick((): void => { void this.openBlockSourceDrawer(); })
      }
      .width('100%')
      .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
      .constraintSize({ maxHeight: this.blockPanelMaxHeight })
      .focusable(true)
      .onKeyEvent((event: KeyEvent): void => { this.onBlockPropertyPanelKey(event); })
    }
  }

  @Builder
  BlockPanelLinkField(label: string, field: string, value: string, placeholder: string) {
    Column({ space: Space.s1 }) {
      Text(label)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s1 }) {
        TextInput({ text: value, placeholder: placeholder })
          .height(Size.buttonH)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .padding({ left: Space.s2, right: Space.s2 })
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(Radius.control)
          .layoutWeight(1)
          .onChange((nextValue: string): void => {
            if (field === 'label') {
              this.blockPanelLinkLabel = nextValue;
            } else {
              this.blockPanelLinkDestination = nextValue;
            }
          })
        Button('保存')
          .onClick((): void => { void this.saveBlockPanelLinkField(field); })
      }
      .width('100%')
      if (field === 'destination') {
        Text('不自动补全协议')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
  }

  @Builder
  BlockPanelImageField(field: string, label: string, value: string, placeholder: string) {
    Column({ space: Space.s1 }) {
      Text(label)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s1 }) {
        TextInput({ text: value, placeholder: placeholder })
          .height(Size.buttonH)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .padding({ left: Space.s2, right: Space.s2 })
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(Radius.control)
          .layoutWeight(1)
          .onChange((nextValue: string): void => {
            if (field === 'alt') {
              this.blockPanelImageAlt = nextValue;
            } else {
              this.blockPanelImageDestination = nextValue;
            }
          })
        Button('保存')
          .onClick((): void => {
            const nextValue: string = field === 'alt'
              ? this.blockPanelImageAlt : this.blockPanelImageDestination;
            void this.saveBlockPanelImageField(field, nextValue);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
  }

  @Builder
  BlockPanelWikiAliasField() {
    Column({ space: Space.s1 }) {
      Text('显示文字')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s1 }) {
        TextInput({ text: this.blockPanelWikiAlias, placeholder: '留空则显示笔记名' })
          .height(Size.buttonH)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .padding({ left: Space.s2, right: Space.s2 })
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(Radius.control)
          .layoutWeight(1)
          .onChange((nextValue: string): void => { this.blockPanelWikiAlias = nextValue; })
        Button('保存')
          .onClick((): void => { void this.saveBlockPanelWikiField('alias', this.blockPanelWikiAlias); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
  }

}

export function blockPanelTitleFor(anchor: PreviewBlockAnchor): string {
  switch (anchor.tapType) {
    case 'image':
      return '图片';
    case 'link':
      return '链接';
    case 'wikilink':
      return '双链';
    case 'inlinecode':
      return '行内代码';
    case 'mathInline':
      return '行内公式';
    case 'footnoteRef':
      return '脚注';
  }
  switch (anchor.type) {
    case 'table':
      return '表格';
    case 'code':
      return '代码块';
    case 'image':
      return '图片';
    case 'link':
      return '链接';
    case 'wikilink':
      return '双链';
    case 'frontmatter':
      return '属性';
    case 'formula':
      return '公式';
    case 'callout':
      return '提示块';
    case 'footnoteDefinition':
      return '脚注';
    case 'html':
      return 'HTML';
    case 'directive':
      return '指令块';
    case 'mixed':
      return '混合语法';
    case 'paragraph':
      return '这一段';
    case 'heading':
      return '标题';
    case 'list':
      return '列表';
    case 'blockquote':
      return '引用';
    default:
      return '当前块';
  }
}

export interface PanelImageReplaceContext {
  anchor: PreviewBlockAnchor;
  raw: string;
  parts: MarkdownImageParts;
  replaceInlineSource: (raw: string, replacement: string, failToast: string) => Promise<boolean>;
  onImageReplaced: (replacement: string) => void;
}
