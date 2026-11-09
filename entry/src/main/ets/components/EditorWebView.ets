/**
 * EditorWebView.ets —— M0.5 spike：侧边「源模式」栏里承载 CodeMirror 6 的 Web 组件。
 *
 * 组件只做三件事：加载 rawfile 页面、维护桥接、把内容/焦点指令转给 Web。
 * **文件 IO 一律不碰**（硬约束 14：路径只由解析器拼）—— 内容由父级读好后传进来，
 * 保存也由父级写，组件保持纯粹，方便 spike 结论出来后单独替换。
 *
 * 桥接协议见 `web/mdeditor/src/index.ts` 头部注释；打包链路见 `web/mdeditor/build.mjs`
 * （改了 Web 源码必须重跑打包，否则设备上跑旧代码 —— AGENTS.md §Web 打包约定）。
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BridgeCodec } from '../common/BridgeCodec';
import { FontSize } from '../common/Tokens';
import { PreviewFollowAnchor } from '../model/PreviewFollowPolicy';

const EDITOR_DOMAIN = 0x0000;
const EDITOR_TAG = 'EditorWebView';

/** 注入到 WebView window.__arkts 的对象：JS -> ArkTS 的唯一入口 */
class EditorNativeProxy {
  handler: (msg: string) => void = () => {};
  readAssetHandler: (vaultId: string, relPath: string) => string = (_vaultId: string, _relPath: string) => '';

  postMessage(msg: string): void {
    this.handler(msg);
  }

  readAsset(requestB64: string): string {
    try {
      const request = JSON.parse(BridgeCodec.decode(requestB64)) as Record<string, string>;
      const vaultId: string = request['vaultId'];
      const relPath: string = request['relPath'];
      if (typeof vaultId !== 'string' || typeof relPath !== 'string') {
        return '';
      }
      return this.readAssetHandler(vaultId, relPath);
    } catch {
      hilog.warn(EDITOR_DOMAIN, EDITOR_TAG, 'readAsset 参数无效');
      return '';
    }
  }
}

/**
 * 编辑器内容快照：正文 + 该正文所属的文档代次（revision）。
 * 二者由 Web 侧在同一线程同批次回包，原子绑定 —— 这是「内容↔文件身份」配对的
 * 单一验证点：保存链必须确认快照 revision 与加载时记录的 revision 一致才允许落盘，
 * 任何加载被取代/撕裂的时序都退化为「拒绝保存」，绝不产生「把 B 笔记正文写进 A 文件」。
 */
export class EditorSnapshot {
  readonly text: string;
  readonly revision: number;

  constructor(text: string, revision: number) {
    this.text = text;
    this.revision = revision;
  }
}

/** 桥接内部实现：页面就绪前收到的指令先进队列，ready 后按序补发 */
class EditorImpl {
  private controller: webview.WebviewController;
  private readyFlag: boolean = false;
  private documentRevision: number = 0;
  private pending: string[] = [];
  /** getContent 往返：reqId → 回调（Web 侧以 content 事件回内容，不走 runJavaScript 返回值） */
  private contentWaiters: Map<number, (b64: string, revision: number) => void> = new Map();
  private blockSourceWaiters: Map<number, (applied: boolean) => void> = new Map();
  private historyUndoWaiters: Map<number, (applied: boolean) => void> = new Map();
  private nextReqId: number = 1;

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
  }

  get ready(): boolean {
    return this.readyFlag;
  }

  async markReady(): Promise<void> {
    while (this.pending.length > 0) {
      const queue = this.pending;
      this.pending = [];
      for (const script of queue) {
        await this.controller.runJavaScript(script);
      }
    }
    this.readyFlag = true;
  }

  async setContent(text: string, documentRevision: number, vaultId: string, noteDir: string): Promise<void> {
    this.setDocumentRevision(documentRevision);
    // 空串直通（BridgeCodec）：空笔记是常态，util.Base64Helper 对空输入会抛错
    const payload = BridgeCodec.encode(text);
    const vaultPayload = BridgeCodec.encode(vaultId);
    const noteDirPayload = BridgeCodec.encode(noteDir);
    // base64 只含 [A-Za-z0-9+/=]，可以直接安全拼进 JS 字符串
    const script: string = `window.__mdeditor.setContent('${payload}',${documentRevision},'${vaultPayload}','${noteDirPayload}')`;
    if (this.readyFlag) {
      await this.controller.runJavaScript(script);
    } else {
      this.pending.push(script);
    }
  }

  async replaceContentFromPreview(text: string, documentRevision: number): Promise<void> {
    const payload = BridgeCodec.encode(text);
    const script = `window.__mdeditor.replaceContentFromPreview('${payload}',${documentRevision})`;
    if (this.readyFlag) {
      await this.controller.runJavaScript(script);
    } else {
      this.pending.push(script);
    }
  }

  setDocumentRevision(documentRevision: number): void {
    this.documentRevision = documentRevision;
  }

  isCurrentDocumentRevision(documentRevision: number): boolean {
    return Number.isInteger(documentRevision) && documentRevision === this.documentRevision;
  }

  /**
   * 拉取编辑器全量内容 + 该内容所属的文档代次。⚠️ 不从 runJavaScript 的返回值取数
   * （2026-10-18 模拟器实测）：ArkWeb（Chromium）的字符串返回值带 JSON 编码痕迹，
   * decodeSync 直接抛 "The input string contains unsupported characters"。改走官方推荐往返
   * （FAQ faqs-arkweb-146）：runJavaScript 只触发 requestContent(reqId)（控制指令，
   * 硬约束 7），Web 侧把内容经 __arkts.postMessage 的 content 事件送回（b64 与 revision 同批）。
   * 保存链一律用本接口并校验 revision；只读读者（预览/章节）可用 getContent() 便捷版。
   */
  async getContentSnapshot(): Promise<EditorSnapshot> {
    const reqId = this.nextReqId;
    this.nextReqId += 1;
    return new Promise<EditorSnapshot>((resolve: (snapshot: EditorSnapshot) => void,
      reject: (e: Error) => void) => {
      let settled = false;
      const timerId = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.contentWaiters.delete(reqId);
        reject(new Error('getContent 超时：Web 侧未回内容'));
      }, 3000);
      this.contentWaiters.set(reqId, (b64: string, revision: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        try {
          resolve(new EditorSnapshot(BridgeCodec.decode(b64), revision));
        } catch (error) {
          reject(error as Error);
        }
      });
      this.enqueue(`window.__mdeditor.requestContent(${reqId})`);
    });
  }

  async replaceBlockSource(from: number, to: number, expectedSource: string, replacement: string,
    expectedRevision: number, userEvent: string = 'input', focusAfter: boolean = true,
    historyIsolated: boolean = false): Promise<boolean> {
    const reqId: number = this.nextReqId;
    this.nextReqId += 1;
    const expectedB64: string = BridgeCodec.encode(expectedSource);
    const replacementB64: string = BridgeCodec.encode(replacement);
    return new Promise<boolean>((resolve: (applied: boolean) => void, reject: (error: Error) => void) => {
      let settled: boolean = false;
      const timerId = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.blockSourceWaiters.delete(reqId);
        reject(new Error('块源码回写超时'));
      }, 3000);
      this.blockSourceWaiters.set(reqId, (applied: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timerId);
        resolve(applied);
      });
      this.enqueue(`window.__mdeditor.replaceBlockSource(${reqId},${from},${to},` +
        `'${expectedB64}','${replacementB64}',${expectedRevision},` +
        `'${userEvent === 'input.type' ? 'input.type' : 'input'}',${focusAfter},${historyIsolated})`);
    });
  }

  async undoHistoryIfContentMatches(expectedContent: string, expectedRevision: number): Promise<boolean> {
    const reqId: number = this.nextReqId;
    this.nextReqId += 1;
    const expectedB64: string = BridgeCodec.encode(expectedContent);
    return new Promise<boolean>((resolve: (applied: boolean) => void, reject: (error: Error) => void) => {
      let settled: boolean = false;
      const timerId = setTimeout((): void => {
        if (settled) return;
        settled = true;
        this.historyUndoWaiters.delete(reqId);
        reject(new Error('撤销操作超时'));
      }, 3000);
      this.historyUndoWaiters.set(reqId, (applied: boolean): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timerId);
        resolve(applied);
      });
      this.enqueue(`window.__mdeditor.undoHistoryIfContentMatches(${reqId},'${expectedB64}',${expectedRevision})`);
    });
  }

  /** Web 侧 content 回复的落点（EditorWebView.handleMessage 按 reqId 路由过来） */
  handleContent(reqId: number, b64: string, revision: number): void {
    const waiter = this.contentWaiters.get(reqId);
    if (waiter) {
      this.contentWaiters.delete(reqId);
      waiter(b64, revision);
    }
  }

  handleBlockSourceEditResult(reqId: number, applied: boolean): void {
    const waiter = this.blockSourceWaiters.get(reqId);
    if (waiter) {
      this.blockSourceWaiters.delete(reqId);
      waiter(applied);
    }
  }

  handleHistoryUndoResult(reqId: number, applied: boolean): void {
    const waiter = this.historyUndoWaiters.get(reqId);
    if (waiter) {
      this.historyUndoWaiters.delete(reqId);
      waiter(applied);
    }
  }

  insertText(text: string): void {
    const payload = BridgeCodec.encode(text);
    this.enqueue(`window.__mdeditor.insertText('${payload}')`);
  }

  applyFormat(kind: string): void {
    const formats: string[] = ['paragraph', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'bold', 'italic',
      'inlineCode', 'code', 'link', 'list', 'ordered', 'task', 'quote'];
    if (!formats.includes(kind)) {
      return;
    }
    this.enqueue(`window.__mdeditor.applyFormat('${kind}')`);
  }

  scrollToOffset(offset: number): void {
    const safeOffset: number = Math.max(0, Math.floor(offset));
    this.enqueue(`window.__mdeditor.scrollToOffset(${safeOffset})`);
  }

  restoreScrollTop(top: number): void {
    const safeTop: number = Number.isFinite(top) ? Math.max(0, Math.floor(top)) : 0;
    this.enqueue(`window.__mdeditor.restoreScrollTop(${safeTop})`);
  }

  focus(): void {
    this.enqueue('window.__mdeditor.focus()');
  }

  blur(): void {
    this.enqueue('window.__mdeditor.blur()');
  }

  setLinkCandidatesResult(id: number, candidates: string): void {
    const payload: string = BridgeCodec.encode(candidates);
    this.enqueue(`window.__mdeditor.setLinkCandidatesResult(${id},'${payload}')`);
  }

  setTheme(theme: string): void {
    const safe = theme === 'dark' ? 'dark' : 'light';
    this.enqueue(`window.__mdeditor.setTheme('${safe}')`);
  }

  setLineNumbers(show: boolean): void {
    this.enqueue(`window.__mdeditor.setLineNumbers(${show})`);
  }

  setExperience(mode: string): void {
    const safeMode: string = mode === 'professional' ? 'professional' : 'simple';
    this.enqueue(`window.__mdeditor.setExperience('${safeMode}')`);
  }

  reportVisibleSourceAnchor(): void {
    this.enqueue('window.__mdeditor.reportVisibleSourceAnchor()');
  }

  async setEditable(editable: boolean): Promise<void> {
    const script: string = `window.__mdeditor.setEditable(${editable})`;
    if (this.readyFlag) {
      await this.controller.runJavaScript(script);
    } else {
      this.pending.push(script);
    }
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
export class EditorBridge {
  private impl: EditorImpl | undefined = undefined;
  private initialContent: string = '';
  private hasInitialContent: boolean = false;
  private currentVaultId: string = '';
  private currentNoteDir: string = '';
  private hasBoundOnce: boolean = false;
  private documentRevision: number = 0;
  private loadedDocumentRevision: number = 0;
  private unavailable: boolean = false;
  private readyWaiters: Array<() => void> = [];
  private workspaceScrollTop: number = 0;
  private hasWorkspaceScrollTop: boolean = false;

  bind(impl: EditorImpl): void {
    this.impl = impl;
    impl.setDocumentRevision(this.documentRevision);
    this.unavailable = false;
    if (!this.hasBoundOnce && this.hasInitialContent) {
      const revision: number = this.documentRevision;
      void impl.setContent(this.initialContent, revision, this.currentVaultId, this.currentNoteDir).then((): void => {
        if (this.documentRevision === revision) {
          this.loadedDocumentRevision = revision;
        }
      });
    }
    this.hasBoundOnce = true;
    if (this.hasWorkspaceScrollTop) {
      impl.restoreScrollTop(this.workspaceScrollTop);
    }
  }

  /** 编辑器页面是否就绪（ready 前 getContent 会返回 ''，落盘会清空文件，故保存前必查） */
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

  /**
   * 下发一份完整正文。返回本次下发使用的 documentRevision —— 调用方必须把它记进
   * 对应的 EditorNoteSession（加载：创建会话；镜像同步：更新会话 revision），
   * 完成内容与文件身份的配对。Web 侧把该 revision 与正文存在同一线程，保存时回响校验。
   */
  async setContent(text: string): Promise<number> {
    this.initialContent = text;
    this.hasInitialContent = true;
    this.documentRevision += 1;
    const revision: number = this.documentRevision;
    if (this.impl) {
      await this.impl.setContent(text, revision, this.currentVaultId, this.currentNoteDir);
      if (this.documentRevision === revision) {
        this.loadedDocumentRevision = revision;
      }
    }
    return revision;
  }

  async replaceContentFromPreview(text: string): Promise<void> {
    this.initialContent = text;
    this.hasInitialContent = true;
    if (this.impl) {
      await this.impl.replaceContentFromPreview(text, this.documentRevision);
    }
  }

  /** Bind local image reads to the exact library and note directory for the next document load. */
  setNoteContext(vaultId: string, noteDir: string): void {
    this.currentVaultId = vaultId;
    this.currentNoteDir = noteDir;
  }

  beginDocumentTransition(): number {
    this.documentRevision += 1;
    this.impl?.setDocumentRevision(this.documentRevision);
    return this.documentRevision;
  }

  restoreDocumentTransition(transitionRevision: number): void {
    if (this.documentRevision !== transitionRevision) {
      return;
    }
    this.documentRevision = this.loadedDocumentRevision;
    this.impl?.setDocumentRevision(this.documentRevision);
  }

  /** 只读便捷版：仅取正文，不带 revision。保存链禁用本接口，一律走 getContentSnapshot。 */
  async getContent(): Promise<string> {
    if (!this.impl) {
      return this.hasInitialContent ? this.initialContent : '';
    }
    return (await this.impl.getContentSnapshot()).text;
  }

  /**
   * 保存链专用：正文 + 文档代次一起取。调用方必须校验 snapshot.revision 与
   * EditorNoteSession 记录的 revision 一致后才允许把正文写入 session.path。
   */
  async getContentSnapshot(): Promise<EditorSnapshot> {
    if (!this.impl) {
      return new EditorSnapshot(this.hasInitialContent ? this.initialContent : '', this.documentRevision);
    }
    return await this.impl.getContentSnapshot();
  }

  get currentDocumentRevision(): number {
    return this.documentRevision;
  }

  async replaceBlockSource(from: number, to: number, expectedSource: string, replacement: string,
    expectedRevision: number, userEvent: string = 'input', focusAfter: boolean = true,
    historyIsolated: boolean = false): Promise<boolean> {
    if (!this.impl) {
      return false;
    }
    return await this.impl.replaceBlockSource(from, to, expectedSource, replacement, expectedRevision,
      userEvent, focusAfter, historyIsolated);
  }

  async undoHistoryIfContentMatches(expectedContent: string, expectedRevision: number): Promise<boolean> {
    if (!this.impl) {
      return false;
    }
    return await this.impl.undoHistoryIfContentMatches(expectedContent, expectedRevision);
  }

  insertText(text: string): void {
    this.impl?.insertText(text);
  }

  applyFormat(kind: string): void {
    this.impl?.applyFormat(kind);
  }

  scrollToOffset(offset: number): void {
    this.impl?.scrollToOffset(offset);
  }

  restoreScrollTop(top: number): void {
    this.rememberScrollTop(top);
    this.impl?.restoreScrollTop(top);
  }

  rememberScrollTop(top: number): void {
    this.workspaceScrollTop = Number.isFinite(top) ? Math.max(0, top) : 0;
    this.hasWorkspaceScrollTop = true;
  }

  focus(): void {
    this.impl?.focus();
  }

  blur(): void {
    this.impl?.blur();
  }

  setLinkCandidatesResult(id: number, candidates: string): void {
    this.impl?.setLinkCandidatesResult(id, candidates);
  }

  setTheme(theme: string): void {
    this.impl?.setTheme(theme);
  }

  reportVisibleSourceAnchor(): void {
    this.impl?.reportVisibleSourceAnchor();
  }

  async setEditable(editable: boolean): Promise<void> {
    await this.impl?.setEditable(editable);
  }

  setExperience(mode: string): void {
    this.impl?.setExperience(mode);
  }
}

/**
 * 可见的编辑器 Web 组件。
 *
 * ⚠️ 与 GitBridgeView 的隐形 1x1 引擎不同，这个要占满内容区，因此受硬约束 12 约束：
 * 宽高 ≤ 7680px 物理像素。三栏各 1/3 约 1061px、高约 1684px，都在限内。
 */
@Component
export struct EditorWebView {
  /** 由 EntryAbility 跟随系统颜色模式写入。 */
  @StorageProp('appTheme') @Watch('onThemeChanged') theme: string = 'light';
  @Prop @Watch('onLineNumbersChanged') showLineNumbers: boolean = false;
  @Prop @Watch('onExperienceChanged') experienceMode: string = 'simple';
  @State private pageReady: boolean = false;
  @State private loadFailed: boolean = false;
  /** 内容变化通知（debounce 300ms，只报长度；要内容请调 bridge.getContent()） */
  onChange: (len: number) => void = (len: number) => {};
  /** 输入法组合输入开始 / 结束；组合期间禁止向该编辑器下发另一栏内容。 */
  onCompositionChange: (composing: boolean) => void = (composing: boolean) => {};
  /** 当前光标 / 选区是否位于同一个围栏代码块。 */
  onCodeBlockStateChange: (active: boolean) => void = (active: boolean) => {};
  /** Web 编辑器视口滚动位置；只上报数字，不传递笔记内容。 */
  onScrollPositionChange: (top: number) => void = (top: number) => {};
  /** 编辑器主动滚动时上报源码位置锚点，不传递正文。 */
  onSourceScrollChange: (anchor: PreviewFollowAnchor) => void = (_anchor: PreviewFollowAnchor) => {};
  /** 页面就绪（首帧可交互） */
  onReady: () => void = () => {};
  /** Web 加载错误 */
  onError: (msg: string) => void = (msg: string) => {};
  /** Web 编辑器请求双链候选，父级返回当前库的少量匹配项。 */
  onLinkCompletion: (id: number, query: string) => void = (_id: number, _query: string) => {};
  /** 本地图片读取由页面所有者通过 VaultAccess 完成。 */
  onReadAsset: (vaultId: string, relPath: string) => string = (_vaultId: string, _relPath: string) => '';
  /** 父级通过这个句柄下发内容 / 拉取内容（外部传入同一实例，ready 时内部 bind） */
  bridge: EditorBridge = new EditorBridge();

  private controller: webview.WebviewController = new webview.WebviewController();
  private proxy: EditorNativeProxy = new EditorNativeProxy();
  /** 当前桥接实现（ready 时创建；content 回复按 reqId 路由给它） */
  private impl: EditorImpl | undefined = undefined;
  /** 代理是否已注册（onControllerAttached 里注册，onPageEnd 兜底；见 build()） */
  private proxyRegistered: boolean = false;

  aboutToAppear(): void {
    this.proxy.handler = (msg: string): void => {
      this.handleMessage(msg);
    };
    this.proxy.readAssetHandler = (vaultId: string, relPath: string): string => {
      return this.onReadAsset(vaultId, relPath);
    };
  }

  onThemeChanged(): void {
    this.impl?.setTheme(this.theme);
    this.impl?.setLineNumbers(this.showLineNumbers);
  }

  onLineNumbersChanged(): void {
    this.impl?.setLineNumbers(this.showLineNumbers);
  }

  onExperienceChanged(): void {
    this.impl?.setExperience(this.experienceMode);
  }

  /**
   * 注册 __arkts 代理（幂等）。失败时复位 proxyRegistered，让 onPageEnd 兜底重试一次。
   * 签名（SDK 实证，api/@ohos.web.webview.d.ts）：
   * registerJavaScriptProxy(jsObject, name, methodList, asyncMethodList?, permission?)
   * —— 位置参数版；options 对象版属于已 deprecated 的 WebController，别混。
   */
  private registerProxy(): void {
    if (this.proxyRegistered) {
      return;
    }
    try {
      this.controller.registerJavaScriptProxy(this.proxy, '__arkts', ['postMessage', 'readAsset']);
      this.proxyRegistered = true;
      hilog.info(EDITOR_DOMAIN, EDITOR_TAG, '__arkts 代理已注册（页面加载前注入，无需 refresh）');
    } catch (_error) {
      hilog.error(EDITOR_DOMAIN, EDITOR_TAG, '注册代理失败');
    }
  }

  private handleMessage(json: string): void {
    let msg: Record<string, string | number | boolean> = {};
    try {
      msg = JSON.parse(json) as Record<string, string | number>;
    } catch (error) {
      // Bridge payloads may contain the complete note body; never include them in logs or UI errors.
      hilog.error(EDITOR_DOMAIN, EDITOR_TAG, '桥接消息解析失败');
      this.onError('桥接消息解析失败');
      return;
    }
    if (msg['type'] !== 'event') {
      return;
    }
    const name = msg['name'] as string;
    if (name === 'setContentError') {
      // Web 侧 setContent 落地校验失败（dispatch 被否决/未生效）并已回滚 revision。
      // 只记 revision，不记内容；正常路径不应出现该事件。
      hilog.error(EDITOR_DOMAIN, EDITOR_TAG,
        'Web 侧 setContent 未生效，revision 已回滚：rev=%{public}d', Number(msg['revision'] ?? -1));
      return;
    }
    if (name === 'ready') {
      if (this.impl) {
        // 二次 ready（onPageEnd 的 onArktsReady 兜底会重发一次）直接忽略：
        // 不重建 impl（会丢 in-flight getContent 的 waiter、重置 reqId），
        // 不重发 onReady（会触发 loadFile 重读文件，冲掉编辑器里未保存的改动）。
        // 双保险：web 侧 setTheme 曾因重建 state 丢 change 监听，见 web/mdeditor/src。
        hilog.info(EDITOR_DOMAIN, EDITOR_TAG, '重复 ready，已忽略（桥接此前建立）');
        return;
      }
      const impl = new EditorImpl(this.controller);
      this.impl = impl;
      this.bridge.bind(impl);
      impl.setTheme(this.theme);
      impl.setLineNumbers(this.showLineNumbers);
      impl.setExperience(this.experienceMode);
      void impl.markReady().then((): void => {
        this.bridge.notifyReady();
        this.pageReady = true;
        this.loadFailed = false;
        hilog.info(EDITOR_DOMAIN, EDITOR_TAG, 'Web 编辑器页面就绪，桥接已建立');
        this.onReady();
      }).catch((_error: Error): void => {
        this.bridge.notifyUnavailable();
        this.loadFailed = true;
        this.onError('编辑器初始化失败；原因未确定');
      });
    } else if (name === 'content') {
      // requestContent 的回复：按 reqId 路由给 impl，解开对应的 getContentSnapshot Promise
      const revision: number = msg['revision'] as number;
      this.impl?.handleContent(msg['id'] as number, msg['b64'] as string,
        typeof revision === 'number' && Number.isInteger(revision) ? revision : -1);
    } else if (name === 'blockSourceEdit') {
      this.impl?.handleBlockSourceEditResult(msg['id'] as number, msg['applied'] as boolean);
    } else if (name === 'historyUndoResult') {
      this.impl?.handleHistoryUndoResult(msg['id'] as number, msg['applied'] as boolean);
    } else if (name === 'change') {
      if (this.impl?.isCurrentDocumentRevision(msg['revision'] as number)) {
        this.onChange((msg['len'] as number) ?? 0);
      }
    } else if (name === 'composition') {
      this.onCompositionChange((msg['composing'] as boolean) ?? false);
    } else if (name === 'codeBlockState') {
      this.onCodeBlockStateChange((msg['active'] as boolean) ?? false);
    } else if (name === 'scroll') {
      this.onScrollPositionChange((msg['top'] as number) ?? 0);
    } else if (name === 'sourceScroll') {
      const line: number = msg['line'] as number;
      const lineProgress: number = msg['lineProgress'] as number;
      const viewportRatio: number = msg['viewportRatio'] as number;
      const atStart: boolean = msg['atStart'] as boolean;
      const atEnd: boolean = msg['atEnd'] as boolean;
      if (Number.isInteger(line) && line > 0 && Number.isFinite(lineProgress) &&
        Number.isFinite(viewportRatio) && typeof atStart === 'boolean' && typeof atEnd === 'boolean') {
        this.onSourceScrollChange({
          line: line,
          lineProgress: Math.max(0, Math.min(1, lineProgress)),
          viewportRatio: Math.max(0, Math.min(1, viewportRatio)),
          atStart: atStart,
          atEnd: atEnd
        });
      }
    } else if (name === 'linkCompletion') {
      this.onLinkCompletion(msg['id'] as number, msg['query'] as string);
    }
  }

  build() {
    Stack() {
      Web({ src: $rawfile('mdeditor/index.html'), controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
        // v1.46 46.8：页面级 OFFSET_WITH_CARET（Index aboutToAppear）下 WebAttribute.keyboardAvoidMode
        // 生效（仅 UIContext=RESIZE 时失效），默认 RESIZE_CONTENT 会与页面上抬叠加成双重避让；
        // RETURN_TO_UICONTEXT（since 22 ≤ 24）让 Web 不再自行避让、完全跟随 UIContext（api_notes L-21）。
        .keyboardAvoidMode(WebKeyboardAvoidMode.RETURN_TO_UICONTEXT)
        .onControllerAttached(() => {
          // ⚠️ 注册时机（2026-10-18 SDK 实证 + 官方生命周期文档）：
          // onControllerAttached 是注入 JS 对象的建议时机 —— controller 绑定后、页面加载前，
          // 此时注册的代理会随本次页面加载一起注入，无需 refresh、页面只加载一次。
          // （onPageBegin 注册已属太晚；onPageEnd 注册必须 refresh 才会生效。）
          this.registerProxy();
        })
        .onPageEnd(() => {
          // 兜底：onControllerAttached 没跑成时（理论上不会），补注册 + refresh 使其生效
          if (!this.proxyRegistered) {
            this.registerProxy();
            if (this.proxyRegistered) {
              this.controller.refresh();
            }
            return;
          }
          // 招呼 Web 侧重发 ready（Web 侧也有轮询兜底）
          void this.controller.runJavaScript(
            'window.__mdeditor && window.__mdeditor.onArktsReady ? window.__mdeditor.onArktsReady() : 0').then(() => {
            hilog.info(EDITOR_DOMAIN, EDITOR_TAG, 'onArktsReady() called');
          }).catch((e: Error) => {
            hilog.error(EDITOR_DOMAIN, EDITOR_TAG, 'onArktsReady failed');
          });
        })
        .onConsole((_event): boolean => {
          // Web console may contain note data; suppress it instead of forwarding it to hilog.
          return true;
        })
        .onErrorReceive((event) => {
          this.loadFailed = true;
          this.bridge.notifyUnavailable();
          this.onError('编辑器加载失败；原因未确定');
        })
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme === 'dark'
          ? $r('app.color.bg_card') : $r('app.color.bg_card'))

      if (!this.pageReady) {
        Column() {
          Text(this.loadFailed ? '编辑器加载失败；原因未确定，请重新打开笔记重试' : '正在加载编辑器…')
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
