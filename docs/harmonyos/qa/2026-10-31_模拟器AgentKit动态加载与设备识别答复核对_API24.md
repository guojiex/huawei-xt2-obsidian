# 模拟器 AgentKit 动态加载与设备识别答复核对（API 24）

日期：2026-10-31。来源：用户粘贴的 AI 生成答复及补充答复（原文带“内容由 AI 生成，仅供参考”；`<rsub ref="…">` 是不可解析的占位引用）。本记录是对答复的核对，不将其视为华为官方答复。

## 问题

首页需要直接显示系统 `FunctionComponent`。当前 API 26 模拟器缺少 `agentKitHsp`，应用启动失败。检查按设备条件动态加载 Kit 依赖组件是否能恢复模拟器启动，并确认是否能继续在首页原位置渲染系统组件。

## 粘贴答复要点

- 建议把静态依赖 `@kit.AgentFrameworkKit` 的组件放入独立 HAR，再从首页动态 `import`；在模拟器跳过加载，在真机加载后仍渲染系统 `FunctionComponent`。
- 建议用 `deviceInfo.productModel === 'emulator'` 区分模拟器和真机。
- 指出 `isAgentSupport` 查询的是指定 Agent 是否可用，不是系统 HSP 是否安装；并指出动态 `import` 被触发后缺少 HSP 时是 Promise reject 还是 native 崩溃仍未知。
- 还断言没有系统 HSP 补装途径、没有构建变体机制，并给出 `ESObject` / `@Builder` 中动态调用组件的示例。

## 依据核对

### 官方文档支持的部分

- 华为[模拟器与真机差异指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-specification)说明部分 Kit 在模拟器上的能力与真机不同；Kit 能力不支持导致应用闪退时，可以尝试动态引入 Kit，并给出缺少 HSP 时的 `LoadJSPandaFile` 错误示例。该文档没有点名 `AgentFrameworkKit`，也没有承诺动态加载后触发该 Kit 一定可被 Promise 异常处理捕获。
- 华为[ArkTS 动态加载指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-dynamic-import)说明动态 `import` 支持条件延迟加载，并可加载 HAR / HSP 等模块；[Navigation 跨包路由指南](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-navigation-cross-package)展示动态加载跨包页面并调用模块返回的 Builder。由此支持“把 Kit 依赖隔离到按需加载模块”作为实现方向，但未核实粘贴答复里的 `ESObject` 属性直接作为 ArkUI 组件在 `@Builder` 内调用这一具体写法。
- 华为[设备信息 API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-device-info)记录 `productModel` 为只读设备信息属性，模块首批 API 从 API 6 起。官方[模拟器 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-tools-faq/app-running-faq-0004)可从官方模拟器 FAQ 目录定位；本轮该 FAQ 正文页面请求超时，未能独立读取原文核验其 `emulator` 字段说明。当前 API 26 模拟器的 `const.product.model=emulator` 已有本机 HDC 实测记录，见下方 F1 历史。
- `deviceInfo.productModel` 可作为模拟器跳过动态加载的门禁，但它不是 HSP 安装状态查询，也不证明 `FunctionComponent` / Agent 本身可用。`isAgentSupport(context, agentId)` 查询的是 Agent 可用性，不能替代模块加载隔离。

### 尚未证实的部分

- 独立 HAR 的具体模块名、动态导入路径、导出形式，以及 `ESObject` + `@Builder` 的组件调用示例没有在本工程编译或运行；不能标注“可编译”。应按实际模块配置及 API 26 SDK 验证。
- 模拟器上实际触发动态导入后，缺少 `agentKitHsp` 的结果仍未知：可能 reject，也可能在 native 加载阶段终止进程。`try/catch` 不是已证实的崩溃保护。
- 官方模拟器差异指南没有证明“所有模拟器都不带 `agentKitHsp`”、没有证明不存在任何 HSP 安装/镜像渠道，也未确认“没有构建变体机制”。粘贴答复中的这些绝对说法不作为结论。
- `productModel === 'emulator'` 是设备型号判断，不等同能力检测；当前 API26 模拟器值已测，XT2 的实际型号与 AgentKit 运行结果仍待真机验证。

## 对本工程的判断

当前 [`Index.ets`](../../../entry/src/main/ets/pages/Index.ets) 在首页静态导入 `@kit.AgentFrameworkKit` 并直接渲染 `FunctionComponent`，因此目前没有 `productModel` 门禁；即使在后续代码中加条件渲染，也不能避免该静态依赖在启动时加载。

既有 2026-10-30 隔离复验将 Kit 依赖留在 `AgentKitPage`，模拟器按 `deviceInfo.productModel` 跳过动态导入；API 26 模拟器构建、安装和启动后进程仍运行。那次只证明“未触发加载时启动隔离可行”，没有证明首页动态挂载 `FunctionComponent`。2026-10-31 当前 main 的启动复验再次命中 `agentKitHsp` 缺失并停留在桌面，详见 [v0.10 验收记录](../../releases/v0.10/需求文档.md#6-验收记录与场景)。

因此推荐的验证方向是：主首页不静态依赖 AgentFrameworkKit；用 `productModel` 在模拟器跳过动态加载；仅在目标设备动态加载 Kit 依赖模块，并在成功后于首页原位置渲染官方组件。该方向受官方动态加载与模拟器差异文档支持，但动态加载后的组件挂载代码、启动稳定性和 XT2 行为仍需分别编译及实机验证。本次只核对和归档文档，没有改代码或声称启动问题已修复。
