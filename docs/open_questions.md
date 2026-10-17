# 待决清单：需要你拍板的 / 需要追问鸿蒙的

> 整理于 2026-10-17，基于 `docs/harmonyos/api_notes.md` 的核实结论。
>
> 📌 与鸿蒙官方 Agent 的问答统一存 **`docs/harmonyos/`**（规则见 `docs/harmonyos/README.md`）：
> 提问前先查 `api_notes.md` 与 `qa/` 索引，问过的不重复问。
> 本机版本：**API 24**（`compatibleSdkVersion 6.1.1(24)`），目标设备华为 XT2 三折叠。
>
> 分三组：
> - **第 1 组**：需要**你**拍板的决策（我给推荐，但这是产品取舍，不该我替你定）
> - **第 2 组**：需要**再问鸿蒙 Agent** 的技术问题（附可直接复制的提示词）
> - **第 3 组**：**问了也没用、只能真机测**的（别浪费轮次）

## 📌 TODO 挂起项（暂不拍板，等触发条件）

| # | 挂起项 | 挂起时间 | 何时回来看 | 挂起的代价 |
| --- | --- | --- | --- | --- |
| Q3 | 抽成 ohpm 库的时机 | 2026-10-17 | `push` 实现完成 **或** 真机跑通全流程 **或** 要对外发布 | ohpm 库名过审后永久占用，晚一步可能被人抢注（可用空占位目录对冲，见 Q3） |

**已决，别再问**：Q1 = 三栏**自绘**；Q4 = 后台同步**先不做**（已转需求池 C 节）。仅剩 **Q2（zip 导出进不进 MVP）** 未拍板。

---

## 第 1 组：需要你拍板的决策

### Q1. 三栏布局用官方 `FoldSplitContainer` 还是自绘？—— ✅ 已定：**自绘**（2026-10-17）

用户先拍板"用官方 `FoldSplitContainer`"，但查完官方参数表后发现**该组件不适用**，故改走自绘。三条硬伤：

1. **它的"三分栏"不是三列横排** —— 实际结构是 `extra` 作为右侧**贯穿列**，`primary` / `secondary` 在左侧**上下堆叠**（`verticalSplitRatio` 控上下高度、`horizontalSplitRatio` 控左右宽度）。横排只有 2 列，而我们要的是三块物理屏横排的「文件树 | 编辑器 | 预览」。
2. **比例只能选预设枚举** —— `PresetSplitRatio` 只有 `LAYOUT_1V1`(1:1) / `LAYOUT_3V2`(3:2) / `LAYOUT_2V3`(2:3)，**没有 1:1:1，也不支持任意值**；带 extra 时默认 `LAYOUT_3V2`，右侧只占 2/5。
3. **它是为双折叠悬停态设计的** —— 二分栏时只有 `verticalSplitRatio`（上下分），连"列表 | 详情"左右分栏都不是它的默认形态。

> 附带事实：导入路径是 `import { FoldSplitContainer } from '@kit.ArkUI'`（不是独立的 advanced 包）。

**最终方案**：三档全部自绘。M0 先用等分（双屏 50% / 三屏各 1/3），折痕只做标注；真机打印 `getCurrentFoldCreaseRegion()` + `foldAngleChange` 双角度**校准后写成常量表**替换等分。

### Q2. zip 导出要不要进 MVP？

背景：官方明确 **PC/2in1 不支持备份恢复、Tablet 开自由多窗后也不生效**，而我们的 `deviceTypes` 含 `2in1`。所以系统备份**不能当唯一保命通道**。

| 选项 | 说明 |
| --- | --- |
| **进 MVP** ⭐推荐 | 沙箱目录文件管理器看不到，用户拿不走自己的笔记就是数据囚笼。成本 S（压缩 + FilePicker） |
| 后置 | 先用系统备份凑合，v2 再补导出 |

**我的推荐**：进。这和 F0（本地库）是同一条逻辑——不配远端也要能用自己的数据。

### Q3. 抽成 ohpm 库的时机？ —— ⏸ **挂起（TODO），2026-10-17 用户决定延后**

背景：D1（HAR 内 rawfile 可被主模块加载）已基本确认可行，抽库的前置风险解除。但 **`push` 还没做**，库的核心能力不完整。

| 选项 | 说明 |
| --- | --- |
| **先补 push → 真机验证 → 再抽库** ⭐推荐 | 抽库后每改一次要重新出 HAR，调试成本上升；且库还没被真机验证过 |
| 现在就抽，抢注库名 | ohpm 库名过审后**永久占用**。但可能把一个没验证过的实现固化出去 |

**我的推荐**：先补 push。除非你想抢名字——那我可以现在就建 `libs/gitbridge/` 占个位。

> **状态：TODO，暂不拍板。** 重新评估的触发条件（满足任一即回来看这条）：
> 1. `push` 已实现，且能跑通一次完整 push（本地或真机）
> 2. 真机（XT2）跑通 clone → 编辑 → commit → push 全流程
> 3. 出现第二个消费方（第二个项目 / 第二个人要用这套 gitbridge）
> 4. 准备对外发布或宣传
>
> ⚠️ **挂起的唯一代价**：ohpm 库名过审后永久占用，晚一步可能被人抢注。
> 零成本对冲：现在建 `libs/gitbridge/` 空占位目录 + README（只写用途与状态，不含代码），不改动 `web/gitbridge/` 现有实现，需要时再升位为正式库。要不要做这个占位，另议。

### Q4. 后台同步做不做？ —— ✅ 已定：**先不做**（2026-10-17），转为需求池条目

背景：前台 clone/push 无需任何额外权限。只有当**退到后台仍需传输**时，才需要 `KEEP_BACKGROUND_RUNNING` + `DATA_TRANSFER` 长时任务。

| 选项 | 说明 |
| --- | --- |
| **只做前台** ⭐已选 | 最简单合规，clone/push 时给进度条、不切走 |
| 做后台长时任务 | 体验更好（可以切走干别的），但多一套权限申请与审核成本 |

**决定**：MVP 只做前台同步；后台自动同步**不作为需求消失**，已登记进 `docs/requirements_backlog.md` 的 C 节（价值中高 / 成本 M / 状态「先不做，v2 再评估」），等前台链路真机跑稳后再回来评估。

---

## 第 2 组：需要追问鸿蒙 Agent 的技术问题

### 用法

复制下面「提示词」整段粘给鸿蒙官方 Agent。**建议一次只问一组**，答得笼统就拆开再问。

按价值排序：**B 组（Web 组件）> A 组（三折叠）> C 组（文件/安全）> D 组（ohpm）**。

---

### 提示词 · B 组 —— ✅ **已问过**（2026-10-17）

> 答案已回来并归档：[`harmonyos/qa/2026-10-17_B组追问_Web组件.md`](harmonyos/qa/2026-10-17_B组追问_Web组件.md)
> 关键结果：**B-1 拦截方案否决**（`getRequestBody()` 返回 string，push 二进制有风险）；**B-4 推翻** NodeContainer（卸载即重载 → 改 `visibility(Hidden)` 常驻）；B-2/B-6 确认 MessagePort 可用且可 transfer 进 Worker。
> **别再问这组**，除非要追问细节。

<details><summary>当时的提问原文（留档）</summary>

```
我在用 HarmonyOS 原生（ArkTS）开发一个笔记应用，工程 API 版本：
compatibleSdkVersion 6.1.1(24)，即 API 24；targetSdkVersion 26.0.0。

架构：在 Web 组件里用 $rawfile 加载一个离线页面，页面内运行 isomorphic-git
（纯 JS 的 git 实现），通过与原生层通信来操作沙箱内的笔记目录、并发网络请求。

上一轮我已确认：ArkWeb 内核禁止 resource:// 协议的跨域访问，所以页面内 fetch
直连 github.com 会被拦。我现在用的是「JS 侧自定义 http client，把请求转发到原生
@ohos.net.http」的方案（已在 node 环境伪真机测试成功 clone 真实仓库）。
官方建议的替代方案是 onInterceptRequest 拦截 + didReceiveResponseBody 流式回填，
那样 JS 侧能继续用原生 fetch、零改动。

请核实以下问题，每条请标注【文档明确记载】还是【推断】，不确定的直接说不确定：

B-1（最关键）onInterceptRequest 的回调参数 WebResourceRequest，能否完整拿到
     POST 请求的 body？具体是哪些字段/接口？是否支持二进制 body？
     背景：git push 走 git-receive-pack，是 POST + 大二进制 body（可能是 zlib 压缩的
     packfile）。如果拿不到 POST body，拦截方案在 push 场景就不成立。
     若确实拿不到，请说明官方文档记载的限制，或给出在拦截模式下处理 POST 的官方做法。

B-2 WebMessagePort（controller.createWebMessagePort）在 resource://rawfile/ 加载的
     页面上能否正常建立？postMessage 传 ArrayBuffer 有没有大小上限？
     背景：runJavaScript 的返回值是 string，我需要一个传 packfile 二进制的通道。

B-3 runJavaScript 传参/返回值的长度上限，官方文档到底有没有记载？
     若有请给出数值和出处；若没有请直说。

B-4 离线 Web 组件（NodeController + NodeContainer 动态挂载/卸载 Web 节点）：
     节点被卸载（NodeContainer 移除）后，页面内的 JS 运行环境与 JS 变量状态是否保留？
     重新挂载时会不会重新加载页面？我想用它承载一个常驻的 git 计算容器。

B-5 中文输入法在 Web 组件的 contenteditable / textarea 上：
     官方是否记载已知的兼容性问题？有没有面向输入法的推荐配置组合
     （keyboardAvoidMode / blurOnKeyboardHideMode / onInterceptKeyboardAttach）？
     我打算用它做 Markdown 编辑器，中文输入法体验是关键。

B-6 Web 页面内的标准 Web Worker，在 ArkWeb（Chromium M114）里是否可用？
     Worker 内能否使用 WebMessagePort？
     背景：我已知道 javaScriptProxy 注入的对象在 Worker 里访问不到（无 window），
     想确认 Worker 是否至少能用 MessagePort 与原生通信。
```

</details>

---

### 提示词 · A 组（决定 M0 三栏怎么实现）

```
我在为华为 XT2（Mate XT 系列，三折叠、双折轴）开发应用，工程 API 版本：
compatibleSdkVersion 6.1.1(24)，即 API 24。

上一轮我确认了：display.getFoldStatus() 的 FoldStatus 枚举只有
UNKNOWN/EXPANDED/FOLDED/HALF_FOLDED 四个值，且对三折叠而言
EXPANDED = 双屏态、FOLDED = 单屏态。但三屏全展开（G 态）对应哪个值官方未记载。
另外 display.getCurrentFoldCreaseRegion() 的签名只返回单个 Rect，
而三折叠有两条铰链。

请核实以下问题，每条请标注【文档明确记载】还是【推断】，不确定的直接说不确定：

A-1 三折叠设备（Mate XT / XTs / XT2）三屏全展开态（G 态）时，
     display.getFoldStatus() 返回什么值？官方文档或三折叠开发实践里有没有明确映射表？
     如果没有，官方推荐用什么方式区分三折叠的 F/M/G 三态？
     （例如是否应改用 foldAngleChange 的双角度值判断？判据阈值是多少？）

A-2 display.getCurrentFoldCreaseRegion() 在三折叠设备上返回什么？
     是返回其中一条折痕、还是合并后的区域、还是其他？官方有没有记载？
     如果它不可靠，官方推荐的获取三折叠两条铰链位置的方式是什么？

A-3 我已确认 FoldSplitContainer 不适用于我的场景（它的"三分栏"是 extra 侧列贯穿 +
     primary/secondary 上下堆叠，不是三列横排；且 PresetSplitRatio 只有 1:1 / 3:2 / 2:3
     三个预设，没有 1:1:1）。
     请回答：面向**三折叠设备的三屏展开态**，官方有没有**多列横排**的布局组件或推荐方案？
     比如 Navigation 的 Split 模式、SideBarContainer、GridRow/GridCol、或其他"一多"布局能力？
     我想要的是：三块物理屏横向排列时，三列各占约 1/3，且列边界落在两条铰链上。
     如果有，请给出组件名、import 路径与是否支持自定义列宽比例。

A-4 三折叠设备展开成三屏态时，窗口宽度（px）的典型值或官方推荐断点分档是多少？
     我想校准我的断点阈值（当前定的是 sm<600vp / md 600-840vp / lg>=840vp）。
```

---

### 提示词 · C 组（文件与安全，可直接落码前确认）

```
工程 API 版本：compatibleSdkVersion 6.1.1(24)，即 API 24。

C-1 fileIo.AtomicFile（API 15+）：
     (1) finishWrite() 在目标文件已存在时的行为是什么？覆盖还是报错？
     (2) openWrite() 打开后，原文件在 finishWrite 之前是否保持可读且内容不变？
     (3) 能否在 TaskPool 子线程中调用？
     (4) 临时文件默认写在哪里？能否指定？
     (5) 写入大文件（比如 5MB 的 Markdown）有没有已知限制？
     背景：我要用它保证笔记写入的原子性——写一半崩溃不能损坏原笔记。

C-2 @kit.AssetStoreKit（asset.addSync / querySync）：
     (1) addSync 在 ALIAS 已存在时的行为？是覆盖还是报错？报错码是多少？
     (2) 单个 SECRET 的长度上限？
     (3) 能否枚举/删除指定 ALIAS 前缀的所有资产？接口名是什么？
     (4) 应用卸载后资产是否保留？（决定我是否需要在重装机时引导用户重填令牌）
     背景：我要按笔记库分别存 GitHub/Gitee 访问令牌，alias 形如 vault:<库id>:token。

C-3 @ohos.file.fs 在 TaskPool 中调用时，有没有需要注意的限制？
     比如 AtomicFile、listFileSync、renameSync 是否都可在子线程调用？

C-4 应用数据备份恢复：官方说 PC/2in1 不支持、Tablet 开自由多窗后不生效。
     请确认这个限制，并说明：如果我的 deviceTypes 同时声明了 phone/tablet/2in1，
     备份能力在 phone 上是否照常生效？是否会因为声明了 2in1 而整体失效？
```

---

### 提示词 · D 组（ohpm 发布，抽库时才需要）

```
我准备把一个 HarmonyOS 三方库发布到 ohpm 中心仓（ohpm.openharmony.cn）。

D-1 ohpm publish 时，是否必须使用 release 构建产出的 .har？
     debug 构建产出的 .har 能否发布？官方有没有强制要求？

D-2 中心仓的审核周期通常是多久？是否有加急通道？
     （如果官方未记载请直说。）

D-3 库名被占用后，除了换名还有别的办法吗？如果我先发布一个 0.0.1 占位版本，
     后续能否继续发布 0.0.2 / 1.0.0？版本号升级有没有限制？

D-4 我的库依赖了 rawfile 资源（一个打包好的 HTML + JS 单文件，约 300KB），
     随 HAR 一起发布。除了主模块与 HAR 的 rawfile 重名冲突，还有没有其他注意点？

D-5 三方库的 LICENSE 是否强制要求？如果我用 Apache-2.0，
     需要在 oh-package.json5 里声明什么字段？
```

---

## 第 3 组：问了也没用，只能真机测

这些官方大概率没记载，追问只会得到"不确定"。**直接排进 M0.5 spike 的检查表**：

| 项 | 怎么测 |
| --- | --- |
| **中文输入法（含 CM6 的 contenteditable vs textarea）** | 真机打字：候选词、光标跟随、中文标点、联想输入、长按选择；⚠️ 官方建议优先 textarea，**必须顺带对比 textarea**，否则 CM6 实测不过时没有降级依据 |
| 三屏态 `getFoldStatus()` 实际返回值 | 三个形态各打印一次，建映射表（若 A-1 问不出来） |
| 两条铰链的实际位置 | 打印 `getCurrentFoldCreaseRegion()` + 双角度值，与视觉折痕对照 |
| 大库 clone 的实际耗时 | 用你真实的笔记库（几百篇）跑一次，记时 |
| `runJavaScript` 实际能传多长 | 二分法测：从 1KB 往上试到失败 |
| WebMessagePort 单条 ArrayBuffer 的实际上限 | 分块 4MB 起步往上试，定出稳定块大小（可用性已确认，只剩上限） |
| `visibility(Hidden)` 时 JS 是否被暂停/降优先级 | git 容器 Hidden 后发起一次 clone，看是否照常跑完 |
| 折叠切换时 Web 组件是否闪烁/丢滚动位置 | 三形态来回切，看编辑区 |
| 三屏态下 Web 组件宽度是否超 7680px 物理像素 | 打印实际像素宽度与断点值 |

**M0.5 spike 建议输出**：一张表，每项写「通过 / 降级 / 阻塞」，并附真机打印的原始值（尤其三折叠那几个）。

---

## 依赖关系（哪条卡住哪条）

```
A-1 / A-2（三折叠 FoldStatus 与折痕）
   └─> Q1 已定为自绘，不再阻塞 M0
   └─> 但仍决定「等分」能否升级为「真机校准值」（影响折痕对齐精度，不阻塞开工）
A-3（有无官方多列横排方案）
   └─> 若有 → 可省掉自绘 + 校准；若无 → 自绘方案不变

~~B-1（onInterceptRequest 能否拿 POST body）~~ ✅ 已解决（2026-10-17）
   └─> 结论：能拿但 getRequestBody() 返回 string，二进制有风险 → **拦截方案否决，转发方案定案**

~~B-2（WebMessagePort 可用性）~~ ✅ 已解决（2026-10-17）
   └─> 结论：rawfile 页面可用、支持 ArrayBuffer → 通道选型定案（分块 4MB）；
       仅「单条上限多少」残留，只能真机测，不阻塞

Q2（zip 导出进不进 MVP）
   └─> 独立，随时可做

Q3（抽库时机）⏸ TODO 挂起
   └─> 依赖 push 完成 + 真机验证，不阻塞任何当前工作
```

**最该先问的一条**：**A-3**（除了已否决的 `FoldSplitContainer`，官方还有没有面向三折叠三屏态的多列横排方案——若有就省掉自绘的折痕校准工作）。
> 原本并列第一的 **B-1 已于 2026-10-17 有答案**（拦截方案否决），B 组其余问题一并回来了，见 `docs/harmonyos/qa/`。
