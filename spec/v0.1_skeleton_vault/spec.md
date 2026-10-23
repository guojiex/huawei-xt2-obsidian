# Feature Specification: v0.1 三形态骨架与多库（M0 + M0.2）

**Created**: 2026-10-17
**Status**: Approved
**Input**: 用户提示词 + `docs/releases/v0.1/需求文档.md`（唯一需求来源）

## Overview

「曜石笔记」第一个可安装版本（v0.1），交付三件事：**形态骨架正确、库模型成立、状态不丢**。本版本还不能写笔记——没有文件树、编辑器、预览。它是后续所有版本的地基：v0.2 往骨架里填编辑能力，v0.3 往库上接 Git。

## User Scenarios & Testing

### User Story 1 - 三档断点与三栏骨架自绘 (Priority: P1)

用户在 XT2 上折叠/展开设备，应用布局按窗口宽度断点正确切换：单屏（sm < 600vp）单栏+抽屉式侧栏；双屏（md 600–840vp）两栏各 50%；三屏展开（lg ≥ 840vp）三栏各 1/3。断点必须用 `window.on('windowSizeChange')` + `px2vp()` 计算，禁止用 `getFoldDisplayMode()` 做形态分支。三栏必须自绘，禁用 `FoldSplitContainer`（已否决，理由见 `api_notes.md` A2-bis）。折痕只做标注（打印 `getCurrentFoldCreaseRegion()` 返回值供将来校准），不参与布局算式。

**Why this priority**: 三折叠是本应用与普通手机 App 的核心差异；断点系统是所有后续 UI 的承载骨架，骨架错则后面全错。

**Independent Test**: 在三种形态下各转一圈，布局按断点正确切换且无控件溢出；hilog 中可见折痕区域与 FoldStatus 打印。

**Acceptance Scenarios**:

1. **Given** 设备单屏态，**When** 启动应用，**Then** 呈现单栏布局，侧栏以抽屉形式唤出。
2. **Given** 设备展开为双屏，**When** 窗口尺寸变化，**Then** 布局切为两栏各 50%，无控件溢出。
3. **Given** 设备全展开三屏，**When** 窗口尺寸变化，**Then** 布局切为三栏各 1/3。
4. **Given** 任一形态，**When** 布局渲染，**Then** hilog 打印一次 `getCurrentFoldCreaseRegion()` 返回值与 `getFoldStatus()` 返回值（真机校准数据点，值本身不进布局计算）。

### User Story 2 - 库模型：注册表持久化 + 库 CRUD (Priority: P1)

首次启动自动创建默认本地库 `vaults/local`（不配任何远端也能进应用）。库注册表持久化（正常退出后重进还在）。用户能新建本地库（名字消毒规则：过滤 `/ \ : * ? " < > |` 与控制字符 → 去前导点 → 去首尾空白 → 空名拒绝 → 重名自动加 `-2`）、库改名（显示名 = 目录名，改名即改目录名）、删除本地库（不可逆，确认弹窗必须写明；弹窗不写"建议先导出备份"）、多库切换（切库后上下文归零允许）。

**Why this priority**: 库是第一等公民；F0 本地库是默认入口，库模型是 v0.2 文件树与 v0.3 Git 同步的地基。

**Independent Test**: 全新安装 → 自动进入 `vaults/local`；新建/改名/删除/切库各操作一遍；正常退出后重进后库列表与当前库还在。

**Acceptance Scenarios**:

1. **Given** 全新安装首次启动，**When** 应用启动完成，**Then** `vaults/local` 已创建并设为当前库。
2. **Given** 用户输入库名 `a/b:c*`，**When** 提交新建，**Then** 非法字符被过滤，目录名合法。
3. **Given** 已存在库「本地笔记」，**When** 再新建同名库，**Then** 自动命名为「本地笔记-2」。
4. **Given** 用户删除本地库，**When** 点击确认，**Then** 弹窗已明示「不可逆/无法恢复」，确认后目录连内容被删除。
5. **Given** 用户改库名，**When** 确认，**Then** `vaults/` 下目录名与显示名同步更新。
6. **Given** 正常退出后重新进入，**When** 应用启动，**Then** 库列表与上次所在库恢复。

### User Story 3 - 形态切换状态保持 + FoldStatus 真机数据点 (Priority: P2)

折叠/展开时当前所在库、当前选中项不丢（UIAbility 折叠切换不重建，但状态必须存放在合适的地方）。三屏态 `FoldStatus` 实际返回值官方未记载——应用在真机上打印实际值建映射表，不硬编码猜测的映射（写留 TODO 的日志点，由真机测试者回填）。

**Why this priority**: 「状态不丢」是完成判定的一部分；FoldStatus 映射表是后续版本形态判断校准的数据来源。

**Independent Test**: 在某库上折叠再展开，当前库名不变；hilog 输出带 TODO 标记的 FoldStatus/FoldCrease 打印点。

**Acceptance Scenarios**:

1. **Given** 当前在库 A，**When** 折叠→展开（任意档位组合），**Then** 当前库仍为 A。
2. **Given** 真机三屏态，**When** 触发布局刷新，**Then** hilog 打印 `getFoldStatus()` 实际返回值（带 `// TODO(真机校准)` 语义的日志标记）。

### User Story 4 - 目录栏整体收起（md / lg） (Priority: P2)

md / lg 两档目录栏可整体收起：收起入口在侧栏右上角「收起 «」，唤回用顶栏汉堡按钮。双屏收起 → 腾出的那栏给预览，变「编辑 | 预览」各占一整块屏（不跨折痕）；三屏收起 → 编辑区扩到 2/3，会跨第一条折痕——这是物理限制不是 bug，原型里该折痕标红并提示「被内容横跨」，照做。

**Why this priority**: 收起交互是原型已实现的明确需求；跨折痕警示是三屏态的诚实设计。

**Independent Test**: md/lg 各收起一次再唤回；三屏收起时看到红色折痕警示标注。

**Acceptance Scenarios**:

1. **Given** md 双栏态，**When** 点「收起 «」，**Then** 变为编辑|预览各 50% 两栏。
2. **Given** lg 三栏态，**When** 点「收起 «」，**Then** 编辑区扩到 2/3，第一条折痕位置显示红色「被内容横跨」警示。
3. **Given** 侧栏已收起，**When** 点顶栏汉堡按钮，**Then** 侧栏按当前档位规则恢复。

### User Story 5 - 工程配套：路径解析器与命名规范 (Priority: P3)

库内相对路径 → 绝对路径只有一层实现，将来 UI 和端侧意图执行器共用。路径只能由 `context.filesDir` 等 Context 属性拼出，禁止硬编码沙箱目录字符串。中文文件名统一用下划线，不用空格与连字符。

**Why this priority**: 为 AI 意图执行器预留的唯一入口（成本为零，事后补很痛）；命名规范与 vault 规范一致。

**Independent Test**: 代码审查：路径拼接仅一处实现且全部从 Context 属性出发；新建文件名走下划线规范。

**Acceptance Scenarios**:

1. **Given** 任意调用方需要库内文件的绝对路径，**When** 传入相对路径，**Then** 由唯一解析器返回基于 `filesDir` 的绝对路径。
2. **Given** 应用创建的任何文件/目录，**When** 命名，**Then** 不含空格与连字符（下划线规范）。

### Edge Cases

- 消毒后库名为空（如用户只输入 `///`）→ 拒绝创建并提示，不产生目录。
- 删除当前所在库 → 删除后回落到列表第一个库；列表为空（理论不可达，local 可删但删除操作后仍有其他库或回落逻辑兜底）→ 回落逻辑必须存在。
- 改名时目标目录名已存在 → 走重名加 `-2` 规则，不覆盖已有目录。
- `getCurrentFoldCreaseRegion()` 在非折叠设备/形态下返回值异常 → 不影响等分布局（返回值不参与计算）。
- 窗口宽度恰在阈值边界（600vp / 840vp）→ 按 `sm: <600, md: [600,840), lg: >=840` 半开区间判定，无重叠无遗漏。

## Requirements

### Functional Requirements

- **FR-001**: 系统 MUST 用 `window.on('windowSizeChange')` + `px2vp()` 计算三档断点 sm/md/lg（阈值 600vp / 840vp，出自 `mvp_design.md` §2），且 MUST NOT 用 `display.getFoldDisplayMode()` 做形态分支。
- **FR-002**: 三栏骨架 MUST 自绘：sm 单栏+抽屉侧栏；md 两栏各 50%；lg 三栏各 1/3。MUST NOT 使用 `FoldSplitContainer`。
- **FR-003**: 系统 MUST 仅标注折痕：打印 `display.getCurrentFoldCreaseRegion()` 返回值；该值 MUST NOT 参与布局计算（本版本按等分实现）。
- **FR-004**: 形态切换时当前库与当前选中项 MUST NOT 丢失。
- **FR-005**: 系统 MUST 在真机打印实际 `FoldStatus` 返回值，MUST NOT 硬编码三屏态映射关系（留 TODO 由真机回填）。
- **FR-006**: 目录栏 MUST 支持整体收起（md/lg），收起/唤回入口与分栏变化遵循原型：md 收起→编辑|预览各一屏；lg 收起→编辑 2/3 且第一条折痕标红警示「被内容横跨」。
- **FR-007**: 首次启动系统 MUST 自动创建默认本地库 `vaults/local` 并设为当前库，不配任何远端也能进入应用。
- **FR-008**: 库注册表 MUST 持久化，正常退出后重进后库列表与当前库恢复。
- **FR-009**: 新建本地库名 MUST 走消毒规则：过滤 `/ \ : * ? " < > |` 与控制字符 → 去前导点 → 去首尾空白 → 空名拒绝 → 重名自动加 `-2`。
- **FR-010**: 库改名 MUST 同步修改目录名（显示名 = 目录名）。
- **FR-011**: 删除本地库 MUST 弹不可逆确认弹窗（写明无法恢复）；弹窗 MUST NOT 出现「建议先导出备份」文案（zip 导出未实现）。
- **FR-012**: 系统 MUST 支持多库切换；切库后上下文归零是允许的。
- **FR-013**: 库内相对路径 → 绝对路径 MUST 只有一层解析器实现，UI 与将来意图执行器共用；路径 MUST 由 `context.filesDir` 等 Context 属性拼出，MUST NOT 硬编码沙箱目录字符串。
- **FR-014**: 中文文件名 MUST 用下划线，不用空格与连字符。
- **FR-015**: 所有实现 MUST 只用 API ≤ 24 的接口（如需更高版本 API 的能力必须降级并在报告注明）。
- **FR-016**: 涉及鸿蒙 API 的结论必须能指到 `docs/harmonyos/api_notes.md` 具体条目或经 DevEco 补全确认；两者都找不到的 API MUST 列入「需要确认的 API」报告，MUST NOT 用猜测实现蒙混。
- **FR-017**: 代码 MUST 通过 `tools\build.ps1` 编译（BUILD SUCCESSFUL）。

### Key Entities

- **库（Vault）**: `vaults/` 下一个目录 = 一个库。属性：id（= 目录名）、显示名（= 目录名）、类型（local/git，本版本只有 local）、目录路径、创建时间。显示名与目录名不分离。
- **库注册表（VaultRegistry）**: 库列表的持久化记录，含每个库的元数据与当前库 id；重进应用恢复。
- **断点（Breakpoint）**: sm/md/lg 三档，由窗口宽度（vp）判定；跨组件共享的全局状态。
- **库名消毒（NameSanitizer）**: 新建与改名共用的名称规则（过滤非法字符 → 去前导点 → 去空白 → 空拒绝 → 重名加后缀）。
- **路径解析器（VaultPathResolver）**: 库内相对路径 → 沙箱绝对路径的唯一转换层。

## Success Criteria

### Measurable Outcomes

- **SC-001**: XT2 单屏/双屏/三屏三档各转一圈，布局按断点正确切换且无控件溢出（真机验收）。
- **SC-002**: 折叠展开后当前所在库不变（真机验收）。
- **SC-003**: 新建本地库、改名、删库、切库全流程可完成；重进应用后库列表还在（真机验收，逻辑可离线自查）。
- **SC-004**: `tools\build.ps1` 输出 BUILD SUCCESSFUL（可离线验收，交付硬门槛）。
- **SC-005**: hilog 中可见折痕区域、FoldStatus 带校准标记的打印点（真机验收）。

## Assumptions

- 库注册表 MVP 存 preferences（`mvp_design.md` §4.1/§4.5：「MVP 存 preferences，app.db 建表是 v2 的事」）。
- v0.1 三栏中无文件树/编辑器/预览内容，栏内以占位内容标注将来用途（如「文件树 · v0.2」）；布局结构、收起交互、顶栏/状态栏照原型简化实现。
- sm 态侧栏抽屉与原型一致（汉堡唤出）；原型中同步按钮、左滑手势、双链渲染等属于后续版本，不实现。
- 顶栏汉堡按钮在 sm 为抽屉开关、在 md/lg 为收起侧栏的唤回入口。
- 状态栏保留（显示当前断点与 vp 宽度），便于真机校准断点。
- 需求文档「验收记录」小节由本版本更新（能离线自查的部分）。

## Open Questions

无（需求已由 `docs/releases/v0.1/需求文档.md` 与用户提示词完整拍板；技术未知项全部转为真机校准 TODO，不阻塞实现）。
