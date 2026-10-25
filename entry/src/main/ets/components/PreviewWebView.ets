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
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BridgeCodec } from '../common/BridgeCodec';

const PREVIEW_DOMAIN = 0x0000;
const PREVIEW_TAG = 'PreviewWebView';

/** 注入到 WebView window.__arkts 的 JS → ArkTS 接口。 */
class PreviewNativeProxy {
  readAssetHandler: (relPath: string) => string = () => '';
  imageViewerChangeHandler: (state: string) => void = () => {};

  readAsset(relB64: string): string {
    return this.readAssetHandler(relB64);
  }

  onImageViewerChange(state: string): void {
    this.imageViewerChangeHandler(state);
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
  private noteDir: string = '';
  private theme: string = 'light';

  bind(impl: PreviewImpl): void {
    this.impl = impl;
    impl.setNoteDir(this.noteDir);
    impl.setTheme(this.theme);
    if (this.hasContent) {
      impl.setContent(this.content);
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

  resetDocument(): void {
    this.imageViewerOpen = false;
    this.impl?.resetDocument();
  }
}

/**
 * 可见的预览 Web 组件（占满预览栏）。
 * 硬约束 12：宽高 ≤ 7680px 物理像素 —— 预览栏 1/3 屏约 1061px，在限内。
 */
@Component
export struct PreviewWebView {
  /** 外部主题：'light' / 'dark'（跟随系统颜色模式，见 aboutToAppear） */
  @Prop theme: string = 'light';
  /** 读库内图片 → data URI（找不到/读失败返回空串，Web 侧显示「图片不存在」） */
  onReadAsset: (relPath: string) => string = (relPath: string) => '';
  /** Web 加载错误 */
  onError: (msg: string) => void = (msg: string) => {};
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
    // 跟随系统深浅色：Web 内读不到 App 的 token，显式传下去
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const mode = ctx.config?.colorMode;
      if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        this.theme = 'dark';
      } else {
        this.theme = 'light';
      }
    } catch (error) {
      const err = error as Error;
      this.onError('读取颜色模式失败: ' + err.message);
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
      this.controller.registerJavaScriptProxy(this.proxy, '__arkts', ['readAsset', 'onImageViewerChange']);
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
          hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, '预览页面就绪，桥接已建立');
        })
        .onConsole((event): boolean => {
          const msg = event?.message?.getMessage() ?? '';
          hilog.info(PREVIEW_DOMAIN, PREVIEW_TAG, 'console: %{public}s', msg);
          return true;
        })
        .onErrorReceive((event) => {
          this.onError('预览加载错误: ' + (event?.error?.getErrorInfo() ?? ''));
        })
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
