# HarmonyOS API 核实笔记（API 24）

> 📌 本文件是**所有鸿蒙行为结论的单一真源**，维护规则见 [`README.md`](README.md)：
> 提问前先查这里；结论只准链接不准复制；被推翻的加删除线保留；真机验证后把 ⚠️/❓ 改成 ✅ 并写实测值。
>
> **来源**：华为官方 AI 助手对本工程 [`prompts/2026-10-17_首批提问_API24.md`](prompts/2026-10-17_首批提问_API24.md) 的答复（2026-10-17）
> （已问过什么见 [`qa/2026-10-17_首批回答_API24.md`](qa/2026-10-17_首批回答_API24.md)）。
> 本机版本：`compatibleSdkVersion 6.1.1(24)` = **API 24**，`targetSdkVersion 26.0.0`。
>
> **可信度标记**（落码前必看）：
> ✅ 官方接口/文档明确记载，可直接落码
> ⚠️ 对方基于文档机制**推断**，务必真机验证
> ❓ 官方文档未记载（对方已诚实标注"不确定"），不要押宝
>
> **总原则：凡标 ⚠️ / ❓ 的，在真机验证前不许写进关键路径。** 已据此调整了 MVP 的验证顺序。

---

## A 组：三折叠形态与折痕

### A1 折叠状态 ✅ —— **Mate XT2 五态实测完成（2026-10-17）**

```typescript
import { display } from '@kit.ArkUI';

display.isFoldable(): boolean          // 是否可折叠
display.getFoldStatus(): display.FoldStatus
display.on('foldStatusChange', cb) / off
display.on('foldAngleChange', cb: Callback<Array<number>>)  // 三折叠返回【两个】角度，从右到左为折轴一、折轴二
```

**`FoldStatus` 完整枚举**（SDK 实证：`sdk/default/openharmony/ets/api/@ohos.display.d.ts:708`）：

| 值 | 名字 | 文档语义 | since |
| --- | --- | --- | --- |
| 0 | `UNKNOWN` | 未知 / 不可折叠 | 10 |
| 1 | `EXPANDED` | 完全展开；**双轴设备：折轴一全开 + 折轴二折叠** | 10 |
| 2 | `FOLDED` | 合起；**双轴设备：两轴均折叠** | 10 |
| 3 | `HALF_FOLDED` | 半折；双轴设备：折轴一半折 + 折轴二折叠 | 10 |
| **11** | `EXPANDED_WITH_SECOND_EXPANDED` | **双轴均全开（= 三屏全展开）** | **15** |
| 12 | `FOLDED_WITH_SECOND_EXPANDED` | 折轴一折叠 + 折轴二全开 | 15 |
| 13 | `HALF_FOLDED_WITH_SECOND_EXPANDED` | 折轴一半折 + 折轴二全开 | 15 |
| 21 | `EXPANDED_WITH_SECOND_HALF_FOLDED` | 折轴一全开 + 折轴二半折 | 15 |
| 22 | `FOLDED_WITH_SECOND_HALF_FOLDED` | 折轴一折叠 + 折轴二半折 | 15 |
| 23 | `HALF_FOLDED_WITH_SECOND_HALF_FOLDED` | 两轴均半折 | 15 |

> 早先 A1 只写了 4 个值（`UNKNOWN/EXPANDED/FOLDED/HALF_FOLDED`）—— 那是 **since 10** 的老枚举。
> 三折叠需要的双轴组合值是 **since 15** 才加的，我们 `compatibleSdkVersion` = 6.1.1(24)，**全部可用**。

#### 真机实测（Mate XT2，状态栏 `FS:` 读数，2026-10-17）

| 形态 | 窗口宽 vp | `FS` | 对应枚举 |
| --- | --- | --- | --- |
| 外屏合起 | 380 | **2** | `FOLDED` ✅ 与文档一致 |
| 内屏只用最左一屏 | 379 | **12** | `FOLDED_WITH_SECOND_EXPANDED`（折轴一折 + 折轴二全开）✅ |
| 左两屏展开 | 709 | **1** | `EXPANDED` ✅ 与文档一致 |
| 右两屏展开 | **683** | **1** | `EXPANDED` ⚠️ 与左两屏同值 |
| 三屏全展开 | 1061 | **11** | `EXPANDED_WITH_SECOND_EXPANDED` ✅ **A1 的 ❓ 销账** |

> **修正（第四轮）**：首轮把「只用最左一屏」读成 11，是**读数滞后**——折完没等刷新就抄了。
> 停稳后实测是 **12**。所以单屏(12) / 三屏(11) **本来就能区分**，歧义 ② 解除。

#### ⚠️ 仍存在的歧义（实测得出）

**`1` 同时表示「左两屏 709vp」与「右两屏 683vp」** —— 两种折法的窗口宽度**不一样**，
但 `foldStatus` 完全无法区分。只靠它连该分几栏都定不了。

#### ✅ 副产品：三块物理屏宽的反推被交叉验证

| 形态 | 实测 vp | 由 379/330/352 推算 | 差 |
| --- | --- | --- | --- |
| 左两屏 | 709 | 379 + 330 = 709 | 0 |
| 右两屏 | **683** | 330 + 352 = 682 | **1vp** |
| 三屏 | 1061 | 379 + 330 + 352 = 1061 | 0 |

→ **反推值可信度大幅提升**（三态自洽，误差 1vp 属取整）。
但性质不变：它仍是**反推**，`creaseRects` 的接口直读值**仍待 A2 采集**（D3）。

#### 结论（架构级，加固 A3 决策）

**`foldStatus` 不可用于任何布局分支**：它有歧义（左/右两屏都是 1，而两者窗口宽不同：709 vs 683），
而**窗口宽度 vp 能唯一区分全部形态**（380 / 379 / 709 / 683 / 1061）。

→ **A3「断点只由窗口宽度决定、不用 `getFoldStatus()` 做形态分支」的决策，被真机数据进一步坐实。**
`foldStatus` 的定位确定为：**只读数、只写日志、只做诊断显示，绝不进布局算式。**

### A2 折痕区域 ⚠️ **官方答复已被 SDK 实证推翻（2026-10-17）**

```typescript
// ❌ 官方 Agent 的答复（2026-10-17 首批）：「只返回单个 Rect」
~~display.getCurrentFoldCreaseRegion(): display.Rect~~

// ✅ SDK 类型定义实证（v0.1 落码时查得）：返回结构体，折痕是【数组】
display.getCurrentFoldCreaseRegion(): display.FoldCreaseRegion
// FoldCreaseRegion { displayId: number, creaseRects: Array<Rect> }
```

**结论修正**：折痕是 **`creaseRects` 数组**，不是单个 Rect —— 这意味着三折叠的两条铰链**有可能**一次性全部拿到。
（出处：`docs/releases/v0.1/需求文档.md` §6.1 验收记录；代码见 `EntryAbility.logFoldCalibration()`，它打印的类型就是 `display.FoldCreaseRegion`。）

> ⚠️ 但这**只是类型定义层面的事实**，不等于三折叠运行时真的返回两段 —— 仍属 ❓，**真机打印前不许进布局算式**。
> 教训记一笔：**官方 Agent 的答复也要交叉验证**，能查 SDK 类型定义时优先查 SDK（这次就是靠 SDK 发现答复错了）。

#### 🔴 真机实测（2026-10-17，Mate XT2）：接口返回**不可用**

状态栏 `C:` 读数（折痕中心 x，vp，多条逗号分隔）在**五种形态下全部是 `372,372`**：

| 形态 | 窗口宽 vp | `FS` | `C:` 读数 |
| --- | --- | --- | --- |
| 外屏合起 | 380 | 2 | **372,372** |
| 内屏只用最左一屏 | 379 | 12 | **372,372** |
| 左两屏展开 | 709 | 1 | **372,372** |
| 右两屏展开 | 683 | 1 | **372,372** |
| 三屏全展开 | 1061 | 11 | **372,372** |

两个致命问题：

1. **两条 rect 中心 x 完全相同** —— 第二条折痕（反推应在 709）完全没体现。
2. **不随形态变化** —— 与接口名 `getCurrent...` 的字面语义矛盾，更像设备级常量而非当前态。

（数值上 372 与反推的第一条折痕 379 差 7vp，接近但不相等。）

→ **结论：该接口在三折叠上不足以支撑「按折痕动态分栏」。**
已就此事咨询鸿蒙官方，提问全文见 **[`咨询_折痕接口_XT2.md`](咨询_折痕接口_XT2.md)**（含复现代码、五态实测表、5 个待确认问题）。

#### 📨 官方答复（2026-10-17 收到，已交叉验证后落码）

**Q1 定性**：两条 rect **符合预期**（三折叠是双折轴设备）；但「两条中心 x 相同 + 五种形态不变」
与 `getCurrent...` 的字面语义**不符**，官方**未**将其说明为三折叠预期行为、也无公开已知问题声明。
推断为**系统侧未完整实现双折轴上报**，属设备/系统实现限制的可能较大，建议走工单反馈。
→ 也就是说：**官方也没法确认这是 bug 还是限制**，但承认现象与语义矛盾。

**Q2 单位与坐标系**：单位是 px ✅（`px2vp()` 换算正确）；坐标系相对 `FoldCreaseRegion.displayId` 对应显示设备；
`creaseRect` 是**有面积的折痕避让区**，`width/height` 是该区域尺寸（不是零宽度的线）；
判折痕方向看宽高比 —— **`width < height` = 竖向折痕（左右分区）**；`left + width / 2` 取中心线 ✅。
⚠️ 官方也说了：因该机型返回值不随形态变，**无法据此反推参考系**。

**Q3 替代方案（按官方推荐序）**：

| 方案 | 能否给折痕坐标 | 备注 |
| --- | --- | --- |
| **`display.getLiveCreaseRegion()`**（**@since 20**） | ✅ 同样返回 `FoldCreaseRegion` | **首选**，官方称更适合动态折叠角度场景 |
| `display.on('foldAngleChange')` | ❌ 只有角度 0~180 | 适合判悬停/半折姿态，推不出位置 |
| `display.getFoldDisplayMode()` | ❌ | 只有 MAIN / FULL，无坐标 |
| **断点方案（我们在用的）** | ❌ | **官方明确说这是最佳实践**：布局适配优先基于响应式断点而非折叠状态 |

> ✅ **官方顺带印证了 A1 的结论**：「左两屏与右两屏 `getFoldStatus()` 都是 1」是**符合预期**的 ——
> 三折叠上 `FOLD_STATUS_EXPANDED` 对应双屏态（M 态），左右两种双屏**本就不可区分**，
> **窗口宽度（709 vs 683）才是区分二者的正确依据**。我们的 A1 判断被官方确认。

**Q4 / Q5**：见 A2-bis（FoldSplitContainer）与下方「设备级常量」。

#### ⚠️ 官方示例代码**两处**不能直接照抄（SDK 实证 + 编译实测）

1. **`display.getLiveCreaseRegion()` 编译不过**。
   SDK 里它是 **`interface Display` 的实例方法**（`@ohos.display.d.ts:1432`，`@since 20`），
   而 `getCurrentFoldCreaseRegion()` 才是**模块函数**（同文件 425 行）。必须写成：

   ```typescript
   display.getDefaultDisplaySync().getLiveCreaseRegion()   // ✅
   // display.getLiveCreaseRegion()                        // ❌ 10505001 Property does not exist
   ```

   （编译实测报错：`ERROR: 10505001 ArkTS Compiler Error — Property 'getLiveCreaseRegion' does not exist on type 'typeof display'`）
2. **`px2vp()` 建议在页面侧（UI 上下文）换算**，UIAbility 早期生命周期调用可能异常。
   已照做：`AppStorage` 只存 **px**（`creasePx`），换算放到 `Index.statusRightText()` 里。

> 教训（第二次）：**官方答复 + 示例代码也要用 SDK 与编译器验证**。
> 上一次是 `build-profile` 的 `name` 字段（d.ts 说要、运行时 schema 拒绝），这一次是接口挂错了对象。

#### 🧪 模拟器反证（2026-10-18，Huawei_TripleFold / API 26）：**接口本身没问题，是 XT2 的锅**

同一份代码、同一套采集逻辑，在三折叠**模拟器**上跑出来的值**随形态变化**：

| 形态 | 窗口宽 | `FS` | `C:`（折痕中心 vp） | 说明 |
| --- | --- | --- | --- | --- |
| 外屏合起（single） | 351 | 2 | `388,388` | 两条相同，但 388 > 351 —— 折痕在可视区外 |
| 展开双屏（double） | 712 | 1 | `373` | **只有一条** |
| 三屏展开（triple） | 1107 | 11 | `373,753` | **两条不同**，比例约 33.7% / 68% |

→ **结论升级**：我们的用法（采集时机、px 换算、接口调用方式）**没有问题** ——
模拟器上能拿到随形态变化的两条折痕，**真机恒定 `372,372` 是 XT2 设备/系统侧的实现缺陷**（与官方 Q1 的推断一致）。
⚠️ 但这**不改变布局决策**：真机上数据就是错的，动态分栏在 XT2 上仍然做不了。
→ **副产品**：三档断点在模拟器上同样验证通过（351→sm、712→md、1107→lg），
说明断点阈值不是「只对 XT2 成立」的偶然值。

#### 已落码：双接口同采，等第六轮读数

`EntryAbility.collectCreasePx()` 现在**两个接口都读一遍**（都写 hilog，状态栏优先显示 live），
已构建装机（`entry-default-signed.hap` **00:03:44**）。判定表：

| 三屏态 `C:` 读数 | 结论 |
| --- | --- |
| `379,709`（与反推吻合、随形态变） | live 接口可用 → **动态分栏重新变得可行** |
| 仍是 `372,372` 或恒定不变 | 两接口同病 → **维持等分，动态分栏就此结案** |
| 单条 / `-` | live 接口也取不到 → 维持等分 |

决策不变（且理由更硬了）：本版本**折痕只做日志采集与读数**，布局按等分；
是否做动态分栏，等官方答复 —— 见 **A6**。

### A2-bis `FoldSplitContainer` 核实结论：**不适用本工程**（2026-10-17 查官方参数表 + SDK 复核）

曾把它列为首选方案（悬停态自动避让折痕 + 支持三分栏），查完官方参数表后**否决**。三条硬伤：

> 🔄 **措辞修正（2026-10-17 官方答复后）**：官方 Q4 说「`FoldSplitContainer` **支持**三分栏」，
> 我们此前写的是「**不能**做三列横排」—— **两边都对，只是说的不是同一件事**：
> 它确实有 `primary` / `secondary` / `extra` 三个区域（SDK 实证：`FoldSplitContainerOptions` 含
> `extraRegionPosition`、`horizontalSplitRatio`），**但 `horizontalSplitRatio` 是「primary 与 extra 的宽度比」**，
> 取值只有 `PresetSplitRatio` 三个预设 —— `LAYOUT_1V1` / `LAYOUT_2V3` / `LAYOUT_3V2`（`@ohos.arkui.advanced.FoldSplitContainer.d.ets:202`），
> **没有任何 1:1:1 三列横排的档位**；官方自己也说「分栏边界由窗口宽度与预设比例决定，**不保证落在物理折痕上**，仅悬停态自动避让」。
> → **结论不变（不适用），但以后引述要说「三分栏语义 + 预设比例都不匹配」，别说「不支持三分栏」**。

**① 它的"三分栏"不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」。**

```
FoldSplitContainer 三分栏实际结构：

+---------------------------+------------------+
|        primary            |                  |
|        （主区）            |      extra       |
+---------------------------+   （扩展区，      |
|        secondary          |    上下贯穿）     |
|        （次区）            |                  |
+---------------------------+------------------+
        ↑ verticalSplitRatio     ↑ horizontalSplitRatio
         控制 primary:secondary     控制 (primary+secondary) : extra
         的【高度】比               的【宽度】比
```

横排的列只有 **2 个**（左半区上下两栏 + 右半区一个贯穿列）。
我们要的是**三块物理屏横向排列 → 文件树 | 编辑器 | 预览 三列横排**，模型对不上。

**② 分栏比例只能用预设枚举，且没有 1:1:1。**

`PresetSplitRatio` 只有三个值：`LAYOUT_1V1`(1:1) / `LAYOUT_3V2`(3:2) / `LAYOUT_2V3`(2:3)。
**不支持任意比例**，做不到各占 1/3。默认值：有 extra 时 `horizontalSplitRatio` 默认 `LAYOUT_3V2`，即右侧列只占 2/5。

**③ 它是为双折叠的「悬停态」设计的。**
核心卖点是悬停态自动避让折痕；三折叠的三屏态（G 态）不在它的模型里。二分栏时只有 `verticalSplitRatio`（**上下**分），连"列表 | 详情"左右分栏都不是它的默认形态。

> 补充事实（与选型无关但有用）：导入路径是 **`import { FoldSplitContainer } from '@kit.ArkUI'`**，
> 不是独立的 advanced 包；配套类型 `ExpandedRegionLayoutOptions` / `HoverModeRegionLayoutOptions` /
> `FoldedRegionLayoutOptions` / `PresetSplitRatio` / `ExtraRegionPosition` 同样从 `@kit.ArkUI` 导入。
> 事件：`onHoverStatusChange`。

→ **决策：三档布局全部自绘**，见 A2 末尾的三条出路之 ②/③。

### 修正后的出路（按推荐顺序）

1. **自绘 + 真机校准**（推荐起步方式）：自绘三档布局，宽度先用等分（50% / 1/3），
   真机打印 `getCurrentFoldCreaseRegion()` 与 `foldAngleChange` 双角度，**校准后写死校准值**。
2. **等分 + 折痕只做标注**：维持 50% / 1/3，折痕不参与决定栏宽。校准前的默认状态。
3. （已否决）~~`FoldSplitContainer`~~ —— 模型与比例都不匹配，见上。

> 官方折痕避让设计标准（悬停态）：上半屏内容由中线**向上避让 16vp**、下半屏**向下避让 40vp**。
> 这条仍有参考价值：三折叠若进入类似的半折悬停姿态，可照此避让。

### A3 断点获取 ✅ —— 现有方案就是官方推荐

`window.on('windowSizeChange')` + `px2vp()` **就是官方推荐做法**，窗口属性里没有直接的 vp 宽度字段。

官方明确建议：**优先用统一断点机制（一次开发多端部署），不要用 `getFoldDisplayMode()` 一类形态接口做分支**（该接口出于兼容考虑不返回全部形态值）。

→ **我们的三档断点（sm/md/lg）方案与官方思路一致，保持不变。**

#### 真机实测（2026-10-17，Mate XT2 三折叠，首轮）

| 形态 | 窗口宽 vp | 断点判定 |
| --- | --- | --- |
| 外屏合起 | 380 | sm ✅ |
| 内折只用第一屏 | 379 | sm ✅ |
| 展开双屏 | 709 | md ✅（∈[600,840)） |
| 三屏全展开 | 1061 | lg ✅（≥840） |

阈值 600 / 840 **四态全部命中**，断点矩阵真机验证通过（A3 ✅ → 已由真机加固）。

⚠️ 但同一批数据推翻了「三栏等分 = 一栏一块物理屏」的假设，见 **A6**。

### A6 ⚠️ 三栏等分 ≠ 一栏一块物理屏 —— 真机实测推翻（2026-10-17）

由首轮实测的四个窗口宽反推 **XT2 三块物理屏的 vp 宽度**：

| 块 | 宽度 vp | 怎么来的 |
| --- | --- | --- |
| 第一屏 | **379** | 内折只用第一屏时窗口宽 |
| 第二屏 | **330** | 709 − 379 |
| 第三屏 | **352** | 1061 − 709 |
| 合计 | **1061** | = 三屏全展开窗口宽 ✅ 完全吻合 |

等分三栏每栏 `1061 / 3 = 353.7`，栏边界落在 **353.7 / 707.3**；
真实折痕在 **379 / 709** → 第一处偏 **25.3vp**，第二处仅偏 **1.7vp**。

→ 这解释了用户的体感「大体上三分之一是准的，但和折痕有点差距」：第二处几乎重合，第一处明显偏。
→ **结论**：设计前提「一栏 = 一整块物理屏、栏边界压折痕」（plan.md R5）**无法靠等分实现**，物理三屏不等宽。

#### ✅ 决策（2026-10-17 用户拍板）：**不做精细适配**

> 用户原话：「我觉得就按他官方给的折痕就差不多了，不用搞太精细没意义。」

采纳如下，**推翻上面三条出路里的精细方案**：

| 项 | 结论 |
| --- | --- |
| 三栏栏宽 | **维持等分**（`layoutWeight` 1:1:1），**不**按物理屏宽 379:330:352 动态分栏 |
| 折痕数据用途 | **只用于标注**（原型里的橙色/红色虚线），不参与分栏 |
| 精度要求 | 不追求像素级。等分与真实折痕最大偏 25vp，视觉可接受，精细适配成本高收益低 |

#### 🔴 实测补强（2026-10-17 晚）：动态分栏**不只是「不值得做」，是「接口做不了」**

上面「警示线位置取官方折痕值」这条已**实测否决** —— `getCurrentFoldCreaseRegion()`
在五种形态下都返回 `372,372`（两条 rect 同值、且不随形态变），详见 **A2 实测段**。

| 原计划 | 实测后 |
| --- | --- |
| 警示线位置改用官方折痕值 | ❌ **维持写死 50%** —— 接口值不可信（比反推的 379 还差 7vp，且不随形态变） |
| 动态分栏「不立项」（成本理由） | ✅ 升级为**实测不可行**（接口理由），等官方答复再议 |

→ 折痕值在本项目的定位彻底明确：**只读数、只标注，绝不做任何几何计算**。
→ 三栏等分与折痕的偏差（最大 25vp）是**已知取舍**，不是 bug，也不是没调好。

→ 即：出路 ③（等分 + 折痕只做标注）**+** 警示线按官方折痕取值。
→ 本条从 v0.2 重排里**降级**：v0.2 只需做「警示线位置改用官方折痕」，动态分栏**不再立项**。

⚠️ 前提：`EditorPane` 的红色警示线位置目前写死「编辑区宽 50%」（`position({ x: '50%' })`）。
lg 收起态编辑区占前两块屏 709vp，折痕在 379vp → 精确值 `379/709 ≈ 53.5%`，与 50% 差约 25vp。
按本决策，改为读官方折痕值即可，**不做机型校准表**。

### A4 折叠切换时 UIAbility ✅ 不重建

窗口尺寸变化走事件通知，`onDestroy`/`onCreate` 由系统调度（销毁、内存回收），**与尺寸变化无关**。
HarmonyOS 的 `module.json5` **不存在**类似 Android `configChanges` 的"排除配置变更"配置项，无需配置。

→ 但仍建议编辑中内容定期落盘或存 `AppStorage`（防内存回收等极端场景）。

### A5 设备类型 ✅

三折叠手机在系统中**始终是 `phone`**，全展开 10 英寸的 G 态也不会变成 tablet / 2in1。
我们的 `deviceTypes: ["phone","tablet","2in1"]` 合适，断点差异靠 `windowSizeChange` 处理。

---

## B 组：Web 组件

### B1 大数据通道 ❓ → 应改用 WebMessagePort

`runJavaScript()` 的脚本长度上限**官方未记载**。但它的返回值是 string，100KB 级文本经它往返有明显序列化开销，**不适合做数据通道**。

官方大数据通道是 **WebMessagePort**：

```typescript
controller.createWebMessagePort()   // 建立双向端口
port.postMessage(...)               // 支持 string、ArrayBuffer
```

→ **通道分工（待落码）**：控制指令走 `runJavaScript` / `javaScriptProxy`；**大文本与 git packfile 走 MessagePort 传 ArrayBuffer**。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-3）**：
> `runJavaScript(script: string, callback: (result: string) => void)` —— **参数与返回值的长度上限官方均未记载** ❓。
> 返回值是 JS 表达式的字符串化结果，二进制要先 base64（**膨胀 33%**）。→ 结论不变：packfile 走 MessagePort。

### B2 隐藏的计算型 Web 组件 ⚠️ → **常驻用 `visibility(Hidden)`，不要用 NodeContainer 卸载**

`visibility(Hidden)` / `opacity(0)` 时组件仍在树上、JS 环境保留（反向推断，未逐字记载）。**不建议用 1×1 像素**。

> ❌ **已推翻（2026-10-17）**：~~官方方案是 `NodeController` + `NodeContainer` 动态挂载/卸载~~ —— 二次核实确认
> **NodeContainer 从组件树移除时 Web 组件被销毁、Chromium 实例释放，重新挂载会重新加载页面，JS 状态（变量/闭包/Worker）全丢**（⚠️ 推断，文档未记载"节点缓存/后台保活"）。
>
> ✅ **正确做法**：git 计算容器**常驻**，用 `Stack` + `visibility(Hidden)` 控制可见性而非存在性：
> ```typescript
> Stack() {
>   Web({ src: $rawfile('gitbridge/index.html'), controller: this.controller })
>     .width('100%').height('100%')
>     .visibility(this.webVisible ? Visibility.Visible : Visibility.Hidden)
>   NoteEditor()
> }
> ```
> ⚠️ 待真机验证：Hidden 状态下 ArkWeb 会不会做内存优化（暂停 JS 执行 / 降低优先级）。
> 详见 `qa/2026-10-17_B组追问_Web组件.md` B-4。

### B3 Worker 内无法访问 javaScriptProxy ⚠️ —— 影响我们的"桥接放 Worker"计划

- Web 页面内可用标准 Web Worker（ArkWeb 基于 Chromium M114，推断）
- **Worker 内访问不到 `javaScriptProxy` 注入的对象**：注入是"注入到 window 对象"，Worker 是独立全局作用域、没有 window

→ **原计划"fs 桥接放 Worker"行不通**（直接调 javaScriptProxy 这条路）。
→ **MVP 决策：先放主线程**（数百篇量级可接受），性能实测不够再优化。文档里"必须批量化并放 Worker"的表述已修正。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-6）**：Worker 可救，只是要换通道。
> ArkWeb 基于 Chromium M114，标准 Web Worker 可用（⚠️ 推断）；`javaScriptProxy` 不可访问（因为它绑在 window 上）。
> **绕过办法**：把原生侧的 `WebMessagePort` **transfer 进 Worker**，Worker 内直接用它收发 ArrayBuffer 与原生通信：
> ```typescript
> worker.postMessage({ type: 'init', port }, [port]);   // 主线程把 port 转移进 Worker
> // worker 内：nativePort.onmessage = e => handle(e.data /* ArrayBuffer */)
> ```
> → **性能优化路径已明确**：桥接要进 Worker 时，走 transferred MessagePort，而不是 javaScriptProxy。MVP 仍先主线程。

### B4 rawfile 页面的 origin 与 CORS ✅ —— 官方更推荐"拦截"而非"转发"

`$rawfile` 页面走 `resource://rawfile/` 协议，**ArkWeb 内核明确禁止 file / resource 协议的跨域访问**，页面内 fetch 会被拦。
（与我们的实测一致：github.com 的 git 端点不返回 CORS 头。）

官方给的**首选方案是拦截，不是转发**：

```
onInterceptRequest 拦截请求
  → 原生层用 @ohos.net.http 真正发出
  → WebResourceHandler.didReceiveResponseBody(data: ArrayBuffer) 流式回填
```

这样 isomorphic-git **继续用原生 fetch、JS 侧代码零改动**，原生层对 JS 完全透明，也绕开 CORS。

> ⚠️ **但拦截方案有一个我们还没验证的致命前提**：`git-receive-pack`（push）是 **POST + 大二进制 body**。
> `onInterceptRequest` 回调的 `WebResourceRequest` **能否完整拿到 POST 请求体**，官方答复未覆盖。拿不到 → 拦截方案在 push 场景直接废掉。
> 现有方案（JS 侧自定义 http client 转发到原生）已在 node 冒烟测试中**真实 clone 成功**，POST body 由我们自己构造、不受此限制。
>
> **决策（2026-10-17 二次核实后定案）**：**拦截方案 ❌ 否决（对 push 不适用）**，现有转发方案为最终方案。
>
> 📌 二次核实结果（`qa/2026-10-17_B组追问_Web组件.md` B-1）：
> - ✅ `WebResourceRequest` 有 `getMethod()` / `getUrl()` / `getHeader()` / **`getRequestBody(): string`**
> - ⚠️ **返回类型是 `string` 而非 `ArrayBuffer`** → 文本 body 没问题，**二进制 packfile 经 string 序列化有编码损坏风险**
> - ❓ 官方既未说"支持二进制"也未说"仅支持文本"
>
> → 结论：**clone/fetch（GET 为主）走拦截可行，但 `git-receive-pack`（push，POST + 大二进制）不可靠**。
> 既然 push 是硬需求，统一走**转发**更省心，不再保留"拦截迁移"这条优化线。
> ⚠️ 新接口名 `getRequestBody()` 本次答复**未附文档链接**，若将来真要用拦截，落码前在 DevEco 里用 `@kit.ArkWeb` 补全复核。

### B5 尺寸变化不重载 ✅，但有尺寸上限要注意

`onPageEnd` 只在加载完成触发，尺寸变化不构成导航，**页面不重载**，滚动位置与编辑内容自然保留。

两个坑（文档记载）：
- **异步渲染模式下 Web 组件宽高不能超过 7680px（物理像素），超过会白屏**。三折叠全展开宽度大，全屏 Web 要留意；我们三栏各 1/3 时单栏约 1061px，安全。
- `onRenderExited`（渲染子进程异常退出）后需 `loadUrl` 重载，此时状态会丢 → 回调里做数据保存。

### B6 中文输入法 ❓ —— 仍是 M0.5 spike 的头号验证项

文档未记载系统性兼容问题，**必须真机实测** contenteditable / textarea。

可配置项：`keyboardAvoidMode`（软键盘避让）、`blurOnKeyboardHideMode`、`onInterceptKeyboardAttach` + `WebKeyboardController`（完全接管键盘）。
页面级键盘避让：`win.setWindowAvoidAreaTypes([AvoidAreaType.TYPE_KEYBOARD], cb)`。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-5）**：官方仍**无**明确记载 ❓。
> ⚠️ 上述键盘配置项主要影响**容器布局**，不直接管 Web 内部的输入逻辑。
> ⚠️ **对方建议优先用 `<textarea>` 而非 `contenteditable`**（输入法兼容性更好）→ **与我们的选型冲突**：
> 编辑器方案 A 用的 **CodeMirror 6 基于 `contenteditable`**。
> → **M0.5 spike 必须实测**：拼音 / 语音 / 手写三种输入下的 **composition 预编辑事件**与**光标定位**。
> 若 CM6 实测有问题，提前准备降级路径（textarea 自绘高亮 / CodeMirror 的 textarea 模式）。

---

### B7 WebMessagePort：rawfile 页面可用，支持 ArrayBuffer，上限未记载 （2026-10-17 新增）

- ✅ `WebMessage` 定义 `interface WebMessage { data: string | ArrayBuffer }` —— **文档明确支持 ArrayBuffer**
- ✅ `controller.createWebMessagePort()` 返回一对 port：一端注入 HTML（`postMessage`），一端原生持有（`onMessageEvent`）
- ⚠️ **`resource://rawfile/` 页面可用**：它是 ArkWeb 内部协议，`createWebMessagePort` 是**组件级** API，不受页面协议的跨域策略影响
- ❓ **单条消息的 ArrayBuffer 大小上限未记载**；推断受 Chromium IPC 单条上限（数十 MB 级）与设备内存约束
- ⚠️ **传输策略：分块**（示例 4MB/块，末尾发完成标记如 `__TRANSFER_COMPLETE__`），不要赌单条上限

```typescript
// 原生侧接收
nativePort.onMessageEvent((result: WebMessage) => {
  if (result.data instanceof ArrayBuffer) { /* new Uint8Array(result.data) */ }
});
```

→ **通道选型定案**：控制指令走 `runJavaScript` / `javaScriptProxy`；**大文本与 packfile 走 MessagePort + ArrayBuffer + 分块**。
→ 真机需实测：上限具体多少、分块大小取多少最稳（列入 M0.5 spike）。

---

## C 组：文件系统与存储

### C1 原子写 ✅ —— 用官方 AtomicFile 替换自研 tmp+rename

`renameSync` 在 dest 已存在时是否覆盖、是否原子，**官方均未记载**（不要把笔记完整性押在它上面）。

官方专门能力：**`fileIo.AtomicFile`（API 15+，我们的 API 24 可用）**

```typescript
import { fileIo } from '@kit.CoreFileKit';

let atomicFile = new fileIo.AtomicFile(targetPath);
let stream = atomicFile.openWrite();
try {
  stream.writeSync(content);
  stream.closeSync();
  atomicFile.finishWrite();   // 成功：临时文件重命名到目标位置
} catch (err) {
  atomicFile.failWrite();     // 失败：删临时文件，原文件不受影响
}
```

→ **直接采纳**，替换 4.2 节的自研 tmp+rename，以及 fs 桥接层里工作区 md 的写入。

### C2 目录遍历 ✅

`listFileSync(path, options)` **无分页游标**，一次性返回 `string[]`；`ListFileOptions` 有 `recursion`、`listNum`（0 = 全部）。
**API 26 才有 `listFileExt`（支持 `fileFilter`），我们 API 24 用不了** → 按后缀过滤要自己写。

TaskPool / Worker 中可调用 `@ohos.file.fs`，官方推荐把 IO 放 TaskPool；未记载"必须主线程"的接口。
上千文件：子线程遍历 + 分批处理，别在主线程一次性构建大数组。

### C3 访问令牌 ✅ —— Asset Store Kit，无需权限

```typescript
import { asset } from '@kit.AssetStoreKit';

// 写入
let attr: asset.AssetMap = new Map();
attr.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(token));  // 加密存储位
attr.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('github_token')); // 检索用，不加密
asset.addSync(attr);

// 读取（未找到抛 24000002，需捕获）
let query: asset.AssetMap = new Map();
query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('github_token'));
query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
let secret = asset.querySync(query)[0].get(asset.Tag.SECRET) as Uint8Array;
```

- 模块 `@ohos.security.asset`，导入 `@kit.AssetStoreKit`，首批 API 11+，`addSync/querySync` API 12+
- **无需申请任何权限**（SystemCapability.Security.Asset，非权限管控）
- **ALIAS 与含 DATA_LABEL 的属性不加密**，敏感数据只能放 `SECRET`
- 多库场景下 token 按库存 → **ALIAS 用 `vault:<库id>:token`**

### C4 备份 ✅（体积上限 ❓）

`backup_config.json` 的 `includes` 支持目录与通配符，可覆盖含子目录的整个文件树。体积上限未记载。

> ⚠️ **设备差异**：**PC/2in1 不支持备份恢复；Tablet 开启自由多窗后也不生效。**
> 我们的 `deviceTypes` 含 `2in1` → 备份不能作为唯一的数据保命通道，**导出 zip 仍要做**。

---

## D 组：HAR 打包与 ohpm 发布

### D1 HAR 内 rawfile ✅（建议编译确认）

HAR 的资源（含 `resources/rawfile`）编译期合并进依赖方 HAP，主模块可直接 `$rawfile('xxx/index.html')`。
注意主模块与 HAR 的 rawfile **重名冲突**问题。

→ 抽库的前置风险基本解除，但仍建议先建个空 HAR 编译确认一次。

### D2 ohpm 发布 ✅（是否必须 release ❓，审核周期 ❓）

```bash
ohpm config set publish_registry https://ohpm.openharmony.cn/ohpm/
ohpm config set publish_id <发布码>
ohpm publish yourlib.har
```

- 流程：准备 `oh-package.json5`（name/version 须符合 semver）→ 生成公私钥、公钥上传中心仓取**发布码** → `.ohpmrc` 配 `publish_registry`/`publish_id`/私钥路径 → 构建 .har → `ohpm publish`
- 包大小上限 **300MB**（ohpm 5.0.1+）
- `@<group>/<package>` 只有组织成员可发布；库名被占用后不能重复发布

---

## E 组：权限与网络

### E1 沙箱权限 ✅ —— 无需任何权限，当前无遗漏

应用对自己沙箱（`filesDir`）内自建文件有完全读写能力。只申请 `INTERNET` 是对的。

### E2 ARRAY_BUFFER 大小 ❓

`@ohos.net.http` 无流式读取接口，一次性返回完整响应。几十 MB 可行但占内存峰值。
超大对象可用 HTTP Range 分片自行拼接。

### E3 长时间网络 ✅

前台 clone/push **无需额外权限**。只有退后台仍需传输时才需 `KEEP_BACKGROUND_RUNNING` + `DATA_TRANSFER` 长时任务。

→ **决策：clone/push 保持前台执行 + 进度提示**（最简单合规）。不做后台同步。

---

## F 组：小艺智能体与端侧意图（Insight Intent）

> 来源：[`qa/2026-10-17_小艺智能体_端侧意图框架.md`](qa/2026-10-17_小艺智能体_端侧意图框架.md)（2026-10-17）
> ⚠️ **本组所有结论均未附文档链接**，落码前必须在 DevEco 用 `@kit.*` 补全复核接口名与签名。
> **不要在别的文档里复制本组结论**，一律链接过来 —— 下面标 ⚠️ 的随时可能被推翻。

### F1 应用内对话入口：`FunctionComponent` ⚠️

`@kit.AgentFrameworkKit` 提供 `FunctionComponent`（配 `FunctionController` 监听
`agentDialogOpened` / `agentDialogClosed`），传 `agentId` 即可在 App 内拉起智能体对话面板。
→ 这是「App 内嵌 AI 对话」的官方路径，**无需人工审核**（技能以 MCP / 插件形式发布到**自己**的智能体；
要进小艺主对话入口才需审核）。

### F2 意图声明：`@InsightIntentEntry` 装饰器 ⚠️

意图执行器用 `@InsightIntentEntry({...})` 装饰，参数用 **JSON Schema 内联声明**；
执行文件在 `insight_intent.json` 里用 `insightIntentsSrcEntry` 声明。
⚠️ 官方自己也不确定该字段是否支持**数组形式**（答复用「若不支持请以 IDE 编译提示为准」带过）。
→ 落码前先建一个单文件最小样例跑通编译，再决定怎么组织。

### F3 参数传递：同名属性自动注入 ⚠️

大模型解析出的参数**自动赋值给执行器的同名类属性**，随后触发 `onExecute()`。
**每个字段的 `description` 会被大模型用来理解怎么填参 —— 务必写清楚**，这是意图能不能填对的关键。

### F4 生命周期：`onCreate → onExecute`，不建 window ⚠️⚠️

后台执行模式（`UI_ABILITY_BACKGROUND`）下若冷启动，生命周期顺序是
`onCreate → onExecute`，**不经过 `onWindowStageCreate`**。
→ 需在 `EntryAbility.onCreate` 里把 context 存进全局单例，否则执行器拿不到 `filesDir`。
→ ⚠️ **这条对我们是致命的**：不建 window 意味着 **ArkWeb 组件没挂载 → 我们的 gitbridge 不可用 →
意图内无法同步 commit**。详见 §F6。

### F5 路径与写入 ✅ / ⚠️ 混合

- ✅ **路径必须基于 `context.filesDir` 等 Context 属性动态获取，禁止硬编码沙箱目录字符串**
  （与我们的既有硬约束一致）。
- ⚠️ 官方示例代码用 `openSync(READ_WRITE | TRUNC)` 覆盖写 —— **违反我们的原子写硬约束（见 C1）**。
  → **意图执行器里的写回必须换成 `fileIo.AtomicFile`**，别被示例带偏。
- ✅ 单篇数 MB 时 `readTextSync` 全量读入内存有风险，改用 `createReadStream` 分段读。

### F6 ⚠️ **关键冲突：git 版本底座在本工程里不成立**

官方方案假定存在一个**原生 ArkTS git**（`GitService.commit()`）。
我们的 git 是 **isomorphic-git 打包进 `rawfile/gitbridge/index.html`，跑在 ArkWeb 页面里**，
ArkTS 侧只有 fs / http 桥接。叠加 F4 的「后台执行不建 window」：

> **后台意图执行时，Web 组件可能根本不存在 → commit 无处调用。**

三种出路（**待拍板**，记录在 `docs/open_questions.md`）：

| 出路 | 做法 | 代价 |
| --- | --- | --- |
| **A. commit 入队、延迟执行** ⭐推荐 | 执行器写文件后把「待 commit 路径 + 消息」写进队列文件；App 回前台、Web 就绪后由主线程消费 | 反馈文案要改成「已修改，版本待提交」 |
| B. 执行时同步拉起不可见 Web 再 commit | 冷启动建 WebView 有耗时，且 Hidden 下 JS 是否执行未验证 | 慢 + 不可靠 |
| C. 放弃意图内 git，改文件级备份 | 写前复制 `.bak` / 自建轻量历史目录 | 失去 git log 摘要等扩展，且污染 vault |

→ 在出路拍板前，**不要把「AI 改笔记」排进 MVP 主链路**。

### F7 意图设计：锚点定位法 ✅（值得直接采纳）

「细粒度修改」的关键不在代码而在**参数设计**：修改指令必须携带 `anchor`（笔记原文中的精确片段），
执行器用字符串定位后按 `action` 重组。比「第几行」「标题路径」可靠——
大模型读完原文后擅长精确复制片段，且锚点对不上时可以**拒绝执行并要求重新读取**（防错改的闸门）。

建议意图清单：`QueryNotes` / `ReadNote` / `EditNote`（`replace`·`insertBefore`·`insertAfter`·`delete`）/
`AppendNote`（高频简单操作单独开意图，降低出错率）/ `UndoLastEdit`。

→ **我们要补的工程细节**：anchor 在文中出现**多次**时必须拒绝执行，
执行器应校验出现次数 >1 就要求智能体给更长的锚点。

### F8 智能体侧约束 ✅（建议照抄进系统提示词）

> 修改任何笔记前必须先调用 `ReadNote` 获取原文；
> `anchor` 必须取自原文，禁止凭记忆编造；
> 执行修改后向用户复述变更内容。

高风险操作（删除整篇）**单独设意图**，并在智能体侧配置执行前向用户确认。

---

## G 组：埋点与事件打点（hiAppEvent / UIObserver）

> 来源：2026-10-17 官方答复，**附了信息来源链接**（比前两批无链接答复可信度高一档）。
> 存档：`qa/2026-10-17_埋点与事件打点.md`。核实深度：**答复口径**，未逐条对照官方文档原文。

### G1 三类埋点都有原生能力，且版本全部可用 ✅

| 类型 | API | 起始版本 | API 24 可用 |
| --- | --- | --- | --- |
| 曝光（组件级） | `onVisibleAreaApproximateChange` | **17+** | ✅ |
| 曝光（全局无侵入） | `FrameNode.setOnVisibleAreaApproximateChange` | **12+** | ✅ |
| 点击 | `UIObserver.on('willClick')`（点击前回调，可拿 `ClickEvent` + `FrameNode`） | **12+** | ✅ |
| 页面切换 | `UIObserver.on('navDestinationSwitch')` | **12+** | ✅ |

**能力分层**：采集 → `hiAppEvent.write` 落盘 → `addWatcher` 订阅 → `onTrigger` 批量 `takeNext()` → 自建 http 上报。
→ **无需引入第三方埋点 SDK。**

### G2 曝光埋点细节 ✅

- `ratios: [0.5]` 的**实际生效阈值区间是 `[0.0, 0.5]`**，回调在比值**跨越**阈值时触发（非每帧）。
- 用 `onVisibleAreaApproximateChange` 而非 `onVisibleAreaChange`：计算频度由 `expectedUpdateInterval` 控制，**列表大量注册时功耗更优** → 文件树场景应当用它。
- ⚠️ **去重必须自己做**，官方示例的 `exposedSet` 是**内存态**，进程重启失效。

### G3 批量取出 ✅ / ⚠️

`triggerCondition: { row, size }` 满足任一即触发；`onTrigger` 里 `holder.takeNext()` 取到 null 为止。
⚠️ `addWatcher` 涉及 I/O，**性能敏感场景放子线程**，且该线程在使用周期内**不能被销毁**；watcher **同名会覆盖前一次订阅**。

### G4 全局无侵入方案 ✅（最匹配我们的文件树）

业务组件只声明 `.id()` 与 `.customProperty()` 标识身份；Ability 层统一用 `UIObserver` + `FrameNode.setOnVisibleAreaApproximateChange` 监听，**业务代码零侵入**。
点击同理：`observer.on('willClick', cb)` **全局注册一次**，回调里读 `FrameNode` 标识。

### G5 明确的能力限制 ⚠️

可见区域计算**不支持**：兄弟组件遮挡、窗口遮挡、组件旋转；只算自身节点相对祖先直至窗口边界的裁切比。
→ 三折叠形态切换瞬间的曝光比值**准确性无保证**，相关埋点只作趋势看。

### G6 另一条路径：华为分析 Analytics Kit ✅

上架华为应用市场后可用，AGC 控制台直接看板，免自建后台。与原生方案可**并用**（hiAppEvent 落盘保不丢 + 云端看板）。
差别：原生方案**数据归你自己**；Analytics Kit 数据在华为侧。

### G7 🔴 本项目红线：笔记内容一律不得进入埋点

**可采集**：行为坐标（目录层级、当前形态、按钮点击、同步成败与耗时）。
**禁止采集**：笔记标题、文件名、路径、正文、字数、标签。

理由：① 这是个人知识库，不是内容社区；② 采集用户内容会显著抬高隐私合规成本与上架审核风险。
→ **埋点字段设计必须先过这条红线再落码。**

### G8 我们补的三条工程约束（官方没提）

1. **曝光去重按「会话内」定义指标** —— 官方 Set 是内存态，重启后同一批笔记会重复计曝光。推荐先把指标定义为"单会话内曝光"，而非跨会话去重。
2. **上报非实时、失败即丢** —— `triggerCondition` 本就是累积触发；**不做重试队列**，避免埋点上报与 git 同步抢带宽、拖累主链路。
3. **埋点不得阻塞主链路** —— 采集与上报全部走旁路，异常吞掉，不许让埋点崩溃影响编辑/同步。

### G9 待核实 ❓（不阻塞）

| 编号 | 问题 |
| --- | --- |
| **G-A** | `hiAppEvent.write` 是否需要权限？落盘是否在应用沙箱内？ |
| **G-B** | `UIObserver.on('willClick')` 只能观察，还是能拦截点击？ |
| **G-C** | `customProperty()` 的值有无类型/长度限制？ |

---

## H 组：应用元信息与版本读取

> 2026-10-17 建立。起因：需要「关于」页显示版本号，**运行时怎么读 `versionName` 尚未核实**。

### H1 版本号的单一真源是 `AppScope/app.json5` ✅

```
AppScope/app.json5 → app.versionCode / app.versionName
```

⚠️ **当前值仍是工程模板默认（`1.0.0` / `1000000`）**，未与版本规则对齐。
按 `docs/releases/README.md` R1：版本目录 `v0.1` → `versionName = "0.1.0"`，`versionCode` 单调递增。
**发布时必须同步**（R9 第 2 条），否则装到手机上的版本号与版本档案对不上。

### H2 运行时读取版本号 ❓ 待核实（**别凭记忆写**）

候选路径（**均未核实，落码前必须 DevEco 补全确认**）：

| 候选 | 说明 | 状态 |
| --- | --- | --- |
| `bundleManager.getBundleInfoForSelf(...)` → `BundleInfo.appInfo.versionName` | 读自身包信息 | ❓ 是否存在该 flag / 是否需要权限，未核实 |
| 资源文件 `$r('app.string.xxx')` 手写版本字符串 | 简单但**必然与 app.json5 漂移** | ❌ 不推荐 |
| 构建期注入常量 | 需改构建脚本 | ❓ 待评估 |

> **硬规则**：版本号**只能从包信息读出**或**构建期注入**，**禁止在源码里手写版本字符串**——手写必然与 `app.json5` 不一致，且每次发版都要记得改。

### H3 待核实清单

| 编号 | 问题 |
| --- | --- |
| **H-1** | API 24 下运行时读取自身 `versionName` 的**确切接口与所需 flag**？读自身包信息是否需要权限？ |
| **H-2** | `bundleManager` 的同步版本（如 `getBundleInfoForSelfSync`）在 API 24 是否可用？ |

---

## I 组：视觉与设计系统（UI Design Kit / Symbol / 字体）

> 2026-10-17 建立。起因：用户要求设计稿按华为设计资源修，引出的**落码侧待核实项**。
> ⚠️ 本组**全部未核实**，按铁律 5：**未核实项不进关键路径**，先用兜底方案（自绘 / 默认样式）。

### I1 三个待核实项 ❓（对应需求池 J 节）

| 编号 | 问题 | 兜底方案 |
| --- | --- | --- |
| **J-1** | **UI Design Kit（`Hds*` 组件，如 `HdsListItem` / `HdsSnackBar`）在 API 24 是否可直接引入？** 引入方式（ohpm 包？SDK 内置？）、最低版本、是否需额外依赖 | 按同观感**自绘**列表项（主文本 16fp / 副文本 12fp / 行高 56vp / 选中主色实底） |
| **J-2** | **HarmonyOS Symbol 在 ArkTS 中的引用方式**：`SymbolGlyph($r('sys.symbol.xxx'))` 的资源 id 从哪里查？自定义 SVG 是否要转资源？ | 自绘 SVG / Path 图标，风格统一（24 viewBox 描边、圆头圆角） |
| **J-3** | **HarmonyOS Sans 是否需显式指定**：ArkUI 的 `fontFamily` 默认值是什么？要显式写 `'HarmonyOS Sans'` 吗？ | 不指定（用系统默认），但**字号/字重阶梯照 token 走** |

### I2 已确定的部分 ✅（不依赖上面三项）

- **token 化本身没有技术风险**：`app.color.*` / `app.float.*` 资源或常量模块，纯工程约定。
- **深色模式**：ArkUI 有系统级深色资源目录（`resources/dark/`），
  但**在 J-1～J-3 核实前**，本版本只保证「另有一套 token」，不承诺手动切换开关（需求池 J 节已标后置）。
- **token 真源**：`docs/prototype/index.html` 的 `:root` 与 `[data-theme="dark"]` 段。
  ArkTS 侧改值时**两边同步**。

### I3 系统返回键 / 侧滑返回的拦截 —— **I-1 ✅ 已核实（2026-10-17）**

> 起因：2026-10-17 用户指出「库管理、配置页没有返回按钮」。查代码发现**视图切换是条件渲染（`if (this.showVaultManager)`），不是 Navigation 路由**，
> 所以系统返回手势不会"回上一页"，而是**直接退出应用**。

| 编号 | 问题 | 兜底 |
| --- | --- | --- |
| **I-1** ✅ **已核实：可用。** 见下方 I3.1 |
| **I-2** ❓ **不再需要。** 条件渲染 + `onBackPress` 已能覆盖当前全部次级页面，**不重构 Navigation**；后续若出现真正的层级导航（如设置 → 子设置）再评估 |

> 结论仍成立：**任何次级页面（库管理 / 导入 / 设置）必须有可见的顶栏返回箭头**——这是 UI 层的硬要求，
> 不依赖系统返回可否拦截。系统返回拦截现在是**已实现的增强项**，不再是"能拦就拦"。

### I3.1 `onBackPress` 核实结论 ✅（双证据）

**证据一：本地 SDK 实证**（`sdk/default/hms/ets/api/device-define/api-version/ArkUI.json`）

```
apiText:     onBackPress?(): boolean
kit:         ArkUI          isSystemApi: false
syscap:      SystemCapability.ArkUI.ArkUI.Full
since:       4（OpenHarmony）；phone/tablet 12、2in1 13
```

**证据二：官方文档原文**（自定义组件的生命周期）

> `onBackPress?(): void | boolean`
> 当用户点击返回按钮时触发，**仅 `@Entry` 装饰的自定义组件生效**。
> 返回 `true` 表示页面自己处理返回逻辑，不进行页面路由；
> 返回 `false` 表示使用默认的路由返回逻辑，**不设置返回值按照 false 处理**。

**落地结论**：条件渲染视图（非路由）下，`@Entry` 页面的 `onBackPress()` 返回 `true` 即可拦截退出 ——
**不需要为了系统返回而改用 Navigation**。v0.1 需求 2.7 已按此实现（库管理视图返 `true` 回笔记视图，笔记视图返 `false`）。

### ✅ 侧滑返回也会触发 `onBackPress` —— 真机实测（2026-10-17，Mate XT2）

官方只写了「用户**点击返回按钮**时触发」，**侧滑手势是否同样触发**没明说，
第三方文章的说法不足为据，所以一直是 ❓。真机结论：

| 触发方式 | 结果 | 判定 |
| --- | --- | --- |
| 顶栏 `‹` | 回到笔记视图 | ✅ |
| 系统返回键 | 回到笔记视图，**不退出应用** | ✅ |
| **屏幕边缘侧滑** | 回到笔记视图，**不退出应用** | ✅ **官方未记载，本次实测确认** |

→ **`onBackPress()` 同时覆盖返回键与侧滑手势**，条件渲染视图不需要为侧滑另写兜底。
→ 需求 2.7 真机验收通过，该❓销账。

⚠️ 未测的边界（不阻塞 v0.1）：sm 态抽屉打开时按返回键是否只关抽屉（2.7b 的分档逻辑）、
库管理页顶栏是否只有一个标题。见 `docs/releases/v0.1/真机验证清单.md` §B 的 B4/B6。

> 🔴 **红线**：禁止凭记忆编 `Hds*` 组件名或 `sys.symbol.*` 资源 id。
> 查不到就在需求文档的验收记录里写明「未核实，用兜底」。

### I4 签名配置注入：`config.ohos.overrides.signingConfig` ✅ 已核实并落地（2026-10-17）

**结论**：工程级 `hvigorfile.ts` 可用 `config.ohos.overrides.signingConfig` 覆盖
`build-profile.json5` 的签名配置 → **后者永久保持 `"signingConfigs": []`**，凭据只留本地。
这解决了「build-profile.json5 必须入库、但 DevEco 自动签名会往里写密码明文」的死结
（该文件不能 ignore：移除后 hvigor 直接报 `00304035 Not Found`，实测）。

**SDK 证据**（`C:\Program Files\Huawei\DevEco Studio\tools\hvigor\hvigor-ohos-plugin`）：

| 文件 | 内容 |
| --- | --- |
| `src/options/build/app-ohos-config.d.ts` | `AppOhosConfig = { overrides?: Overrides }`，`Overrides = { appOpt?, signingConfig?: SigningConfigBuildOpt }` |
| `src/tasks/sign/sign-util.d.ts` | `mergeSigningConfig(signingConfig, signingConfigFromHvigorfile)` → **overrides 优先级更高** |
| `src/options/build/project-build-profile.d.ts` | `MaterialBuildOpt` 七字段（全必填）：`storeFile` `storePassword` `keyAlias` `keyPassword` `signAlg` `profile` `certpath` |

⚠️ **运行时 schema 比 `.d.ts` 更严**（实测 `ERROR 00303038 Schema validate failed`）：
`.d.ts` 里 `SigningConfigBuildOpt extends RequiredNamed`（含 `name: string`），
但**写 `name` 会直接构建失败**——schema 只允许 `material` 与 `type` 两个字段：

```
instancePath '/overrides/signingConfig', keyword 'enum',
  params: { allowedValues: [ 'material', 'type' ] }
instancePath '/overrides/signingConfig', keyword 'propertyNames',
  params: { propertyName: 'name' } → 'property name must be valid'
```

→ **类型定义与运行时校验冲突时，以运行时为准**（又一个「别只信 d.ts」的实证）。
→ 工程级用 `appTasks`（不是 `hapTasks`，那是模块级）。

**落地方式**：根 `hvigorfile.ts` 读 `.local/local-signing.json`（已 gitignore），
有则注入、无则不签名（构建照样成功，产物 `-unsigned.hap`）。
实测：`BUILD SUCCESSFUL` + `entry-default-signed.hap`，`build-profile.json5` 保持 `[]`。
凭据抽取走 `.\tools\signing.ps1 -Import`。

---

## J 组：视觉基线的三个待核实项（J-1 / J-2 / J-3）—— ✅ 全部核实完毕（2026-10-18）

> 来源：需求池 J 节 → v0.2 §3.5。铁律：**查不到就用兜底，禁止凭记忆编 `Hds*` 或 `sys.symbol.*`**。

### J-1 `Hds*` 组件能否直接引？ ❌ **不存在，改为自绘同观感**

在本地 SDK 里全量搜 `HdsListItem` / `HdsButton` / `HdsNavigation`：

```
sdk/default/openharmony/ets/api/ + component/   → 0 命中
sdk/default/openharmony/ets/kits/               → 没有 UI Design Kit
```

**结论**：API 24 的 SDK 里**没有** UI Design Kit 的 `Hds*` 组件。
→ 按需求 4.6 的兜底执行：**自绘同观感列表项**（主文本 16fp / 副文本 12fp / 行高 56vp / 选中主色实底）。
不为一个列表项引整套 Design Kit（v0.2 §4「明确不做」也这么定）。

### J-2 `SymbolGlyph` + `sys.symbol.*` 能否覆盖图标清单？ ⚠️ **只能核实 3 个 id，改为统一自绘**

- `SymbolGlyph` 组件**存在**（`component/common.d.ts` 有 `SymbolGlyphModifier`）。
- 但 `sys.symbol.*` 的**可用名单在 SDK 里查不到全量**，只有 d.ts 注释里出现的几个：
  `sys.symbol.open_sidebar` / `chevron_down` / `chevron_forward` / `ohos_wifi` / `ohos_lungs`。
  文件树需要的 文件夹 / 文档 / 收起 / 重命名 / 删除 **都核实不到**。

**结论**：只用核实得到的 3 个会与自绘混成两套风格（4.7 明确禁止混用）→ **全部自绘**。
实现见 `entry/src/main/ets/common/Icons.ets`：24 viewBox 描边、`strokeWidth 2`、圆头圆角。
→ **待办（v0.3）**：拿到官方 Symbol 资源全量名单后，整体替换为 `SymbolGlyph`。

> ⚠️ 自绘踩坑记录（两次，都已修）：
> ① `Shape().viewPort()` **不缩放子 Path** —— 图标被渲染成几个像素的点；
> ② `Path.commands` 的坐标单位是 **px**，而 `.width(size)` 是 **vp** ——
>    直接按 24→size 缩放只能占容器 35%（460dpi 上看起来还是个点），
>    系数必须是 `vp2px(size) / 24`。
> ③ 路径**只用直线命令**（M/L/H/V/Z）：弧线命令 `a/A` 里的 flag 是 0/1，
>    整体乘缩放系数会破坏语义，所以约定新增图标不许用弧线。

### J-3 要不要显式 `fontFamily: 'HarmonyOS Sans'`？ ❌ **不需要**

- SDK 自带 `HarmonyOS_Sans.ttf` / `HarmonyOS_Sans_Condensed.ttf`（`previewer/common/bin/fonts/`）；
- HarmonyOS 系统的**默认字体就是 HarmonyOS Sans**，ArkUI 不设 `fontFamily` 即等于它。

**结论**：**不写** `fontFamily`。显式写死反而会在多语言/系统换字体时变成硬编码负担。
（若日后要区分 Condensed 做数字排版，再按需显式指定。）

---

## K 组：zip 导出（打包 + FilePicker）

> 2026-10-17 建立。⚠️ **Q2 已决定后置（2026-10-17 用户决定）**：MVP 未在真机跑通、无用户、无笔记存量，
> 导出无对象。**本组当前不进任何版本**，仅作为将来开工时的预先登记。
> 触发条件见 `open_questions.md` Q2（真机上有真实存量 / 换机 / 有第二个用户 / 系统备份确认不可用）。
> 本组**全部未核实**，按铁律 5：未核实项不进关键路径。

### K1 两个待核实项 ❓

| 编号 | 问题 | 兜底方案 |
| --- | --- | --- |
| **K-1** | **打包能力**：API 24 下 ArkTS 侧有没有现成的压缩 API（`@kit.PerformanceAnalysisKit` 的 zlib？`fileIo`？还是完全没有）？如果没有，是否要在 Web 侧用 JSZip 打包再回传 | 兜底：Web 侧 JSZip（与编辑器同一条 Web 链路），或先导出到应用沙箱 `Download` 目录再由用户取 |
| **K-2** | **保存位置**：`picker.DocumentViewPicker` 的保存模式在 API 24 的准确用法？是否需要权限？能否拿到用户选择的目录 uri 再写入 | 兜底：写到应用沙箱 Download 目录（用户可在「文件管理 > 我的手机 > 应用」里找），**体验降级但不阻塞** |

### K2 已确定的部分 ✅

- **系统备份不能当唯一保命通道**：官方明确 **PC/2in1 不支持备份恢复、Tablet 开自由多窗后也不生效**，
  而 `deviceTypes` 含 `2in1`；且沙箱目录在系统文件管理器里**不可见**。所以导出是**唯一**保命通道。
- **导出范围 = 整库**（`vaults/<id>/`），导出后目录结构与库内一致（不做筛选、不做格式转换）。
- **入口放在「设置与关于」页**，不在文件树上加入口（原型已留占位）。

> 🔴 **红线**：禁止凭记忆编压缩 API 名或 `picker.*` 的用法。查不到就在报告里列出并用兜底。

---

## 落地决策表

| 结论 | 决策 | 何时做 |
| --- | --- | --- |
| 三档断点用 windowSizeChange + px2vp | ✅ 维持原方案 | 已是现状 |
| UIAbility 折叠切换不重建 | ✅ 解除顾虑，仍需定期落盘 | 已是现状 |
| 三折叠恒为 phone | ✅ deviceTypes 不动 | 已是现状 |
| ~~折痕接口只返回单个 Rect~~ | ⚠️ **纠正**：SDK 实证返回 `FoldCreaseRegion{ creaseRects: Array<Rect> }`（官方答复错了）。决策不变：**自绘等分 + 真机校准**（~~`FoldSplitContainer`~~ 已于 2026-10-17 否决） | 已定为自绘；真机校准待做 |
| **三屏态 FoldStatus 返回值未知** | ⚠️ 真机打印建映射表 | M0.5 顺带做 |
| **AtomicFile 官方原子写** | ✅ **替换自研 tmp+rename** | M0.2 落码时 |
| **Asset Store Kit 存令牌** | ✅ **实现 TokenStore，alias 按库** | M3.5 前 |
| **大文本/packfile 走 WebMessagePort** | ✅ 新增通道（**分块 4MB**），替代 runJavaScript 传大数据 | 真机验证上限后 |
| **Worker 内拿不到 javaScriptProxy** | ✅ 桥接**先放主线程**；要进 Worker 时把 port **transfer** 进去 | 性能优化时 |
| 拦截方案（onInterceptRequest） | ❌ **否决（2026-10-17）**：`getRequestBody()` 返回 **string**，二进制 packfile 有损坏风险 → push 不可靠 | 转发方案为最终方案 |
| 离线 Web 组件（NodeContainer） | ❌ **推翻（2026-10-17）**：卸载即销毁、重挂会重载页面 → git 容器改 **`visibility(Hidden)` 常驻** | M0 落码时 |
| 沙箱无权限需求 | ✅ 确认无遗漏 | — |
| 后台同步不做 | ✅ 保持前台 | — |
| HAR rawfile 可加载 | ✅ 抽库前置风险基本解除 | 抽库前编译确认 |
| Web 组件 7680px 上限 | ✅ 三栏各 1/3 安全，全屏 Web 要留意 | 编码时注意 |
| **zip 导出** | ⏸ **后置**（Q2，2026-10-17 用户决定）：MVP 未在真机跑通、无用户、无存量；打包能力与 FilePicker 用法待核实（**K 组**）。触发条件见 `open_questions.md` Q2 | 未定（≥ v0.4） |
| 中文输入法 | ❓ **M0.5 spike 头号验证项**；⚠️ 官方建议优先 textarea，**与 CodeMirror 6（contenteditable）冲突**，实测不过要准备降级路径 | M0.5 |
| **小艺智能体 + 端侧意图** | ⚠️ 方案可行但**未附文档链接**，且 §F6 与我们的 Web 内 git **存在架构冲突** → 出路未拍板前**不进 MVP 主链路** | 核实 F-A/F-B/F-C 后 |
| 意图执行器写文件 | ⚠️ 官方示例用 TRUNC 覆盖写 —— **必须改成 `AtomicFile`**（C1 硬约束优先于示例） | 落码时 |
| **视觉 token 落地** | ✅ **并入 v0.2**（用户 2026-10-17 拍板），v0.1 界面不动；待核实 J-1/J-2/J-3 见 **I 组**，核实前用兜底方案 | v0.2 |
| **埋点（曝光/点击/页面）** | ✅ **用原生 `hiAppEvent` + `UIObserver`，不引第三方 SDK**；三类 API 起始版本 12–17，**API 24 全部可用**；🔴 **笔记内容一律禁止进埋点** | **后置**（不在 v0.1–v0.3） |
| 埋点上报策略 | ✅ 非实时批量 + **失败即丢**（不做重试），避免与 git 同步抢带宽 | 落码时 |
| 形态分布埋点（sm/md/lg 使用占比） | ✅ 本项目最独有的数据，**v0.1 发布后即可采集**且不触碰内容红线 | v0.1 之后评估 |
