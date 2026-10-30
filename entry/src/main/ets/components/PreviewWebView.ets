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

export interface PreviewCaptureResult {
  scrollHeight: number;
  viewportHeight: number;
  viewportWidth: number;
  scrollTop: number;
}

interface CaptureWaiter {
  resolve: (result: PreviewCaptureResult) => void;
  reject: (error: Error) => void;
  timerId: number;
}

const PREVIEW_DOMAIN = 0x0000;
const PREVIEW_TAG = 'PreviewWebView';

/** 注入到 WebView window.__arkts 的 JS → ArkTS 接口。 */
class PreviewNativeProxy {
  readAssetHandler: (relPath: string) => string = () => '';
  imageViewerChangeHandler: (state: string) => void = () => {};
  shareCaptureHandler: (payload: string) => void = (payload: string) => {};
  wikiLinkClickHandler: (targetB64: string) => void = (_targetB64: string) => {};
  workspaceScrollHandler: (top: number) => void = (_top: number) => {};

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

}

/** 桥接内部实现：页面就绪前收到的指令先进队列，onPageEnd 后按序补发 */
class PreviewImpl {
  private controller: webview.WebviewController;
  private readyFlag: boolean = false;
  private pending: string[] = [];

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
  }

  markReady(): void {
    if (this.readyFlag) {
      return;
    }
    this.readyFlag = true;
    const queue = this.pending;
    this.pending = [];
    for (const script of queue) {
      void this.controller.runJavaScript(script);
    }
  }

  setContent(text: string): void {
    // 空串直通（BridgeCodec）：空笔记是常态，util.Base64Helper 对空输入会抛错
    const payload = BridgeCodec.encode(text);
    this.enqueue(`window.__mdpreview.setContent('${payload}')`);
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

  setShareCaptureScrollTop(id: number, top: number): void {
    this.enqueue(`window.__mdpreview.setShareCaptureScrollTop(${id},${top})`);
  }

  /** Install a fixed click delegate; link targets travel through the existing JS proxy. */
  watchWikiLinks(): void {
    this.enqueue(`document.addEventListener('click',function(event){var node=event.target;
      while(node&&node!==document){if(node.nodeType===1&&node.classList&&node.classList.contains('wiki-link')){
      var href=node.getAttribute('href')||'';if(href.indexOf('#wikilink:')===0){event.preventDefault();
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
  private content: string = '';
  private hasContent: boolean = false;
  private workspaceScrollTop: number = 0;
  private hasWorkspaceScrollTop: boolean = false;
  private noteDir: string = '';
  private theme: string = 'light';
  private captureWaiters: Map<number, CaptureWaiter> = new Map<number, CaptureWaiter>();
  private nextCaptureId: number = 1;

  bind(impl: PreviewImpl): void {
    this.impl = impl;
    impl.setNoteDir(this.noteDir);
    impl.setTheme(this.theme);
    if (this.hasContent) {
      impl.setContent(this.content);
    }
    if (this.hasWorkspaceScrollTop) {
      impl.restoreScrollTop(this.workspaceScrollTop);
    }
  }

  setContent(text: string): void {
    this.content = text;
    this.hasContent = true;
    this.impl?.setContent(text);
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
  /** Web 组件标识，供分享图片分页截图定位。 */
  componentId: string = 'note-preview-web';
  /** 父级通过这个句柄下发渲染内容 / 笔记目录 / 主题 */
  bridge: PreviewBridge = new PreviewBridge();

  private controller: webview.WebviewController = new webview.WebviewController();
  private proxy: PreviewNativeProxy = new PreviewNativeProxy();
  private base64: util.Base64Helper = new util.Base64Helper();
  /** 代理是否已注册（onControllerAttached 里注册，onPageEnd 兜底） */
  private proxyRegistered: boolean = false;

  aboutToAppear(): void {
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
    // JS 桥收的是 base64（避免引号/换行转义），这里解开再交给父级回调
    this.proxy.readAssetHandler = (relB64: string): string => {
      try {
        const bytes = this.base64.decodeSync(relB64);
        const relPath = new util.TextDecoder().decodeToString(bytes);
        return this.onReadAsset(relPath);
      } catch (error) {
        const err = error as Error;
        hilog.warn(PREVIEW_DOMAIN, PREVIEW_TAG, 'readAsset 参数解码失败: %{public}s', err.message);
        return '';
      }
    };
    this.bridge.setTheme(this.theme);
  }

  onThemeChanged(): void {
    this.bridge.setTheme(this.theme);
  }

  private handleWikiLinkClick(targetB64: string): void {
    try {
      this.onWikiLinkClick(BridgeCodec.decode(targetB64));
    } catch (error) {
      const err = error as Error;
      hilog.warn(PREVIEW_DOMAIN, PREVIEW_TAG, '双链目标解码失败: %{public}s', err.message);
    }
  }

  aboutToDisappear(): void {
    this.bridge.setImageViewerOpen(false);
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
        ['readAsset', 'onImageViewerChange', 'onShareCaptureResult', 'onWikiLinkClick', 'onWorkspaceScroll']);
      this.proxyRegistered = true;
      hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, '__arkts 代理已注册（readAsset）');
    } catch (error) {
      const err = error as Error;
      hilog.error(PREVIEW_DOMAIN, PREVIEW_TAG, '注册代理失败: %{public}s', err.message);
    }
  }

  build() {
    Column() {
      Web({ src: $rawfile('mdpreview/index.html'), controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
        .onControllerAttached(() => {
          this.registerProxy();
        })
        .onPageEnd(() => {
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
          this.bridge.bind(impl);
          impl.markReady();
          impl.watchWikiLinks();
          this.pageReady = true;
          this.loadFailed = false;
          this.onReady();
          hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, '预览页面就绪，桥接已建立');
        })
        .onConsole((event): boolean => {
          const msg = event?.message?.getMessage() ?? '';
          hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, 'console: %{public}s', msg);
          return true;
        })
        .onErrorReceive((event) => {
          this.loadFailed = true;
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
