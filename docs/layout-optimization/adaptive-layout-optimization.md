# 自适应布局优化建议

> 基于 HarmonyOS 七种自适应布局能力对项目进行审计，发现已有成果与待优化方向。
>
> 审计日期：2025 年 7 月 · 工程基础：`com.jxg.huaweiobsidian`，Stage 模型 + ArkTS

---

## 一、背景

根据 [HarmonyOS 自适应布局文档](https%3A//developer.huawei.com/consumer/cn/doc/doccenter-ux-design/design-responsive-layout-method-0000001795698449)，自适应布局由以下 **七种核心能力** 构成：

| # | 能力 | 说明 |
|---|------|------|
| 1 | **拉伸能力** | 通过 `flexGrow` / `flexShrink` 控制子组件拉伸/收缩 |
| 2 | **均分能力** | `justifyContent(FlexAlign.SpaceEvenly/SpaceAround/SpaceBetween)` |
| 3 | **占比能力** | `.layoutWeight(1)` 按权重分配剩余空间 |
| 4 | **缩放能力** | `.aspectRatio()` 保持宽高比缩放 |
| 5 | **延伸能力** | `List` 或 `Scroll` 容器实现内容超出后滚动 |
| 6 | **折行能力** | `FlexWrap.Wrap` 实现子项自动换行 |
| 7 | **隐藏能力** | `displayPriority` 按优先级自动显隐 |

---

## 二、当前使用情况总览

| 能力 | 状态 | 使用次数 | 证据位置 |
|------|------|---------|---------|
| ✅ 拉伸能力 | 未直接使用 `flexGrow`/`flexShrink` | 0 | — |
| ✅ 均分能力 | **已大量使用** | 41 | `NoteDialogs.ets` L173, `QuickSwitcher.ets` L272 等 |
| ✅ 占比能力 | **已大量使用** | 41 | `FileTreeView.ets` L488, `AgentWorkspace.ets` L589 等 |
| ✅ 缩放能力 | **偶尔使用** | 1 | `ShareImagePreviewDialog.ets` L50 |
| ✅ 延伸能力 | **已大量使用** | 13+ | `List` 3 处 + `Scroll` 10+ 处 |
| ✅ 折行能力 | **偶尔使用** | 1 | `AgentWorkspace.ets` L863 (`FlexWrap.Wrap`) |
| ❌ **隐藏能力** | **完全未使用** | **0** | 无任何 `displayPriority` 引用 |

---

## 三、待优化方向（按优先级排序）

---

### 🔴 P0 — 引入 `displayPriority` 隐藏能力

#### 问题描述

`displayPriority` 是七种自适应能力中 **唯一缺失** 的。它允许容器内子组件按优先级随容器尺寸变化**自动显示或隐藏**（相同优先级同时显隐），适合侧栏、工具栏等空间受限的场景。

#### 当前做法

项目目前手动使用 `if/else` + `.visibility()` 控制显隐：

```typescript
// VaultSidebar.ets L618 — 手动条件判断
.visibility(this.referenceOnly || this.sidebarTab === 'files'
  ? Visibility.Visible : Visibility.Hidden)



// SettingsView.ets L429 — 通过断点分支渲染不同 UI
if (this.singleScreenLayout && this.showCategoryList) {
  Scroll() { /* 分类列表 */ }
} else if (this.singleScreenLayout) {
  this.CategoryContent()
} else {
  Row() { /* 左右分栏 */ }
}
优化建议
在 侧栏列表项、工具栏、面包屑导航 中，将次要信息改用 displayPriority：




// 示例：侧栏笔记列表项
Row() {
  Text(note.title)
    .displayPriority(1)         // 始终显示
  Text(note.modifiedTime)
    .fontSize(FontSize.caption)
    .displayPriority(2)         // 窄屏自动隐藏
  Icon('more', 16, ...)
    .displayPriority(3)         // 超窄屏优先隐藏
}
适用场景
场景	文件	说明
侧栏文件列表元信息	FileTreeView.ets	文件大小、修改时间
仓库选择器下拉菜单	VaultSidebar.ets L277	仓库条目的 VaultBadge
设置页分类列表	SettingsView.ets L432	次要设置分组
固定问法横向滚动的标签	AgentWorkspace.ets L763	次要固定问法
🔴 P0 — ForEach → LazyForEach 列表性能优化
问题描述
项目中所有 8 处列表迭代均使用 ForEach，无一处使用 LazyForEach。ForEach 会一次性创建所有列表项节点，当列表项较多时（文件树、对话列表、搜索结果），首帧渲染节点数过多，影响启动性能。

当前做法



// AgentWorkspace.ets L612
ForEach(this.sessions, (session: AgentSession) => {
  ListItem() { /* ... */ }
})
优化建议
改造为 LazyForEach，配合 IDataSource 接口实现按需创建：




// 1. 实现数据源
class SessionDataSource implements IDataSource {
  private sessions: AgentSession[] = [];

  totalCount(): number { return this.sessions.length; }
  getData(index: number): AgentSession { return this.sessions[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {}
  unregisterDataChangeListener(listener: DataChangeListener): void {}
}

// 2. 使用 LazyForEach
LazyForEach(this.sessionDataSource, (session: AgentSession) => {
  ListItem() { /* ... */ }
}, (session: AgentSession) => session.id)
改造清单（共 8 处）
文件	行号	列表内容	数据量预期
FileTreeView.ets	L449	文件树节点	中-高
AgentWorkspace.ets	L612	对话会话列表	中
QuickSwitcher.ets	L306, L359	全文搜索结果	高
VaultSidebar.ets	L628	章节大纲列表	中
NoteDialogs.ets	L233, L580	目录选择列表	低-中
SettingsView.ets	L678	设置列表	低
TrashView.ets	L174	回收站列表	低-中
ChangelogList.ets	L11	更新日志列表	低
🟡 P1 — 为 List / Scroll 添加 edgeEffect 回弹效果
问题描述
所有 List 和 Scroll 组件均未设置 edgeEffect，滚动到边缘时缺少阻尼回弹效果，交互反馈不够自然。

当前做法



// FileTreeView.ets L448-L621
List() { /* ... */ }
.layoutWeight(1)
.width('100%')
.scrollBar(BarState.Auto)
// ← 缺少 .edgeEffect(EdgeEffect.Spring)
优化建议



// 改造后
List() { /* ... */ }
.layoutWeight(1)
.width('100%')
.scrollBar(BarState.Auto)
.edgeEffect(EdgeEffect.Spring)   // 回弹效果
改造清单
文件	行号	组件类型
FileTreeView.ets	L448	List
AgentWorkspace.ets	L611	List
AgentWorkspace.ets	L732	Scroll（纵向消息区）
AgentWorkspace.ets	L761	Scroll（横向固定问法）
QuickSwitcher.ets	L305, L359	List
Index.ets	L4301	Scroll（格式菜单）
SettingsView.ets	L430, L449, L512	Scroll（设置页）
SyncPage.ets	L264	Scroll
NoteDialogs.ets	L230, L577	Scroll
TrashView.ets	L172	Scroll
VaultManagerView.ets	L48	Scroll
ReleaseHistoryView.ets	L9	Scroll
ShareImagePreviewDialog.ets	L40	Scroll
🟡 P1 — 固定高度区域改为自适应
问题描述
NoteDialogs.ets 中的目录选择器使用了固定高度，当目录项较少时会留白，不能自适应内容。

当前做法



// NoteDialogs.ets L230-L243
Scroll() {
  Column({ space: 2 }) {
    this.DirItem('', '根目录')
    ForEach(this.dirs, (d: string) => { this.DirItem(d, d) })
  }
}
.width('100%')
.height(160)   // ← 固定高度，内容少时留白
优化建议



// 可选方案一：使用 maxHeight 让内容撑开但不超过上限
Scroll() {
  Column({ space: 2 }) {
    this.DirItem('', '根目录')
    ForEach(this.dirs, (d: string) => { this.DirItem(d, d) })
  }
}
.width('100%')
.maxHeight(160)   // ← 内容少时自适应，多时最多到 160
.constraintSize({ maxHeight: 160 })

// 可选方案二：使用 layoutWeight 占满容器剩余空间
Scroll() { /* ... */ }
.layoutWeight(1)
.width('100%')
改造清单
文件	行号	当前值	建议
NoteDialogs.ets	L239	.height(160)	maxHeight(160)
NoteDialogs.ets	L586	.height(160)	maxHeight(160)
🟢 P2 — 考虑使用 RelativeContainer 扁平化布局层级
问题描述
当前所有页面使用 Column/Row 线性布局嵌套，未使用 RelativeContainer。根据 布局优化指导，使用相对布局可将 4 层嵌套减少到 2 层，减少 ~5 个节点。

适合改造的场景（嵌套深度 ≥ 4 层）
场景	文件	当前嵌套深度
格式菜单面板	Index.ets L4301	Scroll → Column → Column → GridRow → GridCol
设置页分类内容区	SettingsView.ets L448	Row → Scroll → Column → CategoryRow
仓库管理视图	VaultManagerView.ets	Column → Column → Scroll → Column → Row
优化示例



// 当前（线性嵌套 4 层）
Column() {
  Column() {
    GridRow() {
      GridCol() { /* 格式选项 */ }
    }
  }
}

// 建议（相对布局 2 层）
RelativeContainer() {
  GridRow() { /* 格式选项 */ }
    .alignRules({ top: { anchor: '__container__', align: VerticalAlign.Top },
                  left: { anchor: '__container__', align: HorizontalAlign.Start } })
}
🟢 P2 — 稳定区域改用固定宽高减少重新 Measure
问题描述
项目中大量使用 .width('100%').height('100%')（41 处），包括一些内容不会动态变化的区域。根据布局优化指导：

设置固定宽高的组件，在外层容器尺寸变化时不会触发重新 Measure，性能显著优于百分比宽高。

适合改为固定宽高的场景
场景	文件	说明
工具栏/标题栏	AgentWorkspace.ets L584 (SessionPanel 头部)	固定高度 Size.paneHeadH
操作按钮行	NoteDialogs.ets L267 (取消/创建按钮行)	固定高度 30 但宽度可自适应
设置页信息行	SettingsView.ets L408 (InfoRow)	固定高度标签-值行
四、补充建议
4.1 统一 ScrollBar 策略
当前 scrollBar 设置不一致（BarState.Auto、BarState.Off 混用），建议：

场景	建议值	说明
内容区列表（文件树、对话）	BarState.Auto	滚动时显示，静止后消失
设置页、静态内容	BarState.Off	内容有限，无需滚动条
横向标签栏	BarState.Off	横向内容用户通过拨动感知
4.2 考虑引入 Visibility + 过渡动画
当前显隐切换（Visibility.Hidden/Visible）是瞬间切换，缺乏动画过渡。建议：




.visibility(this.show ? Visibility.Visible : Visibility.None)
.transition(TransitionEffect.opacity(0.3))  // 淡入淡出
4.3 监控断点与自适应策略对齐
项目已实现自定义三档断点（Breakpoint.ets：sm/md/lg），并且通过 PaneLayout.ets 计算导航栏宽度。建议在 Index.ets 的主布局中，确保隐藏能力（displayPriority）与断点联动——例如 lg 档显示全部信息，sm 档隐藏低优先级内容。

五、总结



P0（高优先，影响大）
├── 🔴 引入 displayPriority 隐藏能力（填补七种能力空白）
└── 🔴 ForEach → LazyForEach 改造（8 处列表性能提升）

P1（中优先，体验改善）
├── 🟡 添加 edgeEffect 回弹（13+ 处组件）
└── 🟡 固定高度改为自适应（2 处 Scroll）

P2（低优先，长远收益）
├── 🟢 RelativeContainer 扁平化（减少嵌套深度）
└── 🟢 稳定区域固定宽高（减少重新 Measure）
建议优先从 P0 开始，尤其是 LazyForEach 改造，对列表性能提升最为显著。
