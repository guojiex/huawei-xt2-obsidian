# UI 自动化测试

> hypium + `@ohos.UiTest` 的仪器化 UI 套件：代码在 `entry/src/ohosTest/ets/test/ui/`，一键执行 `tools/uitest.ps1`。
> **定位（2026-11-07 用户决定）：UI 测试是质量保障资产，不是产品需求。**
> 不为它单独立版本目录（[releases R3/R4](../releases/README.md) 管产品需求落码，QA 资产豁免）；
> 每个需求版本落码时**同步补对应 UI 用例**，并在本文映射表登记。

## 边界与不做

- 自动化只覆盖 [模拟器回归用例](模拟器回归用例.md) 中 x86 模拟器**可达**的冒烟子集；
  视觉、手感、折叠形态与真机验收仍走人工回归（[README](README.md)，规则不变）。
- 明确不做（依据 [api_notes](../harmonyos/api_notes.md) **L-8 / L-9 / Z3**，结论只链接不复制）：
  - Web 编辑器（mdeditor/mdpreview）内的文本注入与内容断言 —— x86 系确定性不可用；
  - 拖拽 / 左滑手势路径 —— 手势注入不可靠，只走按钮与键盘路径；
  - 折叠形态切换（single/double/triple）—— 由宿主侧 Emulator.exe 控制，设备内测试中途切不了；
  - 像素级视觉断言 —— 颜色 / 间距 / token 验收归人工回归；
  - 崩溃 / 强杀 / 写入中断注入 —— 测试边界（`AGENTS.md`）。
- 文件树行内路径菜单（重命名 / 移动 / 删除）通过 `driver.triggerKey(KEYCODE_MENU = 2067)` 打开
  （`FileTreeView.onTreeRowKey` 的键盘分支），先点行使其获得焦点。

## 运行

```powershell
.\tools\uitest.ps1                  # 全量：构建双 HAP → 装机 → 跑全部 UI 套件 → 解析结果
.\tools\uitest.ps1 -Suite UiLaunch  # 只跑指定套件（UiLaunch / UiNoteFlow / UiPanels，逗号分隔）
.\tools\uitest.ps1 -Fresh           # 先卸载应用清数据再装（清掉测试残留）
```

- 前置：x86_64 模拟器在线（不在线时脚本会尝试启动 `Huawei_TripleFold`），ABI 需为 x86_64 或 dual
  （`tools/abi.ps1 -Status`）；两种架构的 libgit2 都已编过时用 `-Dual`。
- 结果解析自 `aa test` 的 `OHOS_REPORT_*` 输出；原始输出与 hilog 存 `.local/uitest/<时间戳>/`（gitignore）。
- 与既有仪器化测试（GitImport / GitCredentialStore / Git2Native，依赖本机 fixture）互不干扰：
  harness 用 `-s class` 只跑 UI 套件；DevEco 内运行时按套件过滤。

## 套件与用例映射

> 状态不在此登记；执行结果记入当轮输出的摘要与 `.local/uitest/` 证据，版本验收时引用。
> 主工程为本测试补的 `.id()`：`vault-sidebar-search`、`vault-sidebar-new-note`、`note-create-input`。

| 套件 | 用例 | 覆盖要点 | EM 对应 |
| --- | --- | --- | --- |
| UiLaunch | `cold_launch_workspace_ready` | 冷启动后工作区骨架（汉堡 / 库切换 / 笔记计数）就位，无白屏 | EM-A1 |
| UiLaunch | `file_tree_not_empty_fresh_install` | 首装教程库文件树非空（空树提示不出现） | EM-A1 |
| UiLaunch | `split_handle_hidden_when_sidebar_collapsed` | 宽屏（≥600vp）下收起目录后 nav 分栏把手从控件树消失、展开复原（295bd23 回归防线；单屏直通） | EM-A3 增补 |
| UiLaunch | `more_menu_opens_and_closes` | 宽屏更多菜单开合 | EM-H1（可达部分） |
| UiLaunch | `quick_switcher_open_and_close` | 快切开合（入口 → Back 关闭） | EM-E1（可达部分） |
| UiNoteFlow | `create_note_dialog_open_and_cancel` | 新建弹窗外壳 + 取消路径 | EM-B2 / EM-G1 |
| UiNoteFlow | `create_note_empty_name_keeps_dialog` | 空名时「创建」不生效（禁用路径） | EM-B2 / EM-G3 |
| UiNoteFlow | `create_note_with_name_full_flow` | 原生 TextInput 注入 + 创建全链路（树就位、栏就位）；兼作 inputText 可用性探针 | EM-B2 |
| UiNoteFlow | `create_folder_flow` | 类型切「文件夹」→ 创建 → 树就位 | EM-B2 |
| UiNoteFlow | `delete_note_confirm_and_undo` | 行菜单删除 → 确认 → 撤销条出现 → 撤销恢复 | EM-B3（按钮路径） |
| UiNoteFlow | `delete_note_dialog_cancel_keeps` | 删除确认取消后文件保留 | EM-G1 |
| UiNoteFlow | `trash_section_visible_after_delete` | 删除后侧栏回收站区块出现 | EM-B4（可达部分） |
| UiNoteFlow | `close_note_shows_empty_state` | 关闭当前笔记 → 空态（新建入口 id 就位） | EM-B5（可达部分） |
| UiPanels | `settings_groups_visible_and_back` | 设置页分组标题就位 + 返回 | EM-F1（可达部分） |
| UiPanels | `settings_editor_mode_toggle` | 设置内简单 / 专业模式切换与还原 | EM-C1 / EM-F1 |
| UiPanels | `vault_manager_open_and_back` | 库下拉 → 管理库 → 返回 | EM-B1（可达部分） |
| UiPanels | `git_entry_hidden_for_non_git_vault` | 非 Git 库（首装教程库）不显示同步入口 | EM-K1（反向断言） |

## 约定

1. **选择器**：优先 `.id()`（kebab-case，沿用主工程现有命名）；静态文案 `ON.text()`（EQUALS），
   动态内容 CONTAINS。新增控件若要可测，先补 id 再写用例。
2. **测试数据**：一律 `uitest` 前缀 + 时间戳唯一名（`uniqueUiName`）；接受模拟器残留，
   `-Fresh` 卸载重装可清零。不把个人笔记、令牌或运行时状态写入用例。
3. **等待**：默认等待 15s（x86 渲染慢，api_notes L-8）；撤销条只停 5 秒，专用短超时。
   等待只信控件树（`waitForComponent`），不信截图。
4. **新版本落码时**：在对应套件文件加用例（新域则建 `Ui<域>.test.ets` 并在
   `List.test.ets` 注册），本文映射表补一行写明 EM 对应（没有对应 EM 用例的先补
   [模拟器回归用例](模拟器回归用例.md)），验收记录引用本文。
5. **不稳定项处理**：harness 不自动重试（避免掩盖）；同一用例连续两轮失败才判不稳定，
   先修超时 / 选择器，确属环境阻塞的从套件移除并在本文标注原因，不硬凑通过。
