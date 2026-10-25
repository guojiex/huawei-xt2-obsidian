# API 26 模拟器中 rawfile 页面的 WebMessagePort 握手

我在开发“曜石笔记”，HarmonyOS Stage 模型 ArkTS 应用，包名 `com.jxg.huaweiobsidian`，工程 `compatibleSdkVersion 6.1.1(24)`，`targetSdkVersion 26.0.0`。本机 DevEco Studio 为 26.0.0.851，安装的 API 26 SDK 中 `@ohos.web.webview.d.ts` 将 `WebMessage` 定义为 `ArrayBuffer | string`，并将 `createWebMessagePorts()`、`postMessage(name, ports, uri)`、`WebMessagePort.onMessageEvent()` 标注为 `@since 9`。

同步桥接的 Web 页面由 `$rawfile('gitbridge/index.html')` 加载，实际控制器 `getUrl()` 返回 `resource://rawfile/gitbridge/index.html`；页面内 `window.location.origin` 返回 `resource://rawfile`。HarmonyOS 官方答复曾称 rawfile 页面可使用 WebMessagePort，但没有给出完整、可直接运行的握手代码。

## 当前实现与复现

ArkTS 在 Web 组件 `onPageEnd` 中调用 `createWebMessagePorts()`，给一端注册 `onMessageEvent`，然后执行：

```ts
const ports = this.controller.createWebMessagePorts()
const nativePort = ports[1]
nativePort.onMessageEvent((message: webview.WebMessage) => {
  this.handlePortMessage(message)
})
this.controller.postMessage('gitbridge-port', [ports[0]], this.controller.getUrl())
```

页面端注册 `window.addEventListener('message', ...)`，检查 `event.ports` 并绑定第一个 port。`javaScriptProxy` 控制桥接正常，页面也已加载；同步 UI 显示“git 桥接层就绪”。但 clone 收到大于 64 KB 的 HTTP 响应后，ArkTS 能看到 native port 已创建，页面端 `onTransferResult` 报错 `WebMessagePort is not ready`，无法传输数据。

已在 Huawei_TripleFold API 26 arm64 模拟器上做过这些对照：

- `uri` 使用控制器返回的完整页面 URL `resource://rawfile/gitbridge/index.html`，未建立握手。
- `uri` 使用页面 origin `resource://rawfile`，未建立握手。
- 对调两个返回 port 的角色后，页面仍未观察到携带 port 的 `message` 事件。
- 页面 `location.origin` 为 `resource://rawfile`；完整 URL 与 origin 均已由运行时读取，不是猜测值。
- macOS Node 冒烟克隆 GitHub 公共仓库时，`info/refs` 响应为 255,814 字节；Node 环境走 base64 fallback，不能证明 HarmonyOS WebMessagePort。

## 请核实

请依据 HarmonyOS 官方文档和 API 声明回答：

1. `createWebMessagePorts()` 返回数组中哪一个 port 应通过 `controller.postMessage()` 传给 HTML，哪一个应由 ArkTS 注册 `onMessageEvent()`？请给出完整顺序和官方示例。
2. `postMessage(name, ports, uri)` 的 `uri` 要填完整 URL、origin，还是其他格式？rawfile 页面应使用什么确切值？是否支持 `*`？请说明判定规则及文档依据。
3. HTML 页面应监听哪个对象和事件来接收 port？`event.data`、`event.ports` 的实际类型和字段如何读取？是否还需调用 port 的 `start()`？请给出 API 24 可用的最小 ArkTS + HTML 示例。
4. 这些 API 的最低 API 版本分别是多少？API 26 arm64 模拟器里，rawfile 页面是否有已知限制或特殊配置要求？
5. 若官方文档没有覆盖上述运行时行为，请明确标为未记载或推断，不要把推断写成保证；建议给出最小可复现的模拟器验证办法。

请为关键结论附官方文档链接和对应类型声明/示例，并明确区分文档确认、SDK 声明和运行时推断。不要凭记忆编造接口名或默认值。
