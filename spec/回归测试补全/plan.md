# Implementation Plan: 回归测试补全（Bug 驱动）

**Input**: Feature specification from `spec/回归测试补全/spec.md`

## Summary

以 bug 驱动为主线，为曜石笔记已实现需求补全回归测试防线：盘点全部 143 个历史 fix 提交与 api_notes 实测踩坑，产出《bug
回归清单》并逐条核对/补齐防回归测试（Node 单测、hypium UI 用例、源码级断言三层）；按 EM 用例组扩展 UI 自动化可达子集；过程中发现的
bug 直接修复并带防回归测试；收尾在 x86_64 模拟器统一执行一轮全量 UI 终验。

## Technical Context

**Language/Version**: ArkTS（API 24，`compatibleSdkVersion 6.1.1(24)`）+ Node 20（测试 harness）+ PowerShell 5.1（工具脚本）
**Primary Dependencies**: hypium + `@ohos.UiTest`（UI 仪器化）、esbuild + node:vm（自研 Node 测试 runner）、hvigor（构建）、libgit2
native（`.build/` 已编双 ABI）
**State Management**: 存量项目混合 V1/V2，本工作不新增产品状态管理；新增 UI 用例只依赖控件树断言，不侵入状态层
**Storage**: 不新增持久化；测试数据遵循 `uitest` 前缀 + 时间戳唯一名约定
**Testing**: 三层防线——`tools/tests/test_*.mjs`（Node 源码断言/逻辑测试，135 个存量）、
`entry/src/ohosTest/ets/test/ui/Ui*.test.ets`（hypium，17 用例存量）、`docs/testing/模拟器回归用例.md`（人工 EM，兜底不可自动化项）
**Target Platform**: Windows x86_64 宿主 + x86_64 API26 模拟器（终验）；API24/XT2 真机验收仍归用户，不在本工作范围
**Project Type**: 存量 HarmonyOS Stage 模型应用的 QA 资产增强
**Performance Goals**: 不适用（无运行时性能目标）；全仓 Node 测试一键回归、UI 终验一轮 ≤ 40 分钟（aa test 现有超时上限）
**Constraints**: UI 自动化边界（不做 Web 文本注入/拖拽/折叠形态/像素断言/崩溃注入）；隐私红线（笔记内容不进日志与埋点）；5
项既有基线失败保持原状不修
**Scale/Scope**: 143 个 fix 提交盘点 + 约 10～20 个新 UI 用例 + 缺口对应的 Node 测试（数量以盘点结果为准）

## Project Structure

### Documentation (this feature)

```text
spec/回归测试补全/
├── spec.md               # 需求（已批准）
├── plan.md               # 本文件
└── tasks.md              # 任务清单（Phase 3 产出）
```

### Source Code (repository root)

```text
docs/testing/
├── bug回归清单.md          # ★ 新增：《bug 回归清单》长期 QA 资产（US1 核心交付物）
├── UI自动化测试.md         # 修改：映射表补新用例行、套件白名单说明
├── 模拟器回归用例.md       # 视需要补 EM 用例（无对应 EM 的新 UI 用例先补此文件）
└── README.md              # 不改（环境与记录规则不变）

tools/tests/
├── test_<域>_<主题>.mjs    # ★ 新增：按盘点缺口补的 Node 防回归测试（命名沿用现有约定）
└── lib/source.mjs         # 不改（CRLF 归一等既有能力复用）

tools/
└── uitest.ps1             # 修改：$knownSuites 白名单加新套件名

entry/src/ohosTest/ets/test/
├── List.test.ets          # 修改：注册新 UI 套件
├── ui/UiTestHelpers.ets   # 修改/扩展：新用例共用的等待、查找、断言辅助（clickUntilTextAppear、findTreeRow、SNACK_MS 等既有能力复用）
├── ui/UiLaunch.test.ets        # 存量三套件维持，必要时增补用例
├── ui/UiNoteFlow.test.ets
├── ui/UiPanels.test.ets
└── ui/Ui<域>.test.ets     # ★ 新增：按域扩展（候选：UiQuickSwitch / UiTrash / UiSettingsExt / UiShareImport，以盘点与 EM 可达性定稿）

entry/src/main/ets/…        # 仅两类改动：为可测性补 .id() 锚点；修复过程中发现的 bug（fix + 防回归）
```

**Structure Decision**: 完全遵循现有项目架构，不选新结构层级、不做 MVVM 迁移。测试资产挂接现有三处 harness（Node runner、
`uitest.ps1`、`List.test.ets`），不新建测试框架。产品源码改动仅限「可测性 id 锚点」与「bug 修复」两类，均为最小增量。

## Complexity Tracking

| Violation                       | Why Needed                                                                            | Simpler Alternative Rejected Because                                   |
|---------------------------------|---------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| 产品源码出现本工作引发的改动（原则上 QA 资产不碰产品码）  | ① 新 UI 用例需要控件 `.id()` 锚点（既有先例：`vault-sidebar-search` 等为主工程补 id）；② 过程发现的 bug 按 US2 直接修 | 只写测试不改源码：① 无锚点则 UI 用例退化为脆弱的坐标/文案匹配；② 发现缺陷不修违背本工作目的                     |
| 新增 `docs/testing/bug回归清单.md` 文档 | 清单是 US1 的核心交付物与长期防回归资产，须在 git 内长期维护、跨会话引用                                             | 放 `spec/`（用户已确认 spec 目录可保留或清理，不适合放长期资产）；放需求文档 §6（版本冻结后不可追加，QA 资产需持续更新） |

## Research & Decisions

### R1: bug 清单的盘点方法与产物位置

- **Decision**: 用 `git log --grep` 全量提取 143 个 fix 提交（`git log --oneline --grep="^fix" -i`），叠加
  `docs/harmonyos/api_notes.md` 的 ⚠️ 实测坑条目（L/Z/I 组实测结论中属于应用缺陷的部分；纯环境限制如 L-8 不算应用
  bug，登记为「不可自动化·环境」参考行）。逐条映射到现有测试资产（`tools/tests/` 文件名与用例注释、`UI自动化测试.md` 映射表、EM
  用例关联列）。产物为 `docs/testing/bug回归清单.md`。
- **Rationale**: git 提交史是已修复 bug 的完备真源；api_notes 实测坑含未走 fix 提交的缺陷。清单放 `docs/testing/` 与既有
  QA 资产同目录、同豁免规则，可长期维护。
- **Alternatives considered**: 按版本需求文档逐版人工回忆（不可靠、有遗漏）；清单放 spec/（非长期资产位置）。

### R2: 防线三层的判定规则（哪个缺口补哪层测试）

- **Decision**: 按根因层判定——① 逻辑/数据/服务层缺陷（状态机、文件 IO、原子性、恢复路径、搜索合并等）→ Node 单测（
  `tools/tests/`，能直接断言源码行为/结构的优先）；② UI 行为缺陷（弹窗开合、按钮禁用、菜单宽度、焦点归还、控件树存在性）→ hypium
  UI 用例；③ 视觉 token 缺陷（颜色/间距/定宽数值）→ Node 源码断言测试（既有 `test_*_design.mjs` 模式），像素验收仍归人工；④
  环境相关/真机专属（签名链、x86 限制、系统手势）→ 标注「不可自动化 + EM 人工用例编号或用户真机项」。
- **Rationale**: 与既有 135 个 Node 测试和 17 个 UI 用例的实际分层一致；源码断言可在无模拟器条件下验证（符合「先写、少依赖模拟器」的用户要求）。
- **Alternatives considered**: 全部下沉 UI 用例（模拟器耗时且 x86 可达性受限）；全部源码断言（测不到真实控件行为）。

### R3: UI 用例扩展的分组与 fixture 约束

- **Decision**: 按域新增套件，候选域与 EM 对应——快切/搜索（EM-E1～E4 可达部分，`UiQuickSwitch`）、回收站恢复（EM-B4，`UiTrash`
  或并入 UiNoteFlow）、设置诊断/更新日志/备份导出（EM-F2/F5/F4 可达部分，`UiSettingsExt`）、分享/导入弹窗（EM-J2 面板层/EM-M1
  弹窗视觉可达部分）。每域先评估 fixture 成本：依赖本地 Git 库的 EM-K2/K4 需要在模拟器构造 Git 库
  fixture，成本高，本轮标记为「评估后决定」，不承诺。定稿域名后同步改三处：`List.test.ets` 注册、`uitest.ps1` `$knownSuites`、
  `UI自动化测试.md` 映射表。
- **Rationale**: 既有三套件即按域组织；`$knownSuites` 是硬编码白名单，漏改会导致 `-Suite` 无法选中新套件（harness 源码核实）。
- **Alternatives considered**: 全部塞进存量三套件（单文件膨胀、域不清晰）；建一个大而全新套件（失败定位粒度差）。

### R4: 验证深度与模拟器使用时机

- **Decision**: 写用例阶段用「无模拟器验证」——Node 测试直接跑、ArkTS 改动跑 `arkts_check` + hvigor
  `assembleHap --mode module -p module=entry@ohosTest` 构建验证、UI 用例逻辑用源码断言预检（如选择器 id 存在性由 Node
  测试保证）。全部用例写完后统一一轮模拟器终验（`uitest.ps1` 全量 + 证据落 `.local/uitest/`）。
- **Rationale**: 用户明确「先写、尽量不需要模拟器、写完全部再用模拟器测试」；单套件模拟器轮 10～20 分钟，逐用例跑不经济。
- **Alternatives considered**: 每批新用例即跑模拟器（被用户否决）；完全不跑模拟器（无法证明用例真实可用，违背 17/17
  先例的可信度标准）。

### R5: 过程 bug 修复的提交与回归约束

- **Decision**: 发现即修，沿用仓库 `fix(<域>): <描述>` 提交惯例；每个修复附带防回归测试（修复前失败、修复后通过）；修复不新建版本目录（纯
  bug 修复 + QA 资产豁免）；修复涉及产品行为的，在提交信息与清单中注明对应需求条款或「既有实现缺陷」。
- **Rationale**: US2 已确认；仓库历史 fix 提交均有此惯例。
- **Alternatives considered**: 攒批统一修（回归定位困难）；只记录不修（被用户否决）。

### R6: Node 测试基线的 5 项既有失败

- **Decision**: 保持原状（原型 v2 旧断言 4 项 + 硬编码 Windows SDK 路径 1
  项），本轮新测试不触碰、不修复、不重跑期待通过；全仓跑分时以「新增失败 = 0」为判据。
- **Rationale**: spec 假设节已明确不在范围；避免 QA 工作扩散为原型修缮。
- **Alternatives considered**: 顺手修复（scope creep，且原型断言属设计真源决策，不宜顺手改）。

## Data Model

### bug 回归清单条目（`docs/testing/bug回归清单.md`，Markdown 表格）

| 字段     | 说明                                                                                   |
|--------|--------------------------------------------------------------------------------------|
| 来源     | fix 提交短 hash（如 `1e4e389`）或 `api_notes` 条目号（如 `Z2`）                                   |
| bug 摘要 | 一句话：现象 + 根因（如「弹窗按钮 enabled 固化，创建永远禁用——@Builder 全局多参按值传递」）                            |
| 根因类别   | 枚举：状态管理 / ArkUI 布局与弹层 / 文件 IO 与原子性 / 焦点与键盘 / 日志与隐私 / Git 与桥接 / 构建链与签名 / Web 编辑器 / 其他 |
| 涉及版本   | v1.32 等（无版本号的填「—」）                                                                   |
| 防线     | 测试归属：`test_xxx.mjs` / `UiXxx#case` / EM 人工编号，可多项                                     |
| 状态     | 枚举：已有防线 / 已补防线 / 不可自动化（注明原因与人工依赖） / 根因已消除                                            |

清单头部维护汇总（总数、各状态计数），尾部维护「本轮新修复」小节（US2 产出的新 fix 登记）。

### UI 用例映射行（`docs/testing/UI自动化测试.md` 既有表结构扩展）

套件 | 用例 | 覆盖要点 | EM 对应——新行填空即可，不新增列。

### 防回归测试实体

- **Node 测试**: `tools/tests/test_<域>_<主题>.mjs`，自研 runner（`import` 源码切片断言或纯逻辑测试），用例计数惯例 `N/N`
  输出、非零退出码表失败。
- **UI 用例**: `Ui<域>.test.ets` 内 `it('<snake_case_name>', ...)`；选择器优先 `.id()`，动态文案 CONTAINS；等待
  `waitForComponent` 30s / 撤销条 5s（`SNACK_MS`）既有约定。

## Contracts & Interfaces

### harness 接线契约（三处必须同步，漏一处即断链）

1. `List.test.ets`: `import + testsuite()` 内调用新套件导出函数（默认导出 `function testsuite()` 模式）。
2. `tools/uitest.ps1`: `$knownSuites` 数组追加新套件名（`-Suite` 参数校验依赖此白名单）。
3. `docs/testing/UI自动化测试.md`: 映射表新增行（含 EM 对应；无对应 EM 用例的先补 `模拟器回归用例.md`）。

### UiTestHelpers 复用契约

新增 UI 用例复用既有辅助（不重复造轮子）：`clickUntilTextAppear`（冷启动首击被吞的重试点击）、`findTreeRow`（LazyForEach
折叠线滚动查找）、`uniqueUiName`（`uitest` 前缀 + 时间戳）、短超时常量（`SNACK_MS`）。新辅助函数如需新增，一律进
`UiTestHelpers.ets` 并在本文件登记。

### 主工程可测性锚点契约

仅允许为控件补 `.id()`（kebab-case，如 `trash-restore-button`），不改变布局、样式与行为；id 命名沿用主工程现有风格（
`vault-sidebar-*`、`note-create-input` 先例）。

### Node 测试运行契约

全仓跑法沿用现状（各 `test_*.mjs` 独立可执行，`node tools/tests/test_xxx.mjs` 输出 `N/N`）；新测试不依赖模拟器、网络与个人数据；CRLF
经 `lib/source.mjs` 归一。

## Changelog

- 2026-11-08 初版：依据 spec.md 生成；R3 中 EM-K2/K4（Git 界面域）标记为 fixture 成本评估项，未承诺实现。
