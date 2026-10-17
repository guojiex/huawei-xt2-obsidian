# 咨询：`getCurrentFoldCreaseRegion()` 在三折叠（Mate XT2）上返回值不随形态变化

> 用法：把「问题正文」整段复制，发给鸿蒙官方技术支持 / 开发者问答 / 官方 AI 助手。
> 正文自包含：环境、复现代码、实测数据、已排除方案都在里面，对方不需要追问就能回答。
>
> ✅ **2026-10-17 已收到答复**：见 [`qa/2026-10-17_折痕接口追问_实测反馈.md`](qa/2026-10-17_折痕接口追问_实测反馈.md)，
> 结论已沉淀进 [`api_notes.md`](api_notes.md) **A2 / A2-bis**。核心：官方**无法定性**（倾向系统侧限制），
> 建议改用 `display.getLiveCreaseRegion()`（@since 20）—— ⚠️ 官方示例代码写错了，
> 它是 `Display` **实例方法**，须 `display.getDefaultDisplaySync().getLiveCreaseRegion()`（编译实测）。
>
> ⚠️ **采纳答复前请注意**：本项目有硬约束——**官方答复也要交叉验证**。
> 我们已被官方答复误导过三次：① 说 `getCurrentFoldCreaseRegion()` 返回单个 Rect（SDK 实证是 `Array<Rect>`）
> ② `build-profile` overrides 的 `name` 字段（d.ts 说要、运行时 schema 拒绝）
> ③ `display.getLiveCreaseRegion()` 挂错对象（编译器报错 10505001）。
> **拿到答复后请尽量给出 API 文档链接或 SDK 出处。**

---

## 一句话问题

在 **Mate XT2（三折叠，双折轴）** 上，`display.getCurrentFoldCreaseRegion()` 返回的
`creaseRects` 是**两条 rect，但两条的中心 x 都是同一个值（372vp）**，
并且**在五种折叠形态下完全不变**。这是预期行为吗？
如果是，三折叠「当前形态下每条折痕的位置」应该怎么拿？

---

## 问题正文

````
### 环境

- 设备：**HUAWEI Mate XT / XT2**（三折叠，双折轴；系统里 deviceType 是 phone）
- 系统：HarmonyOS NEXT
- compileSdkVersion 6.0.0(26) / compatibleSdkVersion **6.1.1(24)**（API 24）
- 语言：ArkTS，Stage 模型
- 我们只用 **API ≤ 24** 的接口（更高的接口请注明版本，我们会评估升级）

### 目标

做三折叠适配：让**分栏边界落在折痕上**，即「一栏占一块物理屏」，
避免任何一栏的内容横跨折痕。

### 复现代码（最小片段）

```typescript
import { display } from '@kit.ArkUI';

const region: display.FoldCreaseRegion = display.getCurrentFoldCreaseRegion();
const rects: Array<display.Rect> = region.creaseRects;
// 每条折痕中心 x：px → vp
for (let i = 0; i < rects.length; i++) {
  const centerVp = px2vp(rects[i].left + rects[i].width / 2);
  // 打印/显示
}
```

采集时机：① UIAbility 里 `window.on('windowSizeChange')` 回调中；
② `display.on('foldStatusChange')` 回调中。两个时机都试过，结果相同。

### 实测结果（五种形态，同一个接口）

| 形态 | 窗口宽(vp) | display.getFoldStatus() | creaseRects 条数 | 两条折痕中心 x(vp) |
| --- | --- | --- | --- | --- |
| 外屏合起 | 380 | 2 (FOLDED) | 2 | **372, 372** |
| 内屏只用最左一屏 | 379 | 12 (FOLDED_WITH_SECOND_EXPANDED) | 2 | **372, 372** |
| 左两屏展开 | 709 | 1 (EXPANDED) | 2 | **372, 372** |
| 右两屏展开 | 683 | 1 (EXPANDED) | 2 | **372, 372** |
| 三屏全展开 | 1061 | 11 (EXPANDED_WITH_SECOND_EXPANDED) | 2 | **372, 372** |

**异常点有两个：**

1. **两条 rect 的中心 x 完全相同（都是 372）**。三折叠有两条物理折痕，
   按窗口宽度反推应分别在 **379** 与 **709**（三块物理屏 379 / 330 / 352，合计 1061）——
   第二条折痕的位置完全没体现出来。
2. **五种形态下返回值一模一样**，完全不随折叠状态变化。
   按接口名 `getCurrentFoldCreaseRegion()` 的字面语义，它应该反映「当前」形态。

### 想请你确认的问题（可逐条回答，方便我对照）

**Q1.** Mate XT2 上 `getCurrentFoldCreaseRegion()` 返回「两条 rect 但中心 x 相同、且不随形态变化」，
是**预期行为**、**已知问题**，还是**我们的用法不对**？

**Q2.** `creaseRects[i]` 的 `left / width`：
- 单位是 **px** 吗？（我们按 SDK 注释理解为 px，并用 `px2vp()` 转换）
- 坐标系是**相对整个展开后的逻辑屏**，还是相对某一块物理屏 / 某个 display？
- `width` 是折痕区域的**宽度**（即折痕本身有厚度）吗？我们用 `left + width/2` 取中心线，对吗？

**Q3.** 如果 `getCurrentFoldCreaseRegion()` 在三折叠上不可靠，
**推荐的替代方案是什么**？请给出具体 API 名与版本。我们了解到的候选有：
- `display.getDefaultDisplaySync()` 系列里的尺寸 / 可用区域接口
- `display.on('foldAngleChange')`（三折叠返回两个角度）——能否由角度推算折痕？
- `window.getWindowProperties().windowRect` 配合断点（我们目前的兜底方案）

**Q4.** 三折叠「一栏占一块物理屏」的**官方推荐实现方式**是什么？
- `FoldSplitContainer`（我们查过参数表，判断它的分栏模板是**双折**语义，
  不支持三折叠三分栏，**结论是否准确**？如支持，请给出三分栏用法）
- 还是官方本就推荐「按窗口宽度断点自行分栏，不追求精确对齐折痕」？

**Q5.** 是否存在**设备级常量**可以拿到三折叠每块物理屏的宽度（类似 379/330/352）？
如果有，比运行时接口更适合我们（不需要随形态刷新）。

### 我们已经做过 / 已排除的（避免重复建议）

- ❌ 已确认 `creaseRects` 是 **Array**（SDK `sdk/default/openharmony/ets/api/@ohos.display.d.ts`
  中 `FoldCreaseRegion { readonly displayId; readonly creaseRects: Array<Rect> }`）。
  ⚠️ 注意：我们曾收到「只返回单个 Rect」的答复，与 SDK 类型定义冲突，**以 SDK 为准**。
- ❌ 已实测 `display.getFoldStatus()` 无法用于布局：左两屏(709vp) 与右两屏(683vp) **返回值都是 1**，
  无法区分，所以不能靠它判断「该分几栏」。
- ✅ 目前方案：断点只由**窗口宽度 vp** 决定（阈值 600 / 840），五态实测全部命中。
  代价是等分栏边界与真实折痕有偏差（最大约 25vp），**部分栏会横跨折痕**。
- ⚠️ 我们**不打算**硬编码某机型的物理屏宽度（换机不通用）。
  只有官方提供**通用接口**或**设备级常量**时，我们才会做精确对齐。
````

---

## 拿到答复后（给我自己看）

按结论分流：

| 答复 | 动作 |
| --- | --- |
| 有可用的通用折痕接口 | 回填 `api_notes.md` **A2**（❓→✅），v0.2 重排「按折痕动态分栏」 |
| 官方确认三折叠不支持 / 无通用方案 | 回填 **A2** 为「实测不可用 + 官方确认」，**动态分栏永久否决**，维持等分；A6 结论从「决策不做」升级为「实测+官方双重确认不可行」 |
| 提供了设备级常量 | 回填 A2，评估是否值得做「按常量比例分栏」（换机需扩展机型表） |

回填位置：

- `docs/harmonyos/api_notes.md` —— **A2**（折痕）、**A2-bis**（FoldSplitContainer）、**A6**（等分 vs 折痕决策）
- `docs/releases/v0.1/真机验证清单.md` —— D6（C 读数已实测为 `372,372` 且不随形态变）
- `docs/releases/v0.2/需求文档.md` —— 若结论变化，§3.5 视觉基线里的分栏条目要跟着改

> ⚠️ 无论结论如何，**发版前必须移除状态栏的调试读数**（`FS:` / `C:`）——
> 它们是调试期加的，不该出现在 v0.1 正式版界面上。已登记待办。
