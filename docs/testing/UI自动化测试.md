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
.\tools\uitest.ps1 -Suite UiLaunch  # 只跑指定套件（映射表内套件名，逗号分隔）
.\tools\uitest.ps1 -Fresh           # 先卸载应用清数据再装（清掉测试残留）
```

- 前置：x86_64 模拟器在线（不在线时脚本会尝试启动 `Huawei_TripleFold`），ABI 需为 x86_64 或 dual
  （`tools/abi.ps1 -Status`）；两种架构的 libgit2 都已编过时用 `-Dual`。
- UiNoteFlow 的 `uitest*` 测试残留由 harness **宿主侧清理**：force-stop 后、aa test 前
  `rm -rf` 库内 `uitest*` 与回收站 `trash/*/uitest*`（v1.5 起回收站在模块级
  `haps/entry/files/trash/<vaultKey>/`，vaultKey 形如 `vault-<ts>-<seq>` 非库名；
  测试进程跨模块够不到 entry 沙箱，见「实测结论」）。
- 结果解析自 `aa test` 的 `OHOS_REPORT_*` 输出；原始输出与 hilog 存 `.local/uitest/<时间戳>/`（gitignore）。
- 与既有仪器化测试（GitImport / GitCredentialStore / Git2Native，依赖本机 fixture）互不干扰：
  harness 用 `-s class` 只跑 UI 套件；DevEco 内运行时按套件过滤。
- ⚠️ **运行期间勿在 DevEco Studio 点运行/部署**：宿主部署会 force-stop + 重装应用，
  连坐杀掉进行中的测试进程（run 185753 t8 "App died" 实证）。

## 套件与用例映射

> 状态不在此登记；执行结果记入当轮输出的摘要与 `.local/uitest/` 证据，版本验收时引用。
> 主工程为本测试补的 `.id()`：`vault-sidebar-search`、`vault-sidebar-new-note`、`note-create-input`、
> `quick-switcher-scope-current`/`quick-switcher-scope-all`、`quick-switcher-search-input`、
> `quick-switcher-skip-hint`、`trash-section-header`、`trash-restore-button`、`trash-purge-button`、
> `trash-row-<vaultId>:<relPath>`（回收站行，47.3）、
> `settings-diagnostics-row`、`settings-changelog-row`、`settings-reset-pane-widths`、
> `utility-dialog-close`（弹窗外壳 × 关闭）、`vault-create-input`（新建库输入框）、
> `vault-manager-delete-<vaultId>`（库管理删除/解除关联按钮）。

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
| UiNoteFlow | `trash_purge_confirm_and_cancel` | 回收站永久删除全链路：行内按钮 → 确认弹窗 → 取消保留 / 确认真删（行消失，无撤销条）；复用 UiNoteFlow 树操作 helpers，故不放 UiTrash | EM-B7 |
| UiNoteFlow | `close_note_shows_empty_state` | 关闭当前笔记 → 空态（新建入口 id 就位） | EM-B5（可达部分） |
| UiPanels | `settings_groups_visible_and_back` | 设置页分组标题就位 + 返回 | EM-F1（可达部分） |
| UiPanels | `settings_editor_mode_toggle` | 设置内简单 / 专业模式切换与还原 | EM-C1 / EM-F1 |
| UiPanels | `vault_manager_open_and_back` | 库下拉 → 管理库 → 返回 | EM-B1（可达部分） |
| UiPanels | `git_entry_hidden_for_non_git_vault` | 非 Git 库（首装教程库）不显示同步入口 | EM-K1（反向断言） |
| UiPanels | `share_panel_accessible_from_more_menu` | 更多菜单中分享入口可见 | EM-J2（可达部分） |
| UiPanels | `import_dialog_accessible_from_vault_manager` | 库管理中导入按钮可达 | EM-M1（可达部分） |
| UiQuickSwitch | `quick_switcher_opens_with_search_input` | 快切弹窗搜索输入框可见 | EM-E1 |
| UiQuickSwitch | `scope_defaults_to_current_vault` | 范围分段「当前库」默认选中 | EM-E1 |
| UiQuickSwitch | `scope_toggle_to_all_vaults` | 范围分段切换到「全部库」 | EM-E2（可达部分） |
| UiQuickSwitch | `skip_hint_ui_skeleton_accessible` | 跳过提示 UI 骨架可达 | EM-E3（可达部分） |
| UiSmDrawer | `folder_toggle_responds_in_navigation` | 文件列表目录行点按有翻转响应，导航异常时汉堡 toggle 自愈后重试（2026-11-08 抽屉失步回归防线） | —（回归新增） |
| UiSmDrawer | `create_note_keeps_navigation_usable` | 抽屉头「+」新建笔记后导航仍可复用（doCreateNote 收抽屉走 setDrawerOpen 的链路） | EM-B2 增补 |
| UiTrash | `trash_section_visibility` | 回收站区块可见性（空/非空两种正确状态） | EM-B4 |
| UiTrash | `trash_restore_button_accessible_when_items_exist` | 回收站有内容时恢复按钮可达 | EM-B4（按钮路径） |
| UiTrash | `trash_section_label_correct` | 回收站标题文案正确 | EM-B4 |
| UiSettingsExt | `diagnostics_info_row_visible_and_expandable` | 诊断信息行可见且可展开（含构建提交行） | EM-F2 |
| UiSettingsExt | `changelog_section_visible` | 更新日志区可见且有内容或占位 | EM-F5 |
| UiSettingsExt | `reset_pane_widths_row_visible` | 恢复等分栏宽行可见 | EM-F6 |
| UiShare | `share_panel_opens_from_more_menu` | 更多菜单「分享笔记」**点击穿透**：应用内分享面板真的打开（格式行/描述就位，标题与菜单项同名，判定用弹窗独有文本「长图」）；非 Git 库不显示「远端网页链接」行 | EM-J2 / EM-J4（反向） |
| UiShare | `share_scope_segments_switch_formats` | 范围分段「笔记/文件夹/知识库」切换，各范围标题与格式列表正确 | EM-J2 25.12/25.13 |
| UiShare | `share_note_text_preview_roundtrip` | 文本分享详情（可编辑说明 + 返回格式选择）可达并返回 | v0.9 9.14 |
| UiShare | `share_text_system_handoff_cancel_keeps_dialog` | 分享文本调起系统分享：无交接失败文案；取消（pressBack）后应用内弹窗保留；系统面板标记（华为分享/复制/另存为/中转站）尽力探测不硬断言 | EM-J2（取消系统分享，可达部分） |
| UiShare | `share_note_file_preview_roundtrip` | Markdown / ZIP 文件详情（标题按格式 / 分享文件 / 返回）可达并返回 | EM-J2 / v0.8 |
| UiShare | `share_long_image_preview_roundtrip` | 长图详情（宽度/外观设置区 + 返回）可达并返回；不断言成图 | EM-J2 / v1.19 / v1.25 |
| UiShare | `share_vault_zip_preview_roundtrip` | 知识库范围 ZIP 详情（1 个 ZIP / 分享文件）可达并返回 | EM-J2 / v0.8 |
| UiShare | `share_vault_entry_from_manager` | 库管理「分享」→ 仅 ZIP 的「分享知识库」面板（无范围分段） | EM-J1 / v1.25 25.18 |
| UiShare | `share_export_current_vault_from_settings` | 设置 → 数据 → 导出当前知识库复用同一分享面板，关闭后仍在设置数据页 | EM-J3 / v1.37 37.2 |
| UiShare | `share_pdf_row_matches_capability` | 能力自适应：有「PDF 文档」行则点入断言详情弹窗；无则基础三行在（优雅降级）。x86 模拟器预期无 PDF 行（SystemCapability，AD 组） | v1.53 53.3（可达部分） |
| UiShare | `share_empty_vault_entry_disabled` | 空库分享入口禁用（`uitest_share_empty_*` 新建空库探针 + isEnabled 断言 + 删除清理；doCreateVault 自动切库不影响探针） | EM-J1 空库 / EM-B6（可达部分） |

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

## 实测结论补遗（2026-11-09，x86_64 模拟器：最后两个从未绿用例转绿）

`trash_purge_confirm_and_cancel`（UiNoteFlow，EM-B7）与 `reset_pane_widths_row_visible`
（UiSettingsExt，EM-F6）当日连绿两轮（证据 `.local/uitest/20261109_234448`、`20261109_234600`；
reset 首绿另有 `20261109_231431`）。两例根因均为**测试代码**问题，主工程零改动：

- **trash_purge**：① 删除确认后的 UndoBar（5000ms 生命周期）是点击死区——条存活期内
  点击注入落空（链路完整、出现 `CLK RACC, T: <type>` 签名却无 UI 反应），确认后显式
  等条过期再继续；② 永久删除改**组件点击**（`trash-purge-button` 中心）：行右缘坐标点击
  （x≥1009）整条高度被导航分栏把手 `responseRegion`（36vp 宽、`zIndex(4)`）吞掉——
  把手宽触区是有意设计，不改产品代码；③ 展开子用例套「点击后验证未生效则重试」兜底。
- **reset_pane_widths**：原滑动起点落在错误栏位 → 改**显示相对坐标**在右正文栏内滑动；
  陷阱：IME 弹起时页面根高度收矮（实测 2232→1318），坐标须按 IME 状态下的实际布局算，
  否则 swipe 越界静默失败。
- 两例转绿后全套件再无从未绿用例；证据目录含 `aa_test_raw.txt` 与 `hilog_after.txt`。

## 实测结论补遗（2026-11-11，x86_64 模拟器：UiShare 首轮 8/11 → 3 败归因）

首轮证据 `.local/uitest/20261111_000354`。3 败两条根因，一条主工程 bug、一条测试传染：

- **产品 bug（已被用例抓住）**：分享面板切「知识库」范围后 `@BuilderParam` 内容刷新、
  标题仍「分享笔记」——`UtilityDialogShell.title/subtitle` 是未装饰普通成员，父重渲染
  不刷新（api_notes **Z4**）。修复改 `@Prop`；`test_utility_dialog_shell.mjs` 加防线。
  手动取证方法：`uitest uiInput click` 逐步驱动 + `uitest dumpLayout` 控件树比对
  （标题/副标题/内容行同帧 dump，内容变标题不变即实锤）。
- **失败残留传染**：用例抛错不清理现场，残留弹窗遮罩吞掉下一用例首击
  （`shareNoteCtl` `autoCancel: true`，遮罩一击顺带关面板但点击本身落空）——
  `share_vault_entry_from_manager` 的 30s「管理库…」超时即此连锁。防线：用例开场
  `closeLeftoverDialogs`（`utility-dialog-close` 链式关闭最多 3 层），直连侧栏 /
  设置的用例必须带；经 `openTutorialNote` 的用例已内置。
- **库状态污染**：空库探针用例建删库后当前库可能停在别的库（`doDeleteVault` 切库），
  且 aa test 结束应用被杀、下轮冷启动按会话恢复到该库 → `openTutorialNote` 加固：
  当前库找不到教程笔记时经库切换菜单切回「曜石笔记教程」再找（文件树异步加载用
  轮询等待，不用单发 `existsByText`）。

### Aa 选区抑制修复的模拟器旁证（同日，简单模式）

Aa 格式面板打开时压制 Web 选区 UI 的修复（`suppressPaneSelectionUi` / `restoreSuppressedPaneSelectionUi`
链路，需求条目 [46.11](../releases/v1.46/需求文档.md)）在 x86_64 模拟器手动验证通过：双击正文出现
原生胶囊菜单（与栏顶格式坞重叠，即缺陷现场）→ 点 Aa 后胶囊菜单从控件树消失（`dumpLayout` 判定）
且正文保留 → 点「完成」关闭后光标 + 圆形拖拽手柄在原位恢复（关闭前后同区域截图像素级一致，
diff 0.008%）。注意 Aa 按钮本身是开关：面板开着再点 Aa 会触发 autoCancel 关闭 + onClick 重开的竞争，
自动化断言应走「完成」按钮路径。同批 46.12（表格浮条 `visualBlockRect`）验证见
`.local/uitest/20261110_visual_block_rect/`（双击结构可编辑表格单元格后浮条可见）。

## 实测结论补遗（2026-11-12，x86_64 模拟器：43/43 全绿与两轮根因收敛）

修复轮全量 43/43（证据 `.local/uitest/20261112_124710`，含 75 张 `.jpeg` 截图与运行窗口 hilog；
上一轮 39/1/3 见 `20261112_120216`，再上一轮级联崩坏 28/1/14 见 `20261112_104425`）。
本轮全部为**测试侧**修复，主工程零改动：

- **回收站展开挤压树视口（#14/#25/#26 统一根因）**：`trash-section-header` 展开后回收站
  区块占高，树 List（`layoutWeight`）视口从 ~7.5 行缩到 ~4.5 行——mtime 排序下第 7 行的
  `00_开始` 锚点落到 LazyForEach 折线下（探针查无），且 `scrollSidebarToTop` 的滑动终点
  （按钮底 +900 ≈ y1655）越过缩水后的 List 底（≈1526）落进回收站区块，手势被误路由、
  树滚不回顶，恢复链全灭。差分实证：上一轮 #13 早夭没展开回收站，同批 #14 反而是过的。
  防线：`scrollSidebarToTop` 开场先探 `trash-restore-button`（存在 = 展开且有内容），
  有则点区块头收起再滚——空回收站区块整体隐藏，不会误触。
- **回收站区块头是 toggle（#28）**：上游留下展开态时盲点会把展开收起、恢复按钮断言秒败。
  防线：先探 `trash-restore-button` 已存在则跳过点击，不存在才点开再断言。
- **0.7 全滑间歇不越三档阈值（#13 trash_purge）**：裸 `swipeTreeRow(0.7)` 在删除场景
  间歇不触发（同签名失败），统一走带兜底重试的 `swipeDeleteNote`（#12 已用故过）。
- **套件间级联遏制**：单套件把应用留在次级视图（如库管理）会连坐下一套件整批超时
  （28/1/14 那轮 15 连错）。防线：全部套件 `beforeAll` 加 `ensureNoteView`——15s 探
  `workspace-more-button`（实测冷启动到顶栏可达 12.6s，探针窗口必须 ≥15s），缺则
  pressBack 回笔记视图再复探；外加库管理路径 `clickUntilTextAppear` 逐跳驱动。
- **share_pdf_row 按 53.7 更新**：有「PDF 文档」行时点入「PDF 分享」二级弹窗，断言
  「分享 PDF / 按段落分页 / 返回」后点返回回「长图」列表。
- **监控与解析坑**：`snapshot_display -f` 后缀必须是 `.jpeg`（`.jpg` 静默失败 0 字节）；
  宿主侧 `hilog -x` 重定向不可靠（写完当前缓冲即死），取证改拉设备侧
  `/data/log/hilog/*.gz`（二进制按 UTF-8 字节模式搜中文，`strings` 只认 ASCII）；
  `aa test` 输出为分行 `OHOS_REPORT_STATUS: key=value` + `OHOS_REPORT_STATUS_CODE: N`
  （0 过 / -1 错 / -2 败 / 1 起），无 `code=` 内联形式。
- **数据路径澄清**：模块级 `context.filesDir` 是 `haps/entry/files/`（vaults 与 trash 都在
  这）；bundle 级 `files/` 只有 `__arkweb/`、`hiappevent/`，别再当 vault 根。

## 实测结论补遗（2026-11-14，x86_64 模拟器：Index.ets 三阶段拆分回归，43/43 全绿收口）

背景：Index.ets 拆分提交后跑全量回归，首轮 37/0/6（`20261114_205005`），经三类测试侧
修复后全量 **43/43**（`20261114_233140`；中途全量 41/43 见 `20261114_211814`）。
**主工程零改动，全部为测试侧修复**——三类失败均为测试资产陈旧或测试假设错误，不是拆分回归：

- **UiPanels 4 例级联（设置页长高）**：近期功能提交让设置「通用」页长高，`编辑模式` 行
  （`.id` 动态拼接）被挤出首屏——**off-screen 组件不入 a11y 树**，`settings-editor-mode-toggle`
  必败；且该套件无 `afterEach` 遏制，败后留在设置页连坐后续 3 例。修复：该用例以
  `settings-heading-general` 为锚上滑一屏再断言；套件加 `afterEach ensureNoteView` 级联
  遏制。验证：`20261114_211644` 单套件 6/6，两轮全量保持全绿。
- **UiShare 还原切库竞态（下轮库污染）**：`share_empty_vault_entry_disabled` 结尾还原
  教程库走 `void this.switchVault(id)` fire-and-forget 异步链（Index.ets:5711），
  `waitByText('00_开始')` 只证明「切过去」，续段失败会走 catch 回滚 `setCurrent(前库)`
  并持久化——静默把下轮冷启动落在「我的笔记」，UiNoteFlow 整套
  `树中未找到行…（锚点 00_开始 也不可见）`（`20261114_213005` 2/7；2026-11-11 那轮
  7 ERROR 同因）。库持久化本身正常（手动切库→force-stop→重启仍保持；4 次单用例复跑
  落盘全对）——竞态仅全量负载下偶发，产品回滚是既定失败路径，不改产品。修复：测试侧
  还原链「切库→沉淀 3s→`00_开始` 复核→不稳重切」最多 3 次，末尾显式断言，宁可本用例
  报错不静默污染（残余风险：回滚 >4.5s 仍可能污染，复发再加 `beforeAll` 自愈）。
- **UiNoteFlow 2 例 3 连败（钉底簇盖行，本轮最大发现）**：`delete_note_dialog_cancel_keeps`
  / `trash_section_visible_after_delete` 同签名 `半滑 3 次未拉出「删除」操作条` 3 连败
  （`20261114_221617`/`230939`）。根因链（uinput 同坐标 A/B 实锤）：
  `FileTreeView` 根是 Bottom Stack，钉底簇（`左滑操作 · 拖图标到任一栏` 提示 + 回收站，
  不透明 `bg_navigation` 背景，簇顶 y≈2148）**有意盖住树尾行**（源码注释「遮住穿小白条
  滚上来的树行」）。`findTreeRow` 在行进 LazyForEach 渲染区即命中（a11y 有、能
  getBounds），但行中心 y 落进簇区时**滑动触摸被簇吃掉**：贴簇行（底边贴屏底 2232）
  中心 y2184/y2160 慢滑 3 连败，同行上滚抬到 y1722 后同速滑动立即拉出操作条——
  速度不是根因（见下条，但 300px/s 显式慢滑仍保留）。重试 3 次都在同一位置 →
  确定性失败。修复：`swipeTreeRow` 探钉底簇顶（`ON.text` 找提示条），行中心入簇区时
  把滑动 y 收进行顶露出段（`rect.top + 12px`）；`revealRowDelete` 每滑前
  `ensureRowAboveCluster`（整行被盖则手指上滑滚树抬行，最多 4 次；树尾行行高 138px
  > 簇盖区 ~84px，最大滚动处顶段必然露出）。
- **driver.swipe 默认速度处于 swipeAction 识别间歇边界**：SDK 默认 600px/s（范围
  [200,40000]），uinput 同坐标 A/B：100ms 快滑（≈4460px/s）不拉出、300ms（≈1487px/s）
  与 1000ms（≈446px/s）均拉出。`swipeTreeRow` 显式传 300px/s 深入慢拖稳定区，与簇
  修复双保险。**注入速度敏感性**是 2026-11-12 #13 0.7 全滑抖动的合理解释，后续新写
  滑动注入一律显式传速。
- **uinput 手动注入语法**（取证利器，比 dumpLayout 更早介入定位）：`uinput -T -m
  x1 y1 x2 y2`（默认 smooth 1000ms）；快滑显式 `-k 1 300`（keep=0 非法，第 5 位置参
  是 keep、尾参 smooth）。与 `Driver.swipe(x1,y1,x2,y2,speed)`（px/s）量纲不同，换算
  对比时注意。

