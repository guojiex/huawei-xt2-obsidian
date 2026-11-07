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
  - 拖拽手势 —— 未验；**点击与滑动注入实测可用**（2026-11-07，见下「实测结论」），
    左滑删除路径走 `ListItem.swipeAction` 手势注入；
  - 折叠形态切换（single/double/triple）—— 由宿主侧 Emulator.exe 控制，设备内测试中途切不了；
  - 像素级视觉断言 —— 颜色 / 间距 / token 验收归人工回归；
  - 崩溃 / 强杀 / 写入中断注入 —— 测试边界（`AGENTS.md`）。
- 树行 MENU 键路径**作废**：UiTest 的 touch click 不给树行键盘焦点，`triggerKey(KEYCODE_MENU)`
  打不开行内菜单；行内操作一律走 swipeAction 注入（半滑 0.45 出操作条、全滑 0.7 触发删除）。

## 运行

```powershell
.\tools\uitest.ps1                  # 全量：构建双 HAP → 装机 → 跑全部 UI 套件 → 解析结果
.\tools\uitest.ps1 -Suite UiLaunch  # 只跑指定套件（UiLaunch / UiNoteFlow / UiPanels，逗号分隔）
.\tools\uitest.ps1 -Fresh           # 先卸载应用清数据再装（清掉测试残留）
```

- 前置：x86_64 模拟器在线（不在线时脚本会尝试启动 `Huawei_TripleFold`），ABI 需为 x86_64 或 dual
  （`tools/abi.ps1 -Status`）；两种架构的 libgit2 都已编过时用 `-Dual`。
- UiNoteFlow 的 `uitest*` 测试残留由 harness **宿主侧清理**：force-stop 后、aa test 前
  `rm -rf` 库内 `uitest*` 与 `.trash/uitest*`（测试进程跨模块够不到 entry 沙箱，见「实测结论」）。
- 结果解析自 `aa test` 的 `OHOS_REPORT_*` 输出；原始输出与 hilog 存 `.local/uitest/<时间戳>/`（gitignore）。
- 与既有仪器化测试（GitImport / GitCredentialStore / Git2Native，依赖本机 fixture）互不干扰：
  harness 用 `-s class` 只跑 UI 套件；DevEco 内运行时按套件过滤。
- ⚠️ **运行期间勿在 DevEco Studio 点运行/部署**：宿主部署会 force-stop + 重装应用，
  连坐杀掉进行中的测试进程（run 185753 t8 "App died" 实证）。

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
3. **等待**：默认等待 30s（x86 渲染慢，整树一次匹配可花 ~12s，api_notes L-8）；撤销条只停 5 秒，
   专用短超时（`SNACK_MS`）。等待只信控件树（`waitForComponent`），不信截图。
   `waitForComponent` 超时**返回 null 不抛错**，helpers 判空转成清晰错误。
4. **新版本落码时**：在对应套件文件加用例（新域则建 `Ui<域>.test.ets` 并在
   `List.test.ets` 注册），本文映射表补一行写明 EM 对应（没有对应 EM 用例的先补
   [模拟器回归用例](模拟器回归用例.md)），验收记录引用本文。
5. **不稳定项处理**：harness 不自动重试（避免掩盖）；同一用例连续两轮失败才判不稳定，
   先修超时 / 选择器，确属环境阻塞的从套件移除并在本文标注原因，不硬凑通过。

## 实测结论与坑（2026-11-07 首轮落地，x86_64 模拟器）

全量 17/17（证据 `.local/uitest/20261107_193935`）；单套件 UiLaunch 5/5、UiNoteFlow 8/8、
UiPanels 4/4。落地过程中确认的环境行为（细节见对应代码注释与 `api_notes` L-8/L-9 修正）：

- **冷启动首击被吞**：冷启动后约 1 分钟内 UiTest 点击注入间歇性无效（同坐标 uinput 手动注入正常，
  晚于 1 分钟的点击也正常）→ 打开类操作套 `clickUntilTextAppear` 重试，不裸用 clickById。
- **点击 / 滑动注入可用**：`Driver.click`、`Driver.swipe`（px 坐标，speed 800）与
  `ListItem.swipeAction` 手势路径（半滑出操作条 / 全滑触发 `onAction`）均稳定可用；拖拽未验。
- **LazyForEach 折叠线**：文件树运行期折叠线 ~9 行，排序靠后的行不入控件树 → 树行查找一律走
  `findTreeRow`（锚点行取 bounds → 向上滑滚动列表，最多 4 轮）。树行 id：
  `file-tree-row-<vaultId>:<relPath>`（文件含 `.md`，文件夹无扩展名）。
- **文案断言误匹配**：同文案多入口（如空态 CTA「新建笔记」与菜单项「新建笔记」）；
  判弹窗用 id `note-create-input`，不裸等文案。
- **双栏设置一次只渲染一个分类**（`SettingsView` 按 `selectedTab` 渲染 `CategoryContent`）：
  断言多个分组标题须逐类点击 `settings-category-*` 再等 `settings-heading-*`。
- **宿主侧清理的由来**：测试进程跨模块够不到 `haps/entry` 沙箱（`getAppContext().filesDir`
  是 bundle 级 `files/`）→ 测试内清残留是死路，改由 harness 在应用停止后清理。
- aa test 无 teardown 强停；结束后应用退后台，看控件树前先 `aa start`。
