# 键盘避让 OFFSET_WITH_CARET 与 ArkWeb 避让叠加（2026-11-08，API24）

> 背景：v1.46 46.6 修双重避让时固定了 `setKeyboardAvoidMode(RESIZE)`，但 RESIZE 把每次键盘起落变成全窗口 resize —— `windowSizeChange` 重发布 → 三栏 + 两个 Web 全页重排，XT2 真机中文输入法弹起「整页刷新弹一遍」（面板更高、带候选栏、高度分级到位，窗口 resize 两次）。拟改 `OFFSET_WITH_CARET`（本机 SDK `@ohos.arkui.UIContext.d.ts` 实证 `OFFSET_WITH_CARET = 2`，`@since 14` ≤ 24），就以下 5 问求证官方。答复为官方 Agent 文档型回答（用户转交，见下方逐条），关键声明已用本机 API 26 SDK 复核。

## 问了什么（可复现粒度）

环境声明：DevEco Studio 6.0（Windows），工程 `compatibleSdkVersion 6.1.1(24)`，目标设备 Mate XT2（API 24 真机）；本机 SDK 声明核对基于 API 26；x86_64 模拟器（API 26）IME 走 WM 层窗口收矮、等价 RESIZE，不可外推真机。应用形态：ArkUI 三栏自绘 + 每栏一个 ArkWeb（`RenderMode.SYNC_RENDER`），编辑器是 ArkWeb 内 contenteditable（非原生 TextInput）。

1. `OFFSET_WITH_CARET` 的上抬量是固定整个键盘高度，还是仅抬到焦点组件 / 光标可见的最小高度？光标位置变化时的二次调整是平滑动画还是瞬移？
2. `OFFSET_WITH_CARET` 下窗口尺寸是否保持不变（`windowSizeChange` 是否完全不因键盘触发）？`avoidAreaChange` / `getWindowAvoidArea(TYPE_KEYBOARD)` 的 `bottomRect.height` 报键盘实际高度还是 0？
3. **关键**：焦点在 ArkWeb 内部 contenteditable 上时，页面级 `OFFSET_WITH_CARET` 的「光标可见」跟踪是否生效？系统此时能否取得 Web 内光标 rect？是否还需配合 `WebAttribute.keyboardAvoidMode`（@since 12）或 `onInterceptKeyboardAttach`？UIContext 级与 WebAttribute 级两个避让模式同时设置时如何叠加、会不会双重避让？
4. `OFFSET_WITH_CARET` 下，CustomDialog 弹窗中的输入框弹键盘时避让行为如何（弹窗随页面上抬还是自行避让）？
5. API 24 真机上 `OFFSET_WITH_CARET` 有无已知缺陷或与 RESIZE 不同的兼容性限制？

末尾防编造约束：逐条依据官方文档或 SDK 声明回答；查不到直接答「未记载」，不猜接口名 / 参数 / 行为，不把 API 26 模拟器行为当作 API 24 真机结论。

## 官方逐条答复

### 1. 上抬量与二次调整

- 官方枚举声明：「OFFSET_WITH_CARET14+：上抬模式，输入框光标位置发生变化时也会触发避让」。属 OFFSET（上抬）家族，非固定抬整个键盘高度；参照 OFFSET 模式说明「当输入光标距离屏幕底部的高度大于键盘高度时，page 不会抬起」，上抬按需：仅光标会被键盘遮挡时才抬到光标可见。
- 二次调整是动画还是瞬移：**未记载**，真机实测为准。

### 2. 窗口尺寸与避让区域回调

- OFFSET / OFFSET_WITH_CARET 属「上抬」非「压缩」，RESIZE 才压缩页面。上抬模式下 `windowSizeChange` 是否完全不因键盘触发：**未记载该保证**（机制上不做压缩、预期不走窗口尺寸变化路径，真机日志验证）。
- `getWindowAvoidArea(TYPE_KEYBOARD)` 在该模式下的取值：**未记载**。既有事实：`avoidAreaChange` 回调中键盘弹出时 `bottomRect.height` > 0、收起为 0（官方弹窗示例以此判断键盘显隐），但示例未区分避让模式。

### 3. ArkWeb 内 contenteditable 与两级避让叠加（关键）

- **UIContext 级与 Web 级是两套独立机制**：`WebAttribute.keyboardAvoidMode`（API 12+）是 Web 组件自定义避让模式，且明确记载「当 UIContext 设置的键盘避让模式为 KeyboardAvoidMode.RESIZE 模式时，该接口功能不生效」——即 UIContext 为 OFFSET_WITH_CARET（非 RESIZE）时 **Web 组件自己的避让模式生效，两级同时起作用**。
- Web 级默认 `WebKeyboardAvoidMode.RESIZE_CONTENT`（同时调整可视视口和布局视口）。页面级上抬 + Web 内部视口调整存在**双重避让**可能，合成规则**未记载**，真机验证。
- 消解开关：`WebKeyboardAvoidMode.RETURN_TO_UICONTEXT`（**API 22+**）——「Web 组件的软键盘避让行为将跟随 UIContext 设置的 KeyboardAvoidMode 模式，Web 组件不再处理组件的避让」。本工程 API 24 可用，官方推荐以此把避让收敛到 UIContext 一级。
- 页面级 OFFSET_WITH_CARET 能否取得 Web 内 contenteditable 光标 rect：**未记载**。若真机发现 Web 内光标跟踪不生效，RETURN_TO_UICONTEXT 组合是否改善同样**未记载**。
- `onInterceptKeyboardAttach`（API 12+）定位是拦截 / 替换键盘本身（自定义键盘、定制 enter 键），不控制避让几何。

### 4. CustomDialog 弹窗避让

- 明确记载：`setKeyboardAvoidMode` **仅对页面生效**，对弹窗类组件（Dialog、Popup、Menu、BindSheet、BindContentCover、Toast、OverlayManager）**不生效**；弹窗自行避让——与键盘保持 16vp 安全间距，避让到极限高度后压缩高度（压缩发生在外层容器）。API 15 起 `CustomDialogControllerOptions.keyboardAvoidDistance` 可调间距。

### 5. API 24 已知缺陷

**未记载**。通用提示：性能敏感 / 高负载场景键盘与应用动效可能不同步、露出间隙，可用 `expandSafeArea` 让背景铺满规避。

## 本机 SDK 复核（API 26，`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets`）

| 声明 | 位置 | 结果 |
| --- | --- | --- |
| `KeyboardAvoidMode.OFFSET_WITH_CARET = 2` | `api/@ohos.arkui.UIContext.d.ts` | ✅ `@since 14` ≤ 24 |
| `setKeyboardAvoidMode(mode)` | 同上 | ✅ `@since 12` |
| `enum WebKeyboardAvoidMode { RESIZE_VISUAL=0, RESIZE_CONTENT=1, OVERLAYS_CONTENT=2, RETURN_TO_UICONTEXT=3 }` | `component/web.d.ts` 约 5345 行 | ✅ 前三者 `@since 12`；`RETURN_TO_UICONTEXT` **`@since 22`** ≤ 24，注释语义与官方答复一致（跟随 UIContext、Web 不再处理避让） |
| `WebAttribute.keyboardAvoidMode(mode: WebKeyboardAvoidMode): WebAttribute` | `component/web.d.ts` 约 7637 行 | ✅ `@since 12`，默认值注释明确 **Default: WebKeyboardAvoidMode.RESIZE_CONTENT** |

## 结论与落地

- ✅ 落地（v1.46 46.8）：`Index.aboutToAppear` 设 `OFFSET_WITH_CARET`；`EditorWebView` / `PreviewWebView` 两个 Web 显式 `.keyboardAvoidMode(WebKeyboardAvoidMode.RETURN_TO_UICONTEXT)`，Web 默认 RESIZE_CONTENT 不再与页面上抬叠加。
- ⚠️ 真机待验（全部只能在 XT2 / API 24 验）：键盘起落无全页重排（`windowSizeChange` 不触发）；Web 内 contenteditable 光标行是否被系统上抬保持可见（若不生效，评估 Web 侧回退默认 RESIZE_CONTENT 的取舍）；`avoidAreaChange` 在该模式下的报值（`keyboardInsetPx` 消费点已有 `Math.max(0,…)` 防护）；上抬动画平滑度。
- 📌 弹窗结论已解释既有现象：格式弹窗 / 重命名等 Dialog 自行避让（16vp 间距），不随页面上抬——`keyboardSafeBottom` 等 Dialog 内消费点逻辑不受页面级模式切换影响。
- 结论提炼进 [api_notes L-21](../api_notes.md)；改动记录见 [v1.46 需求文档 §46.8](../../releases/v1.46/需求文档.md)。
