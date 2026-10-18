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
import { webview } from '@kit.ArkWeb'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { common, ConfigurationConstant } from '@kit.AbilityKit'

const EDITOR_DOMAIN = 0x0000
const EDITOR_TAG = 'EditorWebView'

/** 注入到 WebView window.__arkts 的对象：JS -> ArkTS 的唯一入口 */
class EditorNativeProxy {
  handler: (msg: string) => void = () => {}

  postMessage(msg: string): void {
    this.handler(msg)
  }
}

/** 桥接内部实现：页面就绪前收到的指令先进队列，ready 后按序补发 */
class EditorImpl {
  private controller: webview.WebviewController
  private base64: util.Base64Helper = new util.Base64Helper()
  private encoder: util.TextEncoder = new util.TextEncoder()
  private readyFlag: boolean = false
  private pending: string[] = []

  constructor(controller: webview.WebviewController) {
    this.controller = controller
  }

  get ready(): boolean {
    return this.readyFlag
  }

  markReady(): void {
    this.readyFlag = true
    const queue = this.pending
    this.pending = []
    for (const script of queue) {
      void this.controller.runJavaScript(script)
    }
  }

  async setContent(text: string): Promise<void> {
    const payload = this.base64.encodeToStringSync(this.encoder.encodeInto(text))
    // base64 只含 [A-Za-z0-9+/=]，可以直接安全拼进 JS 字符串
    this.enqueue(`window.__mdeditor.setContent('${payload}')`)
  }

  async getContent(): Promise<string> {
    const b64: string = await this.controller.runJavaScript('window.__mdeditor.getContent()')
    const bytes = this.base64.decodeSync(b64)
    return new util.TextDecoder().decodeToString(bytes)
  }

  focus(): void {
    this.enqueue('window.__mdeditor.focus()')
  }

  setTheme(theme: string): void {
    const safe = theme === 'dark' ? 'dark' : 'light'
    this.enqueue(`window.__mdeditor.setTheme('${safe}')`)
  }

  private enqueue(script: string): void {
    if (this.readyFlag) {
      void this.controller.runJavaScript(script)
    } else {
      this.pending.push(script)
    }
  }
}

/** 父组件持有的句柄：页面就绪前调用会进队列，不会丢 */
export class EditorBridge {
  private impl: EditorImpl | undefined = undefined

  bind(impl: EditorImpl): void {
    this.impl = impl
  }

  async setContent(text: string): Promise<void> {
    await this.impl?.setContent(text)
  }

  async getContent(): Promise<string> {
    if (!this.impl) {
      return ''
    }
    return await this.impl.getContent()
  }

  focus(): void {
    this.impl?.focus()
  }

  setTheme(theme: string): void {
    this.impl?.setTheme(theme)
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
  /** 外部主题：'light' / 'dark'（跟随系统颜色模式，见 aboutToAppear） */
  @Prop theme: string = 'light'
  /** 内容变化通知（debounce 300ms，只报长度；要内容请调 bridge.getContent()） */
  onChange: (len: number) => void = (len: number) => {}
  /** 页面就绪（首帧可交互） */
  onReady: () => void = () => {}
  /** Web 加载错误 */
  onError: (msg: string) => void = (msg: string) => {}
  /** 父级通过这个句柄下发内容 / 拉取内容（外部传入同一实例，ready 时内部 bind） */
  bridge: EditorBridge = new EditorBridge()

  private controller: webview.WebviewController = new webview.WebviewController()
  private proxy: EditorNativeProxy = new EditorNativeProxy()
  /** 代理是否已注册（onControllerAttached 里注册，onPageEnd 兜底；见 build()） */
  private proxyRegistered: boolean = false

  aboutToAppear(): void {
    this.proxy.handler = (msg: string): void => {
      this.handleMessage(msg)
    }
    // 跟随系统深浅色：Web 内读不到 App 的 token，这里把主题显式传下去
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const mode = ctx.config?.colorMode
      if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        this.theme = 'dark'
      } else {
        this.theme = 'light'
      }
    } catch (error) {
      const err = error as Error
      this.onError('读取颜色模式失败: ' + err.message)
    }
  }

  /**
   * 注册 __arkts 代理（幂等）。失败时复位 proxyRegistered，让 onPageEnd 兜底重试一次。
   * 签名（SDK 实证，api/@ohos.web.webview.d.ts）：
   * registerJavaScriptProxy(jsObject, name, methodList, asyncMethodList?, permission?)
   * —— 位置参数版；options 对象版属于已 deprecated 的 WebController，别混。
   */
  private registerProxy(): void {
    if (this.proxyRegistered) {
      return
    }
    try {
      this.controller.registerJavaScriptProxy(this.proxy, '__arkts', ['postMessage'])
      this.proxyRegistered = true
      hilog.info(EDITOR_DOMAIN, EDITOR_TAG, '__arkts 代理已注册（页面加载前注入，无需 refresh）')
    } catch (error) {
      const err = error as Error
      hilog.error(EDITOR_DOMAIN, EDITOR_TAG, '注册代理失败: %{public}s', err.message)
    }
  }

  private handleMessage(json: string): void {
    let msg: Record<string, string | number> = {}
    try {
      msg = JSON.parse(json) as Record<string, string | number>
    } catch (error) {
      hilog.error(EDITOR_DOMAIN, EDITOR_TAG, '桥接消息解析失败: %{public}s', json);
      this.onError('桥接消息解析失败: ' + json)
      return
    }
    if (msg['type'] !== 'event') {
      return
    }
    const name = msg['name'] as string
    if (name === 'ready') {
      const impl = new EditorImpl(this.controller)
      this.bridge.bind(impl)
      impl.markReady()
      impl.setTheme(this.theme)
      hilog.info(EDITOR_DOMAIN, EDITOR_TAG, 'Web 编辑器页面就绪，桥接已建立');
      this.onReady()
    } else if (name === 'change') {
      this.onChange((msg['len'] as number) ?? 0)
    }
  }

  build() {
    Column() {
      Web({ src: $rawfile('mdeditor/index.html'), controller: this.controller })
        .onControllerAttached(() => {
          // ⚠️ 注册时机（2026-10-18 SDK 实证 + 官方生命周期文档）：
          // onControllerAttached 是注入 JS 对象的建议时机 —— controller 绑定后、页面加载前，
          // 此时注册的代理会随本次页面加载一起注入，无需 refresh、页面只加载一次。
          // （onPageBegin 注册已属太晚；onPageEnd 注册必须 refresh 才会生效。）
          this.registerProxy()
        })
        .onPageEnd(() => {
          // 兜底：onControllerAttached 没跑成时（理论上不会），补注册 + refresh 使其生效
          if (!this.proxyRegistered) {
            this.registerProxy()
            if (this.proxyRegistered) {
              this.controller.refresh()
            }
            return
          }
          // 招呼 Web 侧重发 ready（Web 侧也有轮询兜底）
          void this.controller.runJavaScript(
            'window.__mdeditor && window.__mdeditor.onArktsReady ? window.__mdeditor.onArktsReady() : 0').then(() => {
            hilog.info(EDITOR_DOMAIN, EDITOR_TAG, 'onArktsReady() called')
          }).catch((e: Error) => {
            hilog.error(EDITOR_DOMAIN, EDITOR_TAG, 'onArktsReady failed: %{public}s', e.message)
          })
        })
        .onConsole((event): boolean => {
          // Web 页面 console 输出：spike 排查期的主要证据来源
          // 返回值 true = 不再走系统默认打印（我们只用 hilog 收）
          const msg = event?.message?.getMessage() ?? ''
          hilog.info(EDITOR_DOMAIN, EDITOR_TAG, 'console: %{public}s', msg)
          return true
        })
        .onErrorReceive((event) => {
          this.onError('Web 加载错误: ' + (event?.error?.getErrorInfo() ?? ''))
        })
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme === 'dark'
          ? $r('app.color.bg_card') : $r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }
}
