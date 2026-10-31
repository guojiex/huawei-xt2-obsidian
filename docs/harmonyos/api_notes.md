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

### B6 中文输入法 ❓ —— M0.5 spike 尚未收口

Huawei_TripleFold API 26 arm64 模拟器已确认安装并运行系统输入法；历史操作还观察到 `textarea` 能唤起中文拼音键盘，随后 CodeMirror 可收到已提交的“你好”。完整的 composition 事件序列、首次点击 CodeMirror 未弹键盘的原因，以及系统性 A/B 对照仍待验证。按当前验收顺序先继续模拟器验证，XT2 真机项目留到功能开发完成后统一验收。

可配置项：`keyboardAvoidMode`（软键盘避让）、`blurOnKeyboardHideMode`、`onInterceptKeyboardAttach` + `WebKeyboardController`（完全接管键盘）。
页面级键盘避让：`win.setWindowAvoidAreaTypes([AvoidAreaType.TYPE_KEYBOARD], cb)`。

> 📌 **二次核实（2026-10-17，见 `qa/2026-10-17_B组追问_Web组件.md` B-5）**：官方仍**无**明确记载 ❓。
> ⚠️ 上述键盘配置项主要影响**容器布局**，不直接管 Web 内部的输入逻辑。
> ⚠️ **对方建议优先用 `<textarea>` 而非 `contenteditable`**（输入法兼容性更好）→ **与我们的选型冲突**：
> 编辑器方案 A 用的 **CodeMirror 6 基于 `contenteditable`**。
> → **M0.5 spike 必须实测**：拼音 / 语音 / 手写三种输入下的 **composition 预编辑事件**与**光标定位**。
> 若 CM6 实测有问题，提前准备降级路径（textarea 自绘高亮 / CodeMirror 的 textarea 模式）。

**2026-10-22 模拟器能力检查（Huawei_TripleFold，HarmonyOS 7.0.0.107，API 26，arm64）**：HDC 查询到
系统包 `com.huawei.hmos.inputmethod` 已安装（版本 `1.2.6.463`），进程列表中有 `inputmethod_service`；应用
`com.jxg.huaweiobsidian`（v0.2.0，compatibleSdkVersion 6.1.1(24)）正在运行。17:33 屏幕截图中软键盘已显示，底栏可见“中/英”；随后在 CodeMirror 中逐键输入 `nihao`，键盘显示拼音 `ni'hao` 和候选“你好”，点候选后编辑区出现“你好”。按两次退格并等待 2 秒后，编辑区恢复为空白。截图：`.local/shots/pinyin_nihao_20261022_173935.png`、`.local/shots/pinyin_cleared_20261022_174110.png`。此前一次点按未观察到键盘，不代表输入法不可用。
此前的实际操作记录见 [2026-10-19 模拟器输入法答复](qa/2026-10-19_API26_三折叠模拟器输入法答复.md)：`textarea` 曾唤起中文拼音键盘，之后 CodeMirror 可输入并提交中文。现有截图与留存事件记录没有完整的 `compositionstart/update/end` 序列，因此只确认系统输入法可用、拼音候选可提交到 CodeMirror；composition 细节、光标与滚动、首次焦点差异和系统性 A/B 对照仍待模拟器验证。结论只适用于此 API 26 arm64 模拟器，不外推到 API 24 x86 或 XT2。

**2026-10-29 键盘避让区声明与 UI 验证**：本机 API 26 SDK `@ohos.window.d.ts` 将 `AvoidAreaType.TYPE_KEYBOARD`、`Window.getWindowAvoidArea()` 与 `Window.on/off('avoidAreaChange')` 标记为 `@since 9`，回调使用的 `AvoidAreaOptions` 标记为 `@since 12`，均不高于工程 API 24 上限。原生用该事件发布键盘底部避让高度，Aa 浮层据此重新计算所属栏可视区。unsigned HAP 构建并在 API 26 Huawei TripleFold 实际点按：键盘显示时打开 Aa、滚动选项后“完成”仍可见并成功关闭面板，键盘继续显示。此为本机 API 26 SDK 声明与模拟器结果；API 24 / XT2 运行时行为仍待验。

**2026-10-31 M0.5 部分复验（API 26 arm64 隔离模拟器）**：A/B 页面分别加载 500 行样例，切换编辑器后页面载入时间未变；CodeMirror 短程滚动可从第 1 行移至第 8 行，光标读数保持行 1、列 1、offset 0。该轮未重新输入拼音，没有新 composition 事件证据。之后模拟器报告 `render_service SERVICE_BLOCK`，屏幕变黑且无当前 mission，故停止完整长文滚动与折叠 resize；故障原因未判定。语音、手写、XT2/API24 均未测。本段仅记录部分模拟器观察，B6 仍为 ❓，不据此选择最终编辑器方案。

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

**2026-10-27 二进制能力限制（⚠️ 用户转贴的领域专家答复）**：官方支持回复明确称“当前 WriteStream 调用父类接口 write 不支持二进制为领域规格”，可走新增需求流程。原文及需求草稿见 [答复归档](qa/2026-10-27_WriteStream_二进制写入规格答复.md)。因此不能根据父类 `Writable.write` 的 `Uint8Array` 类型声明认定 `AtomicFile` 返回流支持二进制，也不再将更换 encoding 作为有依据的修复方向。该答复解释了既有 `WriteStream.write(Uint8Array)` 路径为何不受支持；未附 API 版本范围、修复计划或其他替代接口，也未逐项解释旧 hilog 与错误码。API 24 / XT2 运行行为仍待设备验证；此前“根因未知”是 2026-10-22 当时记录，不表示继续尝试 encoding。字符串保存结论不受此二进制限制推翻。

**2026-10-27 新 clone 受控替代写入**：本机 API 26 SDK 的 `ets/api/@ohos.file.fs.d.ts` 声明 `openSync(path, mode?)`、`writeSync(fd, buffer: ArrayBuffer | string, options?)` 与 `closeSync(file)` 均为 `@since 9`；`writeSync` 返回实际写入字节数。新 clone 可在未登记的专属导入目录内用 `OpenMode.WRITE_ONLY | CREATE | TRUNC` + `ArrayBuffer` 写入，循环处理短写并关闭 fd。此路径没有 AtomicFile 的失败回滚保证，只能用于本次新导入数据，不能用于已有库文件。该结论来自本机 API 26 SDK 的版本注解，API 24 / XT2 运行行为仍待设备验收。SDK 的 `renameSync(oldPath, newPath)` 同为 `@since 9`，但声明没有承诺覆盖/原子性；项目只在确认正式目标不存在后用于新目录改名，不据此保护旧文件。


⚠️ **🔴 崩溃实证（2026-10-18 真机级定位，重要）**：`stream.close()` 后再 `finishWrite()` 会
**SIGSEGV cppcrash**（栈：`musl free ← napi_delete_reference ← libfs.z.so`）。`close()` 已释放
native 侧写句柄，`finishWrite()` 再清理同一引用 = **double free**。**AtomicFile 全程不要调 `close()`**。

**官方示例的正确姿势**（js-apis-file-fs.md，write 走回调、`finishWrite()` 在回调里，无 close）：

```typescript
import { fileIo } from '@kit.CoreFileKit';

let atomicFile = new fileIo.AtomicFile(targetPath);
try {
  let stream = atomicFile.startWrite();   // 返回 WriteStream（不是 File！）
  if (content.length > 0) {
    stream.write(content, 'utf-8', (err: BusinessError) => {   // Writable.write：回调 = 落盘完成点
      if (err) { atomicFile.failWrite(); return; }
      atomicFile.finishWrite();          // 成功：临时文件重命名到目标位置
    });
  } else {
    atomicFile.finishWrite();            // 空内容：startWrite 已建空 tmp，直接 finish = 截断为 0 字节
  }
} catch (err) {
  atomicFile.failWrite();                // 失败：删临时文件，原文件不受影响
}
```

⚠️ **要点（2026-10-18 实测定案）**：
- 写入口是 **`startWrite()`**（非 `openWrite()`），返回 **`WriteStream`**（非 `File`）；
  写/关方法是 **`write(str)`**，**没有** `writeSync`/`closeSync`（那是 `File` 的方法）。
- `WriteStream.write` 继承 `stream.Writable`，**禁空字符串**（抛 401）——空内容直接 `finishWrite()` 截断。
- **write 是异步缓冲写**：回调触发才算写完；不传回调返回 boolean 只代表入缓冲。保存路径必须
  等回调（`NoteService.saveNote` 用 Promise 包回调 + 3s 超时兜底 + `saveChain` 串行化并发保存）。
- **回调不触发会永久挂起**（拿它 await 的调用方全部卡死）——必须带超时。

→ **已落地**（NoteService.saveNote），模拟器实测：保存 14 字笔记成功、进程不崩
（修复前同场景 SIGSEGV）。

**2026-10-22 用法追问答复（用户带回）**：答复称官方 `failWrite()` 示例在 `try/catch` 的 `catch`
中对同一 `AtomicFile` 实例调用 `failWrite()`，覆盖 `startWrite()` / `write()` 同步抛错；异步
`write()` 回调失败时调用 `failWrite()`，成功时调用 `finishWrite()`。AtomicFile 示例不对
`startWrite()` 返回的 `WriteStream` 显式 `close()`；写入会话以 `finishWrite()` / `failWrite()` 收尾。
该答复没有附逐项文档直链，已存档于 [2026-10-22 AtomicFile 用法答复](qa/2026-10-22_API24_AtomicFile_startWrite_用法答复.md)。
`failWrite()` 自身可能抛错，调用方应捕获清理异常；`delete()` 会删除原始文件和临时文件，不是
保留旧文件的失败回滚替代方案。实例复用、重试和并发保证仍未记载。

**13900020 边界**：用户带回答复将其通用含义确认为 “Invalid argument”，并指出在线方法章节引用
基础文件 IO 错误码，SDK `@throws` 列表并不穷尽运行时可能返回的错误码。本机 API 26
`@ohos.file.fs.d.ts` 的 `startWrite()` 列表仍未包含 13900020；这不解释其在本次调用中的具体
触发条件，也不证明错误来自临时文件或某一内部操作。API 26 模拟器根因仍未知；不外推至 API 24
运行时或 XT2。

### C2 目录删除与 `rmdirSync` ⚠️（SDK 声明核实，未作设备故障实验）

- 本机 HarmonyOS SDK 的 `ets/api/@ohos.file.fs.d.ts` 声明 `rmdirSync(path: string)`（since 9，低于 API 24），无递归参数；API 文本明确说明同步删除目录及其子目录和文件，异常列表包含 13900032 “Directory not empty”。
- ~~因此它只用于删除空目录，不能当作递归删库接口。~~ 该句是此前对无递归参数及异常列表的过度推断，与 SDK 方法说明冲突；本项目仍用 `listFileSync` + `statSync` 显式逐层删除，便于把清理目标限制在本次导入目录。
- 需要删除目录树时，先用 `listFileSync` 枚举子项、`statSync().isDirectory()` 区分目录与文件，递归删除子项，再对空目录调用 `rmdirSync`；文件用 `unlinkSync`。路径仍须来自统一解析器或基于已解析目录的子项遍历。
- 以上是本机 SDK 声明核实，不代表 API 24 设备运行验收；本项目不通过模拟器强杀或写入中断验证删除恢复。

**2026-10-22 API 26 模拟器 clone 复测补充（⚠️ 具体根因未确认）**：Huawei_TripleFold 模拟器
（系统识别型号 `emulator`，HarmonyOS 7.0.0.107、API 26、arm64-v8a）上，独立
`filesDir/atomicfile_probe_20261022/probe.md` 字符串写入通过；非空 Git clone 仍在 `.git/config` 写入时返回
13900020。早先 UI 的 `AtomicFile startWrite failed` 是因为实现把 `startWrite()` 与 `stream.write()` 放在同一
`try/catch`，不能用作阶段证据。开启实时 hilog 后，同一应用进程记录 `GetWriteArg: Illegal write buffer or encoding`
与 `WriteExec: Failed to resolve buf and options`；将两阶段分开捕获后，UI 显示
`AtomicFile write failed for .git/config: 13900020: Invalid argument`。这支持“失败发生在 `WriteStream.write()`
参数解析路径”的判断，不证明哪一个参数具体非法，也不证明 API 26 SDK 声明错误。

本机 SDK 26.0.0.105 的 `@ohos.util.stream.d.ts` 声明 `Writable.write(chunk?: string | Uint8Array, encoding?: string,
callback?: Function)`，列出的编码为 `utf8`、`gb18030`、`gbk`、`gb2312`。在新隔离目标上使用 `utf8`、省略 encoding、复制
`Uint8Array` 后仍复现；这是该 API 26 模拟器的运行时证据，不外推至 API 24 运行时或 XT2。HTTP fixture 的
`info/refs` 与 `git-upload-pack` 均返回 200；clone 未通过。设备、构建与逐轮页面结果见 [v0.3 §6](../releases/v0.3/需求文档.md)，
需向鸿蒙核实二进制 chunk 的官方调用方式及该日志错误码的含义，见[2026-10-22 提示词](prompts/2026-10-22_API26_AtomicFile_clone_.git_config.md)。

**2026-10-27 API 26 图片导入复验补充**：在 `Huawei_TripleFold_v05Clean` API 26 arm64 模拟器中，经系统 Photo Picker 选中图片后，应用已完成 Picker 资产查询、源 URI 打开和大小读取；随后对 `AtomicFile` 返回的 `WriteStream` 写入 `Uint8Array` 时回报 `13900020: Invalid argument`，应用调用 `failWrite()`，没有插入 Markdown 引用。最初以测试截图复验后，用户补入 JPEG 再次选择并完成，UI 即时捕获同一分阶段错误；随后将调用第二参数从 `undefined` 临时改为 `'utf8'`，重建并替换安装，再次对该 JPEG 导入仍得到同一 `Invalid argument`；本轮改用 `'utf-8'` 复验，构建、安装后再次选择同一图片，仍得到相同错误。编码参数取省略占位、`'utf8'` 或 `'utf-8'` 均未解决失败，根因仍未知。前述临时笔记已移入回收站；本轮使用既有样例笔记且正文未变化。附件目录内容未核验。此结果不外推至 API 24 / XT2。详见 [v1.3 §6](../releases/v1.3/需求文档.md#2026-10-27-图片导入-api26-复验)。

**同日 SDK 参数复核**：本轮查看 `Writable.write(chunk?: string | Uint8Array, encoding?: string, callback?: Function)` 声明和编码说明后，代码去掉了显式 `'utf8'`，以 `undefined` 保留第三参数回调。Hypium 任务与 HAP 构建通过；API26 替换安装后再次从 Picker 选图并点“完成”，但测试笔记没有出现 Markdown 图片引用，且笔记恢复后的编辑器未确认光标焦点，故无法区分图片复制是否完成与引用插入是否因无光标而未执行。此轮不是写入成功证据，也不能确认修复了 `Invalid argument`；应在不接受输入法协议的前提下安排能明确建立编辑器光标的后续复验。API 24 / XT2 仍待设备验证。

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

## F 组：小艺托管 Agent、FunctionComponent 与端插件（Insight Intent 执行器）

> 2026-10-25 范围调整见 [v0.6 需求](../releases/v0.6/需求文档.md)：首期本地操作不调用 Web/git，F6 的冲突仅约束未来自动 commit；F-A/F-B 等接口置信度未因此改变。新的接入核实提示词见 [提问](prompts/2026-10-25_API24_小艺本地笔记操作接入核实.md)。

> 来源：[`qa/2026-10-17_小艺智能体_端侧意图框架.md`](qa/2026-10-17_小艺智能体_端侧意图框架.md)（2026-10-17）
> ~~本组所有结论均未附文档链接~~ → 2026-10-26：F1、F9–F11 已补官方文档核对，见 [对照归档](qa/2026-10-26_小艺开放平台文档对照_API24.md)。其他旧结论置信度保持原标记；落码前仍须复核对应 SDK 和目标设备。
> **2026-10-27 路线结论**：采用平台单 Agent + `FunctionComponent` 入口 + 端插件；端插件在 App 内由 Insight Intent 执行器承接。F2–F8 中与旧方案有关的问法保留作历史记录，不能覆盖 F15 的配置式插件路径；能力、项目绑定和设备验收分别判断，见 F1/F15/F16。
> **不要在别的文档里复制本组结论**，一律链接过来 —— 下面标 ⚠️ 的随时可能被推翻。

### F1 应用内对话入口：`FunctionComponent` ✅ 官方入口明确 / ⚠️ 目标设备与资格待验

[官方 API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/hmaf-function-component) 标明 `FunctionComponent` 支持 Phone / Tablet、Stage 模型，起始于 HarmonyOS 6.0.0(API 20)。本工程 `targetSdkVersion=26.0.0`、`compatibleSdkVersion=6.1.1(24)`，版本范围满足该起始版本，但不证明 XT2 / 当前系统可运行。

[通过 Function 组件拉起智能体](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/hmaf-function) 明确组件分图标和按钮：不传标题显示图标，传标题显示按钮；按钮可配置功能描述。指南要求创建智能体、关联应用、设备登录华为账号并联网；组件需传 `agentId`、`onError`，可设初始 `queryText`，并可用 `isAgentSupport` 检查、监听对话框打开/关闭事件。`FunctionController` 没有普通 ArkUI Button 可调用的公开 `open` / `launch` 方法，因此支持路径是把 `FunctionComponent` 本身放在入口位置，由用户点击该组件启动；不能由普通自绘 Button 程序化拉起，也不能假定能保留自定义图标。标题可用“Agent 对话”，但系统组件的最终外观须在目标设备确认。

2026-10-30 API 26 SDK 样式声明核对：`@hms.ai.AgentFramework.d.ets` 的 `BaseOptions` / `FunctionOptions` 还公开 `titleFontSize`（14–16vp）、`iconSize`（16–24vp）、`iconColors`（单色图标着色）、`controlSize`、`buttonType`（`CIRCLE` / `CAPSULE` / `ICON_ABOVE_TITLE`）、`isShowShadow`（仅 Capsule）、`backgroundColor` 与 `titleColors`（单色或双色）。这些选项能调整系统组件样式，但未提供自定义图像图标或任意自绘外观。`ICON_ABOVE_TITLE` 声明从 HarmonyOS 6.0.1(API 21) 起；其余相关选项在 SDK 中标为 6.0.0(API 20) 起。工程顶栏选择常规尺寸胶囊、14vp 标题、20vp 图标及品牌色，无阴影；XT2 上各选项的显示效果尚未实测。

2026-10-27 客服答复同样建议以 Function 组件作为应用入口，详见[客服与官方文档核对归档](qa/2026-10-27_客服智能体与Skill接入建议_API24.md)。这解决了“是否有受支持的接入路线”，没有验证 AGC 关联状态、Agent 发布/测试资格或 XT2 运行。此前社区答复与 Stack 覆盖 spike 仍是历史证据：公开自绘按钮启动 API 仍不存在；模拟器因缺少 `agentKitHsp` 启动失败，不证明目标真机也缺少该系统 HSP，也不能证明遮罩方案可行。详见[旧答复归档](qa/2026-10-26_小艺自绘按钮拉起答复_API24.md)。

2026-10-26 Stack 覆盖 spike：API 26 模拟器构建成功，但启动接入 `FunctionComponent` 的 HAP 时触发 `SIGABRT`；Faultlogger 的 `LastFatalMessage` 为缺少 `com.huawei.hmsapp.hiai.hsp/agentKitHsp`，尚未进入 UI 触摸验证。该结果说明当前模拟器运行环境不具备此组件依赖，**不能判断遮罩视觉或点击命中是否可行**；临时接线和无效 `agentId` 已撤下，XT2 真机仍待测。

2026-10-30 模拟器启动隔离复验：华为[模拟器与真机差异指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-specification)指出，Kit 能力不支持导致应用闪退时可尝试动态引入 Kit，并给出缺少 Kit HSP 的 `LoadJSPandaFile` 报错示例；[ArkTS 动态加载指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-dynamic-import)说明动态 `import` 可按条件延迟加载模块。当前实现把 `@kit.AgentFrameworkKit` 静态导入及 `FunctionComponent` 放到 `AgentKitPage`，首页根据 `deviceInfo.productModel` 是否包含 `emulator` 决定是否展示入口，并仅在其他设备上动态导入该页。当前 API 26 模拟器通过 HDC 查询到 `const.product.model=emulator`；unsigned HAP 构建、覆盖安装、拉起后，应用主进程仍在运行，UI 树有 111 个节点，未包含 Agent 入口文案，未观察到本次启动的 `agentKitHsp` / `SIGABRT` 匹配日志。这里验证的是当前模拟器启动隔离；`deviceInfo.productModel` 在其他模拟器型号上的具体取值、真实设备的动态页面加载/Agent 拉起，以及模拟器点击绕过 guard 后的行为均未验证。API 26 SDK 将 `deviceInfo.productModel` 标为 API 6 起；动态路由代码已编译，真实设备页面路由待测。

2026-10-31 用户提供的 AI 答复与补充答复核对见[归档](qa/2026-10-31_模拟器AgentKit动态加载与设备识别答复核对_API24.md)。官方模拟器 FAQ 索引中有“在应用中如何区分真机和模拟器”条目，但本轮正文访问超时，未独立复核条目所述 `emulator` 值；本机 API26 模拟器的系统属性值 `emulator` 已有 HDC 实测。动态加载 Kit 依赖并用设备型号跳过模拟器路径，是文档支持的隔离方向；早先直接把动态导入的 `@Component` 类型作为组件调用没有通过 ArkTS 编译。

2026-10-31 代码修复与模拟器复验：`Index` 不再静态导入 `@kit.AgentFrameworkKit`；本机模拟器型号为 `emulator` 时不执行动态导入。Kit 依赖留在 `AgentKitSlot.ets`，由模块内 `@Builder` 经 `wrapBuilder` 包装后导出，首页只在非模拟器路径动态导入并调用包装后的 Builder。Hvigor `assembleHap` 编译及签名成功；签名包覆盖安装因已有安装包签名不一致而失败，同次构建 unsigned HAP 安装成功。重新启动后模拟器显示笔记工作区，日志未发现本次启动对应的 `agentKitHsp` / `SIGABRT` 匹配项。该结果验证当前 API26 模拟器跳过 Kit 模块时可进入应用；真机动态导入、顶栏实际渲染与 Agent 拉起仍未验证。此前“当前 main 已恢复首页静态 Kit 导入、启动再次命中 HSP”的结论只描述本次修复前状态，不再是当前代码状态。

官方指南另要求先创建智能体、关联应用，并确保设备已登录华为账号且联网。`FunctionOptions.queryText` 可设置初始查询文本。满足版本范围不等于本机 Agent 可用，仍需支持查询及设备验证。

该组件用于拉起已上线的指定智能体面板。本文列出的控制器没有消息流、历史注入或工具调用回传接口，**不能据此认定已满足自有聊天工作区的 Provider 协议**；是否存在其他正式接口仍待核实。

~~无需人工审核（技能发布到自己的智能体即可；仅主入口需审核）~~ → ⚠️ 2026-10-26 撤回无依据的泛化：本次文档未证明该免审核规则，发布与调试须按具体模式核实；端 A2A 已有明确前置，见 F10。

### F16 客服推荐的 Agent / Skill 路线 ✅ 路径明确 / ⚠️ 项目闭环待验

2026-10-27 客服回复与官方文档核对见[归档](qa/2026-10-27_客服智能体与Skill接入建议_API24.md)。官方[快速开始](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/quickstart-0000002762985731)列出单 Agent 的模型、插件和关联应用能力；结合 F1、F12、F15，当前需求可走“平台托管单 Agent + `FunctionComponent` 入口 + 端插件调用本地执行器”。客服建议的 AGC 创建/签名、关联、真机调试和上架步骤是路线指导，不等于项目已完成绑定、审核资格或发布。

✅ [Skill 插件指南](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/skill-plugin-0000002592771624)明确 Skill 可添加云、端或 MCP 插件；端插件用于构建设备侧应用交互通路。该文档没有给出从本 App 直接拉起 Skill 的完整接口/生命周期，因此 Skill 记作备选编排形式，当前不替代单 Agent + FunctionComponent 路线。端插件仍需 App 执行器、授权范围、AtomicFile 写保护与撤销逻辑；端插件支持设备侧执行，不代表平台模型聊天全离线。

2026-10-27 平台 Agent“曜石笔记助手”已创建为单 Agent 草稿；预览普通问答可返回，询问本地库访问时也明确回答无法访问。当前角色指令为空、插件数为 0；六项“曜石笔记”插件草稿尚未绑定该 Agent，AGC 应用关联状态未核实。因此现有验证只证明平台预览可对话，不证明端插件执行或 App 接入。API 24 / XT2、AgentKit 系统依赖、真机调试与审核/发布仍待验；不自动恢复 v0.6 排期。

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

### F9 端 A2A：小艺调用 App 已有 Agent ✅ 文档明确 / ❓ 模型 Provider 未核实

[端 A2A 入门](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/device-a2a-quickstart-0000002733266338) 面向已有可对话 Agent 的 HarmonyOS App；[应用内接入](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/agent2agent-inapp-0000002735604994) 要求实现 `AgentExtensionAbility`，用 `module.json5` 注册 `type: "agent"`，metadata 的 `ohos.extension.agent` 指向 `resources/base/profile/agent_config.json`。`AgentUIExtensionAbility` 仅自定义卡片按需实现。

文档列出 `onCreate → onConnect → onAuth（可选）→ onData → onDisconnect → onDestroy`，通过 `AgentHostProxy` 接收 JSON 并以 `sendData` 回传结果。这里是**小艺客户端 → App Agent → 返回小艺**的通信方向；它不证明小艺给 App 提供可调用的模型推理、动态系统提示词或结构化工具规划能力。自有聊天工作区能否接小艺模型仍为 ❓。

### F10 端 A2A 平台与调试前置 ✅ 文档明确 / ❓ 资格与豁免未核实

[官方入门](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/device-a2a-quickstart-0000002733266338) 列出 App 已开发并在 AGC 发布、已有可对话 Agent、设备支持 API 24 及以上等前置。配置需关联应用、填写真实 agent Ability 名称、导入 AgentCard、保存并发布真机测试；当前华为账号需进入有效测试用户组。端 Agent 不支持云侧调试，错误排查使用 DevEco HiLog 查看 `onData` 与回包结果。

这证明有测试白名单路径，不证明个人开发者自动获准、不用审核或未发布 App 可跳过前置。可选端插件权限也不能直接等同于本应用沙箱笔记读写权限或正文不出端保证。

### F11 端 A2A 的 API 24 / 26 边界 ⚠️ 必须分开实现依据

[端 A2A 入门](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/device-a2a-quickstart-0000002733266338) 称支持 API 24 及以上，并区分手工创建和 26.0.0 IDE 创建方式。但它链接的 [A2A ArkTS helper](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/hmaf-a2a-protocol) 将 `createA2AServer`、`Server`、`RequestContext` 等明确标为 **26.0.0 起始**，不能直接用于 API ≤24 的关键路径。

不能由 helper 的版本反推 API 24 不支持端 A2A。API 24 的完整收发/鉴权与报文处理路径仍需逐项核对 SDK / 协议和最小编译，并在 API 24 / XT2 联调。本次未执行这些验证；A2A 任务状态与流式能力也不提供后台常驻资格，继续见 N 组。

---

### F12 单 Agent + 端插件可形成托管工具链 ✅ 文档明确 / ⚠️ 项目未联调

[单 Agent 文档](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/llm-mode-gent-0000002762843985) 支持角色指令、插件参数和输出融合生成。[端插件实现](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/corresponding-code-implementation-of-plug-in-tools-0000002733287138) 明确通过 `InsightIntentExecutor` 的前台/后台执行方法接收工具名称、参数并返回结果。故意图框架可以承载模型调用的本地笔记工具，不能笼统认定“意图框架不能用”。这种托管链路的提示词/调度和对话由平台承担，不自动满足 App 自有 Agent loop 协议。

[云工作流指南](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/workflow-mode-agent-base-0000002765293833) 适合固定流程，开放式对话与自主工具调用优先单 Agent。两者文档均未给出本项目自有原生聊天页主动调用模型的完整协议。端插件的后台执行不等于 App 的任意后台常驻，继续遵守 N 组。

### F13 自有聊天页调用小艺模型：❓ 未找到完整公开协议

来源与 SDK 核对范围见 [同日续查 S8–S13](qa/2026-10-26_小艺开放平台文档对照_API24.md)。[技术支持工程师发布的问题集](https://developer.huawei.com/consumer/cn/forum/topic/0207212692647212464) 对“无对话框获取输出”推荐端插件，并强调智能体必须已运行；其原始答复是被官方栏目收录的社区答复，不是模型 SDK 契约。

结合本机 API 26 `AgentFrameworkKit` 的组件与 A2A 服务端导出，本次未找到完整覆盖历史、动态提示词、流式输出、结构化工具请求/结果回传的 App 主动调用小艺模型协议。**未找到不等于证明绝对不支持**；工作台内部 run 请求、平台界面资源和端插件回调不能替代公开 Provider 契约。模型接入选型须以实际协议为依据，不据此修改排期或发送笔记。

### F14 Data Augmentation Kit 端侧问答不覆盖 XT2 phone ✅ 文档设备约束

[官方简介的设备约束表](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/dataaugmentation-introduction) 明确：RAG 和端侧问答模型支持 PC/2in1，智慧数据检索才包含 Phone；该 Kit 暂不支持模拟器。因此不能把这里的端侧问答模型作为 XT2 的已支持模型 Provider。此结论只针对该 Kit 的对应能力，不泛化成所有手机端侧模型都不支持。

---

### F15 端插件按名称/版本映射到本地意图执行器 ✅ 文档、SDK 与本地接线 / ⚠️ 设备和平台闭环待验

[官方端侧配置文档](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/plugin-to-terminal--configuration-0000002733447010) 要求创建 `entry/src/main/resources/base/profile/insight_intent.json`，`insightIntents` 数组内的 `intentName` / `intentVersion` 与平台工具名/版本完全一致；`srcEntry` 指向执行器，`uiAbility.ability` 指向对应 UIAbility，后台工具示例配置 `executeMode: ["background"]`。这里的配置式 `insightIntents` 不等于 F2 待核实的装饰器 `insightIntentsSrcEntry`。

本机 API 26 SDK 的 `@ohos.app.ability.InsightIntentExecutor.d.ts` 声明 `onExecuteInUIAbilityBackgroundMode(name, param)` 自 API 11 支持，返回 `ExecuteResult` 或其 Promise。冷启动由 UIAbility `onCreate` 进入执行回调，不要求创建 window；热启动直接进入回调。这是 SDK 声明，不是本项目设备运行证据。

2026-10-28 项目进展：仓库已为平台 `ListVaults` 0.1.0 增加配置映射及后台 `InsightIntentExecutor`，把 `VaultRegistry.list()` 投影为知识库 id/name/type/isCurrent 字段。其他六项工具、FunctionComponent 接线、平台调用与 API 24 / XT2 运行仍未验；本次代码只说明本机 SDK 编译目标上的接线实现，不代表设备闭环。平台代码页提供的是 ai_plugin JSON / OpenAPI YAML 声明，不是 App 的完整 ArkTS 业务实现；早期六项草稿配置不等于已经能读写设备笔记。核对来源见 [当日归档](qa/2026-10-26_小艺开放平台文档对照_API24.md)。

2026-10-30 实施更新：本工程 `Index` 已在笔记工作区顶栏接入 `FunctionComponent` 并监听关闭事件刷新文件；`insight_intent.json` 增加 `QueryNotes`、`ReadNote`、`CreateNote`、`AppendNote`、`EditNote`、`UndoLastEdit` / `0.1.0` 后台映射，统一执行器复用 `VaultRegistry`、`FileTree`、`NoteService`、`AgentOperationStorage` 与 `AtomicFile`。源码级工具契约/文本规则测试及 API 26 SDK 目标 HAP 构建通过。平台 Agent 仍是草稿，测试组、平台真实调用、API 24 / XT2 与发布审核尚未验证；SDK 构建不能表述为设备或端到端成功，详见 [v0.6 验收记录](../releases/v0.6/验收记录.md)。

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

### H2 运行时读取版本号 ✅ 已核实（实现见 `SettingsView.ets`）

候选路径（**已用第一条，落码于 2026-10-18 设置与关于页**）：

| 候选 | 说明 | 状态 |
| --- | --- | --- |
| `bundleManager.getBundleInfoForSelfSync(bundleFlags: number): BundleInfo` → `BundleInfo.versionName` / `versionCode` / `name` | 读自身包信息，**API 24 可用、读自身包无需额外权限** | ✅ 已用（`GET_BUNDLE_INFO_WITH_APPLICATION`） |
| 资源文件 `$r('app.string.xxx')` 手写版本字符串 | 简单但**必然与 app.json5 漂移** | ❌ 不推荐 |
| 构建期注入常量 | 需改构建脚本 | ❓ 待评估 |

> **硬规则**：版本号**只能从包信息读出**或**构建期注入**，**禁止在源码里手写版本字符串**——手写必然与 `app.json5` 不一致，且每次发版都要记得改。
>
> ⚠️ 实测要点：`BundleInfo` 自身就带 `versionName` / `versionCode` / `name`（不必走 `appInfo` 子对象）；
> 该同步接口读**自身**包信息不需要 `ohos.permission.GET_BUNDLE_INFO` 等权限；整段包在 `try/catch` 内，读不到时不崩、显示占位。

### H3 待核实清单

| 编号 | 问题 | 状态 |
| --- | --- | --- |
| **H-1** | API 24 下运行时读取自身 `versionName` 的**确切接口与所需 flag**？读自身包信息是否需要权限？ | ✅ 已核实：`getBundleInfoForSelfSync` + `GET_BUNDLE_INFO_WITH_APPLICATION`，无权限 |
| **H-2** | `bundleManager` 的同步版本（如 `getBundleInfoForSelfSync`）在 API 24 是否可用？ | ✅ 已核实：可用 |

---

## I 组：视觉与设计系统（UI Design Kit / Symbol / 字体）

> 2026-10-17 建立。起因：用户要求设计稿按华为设计资源修，引出的**落码侧待核实项**。
> ~~⚠️ 本组全部未核实，未核实项不进关键路径，先用兜底方案。~~ → 已于 2026-10-18 核实，当前结论见 **J 组**；以下保留最初的问题清单，不再作为待问项。

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
- **token 真源**：`docs/prototype/v2/index.html` 的 `:root` 与 `[data-theme="dark"]` 段。
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

## L 组：弹层、命中与 JS 桥接的坑（2026-10-18 实测，侧栏下拉菜单 + 文件树 + M0.5 spike）

> 全部是**模拟器实测复现 + 修复验证**过的，不是纸面结论。踩坑位置：`VaultSidebar` 库切换下拉菜单、`FileTreeView` 行点击、`EditorWebView` + `web/mdeditor` 桥接。

### L-1 下拉菜单被文件树盖住 → 必须用 `bindPopup`，不能自己摆溢出节点 ❓→✅

**现象**：库切换菜单能弹出来，但下半部分被左边的文件树盖住，点不动。

**根因**：菜单原来是「Stack 内一个 `offset({ y: ... })` 溢出的普通 `Column`」。它是**页面内普通子节点**，
而侧栏里文件树在它之后声明 —— **ArkUI 同级组件后声明的绘制在上层**，于是菜单被树盖住
（`Stack` 默认不裁剪溢出内容，所以能看见、但点不到）。

**修法**：改用官方弹层 `bindPopup(show, CustomPopupOptions)`，弹层挂在**窗口覆盖层**上，
层级高于页面内一切组件，天然不可能被遮挡：

```typescript
.bindPopup(this.menuOpen, {
  builder: this.VaultMenu(),          // @Builder 里放完全自定义的 token 化内容
  placement: Placement.BottomLeft,
  offset: { x: 0, y: Space.s2 },
  mask: false,                        // 轻量下拉不需要半透明遮罩
  autoCancel: true,                   // 点外面自动收起
  popupColor: Color.Transparent,      // 底色由内容 Column 自己给（走 token）
  onWillDismiss: (action: DismissPopupAction): void => {
    action.dismiss();                 // ⚠️ 不调 dismiss() 菜单不会真消失
    this.menuOpen = false;            // 同步 chevron 图标状态
  }
})
```

**实测结论（2026-10-18 三屏态）**：
- 弹层在控件树里排在页面内容**之后**（独立节点，不嵌在侧栏 Column 里）→ 层级正确；
- 点菜单项命中并跳转库管理页 ✅；点外面自动收起 ✅；再点一次切换器收起 ✅（**无双重 toggle**，
  outside touch 被弹层消费、不会透传到底层组件的 `onClick`）；
- ~~内容宽 240vp = `Size.sidebarW`、行高 48vp = `Size.touch`，与原型 vault-menu 一致~~（2026-10-21 修订：原型 `.vault-menu` 是 `left:0; right:0` 于切换卡片 —— **与卡片同宽**而非固定 240；现由卡片 `onAreaChange` 实测宽回填 `@State menuW`。行高 48 = `Size.touch` 不变）。

> 同类需求（任何「浮在页面内容之上」的东���）一律走弹层：`bindPopup` / `bindMenu` / `bindContextMenu` / `openMenu`。
> **不要**再用「绝对定位 + offset 溢出」手搓浮层 —— z-order 取决于声明顺序，是个定时炸弹。

### L-2 行内子控件吃掉点击 → `hitTestBehavior(HitTestMode.None)` ❓→✅

**现象**：文件树里**目录行**点得了（折叠/展开正常），**文件行**点文件名没反应，点行的空白处才生效。

**根因**：行内子控件（文件名 `Text`、图标、缩进格）各自是命中目标，会**吃掉**点击，
`onClick` 挂在外层 `Row` 上反而不触发。目录行早期测试点到了箭头图标附近，看起来像好的，误判过一轮。

**修法**：把行内不参与命中的子节点（缩进格 + 内容 `Row`）统一设
`.hitTestBehavior(HitTestMode.None)`，让整行点击冒泡到外层 `Row` 的 `onClick`。

> 判别实验（值得复用的思路）：同一行点上半部/下半部、点最左侧空白 —— 都用同一套坐标注入，
> 只有「文件行文本区」失败，才定位到是子控件吃点击，而不是注入失效或应用崩溃。

### L-3 `versionCode` 必须单调递增 ⚠️

把 versionCode 从 1000000（v0.1）改成 2000（v0.2）→ 装机报
`install version downgrade code:9568263`，**已装旧包的设备/模拟器一律装不上**。
`versionCode` 是装机唯一判定依据，语义版本放 `versionName`。
本项目口径：v0.1 = 1000000，v0.2 = **1000001**（只递增）。

### L-4 JS 调 ArkTS 桥接（`registerJavaScriptProxy`）两个坑 ❓→✅

> 2026-10-18 排查 M0.5 spike「ready 事件不过桥」定位，模拟器实测修复验证。
> 踩坑位置：`EditorWebView.ets` + `web/mdeditor/src/index.ts`。

**坑 1（真正的根因）：桥接方法必须挂在注入对象上直接调用，不能 detach。**

```typescript
// ❌ 抛 "Javascript bridge method can't be invoked on a non-injected object"
const fn = window.__arkts?.postMessage
fn(JSON.stringify(msg))
// ✅ 直接挂在对象上调
window.__arkts.postMessage(JSON.stringify(msg))
```

Chromium 桥接方法（与 Android `@JavascriptInterface` 同款机制，crbug 514628）依赖**接收者 `this`**
做注入校验：方法一旦从对象上取下来再调，`this` 丢失，一律判「非注入对象」。
**误判警示**：此时 `typeof window.__arkts.postMessage === 'function'` 仍然是 true ——
曾据此误判成「对象只是个未注入的壳」，白排查一轮。typeof 正常但调用报 non-injected，
第一反应应该是查调用方式（detach / this），不是查注册。

**坑 2（注册时机）：在 `onControllerAttached` 里注册，不要等 `onPageEnd`。**

- `onControllerAttached`（SDK `component/web.d.ts:7214`，**@since 10**）是官方生命周期文档
  建议的注入时机：controller 绑定后、页面加载前 → 代理随本次页面加载一起注入，
  **无需 `refresh()`、页面只加载一次**，页面脚本首轮执行就能看到对象（实测 `try=0 arkts=yes`）。
- `onPageEnd` 里注册：SDK 原话 *"Registed objects will not appear in JavaScript until the page
  is next (re)load."* —— 必须再 `refresh()`，页面加载两遍。
- `onPageBegin` 注册已属太晚（页面已开始加载）。

**`WebviewController.registerJavaScriptProxy` 正确签名**（位置参数版，API 9+；options 对象版属于
已 deprecated 的 `WebController`，混用直接编译错）：

```typescript
registerJavaScriptProxy(jsObject: object, name: string, methodList: Array<string>,
                        asyncMethodList?: Array<string>, permission?: string): void
```

- `methodList` 同步方法（可拿返回值）；`asyncMethodList` 异步方法（不阻塞 JS 线程、无返回值）；
  同一方法只注册到一个列表，重复注册默认按异步。
- `permission` 默认空串 = 不做 URL 白名单校验；rawfile 页面生产环境建议显式配
  `{"scheme":"resource","host":"rawfile","port":"","path":""}`。
- 注册后必须 `refresh()` 才生效**仅对「注册时页面已加载」成立**；`onControllerAttached` 时机不需要。

**实测通过（2026-10-18 三屏态）**：`onControllerAttached` 注册 → 页面单次加载 →
`announceReady try=0 arkts=yes` → `ready sent to ArkTS at try=0` → ArkTS 侧
`Web 编辑器页面就绪，桥接已建立`。JS→ArkTS 方向自此跑通（此前 gitbridge 只验证过 ArkTS→JS）。

### L-5 `width('100%')` 配水平 margin = 溢出父级 ❓→✅

> 2026-10-18 用户报告「vault-switch 卡片超出侧栏宽度」，模拟器 UI 树实测定位 + 修复验证。
> 踩坑位置：`VaultSidebar.ets` 头部库切换卡片。

```typescript
// ❌ 卡片占宽 = 侧栏宽 + 2×margin，右缘越过栏间分隔线伸进编辑区
.width('100%').margin({ left: Space.s2, right: Space.s2 })
// ✅ inset 放外包层 padding（盒内，不溢出）；卡片自身只留垂直 margin
Column() { Row(...).width('100%')... }.padding({ left: Space.s2, right: Space.s2 })
```

ArkUI 的百分比取**父级内容盒的 100%**，margin 加在盒外 —— 与 CSS `content-box` 同款行为，
但 ArkUI 没有 `box-sizing` 和 `width:auto` 收缩兜底（块级子元素不设宽度才是撑满-减去margin）。
**判别特征**：控件右缘越过父容器边界 / 压到相邻栏的分隔线。
原型 `.vault-switch` 用 CSS `margin` + `width:auto` 不溢出，照抄进 ArkUI 必须换成外包层 padding。

**实测通过（2026-10-18 三屏态，UI 树读数）**：侧栏 0–1061px（369vp），卡片
`left:23, width:1013`（右缘 1036px = 360vp）✅ 不再越界；修前右缘 ≈1084px、探出 8vp。
已全库扫同类反模式（`width('100%')` + 水平 margin），仅此一处。

### L-6 Web 内 CodeMirror：`setState` 重建会剥掉后挂的 listener；双 ready 会重建 view ❓→✅

> 2026-10-18 排查「编辑器 change 事件绝迹 → 自动保存/预览联动全死」。模拟器日志定位 + 修复验证。
> 踩坑位置：`web/mdeditor/src/index.ts` + `EditorWebView.ets`。

**现象**：编辑器加载后 `updateListener`（CodeMirror `EditorView.updateListener`）从不触发，
防抖自动保存、预览联动全部失效；但 `getContent`/`setContent` 桥接正常。

**根因（两层叠加）**：
1. **双 ready**：web 侧 `announceReady` 发一次 `ready`，ArkTS `onPageEnd` → `onArktsReady` 又发一次
   （启动日志实证：37.267 与 37.470 两次「页面就绪」）。第二次 ready 走 `impl 已建 → setTheme` 分支。
2. **setTheme 丢 listener**：`view.setState(EditorState.create({ extensions: extensionsFor(theme) }))`
   —— 若 `updateListener` 是建 view 后才 concat 进 extensions 的（或在 `extensionsFor` 之外），
   重建 state 时就**永久丢失**。change 事件从此绝迹。

**修法（两层都要）**：
- `updateListener` 挪进 `extensionsFor()` 内部 —— **任何 state 重建路径都自动带上**；
- ArkTS 侧 ready 去重：`this.impl` 已存在则忽略第二次 ready（不重建 impl、不重发 onReady）。
  重建会丢 in-flight `getContent` waiter；重发 onReady 会触发 loadFile 重读文件冲掉未保存改动。

**判别特征**：桥接命令（runJavaScript 方向）正常但事件（postMessage 方向）不来，
第一反应查「listener 被谁剥了」，而不是查注册时机。

### L-7 `@Builder` 按值传参不随状态刷新 —— 要刷新用 `$$` + 命名 interface ❓→✅

> 2026-10-18 修复「PaneHead 标题永远停在『源模式』」。踩坑位置：`Index.ets` 三栏 PaneHead。

```typescript
// ❌ 按值传参：调用时求值快照，this.mode 变了标题不动
this.PaneHead('源模式')
// ✅ 按引用传参：$$ 指向命名 interface 字段，状态变化自动重渲染
interface PaneHeadParam { title: string }
this.PaneHead({ title: ... })   // @Builder PaneHead($$: PaneHeadParam)
```

⚠️ `$$: { title: string }` 内联对象类型违反 `arkts-no-obj-literals-as-types`，**必须命名 interface**。
**判别特征**：组件首帧渲染正确、状态变化后纹丝不动 → 查 `@Builder` 参数是不是按值快照。

### L-8 模拟器环境限制清单（2026-10-18 定案）⚠️

模拟器（API 24 x86）上一批接口/能力**确定性不可用**，别再在模拟器上验证这些项：

| 项 | 表现 | 结论 |
| --- | --- | --- |
| IME × Web contenteditable | attach 失败 `errcode=80`，重启不恢复 | 真机才可验（M0.5 头号项） |
| `uitest uiInput inputText` | 报成功但无 text 事件进 Web | 依赖 IME，同上废 |
| `uinput -K -t '文本'` | 产生 kChar 事件但无 text payload，不插入 | 只能发键码，不能发文本 |
| ArkWeb 异步渲染 | 编辑区像素 100% 纯白（连行号槽都没有），JS/桥接正常 | 模拟器白屏是常态；`renderMode: RenderMode.SYNC_RENDER`（since 12）已加，模拟器死亡未验完，**真机复验** |
| 视觉验证 | 截图纯白但视觉模型会「看出」caret/文本 | **幻觉**：关键结论必须像素检测/日志佐证 |

注入替代通道：**临时调试钩子**（隐形 `Text` + `LongPressGesture` → `editorBridge.setContent`）——
`setContent` 派发的 doc 变更走真实 change→自动保存链，可验证保存链路；验收后移除。

### L-9 `ListItem.swipeAction` 三档手势落地（2026-10-21，SDK 核实 + 构建通过）✅ 签名 / ⚠️ 运行时待验

API 24 SDK 签名（`sdk/default/openharmony/ets/component/list_item.d.ts:563`）：

```ts
swipeAction(value: SwipeActionOptions): T
SwipeActionOptions { start?, end?: CustomBuilder | SwipeActionItem, edgeEffect?: SwipeEdgeEffect }
SwipeActionItem {
  builder: CustomBuilder,
  actionAreaDistance?: Length,
  onAction?: (isOperation?: boolean) => void,   // 手势松手越过 actionAreaDistance 后回调
  onEnterActionArea?, onExitActionArea?, onStateChange?, ...
}
SwipeEdgeEffect { None, Spring, FolderLockMode }
```

三档语义的映射（原型 `index.html` 左滑行为 → ArkUI）：

| 原型行为 | 落法 |
| --- | --- |
| 拖一半吸附露出 3 按钮条 | `swipeAction({ end: { builder: SwipeBar, ... }, edgeEffect: Spring })`，SwipeBar 自绘 重命名/移动/删除 三按钮（各 48vp） |
| 滑到底 → 直接删除 + 5 秒撤销条 | `actionAreaDistance: Size.swipeDelExtra(36vp)`，松手越阈值触发 `onAction` → 移入回收站 + UndoBar（**只对文件行**） |
| 文件夹没有第三档（回弹） | 目录行 `onAction` 空操作（不注册删除）；Spring 自动回弹 |

- 状态：签名已在 SDK 核实、`arkts_check` + 签名 HAP 构建通过；**手势手感 / actionAreaDistance 阈值体感未实测**（模拟器手势注入不可靠，见 L-8），随真机验收。
- 关联落码：`FileTreeView.ets`（SwipeBar + swipeAction）、`TrashService.ets`（`vaults/<库>/.trash/` 回收站 + 恢复拒绝覆盖）、`Index.ets`（UndoBar + doTrashFile）；详见 `docs/releases/v0.2/需求文档.md` §6。

### L-10 v0.4 快切遮罩外点击命中（2026-10-23，API SDK 声明 + API 26 模拟器）✅

- 本机 API 24 SDK 的 `component/common.d.ts` 声明 `CommonMethod.onClick`、`onAreaChange`；`ClickEvent.windowX/windowY` 标注 API 10 起。`component/units.d.ts` 中 `Area.globalPosition` 是当前窗口坐标，标注 API 8 起；`Area.width/height` 提供控件实际尺寸。这些接口都不高于 API 24。
- 快切遮罩与卡片是同屏自绘层。外层 `Row` 横向铺满屏幕，点在卡片左右间隙时会命中它，不能只依赖下层遮罩的点击回调。实现用 `onAreaChange` 记录卡片窗口边界，并在该 `Row` 的 `onClick` 里比较窗口坐标；卡片内点击不关闭，边界外点击关闭。
- API 26 TripleFold 模拟器实测：sm、md、lg 左右空白均能关闭；md/lg 卡片与屏幕边缘之间的空白也能关闭。搜索框点击后保持焦点且弹层不误关。API 24 设备和 XT2 运行时仍待验。
- 输入框聚焦时模拟器第一次系统 Back 只清除焦点、弹层仍在，第二次 Back 才关闭。尝试在输入框处理 Back 未改变该现象；目前尚未确定是输入焦点处理还是 IME 消费，API 24 / XT2 需实测，不宣称该状态下单次返回关闭。

### L-11 v0.7 分栏手势与单屏横向窗口识别（API 24 SDK 声明）⚠️

- 本机 API 24 SDK 的 `ets/component/gesture.d.ts` 声明 `PanGesture`、`onActionStart` / `onActionUpdate` / `onActionEnd` 与 `GestureEvent.offsetX` 均 since 7；`offsetX` 单位为 vp，且相对手指按下位置，可用于分隔条拖动。
- 原生通过现有 `windowSizeChange` 的宽高 vp 判断紧凑横向窗口：宽度落入 md 范围、窗口高度低于 md 下限且宽大于高。此判断只使用窗口几何，不读 `foldStatus`，也不复用原型预设值；它是项目布局规则，不是系统提供的物理屏幕类型。
- 该几何规则及手势仅经 API 24 声明和本机构建核实；真实 XT2 的横向窗口读数、触控手感与旋转继承仍待设备验证。宽度小于所有栏最小值总和时无法同时满足 240vp，此时仅作窄窗口退让，设备目标尺寸不应进入该分支。

### L-12 会话重命名的双击与 F2 输入（SDK 声明 + API 26 模拟器）⚠️

- 当前本机 HarmonyOS SDK 的 `ets/component/gesture.d.ts` 声明 `TapGesture` since 7、连续点击参数 `count` since 11；`ets/component/common.d.ts` 声明 `onKeyEvent` since 7；`ets/api/@ohos.multimodalInput.keyCode.d.ts` 声明 `KEYCODE_F2 = 2091` since 9。均早于工程兼容上限 API 24，未使用更新接口。
- API 26 TripleFold lg 实测：双击会话标题打开改名；键盘路径需先 Tab 将焦点移至会话行，再发送 F2。该结果只证明当前模拟器交互，不证明 API 24/XT2 的焦点行为。

### L-13 v0.9 章节侧栏键盘导航（本机 SDK 声明）⚠️

- 本机 HarmonyOS SDK 的 `ets/api/@ohos.multimodalInput.keyCode.d.ts` 声明方向键 `KEYCODE_DPAD_UP/DOWN/LEFT/RIGHT` 为 2012–2015、中心键 2016、空格 2050、Enter 2054、Home/End 2081–2082，均为 since 9。
- `ets/component/common.d.ts` 的布尔型 `onKeyEvent` 回调为 since 15（void 型重载为 since 7），组件 `id()` 为 since 11；`ets/api/@ohos.arkui.UIContext.d.ts` 的 `UIContext.getFocusController()` / `FocusController.requestFocus()` 为 since 12。声明版本均不高于工程兼容上限 API 24。
- 文件树操作菜单快捷键声明：`ets/api/@ohos.multimodalInput.keyCode.d.ts` 的 `KEYCODE_MENU` / `KEYCODE_F10` 均为 since 9；ArkUI `KeyEvent.getModifierKeyState(['Shift'])` 以及 `DismissPopupAction.reason` / `dismiss()` 均为 since 12，`DismissReason.PRESS_BACK` 包含 Esc 与系统 Back。均不高于 API 24；这只是本机 SDK 声明核对，不证明键盘路由、弹层焦点或设备交互。
- 以上仅核对当前本机 SDK 的声明与可用版本；本轮 HAP 在 API 26 模拟器安装，未实际注入键盘事件，不能据此宣称 API 24 / XT2 键盘行为通过。

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
| **浮在内容之上的菜单/浮层** | ✅ **一律走官方弹层**（`bindPopup` 等）；❌ 禁「offset 溢出 + 绝对定位」手搓浮层（会被后声明组件盖住，**L-1 实测**） | 已落地（侧栏库切换菜单） |
| **行内子控件吃点击** | ✅ 行内不参与命中的节点统一 `hitTestBehavior(HitTestMode.None)`，冒泡到外层 Row（**L-2 实测**） | 已落地（文件树行） |
| **versionCode** | ✅ 单调递增（v0.1=1000000 → v0.2=1000001）；调小直接 `install version downgrade` 装不上（**L-3 实测**） | 已是现状 |
| **JS→ArkTS 桥接调用方式** | ✅ 桥接方法**必须挂在注入对象上直接调**（`window.__arkts.postMessage(x)`）；detach 后调用抛 `non-injected object`，且 `typeof` 仍是 function（**L-4 实测**，曾误判成「壳」） | 已落地（EditorWebView / gitbridge 复用） |
| **桥接代理注册时机** | ✅ `onControllerAttached`（页面加载前，单次加载即注入）；❌ `onPageEnd` 注册要 `refresh()` 且页面加载两遍（**L-4 实测**） | 已落地（EditorWebView） |
| **控件 inset 的写法** | ✅ 外包层 `padding` 做 inset；❌ 控件自身 `width('100%')` + 水平 `margin`（占宽 = 父宽 + 2×margin，溢出）（**L-5 实测**） | 已落地（VaultSidebar 库切换卡片） |
| **registerJavaScriptProxy 签名** | ✅ 位置参数版 `(obj, name, methodList, asyncMethodList?, permission?)`；options 对象版是 deprecated `WebController` 的，编译直接错 | 已是现状 |
| **AtomicFile 用法** | ✅ **回调式 write + 回调内 `finishWrite()`，全程禁 `close()`**（close+finish = double free → SIGSEGV，C1 实测）；空内容直接 finishWrite；写路径必须超时+串行化 | 已落地（NoteService.saveNote） |
| **CodeMirror state 重建剥 listener** | ✅ updateListener 进 `extensionsFor()` 内部 + ArkTS 侧 ready 去重（双 ready 重建会永久丢 change 事件，**L-6 实测**） | 已落地（mdeditor） |
| **@Builder 传参刷新** | ✅ 需随状态刷新的参数用 `$$: 命名 interface` 按引用传；按值传参是调用时快照（**L-7 实测**） | 已落地（PaneHead） |
| **模拟器能力边界** | ⚠️ IME×Web（errcode=80）/ 文本注入 / ArkWeb 渲染在模拟器全不可用（**L-8**）；编辑器/输入法验证一律真机 | 已定案 |
| **列表项三档左滑** | ✅ `ListItem.swipeAction` + `SwipeActionItem.actionAreaDistance/onAction`（`edgeEffect: Spring`），签名 API 24 已核实（**L-9**）；文件夹不注册 onAction 即无第三档 | 已落地（FileTreeView，手感待真机） |
| **回收站位置** | ✅ `vaults/<库>/.trash/` 镜像原相对路径：FileTree 天然过滤点前缀、库 rename/delete 自动带着走、恢复目标=镜像路径无需元数据；**v0.3 Git 同步须给 `.trash` 配 .gitignore** | 已落地（TrashService） |


## M 组：设置内重置数据（2026-10-25）

### M1 ApplicationContext.clearUpApplicationData ✅ SDK 明确 / ⚠️ 设备未验

本机 SDK `ets/api/application/ApplicationContext.d.ts`：`clearUpApplicationData(): Promise<void>`，`@since 11`、Stage、主线程调用；声明明确清理应用文件路径数据并撤销应用请求的用户授权，**会终止应用进程，终止后后续回调不再触发**。不是 `restartApp()`，不应在成功回调中恢复库或提示“完成”；产品要求用户重新打开，由首装链路恢复样例。

声明异常：16000011（context 不存在）、16000050（内部错误）。无新增权限要求。此处是 SDK 契约核实，尚未实际清空模拟器或 XT2；它不证明设备清理/重开结果。

### M2 Git 凭据清理 ✅ SDK 签名 / ⚠️ 运行时未验

`ets/api/@ohos.security.asset.d.ts`：`querySync` 与 `removeSync` 自 API 12；查询用 `ReturnType.ATTRIBUTES`（只读属性，不取 SECRET），按返回的 ALIAS 删除本应用 `vault:*:token` 条目，包含 pending-import。24000002 表示不存在，视为无需删除；其他错误中止本次重置并展示失败。不要假定 M1 自动清除了 AssetStore 的安全资产，因此显式清理当前应用的 Git 别名后再调用 M1。

全链路逻辑由 mock 单测验证，禁止为了测试而清空已有设备数据。用户在 App 内主动确认的重置功能与主动制造崩溃实验不同。


## N 组：Agent 后台与通知（2026-10-25 SDK 声明核对）

来源：[本机 SDK 核对记录](qa/2026-10-25_API24_Agent后台与通知_SDK核对.md)。SDK 实际为 API26；下列只按 @since 检查声明，不等于 API24/XT2 运行验证。官方待核实项见 [提问](prompts/2026-10-25_API24_Agent_loop_后台与通知核实.md)。

### N1 ⚠️ 短时/长时接口存在，Agent 场景资格未确认

`requestSuspendDelay`（since 9）、`startBackgroundRunning(context, ContinuousTaskRequest)`（since 21）在本机声明中存在。短时任务不保证整个 Agent loop 完成；长时任务需匹配适用类别与权限。`MODE_DATA_TRANSFER` 描述上传/下载与进度更新，不能把所有网络推理自动归入；phone 上持续计算/特殊场景有受限权限条件。XT2 大屏不改变 phone 身份。是否允许本应用的 Agent 后台执行仍为 ❓，默认前台，不开启假后台模式。

### N2 ⚠️ 通知声明覆盖 ≤24，授权与设备表现待验

本机声明 `notificationManager.publish(request)` since 9、`isNotificationEnabled()` since 11、带 UIAbilityContext 的 `requestEnableNotification(context, callback)` since 10。授权申请需 UI 已加载，拒绝后不可反复弹同一申请。仅证明声明范围，尚未执行系统授权或发通知。完成通知与长时任务系统通知分开处理；通知权限不等于后台运行资格。通知正文不包含笔记内容或文件信息。

### N3 ❓ 小艺后台意图不等于自有 Agent loop 可后台常驻

F4 仍为未充分核实的平台生命周期记录；不能据此声称支持持续模型请求、工具循环、流式回调或进程回收后的恢复。Worker/脱离 Web 的原生 Runner 也不提供系统运行许可。v0.7 mock 独立推进；v0.6 等待正式消息/工具协议、背景资格与通知路径核实，不因本组声明核对恢复实施。


## O 组：本地文件分享与 ZIP 打包（2026-10-26 官方文档 / 本机 SDK 声明核对）

来源：[核对记录](qa/2026-10-26_ShareKit与本地打包_API24.md)。本机 HarmonyOS SDK 为 API 26.0.0.105，工程 `compatibleSdkVersion` 为 6.1.1(24)；以下 API 起始版本均不高于 24。当前只确认文档与声明，不等于 API 24 / XT2 运行验收。

### O1 ✅ 系统分享面板与 App 文件 URI 可用；授权生命周期待运行验证

- `@kit.ShareKit` / `systemShare.SharedData` / `systemShare.ShareController` 在本机声明标注 since 4.1.0(11)；`ShareController.show(UIAbilityContext, options)` 返回 `Promise<void>`。官方文本、视频示例分别使用文本内容和 `fileUri.getUriFromPath(path)` 构造分享数据并调起面板，见[分享文本](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/share-utd-text)与[分享视频](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/share-utd-video-V5)。
- 文本记录使用 `UniformDataType.TEXT` 和 `SharedRecord.content`，不需要文件 URI；本机 SDK 的 `SharedData` 声明注明最多 500 条记录、总大小限制 200 KB。实现应在超限或目标拒绝时显示分享失败，不静默截断文本。
- `ShareController.on/off('dismiss', callback)` 标注 since 4.1.0(11)，用于监听分享面板关闭；`on/off('shareCompleted', callback)` 标注 since 5.1.0(18)，在用户完成分享时返回所用分享渠道，可用于统计。两者均不证明目标应用已读取文件或接收人已收到内容。
- `SharedRecord.uri` 明确支持 App file URI 与 user file URI；`fileUri.getUriFromPath(path)` 的 SDK 声明 since 9。官方资料没有明确说明接收方临时授权何时授予、何时失效，`dismiss` / `shareCompleted` 与授权撤销或临时文件安全清理的关系，也没有说明 `show()` 的 Promise 何时 resolve；需以系统面板正常交接和目标应用读取结果验证。
- `@ohos.fileshare` 的持久化授权接口标注 since 11，且需要 `ohos.permission.FILE_ACCESS_PERSIST`。该持久化能力不等同于 Share Kit 单次交接授权；不得在未确认需求前额外申请持久化授权。

**2026-10-30 API 26 运行观察（不外推至 API 24 / XT2）**：`Huawei_TripleFold` 对样例 `快速上手.md`（611 B）调起系统面板后，列出“华为分享 / 复制 / 另存为 / 添加至中转站”，未显示微信或飞书。点“另存为”进入“将文件保存至‘我的手机’”界面，列出 `Download` 与 `Documents`；系统 Back 返回分享面板，未保存文件。点“华为分享”后出现设备发现 / 传输权限说明；本轮取消授权，随后只看到“点击开启”页面，没有发现或选择接收设备。截图：`.local/shots/v09_share_system_targets_api26_20261030.png`、`v09_share_save_as_target_api26_20261030.png`、`v09_share_huawei_prompt_api26_20261030.png`、`v09_share_huawei_landing_api26_20261030.png`、`v09_share_after_save_cancel_api26_20261030.png`。此观察只证明 API 26 系统面板和本机保存目标 UI 可达；不证明任何目标应用读取文件或接收人收到内容。

**2026-10-30 API 26 另存为补验（不外推至 API 24 / XT2）**：分享 `欢迎使用.md`（729 B），在系统保存界面选择 `Download` 并确认后返回笔记页。此结果只证明目标选择 / 确认流程可达；HDC shell 无媒体目录权限，首次启动系统文件管理器要求隐私授权，本轮取消，因此未确认下载文件是否存在或内容是否正确，也没有接收方读取证据。控件树留在本机忽略目录 `.local/shots/v09_share_receive_panel_ui.md`、`v09_share_receive_save_as_ui.md`、`v09_share_receive_download_folder_ui.md`、`v09_share_receive_saved_ui.md`。

### O2 ✅ 沙箱文件 / 目录压缩 API 可用于 API 24；目录结构以产物检查验收

- 本机 `@ohos.zlib` 声明 `compressFile(inFile, outFile, options)` since 9，可将沙箱文件或目录压缩成文件；`compressFiles(inFiles, outFile, options)` since 12。API 24 可用前者打包准备好的临时目录。需以解压后文件集合、相对路径和中文 / 空格文件名测试确认实际产物。
- `Options.keepTopLevelFolder` 标注 since 26，API 24 不能配置；实现不得引用此新选项。临时源目录和 zip 路径仍必须由 Context 属性取得并经统一路径解析层生成。

### O3 ⚠️ 排版长图输出链路仍待核实

Share Kit 接受图片文件 URI，但现有文档与 SDK 证据尚未确定如何将当前 ArkWeb Markdown 预览完整、分段地输出为图片，也没有确认长图像素 / 文件大小限制。不得据此把单张截图或静默裁切写成满足 v0.8 的长文分图能力；先核实输出链路并对产物做全文完整性检查。


## P 组：系统主题变更通知（2026-10-27 本机 SDK 声明核对）

### P1 ✅ ApplicationContext 系统配置回调含颜色模式更新

本机 API 26 SDK 的 `ets/api/application/ApplicationContext.d.ts` 声明 `onSystemConfigurationUpdated(callback)` 与 `offSystemConfigurationUpdated(callback?)` 均为 Stage API `@since 24`，并要求主线程调用；其 callback 类型位于 `@ohos.app.ability.systemConfiguration.UpdatedCallback`，其中 `onColorModeUpdated(colorMode)` 明确描述为系统颜色模式更新时调用，同样 `@since 24`。`Configuration.colorMode` 与颜色模式枚举声明为 `@since 9`。因此可用于工程 API 24 上限；本声明核对不等于 API 24 / XT2 运行验收。

本版将系统回调映射到 AppStorage，再由编辑器与预览 WebView 显式同步主题。模拟器系统主题切换和 XT2 仍待正常 UI 验收；禁止把 SDK 声明当作设备实测。


## Q 组：v1.3 相册 Picker 图片读取（API 起始版本核对）

### Q1 ⚠️ Picker URI 的授权范围与 SDK 声明存在不同表述

本机 API 26 `@ohos.file.photoAccessHelper.d.ts` 声明 `PhotoViewPicker`、`PhotoSelectOptions`、`PhotoSelectResult.photoUris` 和 `PhotoAsset.displayName` 均早于 API 24；其中 `photoUris` 注释明确要求通过 `PhotoAccessHelper.getAssets()` 的临时授权使用。`getAssets()` 的通用声明带 `ohos.permission.READ_IMAGEVIDEO` 标注，但华为 Media Library 文档说明，通过 Photo Picker 访问用户明确选择的媒体可不申请图库读取权限。实现仅用 Picker URI 查询所选 `PhotoAsset`，不枚举相册，也不新增 `READ_IMAGEVIDEO`；原始 URI 不直接交给文件 API。官方 FAQ 有直接 `openSync(photoUris[0])` 的示例，与当前 SDK 对 `photoUris` 的限定不一致，因此以 SDK 声明为准。

`PhotoAsset.uri` 为媒体 URI；`fileIo.openSync(path, READ_ONLY)` 接受 URI，二者 API 起始版本均不高于 API 24。当前 `NoteImageService` 在 `getAssets()` 返回所选资产后打开资产 URI，再以 `fileIo.copyFile(sourceFd, uniqueTargetPath)` 复制到库内；源、目标大小核对成功后才插入 Markdown。该复制方式已在 API 26 模拟器跑通，API 24 / XT2 仍待验。Picker URI 授权与元数据查询的上述声明/文档差异仍按 Q1 保留。

**2026-10-27 API 26 运行复验**：`copyFile` 复制到唯一命名附件后，检查目标文件大小与源 fd 相同；第一次交互因包内编辑器 rawfile 过期而未插入 Markdown，重新打包 `web/mdeditor` 并安装后，第二次交互成功插入相对引用并在预览显示 JPEG。确认插入失败时源代码已有 `insertText`、但 rawfile 未更新；这不是 `copyFile` 失败。当前图片导入不走 `AtomicFile`；半成品清理是复制失败后的尽力删除，并不具有 AtomicFile 回滚保证。API24 / XT2 尚未实测。

来源：[Photo Picker 访问图片/视频](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/component-guidelines-photoviewpicker-V5)、[图库图片选择常见问题](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/media-library-kit-faqs-0004)、[图片 Picker 预览 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/video-thumbnail-system)。

## R 组：应用反馈能力核实（2026-10-27）

### R1 ❓ Feedback Kit 独立通用 SDK 未获证实

用户转交答复的提供方已撤回其独立 Kit 说法；本机 SDK 中反馈相关占位文件无可调用签名，不能作为接入依据。自建反馈后台也不能默认与华为运营反馈后台互通。来源与边界见 [核实记录](qa/2026-10-27_应用反馈能力核实_API24.md)。

### R2 ✅ commentManager 是评分评论，声明起始 API20

本机 SDK 明确提供 showCommentDialog，但它不是普通问题反馈表单或工单接口；未登录与频率限制等情况有专用错误码。声明可用于 API24 不等于本应用运行验证。签名与官方链接见同一核实记录。

### R3 ✅ FunctionalButton.onFeedback 仅适用元服务

SDK 声明起始 API20，注释明确仅元服务可用，不能据此为当前普通 App 接线。用户最终选择邮箱方案，原生邮件能力须另行核实；本轮未做设备验证。证据见同一核实记录。

### R4 ✅ 邮件拉起接口存在；⚠️ mailto 设备匹配待验

本机 SDK 的 UIAbilityContext.startAbility Promise 签名自 API9，wantConstant 有 ACTION_SEND_TO_DATA；可作为邮件草稿方案的基础。startAbilityByType Promise 签名自 API11，必需 type/wantParam/abilityStartCallback 三参数，用户转交的两参数例子不能照抄。邮件预填与无客户端处理仍须正常设备验证；不据拉起结果宣称邮件发送/送达，不提供后台静默发送承诺。来源与实施边界见 [邮件反馈核实](qa/2026-10-27_邮件反馈拉起方式_API24.md)。

## S 组：Native libgit2 N-API 封装 PoC（2026-10-27）

### S1 ⚠️ N-API 声明可编译，API 24 设备加载待验

本机安装的 HarmonyOS Native SDK 为 API 26（26.0.0.105）。其 `sysroot/usr/include/napi/native_api.h` 声明 `napi_module_register`、`napi_create_promise`、`napi_create_async_work`、`napi_queue_async_work`、`napi_create_threadsafe_function`、`napi_call_threadsafe_function` 等 N-API 接口；线程安全函数接口起始 API10。`sysroot/usr/lib/aarch64-linux-ohos/libace_napi.z.so` 提供链接库。使用此 SDK 配置 `OHOS_COMPATIBLE_SDK_VERSION=24` 可生成 `aarch64-linux-ohos24.0.0` 编译目标，但仍以 API 26 sysroot 编译，不等于 API 24 SDK 或设备验收。

本机 `@ohos.net.http.d.ts` 的 `HttpRequestOptions.caPath` 从 API10 起可用；不设置时，SDK 声明网络栈使用系统预设 CA，并给出 `/etc/ssl/certs/cacert.pem` 路径。Native libgit2 在 HTTPS 操作前把此路径交给 libgit2/mbedTLS，`caFile` 仅作可选覆盖。API26 模拟器公开 GitHub HTTPS clone 通过；这是 Native 对系统 CA 路径的设备证据，不等同于 API24 / XT2 验收或服务商 HTTPS 认证。

2026-10-31：Native 模块已编入主 App 与 `ohosTest` HAP；API26 模拟器 `Git2Native` Hypium 9/9，包括 Native 模块加载、隔离认证、`xt2` 分支、进度、clone 字节哈希、stage/commit/fetch/push、失败清理、索引写失败保护、`.trash` 排除和非快进拒绝。当前实现没有调用 checkout，也未实现 pull：libgit2 不承诺 checkout 多文件写入/删除的整体原子性或失败/中断整库回滚；`AtomicFile` 不能包裹其原生写入。API24 / XT2、生产 App 页面端到端、AssetStoreKit 真机读令牌和真实服务商 HTTPS 认证仍待验。详见 [v0.3 验收记录](../releases/v0.3/需求文档.md#6-验收记录)。

## T 组：外部目录选择与持久授权（2026-10-31，v1.5 前置核实）

### T1 ✅ API 24 可以用官方 Picker 选目录
本机 `@ohos.file.picker.d.ts`：`DocumentViewPicker.select()` 自 API9；`DocumentSelectOptions.selectMode` 与 `DocumentSelectMode.FOLDER` 自 API11（syscap `FileManagement.UserFileService.FolderSelection`），均在 API 24 内。`maxSelectNumber` 注释写明目录一次只能选一个；`authMode`（since 12）注释写明只在 2-in-1 设备生效，手机上无效果，不能依赖。

### T2 ⚠️ 持久授权依赖 `FILE_ACCESS_PERSIST`；2026-10-31 用户拍板申请，调试期 ACL profile 已就位
`@ohos.fileshare.d.ts` 的 `persistPermission` / `activatePermission` / `deactivatePermission` / `revokePermission` 自 API11，`checkPersistentPermission` 自 API17，全部 ≤ API 24；`OperationMode` 仅 `READ_MODE`(0b1) 与 `WRITE_MODE`(0b10) 可用（`CREATE_MODE` / `DELETE_MODE` 自 API20，超出范围）。五个接口**全部**要求权限 `ohos.permission.FILE_ACCESS_PERSIST`。持久授权存在系统数据库里，**应用或设备重启后必须调 `activatePermission()` 激活**。

**权限等级口径（两个来源，取严者执行）**：
- 官方 Restricted Permissions 文档把该权限列在受限清单内，条目 NOTE 原文：「In API version 12, the permission level of this permission is changed to normal. If the application is only for local debugging: For versions before API version 12, you still need to use this permission by following the restricted permission application method. **For API version 12 and later only, you can directly declare the permission.** If the application needs to be released to an application market: You still need to use this permission by following the restricted permission application method.」
- 官方论坛答疑（华为侧回复开发者同名提问）：该权限属「特殊情况」，等级虽降为 normal，**文档仍特殊说明须按受限权限申请方式**——即 AGC 申请权限 → 申请 profile 时勾选 → `module.json5` 声明，三步齐全才生效。
- 结论：**发布上架必须走受限权限申请（AGC 审核）**；本地调试按 NOTE 可直接声明，但为对齐发布要求，本机同样使用含 ACL 的 profile。

**本机证据（2026-10-31）**：用户提供的调试 profile `测试profileDebug.p7b`（存于 `.local/profile-file-access-persist.p7b`，gitignore）解析结果——`type: debug`、`bundle-name: com.jxg.huaweiobsidian`（与本工程一致）、`apl: normal`、`acls.allowed-acls: ["ohos.permission.FILE_ACCESS_PERSIST"]`、`permissions: {}`、`validity` 覆盖至 2027-10-31。调试期 ACL 通道成立。

**连带变更**：`module.json5` 首次出现 `INTERNET` 之外的权限（`ohos.permission.FILE_ACCESS_PERSIST`），仓库手册硬约束 13 已按「已拍板的例外」补记。**发布前仍需完成 AGC 受限权限申请**，否则上架版本拿不到该权限。

**设备实测 ①（2026-10-31，API26 x86_64 模拟器 + 上述 ACL profile 签名包）**：
- `atm dump -d -p ohos.permission.FILE_ACCESS_PERSIST` → `grantMode: SYSTEM_GRANT`、`availableLevel: NORMAL`、`availableType: NORMAL`、`provisionEnable: true`、`distributedSceneEnable: false`。**即：声明即授予，运行时不需要 `requestPermissionsFromUser` 弹窗**。
- `atm dump -t -b com.jxg.huaweiobsidian` → 该权限与 `INTERNET` 同为 `grantStatus: 0`、`grantFlag: 4`（`0` = 已授予；未授权场景表现为 `-1`）。
- ⚠️ 模拟器非 XT2，且当时只用含 ACL 的 profile 测过，一度误判为「profile 必须含该权限」（见下方实测 ② 的更正）。

**设备实测 ②（2026-10-31 晚，XT2 真机 LAP-AL10 / 系统 API 26 —— 结论推翻了实测 ① 的推论）**：改用 **DevEco 自动签名的 profile（`acls` 为空数组）** 构建，仅凭 `module.json5` 里那一行声明：

```
atm dump -d -p ohos.permission.FILE_ACCESS_PERSIST
    grantMode: SYSTEM_GRANT   availableLevel: NORMAL   availableType: NORMAL   provisionEnable: true
atm dump -t -b com.jxg.huaweiobsidian
    FILE_ACCESS_PERSIST  grantStatus: 0  grantFlag: 4   ← 与 INTERNET 一致，已授予
```

**结论（以本条为准）**：在 API ≥ 12 的设备上（本 XT2 实测为 API 26），**profile 不需要包含 `FILE_ACCESS_PERSIST` 的 ACL，只需要在 `module.json5` 声明即被授予**。`provisionEnable: true` 不等于「profile 必须带权限」——实测 ① 把这个字段解释错了。`Strictly speaking`：我们在 XT2 真机上的这个文件权限已被授予。

这条更正同时意味着：**v1.5 的开发 / 真机调试不需要专门去申请含 ACL 的 debug profile**（那个 profile 反而因为证书不同源导致装不上，见 AGENTS.md 硬约束 19 附带的坑）。发布上架仍按上面的 AGC 三步走。

**残留风险**：以上均为 **API 26 设备**（模拟器 + XT2 真机）证据。目标设备兼容级别为 API 24，官方 NOTE 明确「API version 12 及以后可直接声明」，24 > 12 故预期一致；但手上没有真正只到 API 24 的设备，**不外推**，v1.5 §6.1 仍保留「待验证（需 XT2/API24）」的字样直到其完成判定跑通。

**发布链路：AGC 受限权限申请（官方流程，来源：[申请使用受限权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/declare-permissions-in-acl-V14) / [Requesting Restricted Permissions](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/declare-permissions-in-acl)）**：
1. **AGC 申请权限证书**：在 AppGallery Connect 提交受限权限申请，审核结果通过互动中心与邮件通知（官方称「within the specified review period」，Restricted Permissions 列表里多数标注 3 个工作日）。官方强调「应优先使用 Picker / 安全控件等替代方案，仅少量符合特殊场景的应用被允许申请」——本权限官方给的典型场景正是「文档编辑类应用期望历史记录里直接打开，不必再次拉起 Picker」，与本工程 v1.5 场景吻合。
2. **申请 Profile 时勾选该权限**：必须在 AGC「添加 Profile」页面申请对应受限权限，否则审核被驳回。Profile 里权限没覆盖代码使用的范围会导致签名失败或上架驳回。
3. **工程内声明**：`module.json5` 的 `requestPermissions` 声明；仅 `user_grant` 权限还需运行时弹窗（本权限实测为 `SYSTEM_GRANT`，不需要）。

- ⚠️ 官方明确：**未申请权限证书却在配置文件声明该权限，会导致应用安装失败**。本工程能安装成功，反证当前 profile 已带该权限证书。
- **上架时**：AGC 会按使用场景复核，需为每个受限权限填写权限说明并**上传视频说明使用场景**。
- **调试阶段捷径**：官方写明 DevEco Studio 自动签名会代为向 AGC 申请受限权限；本机所用含 ACL 的 debug profile 与这一机制一致。**发布阶段必须手动按上述 1–3 步重走。**

### T3 ✅ 目录 URI 不能用 `listFileSync` 枚举 —— 官方确认 + 设备实测双向坐实
**结论（2026-10-31 已闭环）**：`fs.listFile* ` 的 path 契约是「应用沙箱路径」，传 Picker 目录 URI
**必然报 13900002（ENOENT）**，官方答复确认不支持、也无公开支持计划。

SDK 契约对照（本机 `@ohos.file.fs.d.ts`）——同一个 URI 在不同接口上的命运由 `@param` 写死：

| 接口 | 行 | path 参数原文 |
| --- | --- | --- |
| `fs.open` | 2491 / 2529 / 2582 | Application sandbox path **or URI** of a file or directory |
| `fs.lstat` | 1711 / 1733 | Application sandbox path **or URI** of the file（注明 URIs can be passed since API n） |
| `fs.listFile` | 1548 起（所有重载） | Application sandbox path of the directory（**无 URI 字样**） |

XT2 实测同一时刻同串两种结果：`listFileSync(uri, {recursion:true})` → 13900002；
`openSync(uri, READ_ONLY)` → 成功拿到 fd。**所以网上「listFile 递归遍历外部目录」的社区示例无官方出处，不可依赖。**

### T4 ❓ 外部变更感知与跨应用共管没有本地证据
`fileshare` 只描述本应用视角的授权；另一款软件能否管理同一目录取决于目录所在命名空间（如 Download 公共目录），不是本 App 授予的权限。此项须选定场景后设备实测。

### T5 ✅ 三方枚举目录 URI 的唯一通路：`open` 拿 fd → Native `fdopendir`（2026-10-31 官方答复 + 设备实测）
官方答复（2026-10-31）明确：**ArkTS 侧没有基于 fd 的 readdir 语义接口，遍历入口在 Native 侧**。
三方应用、NORMAL 权限可用的完整链路：

```
DocumentViewPicker(FOLDER) → file://docs/... 目录 URI
  → fileShare.persistPermission(READ|WRITE)   → fileShare.activatePermission
  → fs.openSync(uri, READ_ONLY | OpenMode.DIR) → 目录 fd
  → Native: dup(fd) → fdopendir(dupFd) → readdir → openat(fd, 子项名) 递归
```

**XT2 实测（LAP-AL10 / API 26，hilog `ProbeRunner`）**：

| 步骤 | 结果 |
| --- | --- |
| `native_flat`（单层 `fdopendir`） | ✅ 16 条 —— 与 Picker 自报「Download 16 项」一致 |
| `native_recursive`（递归 `openat`） | ✅ 31 条，**路径含子目录前缀**（如 `com.xueqiu.hm/xxx.pdf`）→ 授权顺延到子目录得到证明 |

结论：**不存在能力缺口，产品形态不用改**（官方答复 Q5-C 明确不成立）。

实现位置：`native/vaultdir_napi`（C，`listDirByFd` / `listDirRecursiveByFd`）、
`model/VaultDirNative.ets`（ArkTS 封装 + 依赖注入）、
`ExternalDirProbeDevice.ets` 的 `DeviceVaultDirFs` / `DeviceVaultDirNative`。

两个必守的坑：
- **`fdopendir` 接管 fd 所有权** —— 必须先 `dup()`，否则 ArkTS 侧 `closeSync` 会 double close。
- **`OpenMode.READ_DIR` 不存在** —— 官方答复示例写错了，真实是 `OpenMode.DIR = 0o200000`（d.ts L199），
  开目录写 `READ_ONLY | DIR`。**这是第 4 次官方答复出现具体 API 名错误。**

Native 返回约定：相对路径**不带前导斜杠**（与 `listFileSync` 的「以 / 开头」不同），**目录项以 '/' 结尾**，
按 `endsWith('/')` 区分类型，不必再 `stat`。失败返回 `ok:false + errno` 而非抛异常 —— 抛出去 errno 会被
ArkTS 的 Error 包装吃掉。

### T6 ✅ `AtomicFile` 对外部 URI 不可用（code=-1），来自 SDK 契约而非用法错

**已定位并有 SDK 出处**：`AtomicFile(path)` 的 path 参数契约是
"Application sandbox path of the file"（d.ts L4718），**不收 URI**，
传目录 URI / 拼接的子文件 URI 都失败，实测 **code=-1**（非 BusinessError，拿不到 errno）。
官方第二轮答复确认同口径，并明确**ArkTS 侧没有面向外部目录的原子写 API**。

同一坑位的还有：`createStream`(L902/948)、`unlink`(L3455)、`rename`(L3009/3044)、
`createWatcher` —— path 全 Written as 沙箱路径。只有 `open`(L2491/2529/2582) 写的是
"Application sandbox path **or URI**"。

### T7 ✅ 外部目录的写 / 删 / 改名：**全部走 Native POSIX**（2026-10-31 第二轮答复 + 设备实测）

读写删改统一收敛到 `native/vaultdir_napi`，ArkTS 侧只负责 Picker、`fileShare`
持久化与激活、把 dirFd 传进去。**关键是全程用相对名字，不拼 URI** ——
官方明确不保证应用自拼 URI 的可用性（涉及百分号编解码）。

| 动作 | Native 实现 | 实测 |
| --- | --- | --- |
| 读笔记 | `openat(dirFd, name, O_RDONLY)` + 循环 read | ✅ |
| 原子保存 | 写 `name.<pid>.tmp` → `fsync` → `renameat(dirFd, tmp, dirFd, name)` | ✅ 76 字节写后回读一致 |
| 变短覆盖 | 同上（renameat 是整块替换，天然无残留尾部） | ✅ 76 → 7 字节，回读无旧尾 |
| 改名 | `renameat(dirFd, old, dirFd, new)` | ✅ 按新名可读 |
| 删除 | `unlinkat(dirFd, name, 0)` | ✅ 自清理成功（递归仍 31 条，未变 32） |

- **持久化 WRITE_MODE 已覆盖子树的写 / 删 / 改名，系统不再逐次弹窗确认**（答复 Q4）。
  产品层面要不要加确认对话框是 UX 选择，不是系统要求。
- `renameat` 之后对 `dirFd` 做一次 `fsync` 让目录项落盘；部分 DFS/FUSE 挂载点会返回
  `EINVAL`，此时数据本身已在 rename 前 fsync 过，**只降级为软警告，不把写判死**。
- 不使用 NDK 私有 API，只依赖 POSIX 基线 + 官方文档认可的通路，答复明确**不会因此被上架驳回**。
- **重激活后写链路仍成立**：杀进程重启 → `activatePermission` → 写 / 覆盖 / 改名 / 删除全部 ✅。

### T9 ✅ ArkTS 不做结构化类型：同构但异名的结果接口不能互传（2026-10-31 编译实测）

**现象（本机 `-Wall -Wextra` 之外的 ArkTS 编译器实测，错误码 10605030）**：
`entry/src/main/ets/model/VaultAccess.ets` 里 `throwExternalFailure(result: ExternalIoResult, ...)`
被调用时传入 `ExternalReadResult` / `ExternalBinaryResult` / `ExternalStringResult` /
`ExternalFdResult`，编译器逐条报：

```
ERROR: 10605030 ArkTS Compiler Error
Error Message: Structural typing is not supported (arkts-no-structural-typing)
```

这四者与 `ExternalIoResult` 的字段**完全一样或包含它的全部字段**（多一个 `content` / `bytes` /
`entries` / `fd` 而已），在 TS 里合法，在 ArkTS 里非法——**ArkTS 只认声名字，不看结构**。
`as ExternalIoResult` 强转能绕过，但那是把编译期检查按回去，属于技术债，不采用。

**采用的解法（语义上也更准）**：抽公共状态基接口，各结果接口 `extends` 它，抛错函数只收状态部分。

```typescript
export interface ExternalIoStatus { ok: boolean; code: number; message: string; }
export interface ExternalIoResult extends ExternalIoStatus {}
export interface ExternalReadResult extends ExternalIoStatus { content: string; }
export interface ExternalBinaryResult extends ExternalIoStatus { bytes: Uint8Array; }
export interface ExternalStringResult extends ExternalIoStatus { entries: string[]; }
export interface ExternalStatResult extends ExternalIoStatus { size: number; mtime: number; isDir: boolean; }
export interface ExternalFdResult extends ExternalIoStatus { fd: number; }

function throwExternalFailure(result: ExternalIoStatus, action: string): void { /* 只用到 code / message */ }
```

继承关系是 ArkTS 认可的兼容方式，比之一份合一字母段的胖接口（会让文本读也背一个 `bytes`）更贴近语义：
**抛错这件事本来就只关心 `ok/code/message`，不关心载荷类型**。

**连带结论**：Native 返回值在设备侧的转发层（`VaultAccessDevice.ets`）同样要守住这道线——
`.d.ts` 里的 `VaultDir*Result` 与 model 层的 `External*Result` 是两份声明，跨层赋值必须当场
`as` 到目标名（这一处是**有意为之**：`VaultAccessDevice.ets` 是全仓唯一的转译点，转译完以后
model 层再无结构类型混用）。

**校验方式**：hvigor `assembleHap` 全量编译通过（含 x86_64 与 arm64-v8a 两个 ABI 的 Native 编译），
`tools/tests` 345/345 用例通过。

### T10 ✅ Native 侧补齐 15.3 需要的四个能力（2026-10-31 编译 + 既有设备通路实测）

在既有 T5（枚举）/ T7（写链路）之上补了四个方法，均走同一条「持有目录 fd + 相对名字」通路：

| 方法 | Native 实现 | 用途 | 状态 |
| --- | --- | --- | --- |
| `statByFd(fd, name)` | `fstatat(fd, name, &meta, 0)`；`name` 为空串时 `fstat(fd)` | 文件树判定目录 / 文件、15.4 授权体检看目录还在不在 | 编译通过，待设备实跑一次确认 errno |
| `mkdirByFd(fd, name)` | 逐段 `mkdirat` + `openat(O_DIRECTORY)` 进入下一段 | 写文件前备好父目录（`mkdir -p` 语义） | 同上 |
| `removeDirByFd(fd, name)` | `unlinkat(AT_REMOVEDIR)` + 递归清内容 | 删目录树；外部目录没有 `.trash`，这是真删 | 同上 |
| `readBinaryByFd(fd, name)` | `openat` + 按 `st_size` 读成 `Uint8Array` | 图片附件；走 `readFileByFd` 会因 UTF-8 编解码坏字节 | 同上 |

**编译侧踩坑（写下来防复发）**：`stat_by_fd` 里局部变量不能叫 `info` —— 与同函数的形参
`napi_callback_info info` 同名，clang 报 `redefinition of 'info' with a different type`。
局部变量统一改名 `meta`。

### T8 ✅ 外部目录变更感知：没有官方方案，只能轮询

`fileIo.createWatcher` 的 path 契约是**沙箱路径**，不支持外部目录 URI；
媒体库观察者只覆盖媒体类文件，`Download` 下的 documents 目录不在范围。
→ v1.5 若要「用户在 PC 改了 md，App 自动发现」，只能自己轮询（工程建议非官方规范）：
前台可见时轮询、间隔秒级、**目录 mtime 变化才重新扫描子目录**，其余只 stat 已知文件。

来源与逐条证据见 [外部目录授权能力核实记录](qa/2026-10-31_外部目录授权能力_API24.md)、
[目录 URI 遍历答复核验](qa/2026-10-31_目录URI遍历答复核验.md) 与
[目录 URI 写链路答复核验](qa/2026-10-31_目录URI写链路答复核验.md)。
T1 / T2 / T3 / T5 / T6 / T7 / T8 均有设备实测支撑；T9 / T10 由本机编译 + 既有设备通路支撑，
尚未单独上机跑验收用例。
**所有读数来自 API 26 设备（XT2 / 模拟器），目标兼容级别为 API 24，未完成判定跑通前不外推。**
