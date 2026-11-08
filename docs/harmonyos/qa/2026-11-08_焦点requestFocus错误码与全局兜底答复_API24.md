# 焦点 requestFocus 错误码族与全局异常兜底（官方文档型答复 + 本机 SDK 复核，API 24）

> 来源：用户带回答方文档型答复（FocusController 类参考 `arkts-apis-uicontext-focuscontroller`、焦点错误码 `errorcode-focus`、`js-apis-app-ability-errormanager`），2026-11-08。
> 本机 HarmonyOS SDK：`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony`（DevEco Studio 26.0）；工程兼容 API `6.1.1(24)`，答复方确认问题在 API 26 模拟器复现、目标真机 API 24。
> 背景：[api_notes L-19](../api_notes.md) 两次 DFX JSCrash（2026-11-06 a849690、2026-11-08）后列出的 5 项「待官方确认」清单，本答复逐条回答。
> 提问口径：正文带本机 API / SDK 版本与设备，末尾带防编造约束（查不到就答"未记载"，不许猜接口名）。

## 问了什么（L-19 待官方确认清单，可复现粒度）

1. `FocusController.requestFocus` 抛错的完整条件与错误码族（150001 / 150002 / 150003 各自何时触发）；ArkTS 侧是否存在目标不存在时**静默返回**的安全变体。
2. 官方推荐的封装姿势；能否**先查询**目标 id 是否已挂载再请求（等价查询接口）。
3. `setTimeout(0)` 延迟请求焦点是否属反模式；组件 id 的注册时序官方有无记载。
4. 应用侧能否对未捕获 JS 异常做**全局兜底**（errorManager 的现行推荐接口与版本）。
5. 150003 的官方定义、处理步骤与重试 / 放弃建议。

## 官方怎么答

### 1. 抛错条件与错误码族 ✅

- `UIContext.getFocusController().requestFocus(key)` 按组件 id 转移焦点，**当前帧生效**。三个错误码：
  - `150001` the component cannot be focused. —— 节点本身不可获焦（如 `focusable` 为 false 或组件默认无获焦能力）。
  - `150002` This component has an unfocusable ancestor. —— 祖先节点中存在不可获焦节点。
  - `150003` the component is not on tree or does not exist. —— id 不存在、指向错误节点、节点已销毁，或对不具有获焦能力的组件请求焦点。
- **ArkTS 侧未记载**「目标不存在时静默返回」的安全变体（官方文档型答复明确）。NDK（C API）`OH_ArkUI_FocusRequest` 以返回值 `ArkUI_ErrorCode` 报告结果而不抛异常（含 `ARKUI_ERROR_CODE_FOCUS_NON_EXISTENT`），但 C 接口不适用 ArkTS 场景。
- 官方推荐 `FocusController.requestFocus` 而非旧式 `focusControl.requestFocus`：当前帧生效、有异常值返回便于排查失败原因。

### 2. 先查询能力与推荐封装 ✅

- 官方 requestFocus 示例本身即 try-catch 写法（演示按钮捕获错误码并打印）。
- 预查询接口（`UIContext`，API 12+）：
  - `getFrameNodeById(id): FrameNode | null` —— 按实体节点 id 查询，查不到返回 null；文档注明遍历查询性能较差，推荐用 `getAttachedFrameNodeById`。
  - `getAttachedFrameNodeById(id): FrameNode | null` —— 获取已挂载节点，未挂载 / 不存在返回 null。
- 推荐封装模式：先 `getAttachedFrameNodeById` 预查询（null 即放弃）→ 再 try-catch 请求焦点；**预查询无法覆盖 150001/150002（获焦能力问题）与查询后到请求前节点被销毁的窗口**，仍需 try-catch。

### 3. setTimeout 与 id 注册时序 ⚠️（行为推导，非明确记载）

- 官方文档**未记载** id 注册时序细节，也未给 setTimeout 延迟建议。
- 基于已声明行为的推导：requestFocus 是「当前帧生效、针对调用时刻组件树状态做同步判断」；目标未完成挂树时，`setTimeout(0)` 只是推迟到下一宏任务，**不保证目标已挂树**，属不可靠的时序猜测，不建议作为常规手段。
- 更可靠模式：事件驱动 —— 目标组件 `onAppear` 置标志位后再发起请求，或结合预查询失败即放弃。onAppear 触发时组件已挂树，此时 id 可被查询与 requestFocus 命中（onAppear 语义；更细粒度的 id 注册时序属未记载）。
- 该条与 [api_notes L-19 结论2](../api_notes.md)（实测 `setTimeout(0)` 内裸调照样 150003）互证。

### 4. 全局未捕获异常兜底 ✅

- `@ohos.app.ability.errorManager`（`@kit.AbilityKit` 导出）提供 JS_CRASH 等异常的全局观测：
  - **现行推荐**：`errorManager.setDefaultErrorHandler(handler)`（API 21+，**API 24 可用**）—— 发生 JS_CRASH 时链式回调，**返回上一次注册的处理器**用于链式调用，**仅限主线程**（子线程调用抛 16000205）。
  - `errorManager.ErrorHandler = (errObject: Error) => void`（API 21+）。
  - 旧接口 `on('uncaughtException')` 为该模块 API 9 起的旧接口，当前文档主推 setDefaultErrorHandler 链式机制。
- 官方示例结构：handler 内记录日志 → 若有前序处理器则链式调用 → 无前序处理器时用 `process.ProcessManager` 同步退出（`new process.ProcessManager().exit(0)`，`process` 自 `@kit.ArkTS` 导入）。
- 定位：崩溃发生后的**兜底与观测**（记录、上报、可控退出），**不替代**调用侧 try-catch —— 对 requestFocus 这类已知会抛错的同步 API，就地捕获更精确、成本更低。

### 5. 150003 官方定义与处理建议 ✅ / ⚠️

- 官方定义：传入 id 指向不存在或未挂树的节点。可能原因：id 不存在 / 指向错误节点、节点已销毁、对无获焦能力组件请求。官方处理步骤：**使用正确的 id 或节点，并确保节点已挂树、可见且具有获焦能力**。
- 重试 / 放弃策略官方**未记载**；答复方按错误语义给工程建议：条件渲染 / 页面切换中目标预期稍后挂载 → 事件驱动重试（onAppear 后再请求）；id 拼写错 / 组件已销毁 / 本身无获焦能力 → 重试无意义，记录日志降级（默认焦点流转或 `defaultFocus` 构建期声明）。

## 本机 SDK 声明复核（2026-11-08，均 ≤ API 24）

| 声明 | 位置 | since |
| --- | --- | --- |
| `FocusController.requestFocus(key)` `@throws 150001/150002/150003` | `@ohos.arkui.UIContext.d.ts` 3252–3264 行 | 12 |
| `UIContext.getFrameNodeById(id): FrameNode \| null` | 同文件 4965 行 | 12 |
| `UIContext.getAttachedFrameNodeById(id): FrameNode \| null` | 同文件 4977 行 | 12 |
| `errorManager.setDefaultErrorHandler(defaultHandler?: ErrorHandler): ErrorHandler`（主线程限定，子线程抛 16000205） | `@ohos.app.ability.errorManager.d.ts` 492 行 | 21 |
| `errorManager.ErrorHandler = (errObject: Error) => void` | 同文件 530 行 | 21 |
| `process.ProcessManager.exit(code: number): void` | `@ohos.process.d.ts` 113 行（实例方法） | 9 |
| kit 导出：`@kit.AbilityKit` → `errorManager`；`@kit.ArkTS` → `process` | 两个 kit 声明文件均确认 | — |

## 落地影响

- [api_notes L-19](../api_notes.md) 待官方确认 5 项全部有答案；错误码族 / 预查询 / 全局兜底结论提炼进 api_notes（L-19 回填 + 新条目）。
- 工程落地 v1.46：`FocusRequest.safely` 按 150001/150002/150003 区分日志（不记录 focusId，守 AGENTS.md 硬约束 16）；`EntryAbility` 主线程安装 `setDefaultErrorHandler` 全局 JS_CRASH 兜底。崩溃兜底日志只进 hilog 本地诊断，**禁止**作为埋点 / 上报内容。
- `focusEmptyPane` 的 `setTimeout(0)` 时序猜测按 L-19 结论2 维持「有兜底、不重构」；onAppear 事件驱动改造不在本轮范围。
