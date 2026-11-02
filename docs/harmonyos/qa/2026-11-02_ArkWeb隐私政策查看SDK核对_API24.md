# ArkWeb 在线隐私政策查看：本机 SDK 声明核对

> 核实日期：2026-11-02。本文是本机 API 26 SDK 类型声明核对，不是鸿蒙官方 Agent 答复，也不是 API 24 / XT2 运行证据。

## 核对范围

SDK：DevEco Studio 26.0.0.851，`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets`。

- `ets/component/web.d.ts`：`Web` 组件、`javaScriptAccess`、`onPageBegin`、`onPageEnd`、`onErrorReceive`、`onHttpErrorReceive`、`onSslErrorEventReceive`。
- `ets/api/@ohos.web.webview.d.ts`：`WebviewController.loadUrl(url)`。

## 结论

- `Web`、JavaScript 开关、页面开始 / 结束回调声明为 `@since 8`。
- 网络资源错误与 HTTP 错误的新事件类型声明为 `@since 12`；请求主页面判断 `WebResourceRequest.isMainFrame()` 声明为 `@since 8`。
- SSL 错误事件回调声明为 `@since 12`；`SslErrorHandler.handleCancel()` 无参重载声明为 `@since 9`。带 `boolean` 参数的另一重载自 API 20 起，本实现不使用。
- `WebviewController.loadUrl(url)` 声明为 `@since 9`。
- 上述声明版本均不高于工程 `compatibleSdkVersion 6.1.1(24)`。模块原已声明 `ohos.permission.INTERNET`，本次没有增加权限。

## 实现与验证边界

隐私政策正文仍从用户提供的在线地址加载。原生视图显示主页面加载中 / 失败状态；主页面网络错误、HTTP 错误和 SSL 错误会显示重试，SSL 错误请求通过 `handleCancel()` 取消。

本次 API 版本结论来自 API 26 SDK 的 `@since` 注解；构建可检查 ArkTS 类型和调用签名。API26 `Huawei_TripleFold` 模拟器已验证单 / 双 / 三屏关于页入口、单 / 三屏在线正文加载，以及应用栏返回、页内返回和系统 Back 的返回层级；这不代表 API24 / XT2 运行通过，相关设备由用户手动验收。网络不可用与重试状态未在设备上触发，详见 [v1.11 验收记录](../../releases/v1.11/需求文档.md#4-验收记录)。
