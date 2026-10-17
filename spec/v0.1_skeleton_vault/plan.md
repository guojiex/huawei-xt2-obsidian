# Implementation Plan: v0.1 三形态骨架与多库（M0 + M0.2）

**Input**: Feature specification from `spec/v0.1_skeleton_vault/spec.md`

## Summary

在现有「曜石笔记」工程上实现 v0.1：三档断点系统（windowSizeChange + px2vp）、自绘三栏骨架（sm 单栏+抽屉 / md 各 50% / lg 各 1/3，侧栏可收起）、多库模型（默认库 `vaults/local` + 注册表 preferences 持久化 + 库 CRUD/切换/名字消毒）、唯一路径解析器、折痕与 FoldStatus 只标注打印。技术路线全部沿用已定决策（自绘、不用 FoldSplitContainer、不用 getFoldDisplayMode 分支、API ≤ 24）。

## Technical Context

**Language/Version**: ArkTS · Stage 模型 · API 24（`compatibleSdkVersion 6.1.1(24)`），DevEco 26.0.0.851
**Primary Dependencies**: 无新增第三方依赖；只用 `@kit.ArkUI`（window/display）、`@kit.ArkData`（preferences）、`@kit.CoreFileKit`（fileIo）、`@kit.AbilityKit`、`@kit.PerformanceAnalysisKit`（hilog）
**State Management**: 沿用项目现有 **State Management V1**（`@Entry/@Component` + `@State` + `AppStorage` + `@StorageProp`）——增量开发不迁移 V2；断点与窗口宽度走 `AppStorage`（设计文档 §2.1 既有方案）
**Storage**: 库注册表 → **preferences**（`mvp_design.md` §4.1/§4.5「MVP 存 preferences」），JSON 字符串一个 key；库本体 → 沙箱 `filesDir/vaults/<库名>/` 目录；本版本不写笔记文件，**无需 AtomicFile**（注册表由 preferences 自身落盘）
**Testing**: 无自动化测试框架；验收 = `tools\build.ps1` BUILD SUCCESSFUL + 真机三形态手测清单（需求文档 §2/§6）
**Target Platform**: 华为 XT2 三折叠（系统识别恒为 `phone`）；`deviceTypes` 保持 `["phone","tablet","2in1"]` 不动
**Project Type**: 既有 HarmonyOS App（HAP）增量开发
**Performance Goals**: 无特殊性能指标（无文件树/编辑器）；断点切换即时重排无闪烁
**Constraints**: 只用 API ≤ 24；`api_notes.md` 标 ⚠️/❓ 的结论不进关键路径；不动 `web/gitbridge/`、`entry/src/main/ets/git/`、`pages/SyncPage.ets`；不新增权限；路径只由 `context.filesDir` 等 Context 属性拼出
**Scale/Scope**: 6 个新 ArkTS 文件 + 2 个改造文件；单页面应用（无路由新增）

## Project Structure

### Documentation (this feature)

```text
spec/v0.1_skeleton_vault/
├── spec.md              # 需求规格（已批准）
├── plan.md              # 本文件
└── tasks.md             # 任务清单（Phase 3 产出）
```

### Source Code (repository root)

```text
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets        # [改造] 断点监听注册、初始断点计算、Context 保存、折痕/FoldStatus 日志点
├── pages/
│   └── Index.ets               # [重写] 三形态总装：appbar / 侧栏抽屉与收起 / 占位栏 / 红色折痕警示 / 状态栏
├── components/                 # [新增目录]
│   ├── VaultSidebar.ets        # 侧栏：库切换器下拉、占位树区、「收起 «」按钮、「管理库」入口
│   ├── VaultManagerView.ets    # 库管理视图：库卡片（改名/删除/设为当前）+ 新建本地库入口
│   └── VaultDialogs.ets        # 三个 CustomDialog：新建库（含消毒预览）、改名、删除确认（不可逆文案）
├── model/                      # [新增目录]
│   ├── Breakpoint.ets          # 断点枚举 sm/md/lg + 阈值常量（600/840vp）+ vp→档位判定函数
│   ├── Vault.ets               # VaultEntry 模型 + 库名消毒规则（过滤→去前导点→去空白→空拒绝→重名-2）
│   ├── VaultRegistry.ets       # 库注册表：CRUD + 当前库 id + 首启建 local + preferences 持久化
│   └── VaultPathResolver.ets   # 唯一路径解析器：vaultId+相对路径 → 沙箱绝对路径（UI 与将来意图执行器共用）
└── (git/、pages/SyncPage.ets 不动 —— v0.3 同步代码)
```

**Structure Decision**: 遵循**既有项目架构**做增量开发，不引入 MVVM 迁移。现有工程只有 `entryability/` + `pages/` + `git/`（扁平结构），本特性按用户提示词约定新增 `model/`（数据模型与注册表）与 `components/`（侧栏/管理视图/对话框）两个目录，共 6 新文件 + 2 改造文件，与「Light」层级相当：单页面、少量可复用 UI 块、简单本地状态，不足以触发 MVVM（无多页面导航、无复杂表单、无独立 viewmodel 编排需求）。断点与当前库为跨组件共享状态，走 `AppStorage`/注册表，不引状态库。

## Complexity Tracking

无（不违反任何 Constitution 检查项；未新增项目/仓库/依赖）。

## Research & Decisions

### R1 三栏实现：自绘 Row/Stack 分支，禁用官方分栏组件

- **Decision**: 按 `bp` 分支自绘——sm 用 `Stack`（主内容 + 抽屉侧栏覆盖层），md/lg 用 `Row` 等分布局；侧栏收起改变 Row 内宽度配比。
- **Rationale**: `FoldSplitContainer` 已否决（`api_notes.md` A2-bis：三分栏非三列横排、比例只有 1V1/3V2/2V3 预设、面向双折叠悬停态）；「一栏=一整块物理屏，栏边界压折痕」只有等分自绘能保证。
- **Alternatives considered**: `FoldSplitContainer`（否决，理由如上）；`SideBarContainer`（其 Embed/Overlay 模式与「栏宽=物理屏」规则冲突，且收起逻辑被组件接管，无法实现 md 收起→预览补位）。

### R2 断点机制：windowSizeChange + px2vp，初始值单独补算

- **Decision**: `EntryAbility.onWindowStageCreate` 里 `windowStage.getMainWindowSync()` → `win.on('windowSizeChange')` 回调中 `px2vp(size.width)` 判档写 `AppStorage`；**加载时用 `getWindowProperties().windowRect.width` 补算一次初始断点**（windowSizeChange 只在变化时触发）。
- **Rationale**: `api_notes.md` A3 ✅——这就是官方推荐做法；禁止 `getFoldDisplayMode()` 分支（不返回全部形态值）。
- **Alternatives considered**: `getFoldDisplayMode()`（官方明确不推荐）；`display.on('foldStatusChange')` 做布局分支（三屏态返回值未知 ❓，只能做日志）。

### R3 库注册表持久化：preferences 单 key JSON

- **Decision**: preferences（`@kit.ArkData`）存一个 JSON 字符串 key（vault 列表 + 当前库 id），读写经 `VaultRegistry` 单例收口。
- **Rationale**: `mvp_design.md` §4.5「MVP 存 preferences，app.db 建表是 v2 的事」；JSON 序列化结构可随版本演进；preferences 自带落盘，本版本无需自写文件（也就无需 AtomicFile）。
- **Alternatives considered**: 独立 JSON 文件 + AtomicFile（本版本无文件写入需求，多余）；RDB（v2 的事）。

### R4 形态切换状态保持：当前库进注册表持久层，UI 瞬态进组件 @State

- **Decision**: 当前库 id 由 `VaultRegistry` 持久化（杀进程也恢复）；断点/窗口宽度进 `AppStorage`；侧栏收起态、库管理视图开关等 UI 瞬态留在 `@State`（UIAbility 折叠切换不重建，`api_notes.md` A4 ✅，@State 自然存活）。
- **Rationale**: 「状态不丢」分两级——跨进程的必须落盘（当前库），进程内的组件状态天然保留；不引入额外全局状态。
- **Alternatives considered**: 全部塞 AppStorage（收起态等瞬态无持久价值，增加耦合）。

### R5 删除/改名目录的 fs 操作

- **Decision**: 删库用 `fileIo.rmdirSync`（整目录递归删除）、改名用 `fileIo.renameSync`（目标名经消毒+重名-2 保证不存在）；实施前在 DevEco 补全/官方文档确认两接口在 API 24 的签名与递归语义，确认不了就换 `listFileSync` 手写递归删除并注记。
- **Rationale**: AGENTS 硬约束 1（禁凭记忆编 API）；`rmdirSync` 对非空目录的递归行为必须核实后才可落码。
- **Alternatives considered**: 手写递归删除（若 rmdirSync 语义确认则不需要）。

### R6 折痕与 FoldStatus：只标注不参与计算

- **Decision**: hilog 打印 `display.getCurrentFoldCreaseRegion()` 返回值与 `display.getFoldStatus()` 返回值（断点变化时触发 + `display.on('foldStatusChange')` 订阅），日志带 `TODO(真机校准)` 标记；布局纯等分。唯一视觉标注：**lg 收起态**在编辑区 1/3 处渲染红色虚线折痕标记 + 「被内容横跨」提示（原型明确要求）。
- **Rationale**: `api_notes.md` A2（折痕接口只返回单个 Rect，三折叠行为 ❓，不许进布局算式）；A1（三屏态 FoldStatus ❓，不许硬编码映射）。
- **Alternatives considered**: 全形态渲染折痕虚线（原型说明「折痕标注不是 UI」，仅收起态标红是需求）。

### R7 库名消毒与重名处理收口在 model 层

- **Decision**: 消毒规则实现为 `Vault.ets` 中纯函数（过滤 `/ \ : * ? " < > |` 与控制字符 → 去前导点 → trim → 空拒绝），重名加 `-2`/`-3` 由 `VaultRegistry` 基于现有列表判定；新建/改名对话框内实时预览消毒结果与目标路径（原型行为）。
- **Rationale**: 规格要求新建与改名同一套规则；纯函数便于将来意图执行器复用。
- **Alternatives considered**: 在对话框组件里各自实现（两处逻辑会漂移）。

## Data Model

### VaultEntry（库条目）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| id | string | = 目录名 = 显示名（不分离，`mvp_design.md` §4.5.1） |
| type | string | `'local'`（v0.1 仅此一种；`'git'` 为 v0.3 预留） |
| createdAt | number | 创建时间戳 |

### VaultRegistryState（注册表持久化结构，JSON 存 preferences）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| vaults | VaultEntry[] | 库列表（顺序稳定，local 首位） |
| currentVaultId | string | 当前库 id；被删后回落列表第一个 |

- preferences 实例名与 key 常量定义在 `VaultRegistry.ets`（单一真源）。
- 校验规则：currentVaultId 必须存在于 vaults（加载时校验，失配回落第一个）；vaults 为空理论不可达（local 可删但注册表兜底回落仍需处理空列表 → 界面显示空态并引导新建）。

### Breakpoint（断点）

| 值 | 判定（窗口宽度 vp） | 布局 |
| --- | --- | --- |
| sm | < 600 | 单栏 + 抽屉侧栏 |
| md | [600, 840) | 侧栏 + 编辑各 50%；收起后编辑/预览各 50% |
| lg | ≥ 840 | 三栏各 1/3；收起后编辑 2/3（跨第一条折痕，标红）+ 预览 1/3 |

- 阈值 600/840 为常量，出自 `mvp_design.md` §2。
- AppStorage key：`breakpoint`（string）、`windowWidthVp`（number，状态栏显示用）。

### 名称消毒规则（新建/改名共用，纯函数）

1. 过滤 `/ \ : * ? " < > |` 与控制字符（charCode < 0x20）
2. 去前导点（防 `..` 逃逸 `vaults/`）
3. 去首尾空白
4. 结果为空 → 拒绝（UI 实时提示，不等保存）
5. 重名 → 加 `-2`；仍重 → `-3`，依此类推

### 状态存放位置一览

| 状态 | 存放 | 跨进程 | 跨形态切换 |
| --- | --- | --- | --- |
| 断点 / 窗口宽度 | AppStorage | 否 | 是（事件驱动更新） |
| 当前库 id | VaultRegistry → preferences | 是 | 是 |
| 库列表 | VaultRegistry → preferences | 是 | 是 |
| 侧栏收起态、管理视图开关 | 组件 @State | 否 | 是（UIAbility 不重建） |
| 当前选中项（本版本=当前库） | 注册表 currentVaultId | 是 | 是 |

## Contracts & Interfaces

### 模块职责与公开接口（内部契约）

**model/Breakpoint.ets**
- 断点字符串常量 `'sm' | 'md' | 'lg'` 与阈值常量（600/840）
- `breakpointFromWidthVp(widthVp: number): string`——半开区间判定（sm<600，md∈[600,840)，lg≥840）

**model/Vault.ets**
- `VaultEntry` 接口定义
- `sanitizeVaultName(raw: string): string`——消毒规则（空结果返回空串，由调用方拒绝）

**model/VaultPathResolver.ets**（唯一路径解析层，AGENTS 硬约束 14）
- 构造注入 `UIAbilityContext`
- `vaultDir(vaultId: string): string`——`filesDir/vaults/<id>` 绝对路径（**全工程唯一**允许拼此路径处）
- `resolve(vaultId: string, relativePath: string): string`——库内相对路径→绝对路径；拒绝 `..` 片段与绝对路径入参
- 调用方：VaultRegistry 全部 fs 操作；v0.2 文件树 UI、v0.3+ 意图执行器将来共用，不得旁路

**model/VaultRegistry.ets**
- 构造注入 context + VaultPathResolver；单例使用
- `init(): void`——加载/创建注册表；首启（无注册表）自动建 `vaults/local` 并设为当前库
- `list(): VaultEntry[]` / `currentId(): string` / `setCurrent(id): void`
- `createLocal(name: string): VaultEntry`——消毒+重名处理+mkdir+入表+持久化
- `rename(id: string, newName: string): VaultEntry`——改目录名+更新注册表（失败回滚，不允许半状态）
- `remove(id: string): void`——rmdir+出表+当前库回落，持久化
- 所有变更后同步 preferences

**entryability/EntryAbility.ets**（改造）
- `onWindowStageCreate`：loadContent 前注册 `windowSizeChange` 监听 + 补算初始断点；订阅 `display.on('foldStatusChange')`；每次断点变化 hilog 打印折痕 Rect、FoldStatus、窗口 vp 宽（带 `TODO(真机校准)` 标记）

**pages/Index.ets**（重写）
- 组装：appbar（汉堡=sm 抽屉开关 / md+lg 收起唤回；标题=当前库名；「库管理」入口）、内容区（按 bp 分支布局矩阵）、状态栏（当前档位 + vp 宽度 + 当前库）
- 布局矩阵：
  - sm：`Stack{ 单栏内容, 抽屉侧栏(条件渲染+平移动画) }`
  - md 未收起：`Row{ 侧栏 50%, 编辑占位栏 50% }`；收起：`Row{ 编辑 50%, 预览 50% }`
  - lg 未收起：`Row{ 侧栏 1/3, 编辑 1/3, 预览 1/3 }`；收起：`Row{ 编辑 2/3(内嵌红色折痕警示线@1/3处), 预览 1/3 }`
- 库管理视图以内容区整体替换形态呈现（原型 vaultsView 结构）

**components/VaultSidebar.ets**
- 库切换器（下拉菜单列库，当前项高亮，点选即切库）、占位树区（「文件树 · v0.2」占位）、「收起 «」按钮（回调父级）、「管理库」按钮

**components/VaultManagerView.ets**
- 库卡片列表（当前库高亮；每卡：改名 / 删除 / 设为当前）、「+ 新建本地库」入口；**不出现** Git 导入入口与「导出备份」文案

**components/VaultDialogs.ets**
- 新建对话框：TextInput + 消毒实时预览（目标路径）+ 确认/取消；空名禁用确认
- 改名对话框：同上，预填现名
- 删除确认对话框：标题「删除本地笔记？」+「不可逆/无法恢复」明示 + 目标路径展示 + 确认/取消；**不含**「建议先导出备份」

### 布局验收契约（真机手测矩阵）

| 形态 | 侧栏 | 期望布局 | 折痕标注 |
| --- | --- | --- | --- |
| sm | 抽屉 | 单栏 | 无 |
| md | 显示 | 侧栏50% + 编辑50% | 无 |
| md | 收起 | 编辑50% + 预览50% | 无（不跨折痕） |
| lg | 显示 | 各1/3 三栏 | 无 |
| lg | 收起 | 编辑2/3 + 预览1/3 | 编辑区1/3处红色虚线+「被内容横跨」 |

### API 使用清单（全部需 DevEco 补全/文档二次确认，铁律 1）

| API | 来源依据 | 用途 |
| --- | --- | --- |
| `window.Window.on('windowSizeChange')` / `getWindowProperties().windowRect` | `api_notes.md` A3 ✅ | 断点 |
| `display.getFoldStatus()` / `on('foldStatusChange')` / `getCurrentFoldCreaseRegion()` | `api_notes.md` A1/A2 ✅（三折叠具体值 ❓） | 仅日志标注 |
| `px2vp()` | `api_notes.md` A3 ✅ | 换算 |
| `fileIo.mkdirSync` / `renameSync` / `rmdirSync` / `accessSync` / `listFileSync` | `api_notes.md` C2 ✅（rmdirSync 递归语义需确认） | 库目录操作 |
| `preferences.getPreferences/getPreferencesSync` + `getSync/putSync/flush` | `@kit.ArkData`，需补全确认 | 注册表 |
| `hilog` | 既有代码在用 | 日志 |
| `CustomDialogController` / `@CustomDialog` | ArkUI 标准能力 | 对话框 |

> 任一 API 在 DevEco 补全中找不到或签名不符 → 列入「需要确认的 API」报告，禁止猜测实现。
