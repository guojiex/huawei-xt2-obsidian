# ArkWeb 长图截图宽度：API 24 SDK 核对

> 核实日期：2026-11-03。本文基于 DevEco Studio 26.0.0.851 的本机 API 26 SDK 声明与 HarmonyOS 官方组件截图指南；不是官方 Agent 答复，也不是 API 24 / XT2 或模拟器运行证据。

## 核对问题

| # | 问题 | 结论 |
| --- | --- | --- |
| 1 | `ComponentSnapshot` 能否截取超出目标组件布局边界的 Web 内容？ | 不能据此实现。SDK 声明快照严格限制在组件布局边界；官方组件截图指南的长内容方式是滚动后分段截图。 |
| 2 | API 24 是否可取得 ArkWeb Surface 并转成 PixelMap？ | SDK 声明满足版本下限：`WebviewController.getSurfaceId()` 起始 API 12，仅在 `ASYNC_RENDER` 且 Web 初始化后可用；`image.createPixelMapFromSurface(surfaceId, region)` 起始 API 11。 |
| 3 | Surface 截图是否保证取得大于窗口 / Web 组件可视宽度的完整页面？ | 未记载。SDK 声明没有承诺 Surface 尺寸可超出 ArkUI 父容器，也没有承诺截图包含 `documentElement.scrollWidth` 中窗口外的部分。 |
| 4 | 离屏 Builder 能否绕过此限制？ | `ComponentSnapshot.createFromBuilder()` 起始 API 12，声明支持离屏构建，文档提及 Builder 内可含 Web；同时警告 Web 仍在加载时输出可能不完整。没有验证固定宽度、异步加载完成与截图结果的一致性。 |

## 本机 SDK 证据

- `ets/api/@ohos.arkui.UIContext.d.ts`：`ComponentSnapshot.get()` 起始 API 12；类型说明快照受目标组件布局边界限制。
- `ets/api/@ohos.web.webview.d.ts`：`getSurfaceId()` 起始 API 12，只适用于 `RenderMode.ASYNC_RENDER`，且须待 Web 初始化。
- `ets/api/@ohos.multimedia.image.d.ts`：带 `Region` 的 `createPixelMapFromSurface()` 起始 API 11；无 `Region` 重载起始 API 15。
- `ets/component/web.d.ts`：`RenderMode.SYNC_RENDER` 起始 API 12，最大宽度声明为 500,000 px；异步模式最大宽高为 7,680 px。尺寸上限不证明 ArkUI 父容器外布局或 Surface 截图行为。
- 当前 `PreviewWebView` 使用 `RenderMode.SYNC_RENDER`；长图流程对可视 `ShareImageCaptureLayer` 调用 `ComponentSnapshot.get()`，之后按视口分段合成。
- 官方资料：[Using Component Snapshot](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-uicontext-component-snapshot)。

## 当前结论与恢复步骤

固定宽度长图的跨窗口排版 / 完整捕获**尚未证实，不判定为可行或不可行**。DevEco 当前选中的 API 26 `Huawei_TripleFold` 显示等待模拟器在线；本轮未启动、安装或操作模拟器，也未连接 API24 / XT2。

恢复时先用仅含合成 Markdown 的隔离探针，不读取或修改用户笔记、教程样例或现有附件；记录 Web 组件实际布局宽度、`innerWidth` / `scrollWidth`、Surface / PixelMap 尺寸以及同一长图预览与输出的换行。若离屏 Builder 用例无法确认 Web 已完成渲染，应把该路径保持为未验证，不将 mock / 桌面浏览器结果外推为 HarmonyOS 证据。
