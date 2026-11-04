/**
 * PreviewWebView.ets —— M3：右侧「预览」栏里承载 marked 渲染器的 Web 组件。
 *
 * 与 EditorWebView 同族但职责更窄：
 *  - 方向以 ArkTS → JS 为主（setContent / setNoteDir / setTheme，页面就绪前指令进队列）；
 *  - JS → ArkTS：`readAsset(relPathB64) → data URI` 读取本地图片，以及图片查看器打开/关闭状态通知。
 *    资源路径仍由父级的统一解析器处理（resource://rawfile 页面拿不到沙箱文件，
 *    api_notes B4；不做请求拦截，避免 onInterceptRequest 波及页面主资源加载）。
 *
 * ⚠️ 桥接方法必须挂在注入对象上直接调用（L-4 踩坑），Web 侧已按此实现。
 * 文件 IO 不在本组件 —— readAsset 的实际读文件由父级经 `onReadAsset` 回调提供
 * （硬约束 14：路径只由解析器拼）。
 */
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BridgeCodec } from '../common/BridgeCodec';
import { FontSize } from '../common/Tokens';
import { PreviewFollowAnchor } from '../model/PreviewFollowPolicy';
import { WikiLinkPreviewEdit } from '../model/WikiLinkParser';

export interface PreviewCaptureResult {
  scrollHeight: number;
  viewportHeight: number;
  viewportWidth: number;
  scrollTop: number;
}

export interface PreviewBlockInlineItem {
  index: number;
  type: string;
  from: number;
  to: number;
}

export interface PreviewCodeEditRequest {
  id: number;
  from: number;
  to: number;
  expectedSource: string;
  replacement: string;
  userEvent: string;
}

export interface PreviewBlockAnchor {
  type: string;
  tapType: string;
  from: number;
  to: number;
  inlineItems: PreviewBlockInlineItem[];
  inlineIndex: number;
  itemFrom: number;
  itemTo: number;
  codeLanguage: string;
  codeLanguageFrom: number;
  codeLanguageTo: number;
  codeLanguageSelectable: boolean;
  codeLanguages: string[];
  codeEditable: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
}

export function mapPreviewBlockAnchor(payload: string, area: number[]): PreviewBlockAnchor | null {
  if (payload.length === 0 || area.length < 4) {
    return null;
  }
  let source: Record<string, string | number | boolean | PreviewBlockInlineItem[] | string[]>;
  try {
    source = JSON.parse(payload) as Record<string, string | number | PreviewBlockInlineItem[]>;
  } catch {
    return null;
  }
  const type: string = source['type'] as string;
  const rawTapType: string = typeof source['tapType'] === 'string' ? source['tapType'] as string : '';
  let tapType: string = ['image', 'link', 'wikilink', 'inlinecode', 'mathInline'].includes(rawTapType)
    ? rawTapType : '';
  const from: number = source['from'] as number;
  const to: number = source['to'] as number;
  const inlineItems: PreviewBlockInlineItem[] = [];
  const rawInlineItems: PreviewBlockInlineItem[] = source['inlineItems'] as PreviewBlockInlineItem[];
  if (Array.isArray(rawInlineItems)) {
    for (let index = 0; index < rawInlineItems.length; index++) {
      const item: PreviewBlockInlineItem = rawInlineItems[index];
      if (item.index !== index || !['image', 'link', 'wikilink', 'inlinecode', 'mathInline'].includes(item.type) ||
        !Number.isInteger(item.from) || !Number.isInteger(item.to) || item.from < from || item.to > to ||
        item.to <= item.from) {
        inlineItems.length = 0;
        break;
      }
      inlineItems.push({ index: item.index, type: item.type, from: item.from, to: item.to });
    }
  }
  let inlineIndex: number = -1;
  let itemFrom: number = -1;
  let itemTo: number = -1;
  const rawInlineIndex: number = source['inlineIndex'] as number;
  if (Number.isInteger(rawInlineIndex) && rawInlineIndex >= 0) {
    for (let index = 0; index < inlineItems.length; index++) {
      const item: PreviewBlockInlineItem = inlineItems[index];
      if (item.index === rawInlineIndex && item.type === tapType &&
        item.from === source['itemFrom'] && item.to === source['itemTo']) {
        inlineIndex = item.index;
        itemFrom = item.from;
        itemTo = item.to;
        break;
      }
    }
    if (inlineIndex < 0) tapType = '';
  }
  const left: number = source['left'] as number;
  const top: number = source['top'] as number;
  const width: number = source['width'] as number;
  const height: number = source['height'] as number;
  const viewportWidth: number = source['viewportWidth'] as number;
  const viewportHeight: number = source['viewportHeight'] as number;
  const codeLanguage: string = typeof source['codeLanguage'] === 'string'
    ? source['codeLanguage'] as string : '';
  const codeLanguageFrom: number = Number.isInteger(source['codeLanguageFrom'])
    ? source['codeLanguageFrom'] as number : -1;
  const codeLanguageTo: number = Number.isInteger(source['codeLanguageTo'])
    ? source['codeLanguageTo'] as number : -1;
  const codeLanguageSelectable: boolean = source['codeLanguageSelectable'] === true;
  const codeEditable: boolean = source['codeEditable'] === true;
  const codeLanguages: string[] = [];
  const rawCodeLanguages: string[] = source['codeLanguages'] as string[];
  if (Array.isArray(rawCodeLanguages)) {
    for (const language of rawCodeLanguages) {
      if (typeof language === 'string' && codeLanguages.indexOf(language) < 0) {
        codeLanguages.push(language);
      }
    }
  }
  if (type.length === 0 || !Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from ||
    !Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(width) || !Number.isFinite(height) ||
    width <= 0 || height <= 0 || !Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight) ||
    viewportWidth <= 0 || viewportHeight <= 0 || area[2] <= 0 || area[3] <= 0) {
    return null;
  }
  const scaleX: number = area[2] / viewportWidth;
  const scaleY: number = area[3] / viewportHeight;
  return {
    type: type,
    tapType: tapType,
    from: from,
    to: to,
    inlineItems: inlineItems,
    inlineIndex: inlineIndex,
    itemFrom: itemFrom,
    itemTo: itemTo,
    codeLanguage: codeLanguage,
    codeLanguageFrom: codeLanguageFrom,
    codeLanguageTo: codeLanguageTo,
    codeLanguageSelectable: codeLanguageSelectable && codeLanguageFrom >= from &&
      codeLanguageTo >= codeLanguageFrom && codeLanguageTo <= to,
    codeLanguages: codeLanguages,
    codeEditable: codeEditable,
    x: area[0] + left * scaleX,
    y: area[1] + top * scaleY,
    width: width * scaleX,
    height: height * scaleY
  };
}

interface CaptureWaiter {
  resolve: (result: PreviewCaptureResult) => void;
  reject: (error: Error) => void;
  timerId: number;
}

interface ContentWaiter {
  resolve: (content: string) => void;
  reject: (error: Error) => void;
  timerId: number;
}

const PREVIEW_DOMAIN = 0x0000;
const PREVIEW_TAG = 'PreviewWebView';
const PREVIEW_ZOOM_MIN: number = 50;
const PREVIEW_ZOOM_MAX: number = 200;

function normalizePreviewZoomPercent(percent: number): number {
  if (!Number.isFinite(percent)) {
    return 100;
  }
  return Math.max(PREVIEW_ZOOM_MIN, Math.min(PREVIEW_ZOOM_MAX, Math.round(percent)));
}

/** 注入到 WebView window.__arkts 的 JS → ArkTS 接口。 */
class PreviewNativeProxy {
  readAssetHandler: (relPath: string) => string = () => '';
  imageViewerChangeHandler: (state: string) => void = () => {};
  shareCaptureHandler: (payload: string) => void = (payload: string) => {};
  wikiLinkClickHandler: (targetB64: string) => void = (_targetB64: string) => {};
  workspaceScrollHandler: (top: number) => void = (_top: number) => {};
  editableContentHandler: (contentB64: string) => void = (_contentB64: string) => {};
  editableContentRequestHandler: (id: number, contentB64: string) => void = (_id: number, _contentB64: string) => {};
  compositionHandler: (state: string) => void = (_state: string) => {};
  lockedContentTapHandler: (payload: string) => void = (_payload: string) => {};
  lockedBlockSelectionHandler: (payload: string) => void = (_payload: string) => {};
  previewZoomChangeHandler: (percent: number) => void = (_percent: number) => {};
  codeBlockEditHandler: (request: PreviewCodeEditRequest) => void =
    (_request: PreviewCodeEditRequest) => {};
  codeBlockEditingChangeHandler: (editing: boolean) => void = (_editing: boolean) => {};

  readAsset(relB64: string): string {
    return this.readAssetHandler(relB64);
  }

  onImageViewerChange(state: string): void {
    this.imageViewerChangeHandler(state);
  }

  onShareCaptureResult(payload: string): void {
    this.shareCaptureHandler(payload);
  }

  onWikiLinkClick(targetB64: string): void {
    this.wikiLinkClickHandler(targetB64);
  }

  onWorkspaceScroll(top: number): void {
    this.workspaceScrollHandler(top);
  }

  onEditableContentChange(contentB64: string): void {
    this.editableContentHandler(contentB64);
  }

  onEditableContent(id: number, contentB64: string): void {
    this.editableContentRequestHandler(id, contentB64);
  }

  onCompositionChange(state: string): void {
    this.compositionHandler(state);
  }

  onLockedContentTap(payload: string): void {
    this.lockedContentTapHandler(payload);
  }

  onLockedBlockSelection(payload: string): void {
    this.lockedBlockSelectionHandler(payload);
  }

  onPreviewZoomChange(percent: number): void {
    this.previewZoomChangeHandler(percent);
  }

  onCodeBlockEdit(id: number, from: number, to: number, expectedB64: string,
    replacementB64: string, userEvent: string): void {
    if (!Number.isInteger(id) || id <= 0 || !Number.isInteger(from) ||
      !Number.isInteger(to) || from < 0 || to < from ||
      (userEvent !== 'input.type' && userEvent !== 'input')) {
      return;
    }
    try {
      this.codeBlockEditHandler({
        id: id,
        from: from,
        to: to,
        expectedSource: BridgeCodec.decode(expectedB64),
        replacement: BridgeCodec.decode(replacementB64),
        userEvent: userEvent
      });
    } catch {
      return;
    }
  }

  onCodeBlockEditingChange(editing: boolean): void {
    this.codeBlockEditingChangeHandler(editing);
  }
}

/** 桥接内部实现：页面就绪前收到的指令先进队列，onPageEnd 后按序补发 */
class PreviewImpl {
  private controller: webview.WebviewController;
  private readyFlag: boolean = false;
  private pending: string[] = [];

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
  }

  get ready(): boolean {
    return this.readyFlag;
  }

  async markReady(): Promise<void> {
    if (this.readyFlag) {
      return;
    }
    while (this.pending.length > 0) {
      const queue = this.pending;
      this.pending = [];
      for (const script of queue) {
        await this.controller.runJavaScript(script);
      }
    }
    this.readyFlag = true;
  }

  setContent(text: string, sourceText: string, sourceEdits: WikiLinkPreviewEdit[]): void {
    // 空串直通（BridgeCodec）：空笔记是常态，util.Base64Helper 对空输入会抛错
    const payload = BridgeCodec.encode(text);
    const sourcePayload = BridgeCodec.encode(sourceText);
    const mapPayload = BridgeCodec.encode(JSON.stringify(sourceEdits));
    this.enqueue(`window.__mdpreview.setContent('${payload}','${sourcePayload}','${mapPayload}')`);
  }

  setEditable(editable: boolean): void {
    this.enqueue(`window.__mdpreview.setEditable(${editable})`);
  }

  setPreviewZoomPercent(percent: number): void {
    this.enqueue(`window.__mdpreview.setPreviewZoomPercent(${normalizePreviewZoomPercent(percent)})`);
  }

  setPreviewZoomControlsVisible(visible: boolean): void {
    this.enqueue(`window.__mdpreview.setPreviewZoomControlsVisible(${visible})`);
  }

  applyFormat(kind: string): void {
    const allowed = ['paragraph', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'bold', 'italic', 'list', 'ordered', 'task', 'quote'];
    if (allowed.includes(kind)) this.enqueue(`window.__mdpreview.applyFormat('${kind}')`);
  }

  insertText(text: string): void {
    const payload = BridgeCodec.encode(text);
    this.enqueue(`window.__mdpreview.insertText('${payload}')`);
  }

  requestEditableContent(id: number): void {
    this.enqueue(`window.__mdpreview.flushEditableContent(${id})`);
  }

  resetDocument(): void {
    this.enqueue('window.__mdpreview.resetDocument()');
  }

  setNoteDir(dir: string): void {
    const payload = BridgeCodec.encode(dir);
    this.enqueue(`window.__mdpreview.setNoteDir('${payload}')`);
  }

  setTheme(theme: string): void {
    const safe = theme === 'dark' ? 'dark' : 'light';
    this.enqueue(`window.__mdpreview.setTheme('${safe}')`);
  }

  closeImageViewer(): void {
    this.enqueue('window.__mdpreview.closeImageViewer()');
  }

  focusBlock(from: number, to: number): void {
    if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from) {
      return;
    }
    this.enqueue(`window.__mdpreview.focusLockedBlock(${from},${to})`);
  }

  activateLockedContent(from: number, to: number, inlineIndex: number = -1): void {
    if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from) {
      return;
    }
    this.enqueue(`window.__mdpreview.activateLockedContent(${from},${to},${inlineIndex})`);
  }

  completeCodeBlockEdit(id: number, applied: boolean): void {
    if (Number.isInteger(id) && id > 0) {
      this.enqueue(`window.__mdpreview.completeCodeBlockEdit(${id},${applied})`);
    }
  }

  scrollToHeading(index: number): void {
    this.enqueue(`window.__mdpreview.scrollToHeading(${Math.max(0, Math.floor(index))})`);
  }

  restoreScrollTop(top: number): void {
    const safeTop: number = Number.isFinite(top) ? Math.max(0, Math.floor(top)) : 0;
    this.enqueue(`window.__mdpreview.restoreScrollTop(${safeTop})`);
  }

  scrollToSourceLine(anchor: PreviewFollowAnchor): void {
    const line: number = Number.isInteger(anchor.line) ? Math.max(1, anchor.line) : 1;
    const lineProgress: number = Number.isFinite(anchor.lineProgress)
      ? Math.max(0, Math.min(1, anchor.lineProgress)) : 0;
    const viewportRatio: number = Number.isFinite(anchor.viewportRatio)
      ? Math.max(0, Math.min(1, anchor.viewportRatio)) : 0;
    this.enqueue(`window.__mdpreview.scrollToSourceLine(${line},${lineProgress},${viewportRatio},` +
      `${anchor.atStart},${anchor.atEnd})`);
  }

  cancelSourceFollow(): void {
    this.enqueue('window.__mdpreview.cancelSourceFollow()');
  }

  requestShareCaptureMetrics(id: number): void {
    this.enqueue(`window.__mdpreview.requestShareCaptureMetrics(${id})`);
  }

  appendShareWatermark(id: number): void {
    this.enqueue(`window.__mdpreview.appendShareWatermark(${id})`);
  }

  setShareCaptureScrollTop(id: number, top: number): void {
    this.enqueue(`window.__mdpreview.setShareCaptureScrollTop(${id},${top})`);
  }

  /** Install a fixed click delegate; link targets travel through the existing JS proxy. */
  watchWikiLinks(): void {
    this.enqueue(`document.addEventListener('click',function(event){var node=event.target;
      while(node&&node!==document){if(node.nodeType===1&&node.classList&&node.classList.contains('wiki-link')){
      var href=node.getAttribute('href')||'';if(href.indexOf('#wikilink:')===0){
      if(window.__mdpreview&&window.__mdpreview.isEditable()&&
      !(typeof window.__mdpreview.isLockedTapActivation==='function'&&
      window.__mdpreview.isLockedTapActivation()))return;event.preventDefault();
      var api=window.__arkts;if(api&&typeof api.onWikiLinkClick==='function'){
      api.onWikiLinkClick(href.substring(10));}}return;}node=node.parentElement;}} ,true)`);
  }

  prepareShareCapturePages(id: number, pageCount: number): void {
    this.enqueue(`window.__mdpreview.prepareShareCapturePages(${id},${pageCount})`);
  }

  private enqueue(script: string): void {
    if (this.readyFlag) {
      void this.controller.runJavaScript(script);
    } else {
      this.pending.push(script);
    }
  }
}

/** 父组件持有的句柄：页面就绪前调用会进队列，不会丢 */
export class PreviewBridge {
  private impl: PreviewImpl | undefined = undefined;
  private unavailable: boolean = false;
  private readyWaiters: Array<() => void> = [];
  private content: string = '';
  private sourceContent: string = '';
  private sourceEdits: WikiLinkPreviewEdit[] = [];
  private editable: boolean = false;
  private hasContent: boolean = false;
  private workspaceScrollTop: number = 0;
  private hasWorkspaceScrollTop: boolean = false;
  private noteDir: string = '';
  private theme: string = 'light';
  private previewZoomPercent: number = 100;
  private zoomControlsVisible: boolean = false;
  private captureWaiters: Map<number, CaptureWaiter> = new Map<number, CaptureWaiter>();
  private nextCaptureId: number = 1;
  private contentWaiters: Map<number, ContentWaiter> = new Map<number, ContentWaiter>();
  private nextContentId: number = 1;
  onEditableContentChange: (content: string) => void = (_content: string) => {};
  onCompositionChange: (composing: boolean) => void = (_composing: boolean) => {};
  onCodeBlockEdit: (request: PreviewCodeEditRequest) => void =
    (_request: PreviewCodeEditRequest) => {};
  onCodeBlockEditingChange: (editing: boolean) => void = (_editing: boolean) => {};
  onLockedContentTap: () => void = () => {};
  onBlockAnchorChange: (anchor: PreviewBlockAnchor | null) => void = (_anchor: PreviewBlockAnchor | null) => {};
  onContentReplacing: () => void = () => {};

  bind(impl: PreviewImpl): void {
    this.impl = impl;
    this.unavailable = false;
    impl.setNoteDir(this.noteDir);
    impl.setTheme(this.theme);
    impl.setEditable(this.editable);
    impl.setPreviewZoomPercent(this.previewZoomPercent);
    impl.setPreviewZoomControlsVisible(this.zoomControlsVisible);
    if (this.hasContent) {
      impl.setContent(this.content, this.sourceContent, this.sourceEdits);
    }
    if (this.hasWorkspaceScrollTop) {
      impl.restoreScrollTop(this.workspaceScrollTop);
    }
  }

  unbind(impl: PreviewImpl): void {
    if (this.impl === impl) {
      this.impl = undefined;
    }
  }

  get ready(): boolean {
    return this.impl?.ready ?? false;
  }

  waitUntilReady(): Promise<void> {
    if (this.ready || this.unavailable) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      this.readyWaiters.push(resolve);
    });
  }

  notifyReady(): void {
    this.unavailable = false;
    const waiters = this.readyWaiters;
    this.readyWaiters = [];
    for (const resolve of waiters) {
      resolve();
    }
  }

  notifyUnavailable(): void {
    this.unavailable = true;
    const waiters = this.readyWaiters;
    this.readyWaiters = [];
    for (const resolve of waiters) {
      resolve();
    }
  }

  setContent(text: string, sourceText: string = text, sourceEdits: WikiLinkPreviewEdit[] = []): void {
    if (this.hasContent && (this.content !== text || this.sourceContent !== sourceText)) {
      this.onContentReplacing();
    }
    this.content = text;
    this.sourceContent = sourceText;
    this.sourceEdits = sourceEdits;
    this.hasContent = true;
    this.impl?.setContent(text, sourceText, sourceEdits);
  }

  setEditable(editable: boolean): void {
    this.editable = editable;
    this.impl?.setEditable(editable);
  }

  setPreviewZoomPercent(percent: number): void {
    this.previewZoomPercent = normalizePreviewZoomPercent(percent);
    this.impl?.setPreviewZoomPercent(this.previewZoomPercent);
  }

  rememberPreviewZoomPercent(percent: number): void {
    this.previewZoomPercent = normalizePreviewZoomPercent(percent);
  }

  setPreviewZoomControlsVisible(visible: boolean): void {
    this.zoomControlsVisible = visible;
    this.impl?.setPreviewZoomControlsVisible(visible);
  }

  applyFormat(kind: string): void {
    this.impl?.applyFormat(kind);
  }

  completeCodeBlockEdit(id: number, applied: boolean): void {
    this.impl?.completeCodeBlockEdit(id, applied);
  }

  insertText(text: string): void {
    this.impl?.insertText(text);
  }

  requestEditableContent(): Promise<string> {
    const id = this.nextContentId++;
    return new Promise<string>((resolve: (content: string) => void, reject: (error: Error) => void): void => {
      const timerId = setTimeout((): void => {
        this.contentWaiters.delete(id);
        reject(new Error('等待正文编辑内容超时'));
      }, 3000);
      this.contentWaiters.set(id, { resolve: resolve, reject: reject, timerId: timerId });
      this.impl?.requestEditableContent(id);
    });
  }

  handleEditableContent(id: number, contentB64: string): void {
    const waiter = this.contentWaiters.get(id);
    if (!waiter) return;
    this.contentWaiters.delete(id);
    clearTimeout(waiter.timerId);
    try {
      const content = BridgeCodec.decode(contentB64);
      this.sourceContent = content;
      waiter.resolve(content);
    } catch {
      waiter.reject(new Error('读取正文编辑内容失败'));
    }
  }

  handleEditableContentChange(contentB64: string): void {
    try {
      const content = BridgeCodec.decode(contentB64);
      this.sourceContent = content;
      this.onEditableContentChange(content);
    } catch {
      hilog.warn(PREVIEW_DOMAIN, PREVIEW_TAG, '正文编辑内容解码失败');
    }
  }

  handleCompositionChange(state: string): void {
    this.onCompositionChange(state === 'start');
  }

  setNoteDir(dir: string): void {
    this.noteDir = dir;
    this.impl?.setNoteDir(dir);
  }

  setTheme(theme: string): void {
    this.theme = theme === 'dark' ? 'dark' : 'light';
    this.impl?.setTheme(theme);
  }

  private imageViewerOpen: boolean = false;

  setImageViewerOpen(open: boolean): void {
    this.imageViewerOpen = open;
  }

  closeImageViewer(): boolean {
    if (!this.imageViewerOpen) {
      return false;
    }
    this.impl?.closeImageViewer();
    return true;
  }

  focusBlock(from: number, to: number): void {
    this.impl?.focusBlock(from, to);
  }

  activateLockedContent(from: number, to: number, inlineIndex: number = -1): void {
    this.impl?.activateLockedContent(from, to, inlineIndex);
  }

  scrollToHeading(index: number): void {
    this.impl?.scrollToHeading(index);
  }

  restoreScrollTop(top: number): void {
    this.rememberScrollTop(top);
    this.impl?.restoreScrollTop(top);
  }

  scrollToSourceLine(anchor: PreviewFollowAnchor): void {
    this.impl?.scrollToSourceLine(anchor);
  }

  cancelSourceFollow(): void {
    this.impl?.cancelSourceFollow();
  }

  rememberScrollTop(top: number): void {
    this.workspaceScrollTop = Number.isFinite(top) ? Math.max(0, top) : 0;
    this.hasWorkspaceScrollTop = true;
  }

  resetDocument(): void {
    this.imageViewerOpen = false;
    this.impl?.resetDocument();
  }

  requestShareCaptureMetrics(): Promise<PreviewCaptureResult> {
    return this.requestCapture((id: number): void => {
      this.impl?.requestShareCaptureMetrics(id);
    });
  }

  appendShareWatermark(): Promise<PreviewCaptureResult> {
    return this.requestCapture((id: number): void => {
      this.impl?.appendShareWatermark(id);
    });
  }

  setShareCaptureScrollTop(top: number): Promise<PreviewCaptureResult> {
    return this.requestCapture((id: number): void => {
      this.impl?.setShareCaptureScrollTop(id, top);
    });
  }

  prepareShareCapturePages(pageCount: number): Promise<PreviewCaptureResult> {
    return this.requestCapture((id: number): void => {
      this.impl?.prepareShareCapturePages(id, pageCount);
    });
  }

  cancelShareCaptureRequests(message: string): void {
    this.captureWaiters.forEach((waiter: CaptureWaiter): void => {
      clearTimeout(waiter.timerId);
      waiter.reject(new Error(message));
    });
    this.captureWaiters.clear();
  }

  handleShareCaptureResult(payload: string): void {
    let result: Record<string, string | number>;
    try {
      result = JSON.parse(payload) as Record<string, string | number>;
    } catch (error) {
      return;
    }
    const id: number = result['id'] as number;
    const waiter: CaptureWaiter | undefined = this.captureWaiters.get(id);
    if (waiter === undefined) {
      return;
    }
    clearTimeout(waiter.timerId);
    this.captureWaiters.delete(id);
    const errorText: string = (result['error'] as string) ?? '';
    if (errorText.length > 0) {
      waiter.reject(new Error(errorText));
      return;
    }
    waiter.resolve({
      scrollHeight: result['scrollHeight'] as number,
      viewportHeight: result['viewportHeight'] as number,
      viewportWidth: result['viewportWidth'] as number,
      scrollTop: result['scrollTop'] as number
    });
  }

  private requestCapture(send: (id: number) => void): Promise<PreviewCaptureResult> {
    const currentId: number = this.nextCaptureId;
    this.nextCaptureId++;
    return new Promise<PreviewCaptureResult>((resolve: (result: PreviewCaptureResult) => void,
      reject: (error: Error) => void): void => {
      if (this.impl === undefined) {
        reject(new Error('分享预览尚未就绪'));
        return;
      }
      const timerId: number = setTimeout((): void => {
        this.captureWaiters.delete(currentId);
        reject(new Error('等待分享预览渲染超时，请重试'));
      }, 5000);
      this.captureWaiters.set(currentId, { resolve: resolve, reject: reject, timerId: timerId });
      try {
        send(currentId);
      } catch (error) {
        clearTimeout(timerId);
        this.captureWaiters.delete(currentId);
        reject(error as Error);
      }
    });
  }
}

/**
 * 可见的预览 Web 组件（占满预览栏）。
 * 硬约束 12：宽高 ≤ 7680px 物理像素 —— 预览栏 1/3 屏约 1061px，在限内。
 */
@Component
export struct PreviewWebView {
  /** 由 EntryAbility 跟随系统颜色模式写入。 */
  @StorageProp('appTheme') @Watch('onThemeChanged') theme: string = 'light';
  @Prop @Watch('onThemeOverrideChanged') themeOverride: string = '';
  @Prop @Watch('onEditableChanged') editable: boolean = false;
  @Prop @Watch('onZoomControlsVisibleChanged') zoomControlsVisible: boolean = false;
  @State private pageReady: boolean = false;
  @State private loadFailed: boolean = false;
  /** 读库内图片 → data URI（找不到/读失败返回空串，Web 侧显示「图片不存在」） */
  onReadAsset: (relPath: string) => string = (relPath: string) => '';
  /** Web 加载错误 */
  onError: (msg: string) => void = (msg: string) => {};
  /** 双链点击回调，参数为目标文本。 */
  onWikiLinkClick: (target: string) => void = (_target: string) => {};
  /** Web 预览视口滚动位置；只上报数字，不传递笔记内容。 */
  onScrollPositionChange: (top: number) => void = (top: number) => {};
  /** Web 页面桥接就绪。 */
  onReady: () => void = () => {};
  onEditableContentChange: (content: string) => void = (_content: string) => {};
  onCompositionChange: (composing: boolean) => void = (_composing: boolean) => {};
  onCodeBlockEdit: (request: PreviewCodeEditRequest) => void =
    (_request: PreviewCodeEditRequest) => {};
  onCodeBlockEditingChange: (editing: boolean) => void = (_editing: boolean) => {};
  onLockedContentTap: (anchor: PreviewBlockAnchor | null) => void =
    (_anchor: PreviewBlockAnchor | null) => {};
  /** Web 组件标识，供单张长图的视口分段截图定位。 */
  componentId: string = 'note-preview-web';
  /** 父级通过这个句柄下发渲染内容 / 笔记目录 / 主题 */
  bridge: PreviewBridge = new PreviewBridge();

  private controller: webview.WebviewController = new webview.WebviewController();
  private proxy: PreviewNativeProxy = new PreviewNativeProxy();
  private base64: util.Base64Helper = new util.Base64Helper();
  private boundImpl: PreviewImpl | undefined = undefined;
  private componentActive: boolean = false;
  /** 代理是否已注册（onControllerAttached 里注册，onPageEnd 兜底） */
  private proxyRegistered: boolean = false;
  private webAreaVp: number[] = [0, 0, 0, 0];
  private latestBlockAnchorPayload: string = '';

  private effectiveTheme(): string {
    if (this.themeOverride === 'dark' || this.themeOverride === 'light') {
      return this.themeOverride;
    }
    return this.theme;
  }

  aboutToAppear(): void {
    this.componentActive = true;
    this.proxy.imageViewerChangeHandler = (state: string): void => {
      this.bridge.setImageViewerOpen(state === 'open');
    };
    this.proxy.shareCaptureHandler = (payload: string): void => {
      this.bridge.handleShareCaptureResult(payload);
    };
    this.proxy.wikiLinkClickHandler = (targetB64: string): void => {
      this.handleWikiLinkClick(targetB64);
    };
    this.proxy.workspaceScrollHandler = (top: number): void => {
      this.onScrollPositionChange(top);
    };
    this.proxy.editableContentHandler = (contentB64: string): void => {
      this.bridge.handleEditableContentChange(contentB64);
    };
    this.proxy.editableContentRequestHandler = (id: number, contentB64: string): void => {
      this.bridge.handleEditableContent(id, contentB64);
    };
    this.proxy.compositionHandler = (state: string): void => {
      this.bridge.handleCompositionChange(state);
    };
    this.proxy.previewZoomChangeHandler = (percent: number): void => {
      this.bridge.rememberPreviewZoomPercent(percent);
    };
    this.proxy.lockedContentTapHandler = (payload: string): void => {
      this.onLockedContentTap(mapPreviewBlockAnchor(payload, this.webAreaVp));
    };
    this.proxy.lockedBlockSelectionHandler = (payload: string): void => {
      this.latestBlockAnchorPayload = payload;
      this.publishBlockAnchor();
    };
    this.proxy.codeBlockEditHandler = (request: PreviewCodeEditRequest): void => {
      this.onCodeBlockEdit(request);
    };
    this.proxy.codeBlockEditingChangeHandler = (editing: boolean): void => {
      this.onCodeBlockEditingChange(editing);
    };
    this.bridge.onEditableContentChange = (content: string): void => {
      this.onEditableContentChange(content);
    };
    this.bridge.onCompositionChange = (composing: boolean): void => {
      this.onCompositionChange(composing);
    };
    this.bridge.setEditable(this.editable);
    this.bridge.setPreviewZoomControlsVisible(this.zoomControlsVisible);
    // JS 桥收的是 base64（避免引号/换行转义），这里解开再交给父级回调
    this.proxy.readAssetHandler = (relB64: string): string => {
      try {
        const bytes = this.base64.decodeSync(relB64);
        const relPath = new util.TextDecoder().decodeToString(bytes);
        return this.onReadAsset(relPath);
      } catch (_error) {
        hilog.warn(PREVIEW_DOMAIN, PREVIEW_TAG, 'readAsset 参数解码失败');
        return '';
      }
    };
    this.bridge.setTheme(this.effectiveTheme());
  }

  onThemeChanged(): void {
    this.bridge.setTheme(this.effectiveTheme());
  }

  onThemeOverrideChanged(): void {
    this.bridge.setTheme(this.effectiveTheme());
  }

  onEditableChanged(): void {
    this.bridge.setEditable(this.editable);
  }

  onZoomControlsVisibleChanged(): void {
    this.bridge.setPreviewZoomControlsVisible(this.zoomControlsVisible);
  }

  private handleWikiLinkClick(targetB64: string): void {
    try {
      this.onWikiLinkClick(BridgeCodec.decode(targetB64));
    } catch (_error) {
      hilog.warn(PREVIEW_DOMAIN, PREVIEW_TAG, '双链目标解码失败');
    }
  }

  private publishBlockAnchor(): void {
    this.bridge.onBlockAnchorChange(mapPreviewBlockAnchor(this.latestBlockAnchorPayload, this.webAreaVp));
  }

  private recordWebArea(area: Area): void {
    this.webAreaVp[0] = typeof area.globalPosition.x === 'number' ? area.globalPosition.x : 0;
    this.webAreaVp[1] = typeof area.globalPosition.y === 'number' ? area.globalPosition.y : 0;
    this.webAreaVp[2] = typeof area.width === 'number' ? area.width : 0;
    this.webAreaVp[3] = typeof area.height === 'number' ? area.height : 0;
    this.publishBlockAnchor();
  }

  private async finishPageInitialization(impl: PreviewImpl): Promise<void> {
    try {
      await impl.markReady();
      impl.watchWikiLinks();
      this.bridge.notifyReady();
      this.pageReady = true;
      this.loadFailed = false;
      this.onReady();
      hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, '预览页面就绪，桥接已建立');
    } catch (error) {
      const err = error as Error;
      this.bridge.notifyUnavailable();
      this.loadFailed = true;
      this.onError('预览初始化失败: ' + err.message);
    }
  }

  aboutToDisappear(): void {
    this.latestBlockAnchorPayload = '';
    this.publishBlockAnchor();
    this.bridge.setImageViewerOpen(false);
    this.componentActive = false;
    if (this.boundImpl !== undefined) {
      this.bridge.unbind(this.boundImpl);
      this.boundImpl = undefined;
    }
  }

  /**
   * 注册 __arkts 代理（幂等）。时机与 EditorWebView 相同（L-4 实证）：
   * onControllerAttached = 页面加载前注册，随页面一次注入，无需 refresh。
   */
  private registerProxy(): void {
    if (this.proxyRegistered) {
      return;
    }
    try {
      this.controller.registerJavaScriptProxy(this.proxy, '__arkts',
        ['readAsset', 'onImageViewerChange', 'onShareCaptureResult', 'onWikiLinkClick', 'onWorkspaceScroll',
          'onEditableContentChange', 'onEditableContent', 'onCompositionChange', 'onLockedContentTap',
          'onLockedBlockSelection', 'onPreviewZoomChange', 'onCodeBlockEdit', 'onCodeBlockEditingChange']);
      this.proxyRegistered = true;
      hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, '__arkts 代理已注册（readAsset）');
    } catch (_error) {
      hilog.error(PREVIEW_DOMAIN, PREVIEW_TAG, '注册代理失败');
    }
  }

  build() {
    Column() {
      Web({ src: $rawfile('mdpreview/index.html'), controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.recordWebArea(newArea);
        })
        .onControllerAttached(() => {
          this.registerProxy();
        })
        .onPageEnd(() => {
          if (!this.componentActive) {
            return;
          }
          // 兜底：onControllerAttached 没跑成时补注册 + refresh（与 EditorWebView 同款）
          if (!this.proxyRegistered) {
            this.registerProxy();
            if (this.proxyRegistered) {
              this.controller.refresh();
            }
            return;
          }
          // 就绪：绑定 bridge、冲队列、下发主题。onPageEnd 时内联脚本已执行，
          // window.__mdpreview 必然存在（构建产物单文件内联，无外链资源）。
          const impl = new PreviewImpl(this.controller);
          this.boundImpl = impl;
          this.bridge.bind(impl);
          void this.finishPageInitialization(impl);
        })
        .onConsole((_event): boolean => {
          // Rendered note text can appear in Web console messages; do not forward it to hilog.
          return true;
        })
        .onErrorReceive((event) => {
          this.loadFailed = true;
          this.bridge.notifyUnavailable();
          this.onError('预览加载错误: ' + (event?.error?.getErrorInfo() ?? ''));
        })
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
        .id(this.componentId)

      if (!this.pageReady) {
        Column() {
          Text(this.loadFailed ? '预览加载失败' : '正在加载预览…')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
