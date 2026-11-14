# Bug 回归清单

> **定位**：本清单是长期 QA 资产，覆盖全部历史 fix 提交与 api_notes 实测踩坑条目。
> 逐条登记 bug 摘要、根因类别与防回归测试归属；每条 bug 至少有一道自动化防线（或明确标注不可自动化/根因已消除）。
>
> **维护规则**：新增 fix 提交或 api_notes 实测踩坑须同步补条目；防线变更同步更新归属。
>
> **状态枚举**：
> - **已有防线**：该 bug 在本清单登记前已有对应测试覆盖
> - **已补防线**：本工作为无防线缺口补充了测试
> - **不可自动化**：环境/真机/视觉限制，依赖 EM 人工用例或用户真机验收（注明原因与人工依赖）
> - **根因已消除**：代码重构后 bug 根因不复存在，防线为现状测试

## 汇总

| 状态 | 计数 |
| --- | --- |
| 已有防线 | 123 |
| 已补防线 | 6 |
| 不可自动化 | 1 |
| 根因已消除 | 20 |
| **合计** | 150 |

> **注**：
> - T004–T009 新增的 6 个 Node 防回归测试文件是对「已有防线」条目的**加固**（源码级断言防模式退化），
>   非首次覆盖。原有防线仍为 Node 函数测试 + UI 用例 + EM 用例三层体系。
> - 主分类表中标记为「不可自动化」的 1 条是最初盘点结果；另有 28 条在「不可自动化条目明细」节展开详述
>   （因环境/真机/视觉限制无法自动化，依赖 EM 人工用例或真机验收），这些条目在主分类表中以其他状态出现
>   （多数为已有防线，Node 源码防线加固了逻辑层但 UI 层仍需人工验证）。

## 状态管理

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 1e4e389 | 弹窗按钮 enabled 固化，创建永远禁用——@Builder 全局多参按值传递 | 状态管理 | v1.32 | test_disabled_primary_neutral.mjs, test_import_vault_dialog_design.mjs, UiNoteFlow#create_note_empty_name_keeps_dialog | 已有防线 |
| 7e40407 | 弹窗 @BuilderParam 引用传参 this 丢失闪退 | 状态管理 | v1.32 | test_utility_dialog_shell.mjs | 已有防线 |
| 8e70201 | 导入库关联按钮改用弹窗自持状态 | 状态管理 | v1.5 | test_import_vault_dialog_design.mjs | 已有防线 |
| 3252809 | guard cross-pane editor mirrors——跨栏编辑器镜像竞态 | 状态管理 | — | test_editor_composition_sync.mjs | 已有防线 |
| b57b86f | reject stale editor change events——过期编辑器变更事件 | 状态管理 | — | test_editor_composition_sync.mjs | 已有防线 |
| a682ed1 | cancel stale editor change notifications——过期通知 | 状态管理 | — | test_editor_composition_sync.mjs | 已有防线 |
| ca71bd8 | guard mode and workspace target transitions——模式/工作区目标切换保护 | 状态管理 | — | test_editor_experience_transition.mjs | 已有防线 |
| 4314462 | protect editor composition save state——组合输入保存状态保护 | 状态管理 | — | test_editor_composition_save.mjs | 已有防线 |
| 6ce06f3 | 修正栏内菜单宽度为原型min-width内容自适应 | 状态管理 | v1.32 | test_pane_more_menu_design.mjs | 已有防线 |
| 2e9b4dc | 选择空栏时误加载另一栏笔记、文件树打开目标栏错位 | 状态管理 | v1.28 | test_empty_pane_target_selection.mjs；EM-B5 手动双栏步骤 | 已补防线 |
| 3f5433f | switch split and focus controls by layout——按布局切换分栏/专注控件 | 状态管理 | v1.8 | test_split_layout_store.mjs | 已有防线 |
| a2ca64e | keep focus entry with split pane——分栏时保留专注入口 | 状态管理 | v1.8 | test_focus_mode_entry.mjs | 已有防线 |
| 48e00a5 | avoid duplicate focus and split controls——避免重复专注/分栏控件 | 状态管理 | v1.8 | test_split_layout_store.mjs | 已有防线 |
| cb01a58 | keep split entry in simple mode——简单模式保留分栏入口 | 状态管理 | v1.8 | test_split_layout_store.mjs | 已有防线 |
| 60f7b15 | restore split from focus mode——从专注恢复到分栏 | 状态管理 | v1.8 | test_split_layout_store.mjs | 已有防线 |
| 3b2860d | hide focus control without layout target——无布局目标时隐藏专注控件 | 状态管理 | v1.8 | test_focus_mode_entry.mjs | 已有防线 |
| c4b807c | sync focus mode exit control——同步专注退出控件 | 状态管理 | v1.8 | test_focus_mode_entry.mjs | 已有防线 |
| 8a59100 | unify workspace settings in more menu for v1.7——工作区设置统一到更多菜单 | 状态管理 | v1.7 | test_pane_more_menu_design.mjs | 已有防线 |
| 9ab0263 | restore workspace in a single startup render——单次启动渲染恢复工作区 | 状态管理 | — | test_workspace_startup_atomic_render.mjs | 已有防线 |

## ArkUI 布局与弹层

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 44fd846 | 菜单弹层改定宽224/272，修复constraintSize下百分比子项整屏撑开(faqs-arkui-95) | ArkUI 布局与弹层 | v1.32 | test_pane_more_menu_design.mjs, test_mobile_more_menu_design.mjs | 已有防线 |
| 295bd23 | 双屏收起目录后左缘残留分栏把手——包装节点宽度裁不掉内部根 Stack | ArkUI 布局与弹层 | v1.22 | test_split_handle.mjs, UiLaunch#split_handle_hidden_when_sidebar_collapsed | 已有防线 |
| 571e83e | 分栏把手删除拖动读数气泡并修复收起目录时左缘溢出渲染 | ArkUI 布局与弹层 | v1.22 | test_split_handle.mjs | 已有防线 |
| 36feeb3 | 分栏把手右半被右栏背景遮盖——zIndex 移到 SplitHandle 调用处生效 | ArkUI 布局与弹层 | — | test_split_handle.mjs | 已有防线 |
| 7f1667c | 导航把手胶囊对齐正文区垂直中心——把手容器不含 Appbar/Statusbar | ArkUI 布局与弹层 | — | test_split_handle.mjs | 已有防线 |
| 600ab9f | hs-row 行框对齐 v2 设计稿——min-height 56 随内容撑开，不再压 48 固定高 | ArkUI 布局与弹层 | — | test_settings_group_layout.mjs | 已有防线 |
| 1f5b74a | 快切卡片外点击关闭——弹层点击外部未关闭 | ArkUI 布局与弹层 | — | test_quick_switcher_logic.mjs | 已有防线 |
| eba2b3d | 按原型调整快切弹层布局 | ArkUI 布局与弹层 | — | test_quick_switcher_logic.mjs | 已有防线 |
| b6e795c | 使用放大镜图标打开快速切换 | ArkUI 布局与弹层 | — | test_vault_sidebar_keyboard.mjs | 已有防线 |
| 75e242b | 修复 Aa 面板旋转越界定位 | ArkUI 布局与弹层 | — | test_format_popup_bounds.mjs | 已有防线 |
| 5ffda83 | 修复 Aa 面板旋转定位（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| 40d4d6a | 修复 Aa 面板窗口夹边偏移 | ArkUI 布局与弹层 | — | test_format_popup_bounds.mjs | 已有防线 |
| 57a0fed | 修复双栏 Aa 面板越界 | ArkUI 布局与弹层 | — | test_format_popup_bounds.mjs | 已有防线 |
| b601800 | 修复 Aa 面板键盘遮挡 | ArkUI 布局与弹层 | — | test_prof_format_dock_design.mjs | 已有防线 |
| e33e175 | 单屏格式菜单改为贴底面板修复右缘截断 | ArkUI 布局与弹层 | — | test_simple_format_history_ui.mjs | 已有防线 |
| 984e3b9 | 文件树行左符号/文字/行尾加号没对齐——光学补偿清单漏了加号 | ArkUI 布局与弹层 | v0.2 | test_file_tree_snapshot.mjs | 已有防线 |
| a245fde | 文件树层级——每级 24vp 缩进 + 连续引导线，统一 depth 语义 | ArkUI 布局与弹层 | — | test_file_tree_snapshot.mjs | 已有防线 |
| 072d44f | 库切换卡片宽度溢出侧栏（width 100% + 水平 margin） | ArkUI 布局与弹层 | v0.2 | test_vault_menu_design.mjs | 已有防线 |
| 8da6380 | 库切换菜单/卡片照原型重排——vitem 16fp+brand_bg 选中、vbadge 全圆胶囊 | ArkUI 布局与弹层 | v0.2 | test_vault_menu_design.mjs | 已有防线 |
| f12d57a | 7 个对话框标题字号统一到原型 .ct 的 s3=18 | ArkUI 布局与弹层 | v0.2 | test_utility_dialog_shell.mjs, test_new_entry_dialog_design.mjs | 已有防线 |
| c24c6d6 | 双屏下恢复等分栏宽真正生效，并删掉三处死布局 | ArkUI 布局与弹层 | — | test_split_layout_store.mjs, test_pane_layout_md_widths.mjs | 已有防线 |
| 87c54e6 | 双屏态栏边界未对齐折痕，笔记被折痕劈开 | ArkUI 布局与弹层 | — | 不可自动化：真机折痕几何验证，x86 模拟器无折痕 | 不可自动化 |
| 98bc70d | 滑到底删除报「删除失败」——moveToTrash 从未创建 .trash 根目录 | ArkUI 布局与弹层 | v0.2 | test_trash_move_safety.mjs | 已有防线 |
| c9ef0f0 | 修复双屏分栏比例（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| b2e4c81 | 对齐双栏窄宽度响应布局（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| c3e411b | 汉堡推动动画对齐 v2 --nav-duration/--nav-curve（原型） | ArkUI 布局与弹层 | v0.9 | 根因已消除：原型已入库，动画 token 已提取 | 根因已消除 |
| 9a9f0ec | 补齐基础排版并规划预览缩放（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| 448bd6c | 统一Agent设置卡片正文与表单左边距（原型） | ArkUI 布局与弹层 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |
| 9d40088 | 修正数据设置说明宽度与按钮内边距（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| 0266085 | 复用笔记文件树并整理Agent对话布局（原型） | ArkUI 布局与弹层 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |
| 307b521 | 将Agent文字入口改为对话星芒图标（原型） | ArkUI 布局与弹层 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |
| b4f4ae8 | 将页脚链接指向 v2 设计说明（原型） | ArkUI 布局与弹层 | — | 根因已消除：原型已入库 | 根因已消除 |
| a4aa2b4 | 修「新建笔记」两个真 bug —— 点新建无弹窗 + 根级笔记被折叠目录误藏 | ArkUI 布局与弹层 | — | UiNoteFlow#create_note_dialog_open_and_cancel | 已有防线 |
| 225898c | 新建笔记末尾 / 边界对齐 App —— 拒绝「只要目录/」静默建成 md | ArkUI 布局与弹层 | — | test_new_entry_dialog_design.mjs | 已有防线 |

## 文件 IO 与原子性

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 4970d5c | AtomicFile 统一 end 收尾，修复 x86_64 模拟器删除笔记空副本 | 文件 IO 与原子性 | v1.34 | test_note_draft_recovery.mjs | 已有防线 |
| 05c97ad | 修复回收站根目录单级 mkdirSync 导致删除必然失败 | 文件 IO 与原子性 | v1.34 | test_trash_move_safety.mjs | 已有防线 |
| 846c4b0 | 回收站读回校验退避重试+撤销/恢复透出真实原因，修复 x86_64 间歇旧读致撤销失败 | 文件 IO 与原子性 | v1.34 | test_trash_restore_retry.mjs | 已有防线 |
| 2d0d164 | 回收站四处校验点错误信息细化到长度/差异位置/码点/错误码 | 文件 IO 与原子性 | v1.34 | test_trash_move_safety.mjs | 已有防线 |
| 8b0059b | 改用异步 AtomicFile 写入并记录 clone 诊断 | 文件 IO 与原子性 | — | test_git_import_draft_store.mjs | 已有防线 |
| da246ce | 改用 copyFile 保存相册图片 | 文件 IO 与原子性 | — | test_editor_local_image_access.mjs | 已有防线 |
| 9d2ae2a | 撤销时恢复右栏笔记 | 文件 IO 与原子性 | — | test_undo_bar_timer.mjs | 已有防线 |
| 81dd049 | 修正 CRLF 预览源码映射 | 文件 IO 与原子性 | — | test_preview_source_mapping.mjs | 已有防线 |
| 2bc0458 | 修复 Windows CRLF 与路径导致的 Node 回归失败 | 文件 IO 与原子性 | — | test_sample_vault.mjs（CRLF 归一） | 已有防线 |

## 焦点与键盘

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| a849690 | 修复关闭笔记空栏 requestFocus 150003 闪退 | 焦点与键盘 | v1.28 | test_pane_close.mjs | 已有防线 |
| 本轮 2026-11-08 DFX | 修复完成编辑 requestFocus 150003 闪退，全仓 22 处收口 FocusRequest.safely（api_notes L-19） | 焦点与键盘 | v0.2.0 | test_focus_keyboard_regression.mjs（收口模式 + 全仓裸调扫描）；EM-C11 人工 | 已补防线 |
| 本轮 2026-11-08 v1.46 | 兜底日志按官方错误码族区分 150001/150002/150003（api_notes L-20）；EntryAbility 安装 errorManager.setDefaultErrorHandler 全局 JS_CRASH 兜底；focusEmptyPane 撤除 setTimeout(0) 时序猜测改事件驱动（预查询 + onAppear，L-20 官方推荐）；修复 DFX 收口后 test_pane_close 两条陈旧防线（VM 缺 FocusRequest 注入） | 焦点与键盘 / 崩溃兜底 | v1.46 | test_focus_keyboard_regression.mjs（错误码分支 + focusId 不进日志 + CrashGuard 结构 + 安装点）；test_pane_close.mjs 15/15（目标对齐 + 事件驱动 + 150003 双路径不崩溃）；EM-C11 人工 | 已补防线 |
| 3e50b6e | 修复系统返回先收起导航 | 焦点与键盘 | — | test_settings_single_screen_back.mjs | 已有防线 |
| 01d95b7 | 将缩放控件移至独立底栏 | 焦点与键盘 | — | test_preview_zoom.mjs | 已有防线 |
| ad1f3d3 | 专注下点汉堡只推入/收回文件导航，不再退出专注 | 焦点与键盘 | — | test_focus_mode_entry.mjs | 已有防线 |
| c11c104 | 修正双屏专注退出后的导航焦点（原型） | 焦点与键盘 | — | 根因已消除：原型已入库 | 根因已消除 |
| 3411760 | 修复专注模式下汉堡导航无效 | 焦点与键盘 | — | test_focus_mode_entry.mjs | 已有防线 |
| bc788f1 | 对齐分类键盘焦点路径 | 焦点与键盘 | — | test_settings_keyboard.mjs | 已有防线 |
| 24a194e | 对齐单屏设置返回路径 | 焦点与键盘 | — | test_settings_single_screen_back.mjs | 已有防线 |
| a3341d2 | 对齐章节侧栏与键盘导航 | 焦点与键盘 | — | test_screen_reader_labels.mjs | 已有防线 |
| 26fac79 | 修复触摸预览正文焦点黑框 | 焦点与键盘 | — | test_preview_block_selection.mjs | 已有防线 |
| a1cb1b7 | 修复预览整栏焦点框 | 焦点与键盘 | — | test_preview_block_selection.mjs | 已有防线 |
| ee0f091 | 修复 v1.18 18.4 整栏焦点黑框 | 焦点与键盘 | v1.18 | test_preview_block_selection.mjs | 已有防线 |
| 本轮 2026-11-08 v1.46 46.4 | 修复简单模式段落宿主引擎焦点黑框（新聚焦目标回流，非 #content 回归；api_notes L-16） | 焦点与键盘 | v1.46 | test_preview_block_selection.mjs（可编辑宿主 outline 抑制断言）；EM 模拟器点按纯文本段落像素扫描无框 | 已补防线 |
| 本轮 2026-11-08 v1.46 46.6 | 修复 XT2 真机键盘双重避让：页面默认 OFFSET 整页上抬叠加格式栏 dock `margin(keyboardInset)` → dock 悬空键盘高度、聚焦末行被裁；显式 `setKeyboardAvoidMode(RESIZE)` 固定单一避让 + 删两 dock margin + Web 侧 resize 滚回光标行（api_notes L-21） | 焦点与键盘 | v1.46 | test_preview_block_selection.mjs（RESIZE 固定 + dock 无 margin + 产物滚动补齐断言）；XT2 真机验收（x86 模拟器 WM 收矮掩盖 OFFSET 路径，不可复现） | 已补防线 |
| 本轮 2026-11-08 v1.46 46.8 | 键盘避让 pivot（46.6 同日后续）：RESIZE 把键盘起落变成全窗口 resize → `windowSizeChange` 重发布 → 三栏 + 两 Web 全页重排，中文输入法弹起「整页刷新弹一遍」；改 `OFFSET_WITH_CARET`（since 14）+ 官方答复证实 UIContext 非 RESIZE 时 Web 默认 `RESIZE_CONTENT` 避让生效、会与页面上抬叠加双重避让 → `EditorWebView` / `PreviewWebView` 显式 `.keyboardAvoidMode(WebKeyboardAvoidMode.RETURN_TO_UICONTEXT)`（since 22，api_notes L-21） | 焦点与键盘 | v1.46 | test_preview_block_selection.mjs（OFFSET_WITH_CARET + 两 Web RETURN_TO_UICONTEXT + dock 无 margin 断言）；XT2 真机验收（模拟器 WM 收矮不可复现 OFFSET_WITH_CARET 路径） | 已补防线 |
| 5a0be23 | 简化单屏设置逐级返回（原型） | 焦点与键盘 | — | 根因已消除：原型已入库 | 根因已消除 |

## 日志与隐私

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 0829db7 | redact note data from logs——日志中脱敏笔记数据 | 日志与隐私 | v1.7 | test_editor_content_log_privacy.mjs | 已有防线 |
| 70d9d19 | 脱敏工作区与运行状态诊断日志 | 日志与隐私 | — | test_editor_content_log_privacy.mjs | 已有防线 |
| 6a8ec6b | 移除诊断日志中的笔记数据 | 日志与隐私 | — | test_editor_content_log_privacy.mjs | 已有防线 |
| a4cc0e3 | 移除文件树可见项数日志 | 日志与隐私 | — | test_editor_content_log_privacy.mjs | 已有防线 |
| 5795517 | 补齐预览日志脱敏 | 日志与隐私 | — | test_editor_content_log_privacy.mjs | 已有防线 |
| b3b9465 | 修复v1.34 34.5诊断输出白名单边界 | 日志与隐私 | v1.34 | test_build_commit_info.mjs | 已有防线 |

## Git 与桥接

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| c0043b4 | 签名 profile 必须与 keystore 同源，更正 FILE_ACCESS_PERSIST 授予口径 | Git 与桥接 | v1.5 | test_sync_page_git_auth.mjs | 已有防线 |
| aba518a | 导入 Git 仓库页导入态标题与顶栏重复，改为「仓库地址」 | Git 与桥接 | — | test_git_import_draft_store.mjs | 已有防线 |
| 3393b78 | 完善首发 Git 界面暂隐收口 | Git 与桥接 | — | test_git_sync_badge.mjs | 已有防线 |
| 601f14d | 完善首发 Git 界面暂隐收口（重复） | Git 与桥接 | — | test_git_sync_badge.mjs | 已有防线 |
| 184b03a | 修正 gitbridge 冒烟脚本路径 test/node_smoke.mjs | Git 与桥接 | — | 根因已消除：路径已修正且冒烟测试常态化 | 根因已消除 |
| d6c657d | 修复未闭合代码块切换并补充测试 | Git 与桥接 | — | test_markdown_inline_parser.mjs | 已有防线 |

## 构建链与签名

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 86dcb50 | 隔离模拟器不支持的AgentKit依赖 | 构建链与签名 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |
| 7e7f8ca | 隔离模拟器中的 AgentKit 启动依赖 | 构建链与签名 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |
| a06fc62 | 恢复系统 FunctionComponent 入口 | 构建链与签名 | — | 根因已消除：Agent 功能已删除 | 根因已消除 |

## Web 编辑器

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 7d755b4 | 编辑器失配/重载/开栏静默失败路径补齐错误日志 | Web 编辑器 | v1.7 | test_editor_mismatch_recovery.mjs | 已有防线 |
| c12a851 | 修复切换笔记时内容校验误判 | Web 编辑器 | — | test_editor_mismatch_recovery.mjs | 已有防线 |
| 6b44988 | 修复模式切换期间旧预览回写 | Web 编辑器 | — | test_editor_experience_transition.mjs | 已有防线 |
| ecbbd86 | 修复简单模式段距装饰边界 | Web 编辑器 | — | test_simple_format_history_ui.mjs | 已有防线 |
| 8436215 | 预览未就绪/未回内容不再拦住模式切换，失败 toast 带原因 | Web 编辑器 | — | test_editor_experience_transition.mjs | 已有防线 |
| caa24ab | 补齐 v1.19 19.1 组合输入回写保护 | Web 编辑器 | v1.19 | test_editor_composition_save.mjs | 已有防线 |
| 13fb930 | 修复主题切换后行号消失 | Web 编辑器 | — | test_editor_line_number_settings.mjs | 已有防线 |
| 0ae5914 | 修复行号默认隐藏与主题切换保持 | Web 编辑器 | — | test_editor_line_number_settings.mjs | 已有防线 |
| fb05048 | 修复格式栏遮挡笔记末行 | Web 编辑器 | — | test_prof_format_dock_design.mjs | 已有防线 |
| 2194851 | 避免断点切换重置阅读位置 | Web 编辑器 | — | test_preview_follow.mjs | 已有防线 |
| c475fd8 | 保持布局切换时阅读位置 | Web 编辑器 | — | test_preview_follow.mjs | 已有防线 |
| 1e77031 | 修复外层滚动时预览锚点定位 | Web 编辑器 | — | test_preview_follow.mjs | 已有防线 |
| d145e0f | 修复 WebView 重挂时的控制器崩溃 | Web 编辑器 | — | test_preview_webview_detach.mjs | 已有防线 |
| 439e178 | 修复简单模式分栏与编辑模式耦合 | Web 编辑器 | — | test_editor_experience_transition.mjs | 已有防线 |
| 67e0cd8 | 清空已删除笔记的编辑器缓存 | Web 编辑器 | — | test_deleted_note_editor_reset.mjs | 已有防线 |
| 799fb2f | protect extended markdown syntax in simple mode——简单模式下扩展 Markdown 语法保护 | Web 编辑器 | — | test_markdown_inline_parser.mjs | 已有防线 |
| d6c99fa | 修复20.4复杂链接保护与降级 | Web 编辑器 | v1.20 | test_complex_block_edit.mjs | 已有防线 |
| c112f53 | 阻止语法树未就绪时暴露块区间 | Web 编辑器 | — | test_block_context_toolbar.mjs | 已有防线 |

## 其他

| 来源 | bug 摘要 | 根因类别 | 涉及版本 | 防线 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 08c7d14 | 完成v1.34 34.6全范围失败回归 | 其他 | v1.34 | test_error_feedback.mjs | 已有防线 |
| be1e4bd | 完善v1.34 34.3切库与导入恢复 | 其他 | v1.34 | test_vault_switch_context.mjs | 已有防线 |
| 125af48 | 完善v1.34 34.2失败反馈 | 其他 | v1.34 | test_error_feedback.mjs | 已有防线 |
| 6686d4d | 补齐缩放重置图标的描边样式，对齐 v2 设计稿 | 其他 | — | test_preview_zoom.mjs | 已有防线 |
| 759168f | 23.2 保留远端链接分享 | 其他 | v1.23 | test_share_vault_access.mjs | 已有防线 |
| f674783 | v1.25 25.16 捕获分享异常并支持重试 | 其他 | v1.25 | test_share_capture_images.mjs | 已有防线 |
| 3604294 | 保留纯文本分享的链接目标 | 其他 | — | test_note_text_share.mjs | 已有防线 |
| 789925c | 保留行内代码原文 | 其他 | — | test_note_text_share.mjs | 已有防线 |
| 2660d4f | 拦截超限文本交接 | 其他 | — | test_note_text_share_handoff.mjs | 已有防线 |
| 9334583 | 保留首装标记并持久化空工作区 | 其他 | — | test_first_install_tutorial_note.mjs | 已有防线 |
| e8c3c86 | 修复库名空白前缀未去点 | 其他 | — | test_vault_registry_names.mjs | 已有防线 |
| 74b378a | 修复切库后旧内容残留 | 其他 | — | test_vault_switch_context.mjs | 已有防线 |
| a5573a9 | 对齐本地保存成功反馈 | 其他 | — | test_save_feedback_display.mjs | 已有防线 |
| f90216c | 对齐单屏更多菜单空态状态 | 其他 | — | test_mobile_more_menu_design.mjs | 已有防线 |
| d12e097 | 对齐双屏默认双栏布局 | 其他 | — | test_pane_layout.mjs | 已有防线 |
| 6ef86d7 | 对齐单屏顶栏紧凑间距 | 其他 | — | test_sidebar_compact_text.mjs | 已有防线 |
| 4afc299 | 对齐单屏入口与分享回退 | 其他 | — | test_share_scope_dialog.mjs | 已有防线 |
| 3f30051 | 移除笔记栏头选择入口 | 其他 | — | 根因已消除：入口已删除 | 根因已消除 |
| 8dc6b85 | 对齐 v2 笔记左滑按钮 | 其他 | — | test_vault_sidebar_keyboard.mjs | 已有防线 |
| 16f2de4 | 修正 v2 编辑栏与栏标题 | 其他 | — | test_pane_layout.mjs | 已有防线 |
| cfa3f73 | 修正 v2 工作区结构与交互布局 | 其他 | — | test_pane_layout.mjs | 已有防线 |
| 159225b | 按形态调整标题并简化库信息 | 其他 | — | test_vault_menu_design.mjs | 已有防线 |
| bcdc45b | 修正章节列表属性区解析 | 其他 | — | test_native_chapter_entries.mjs | 已有防线 |
| 22b4b12 | 保留编辑保护并校验回归 | 其他 | — | test_workspace_session_save_guard.mjs | 已有防线 |
| a642281 | 保留小艺本地笔记接线 | 其他 | — | test_xiaoyi_note_tools.mjs | 已有防线 |
| d125d10 | v1.18 18.4 修复段落点按误描边 | 其他 | v1.18 | test_preview_block_selection.mjs | 已有防线 |
| 8708121 | 修复v1.18 18.4点按误选整块 | 其他 | v1.18 | test_preview_block_selection.mjs | 已有防线 |
| 44242a1 | 顶栏设置/双栏图标对齐 v2 几何与按下态底色（v0.9） | 其他 | v0.9 | 根因已消除：token 已提取到 Tokens.ets | 根因已消除 |
| 21c71ed | 汉堡图标居中与样例库合并去重，补齐 Windows 工具链与产物同步（v0.9） | 其他 | v0.9 | test_sample_vault.mjs | 已有防线 |
| b010f7d | 关于页移除个人仓库链接，许可行改单行（v0.9） | 其他 | v0.9 | 根因已消除：链接已移除 | 根因已消除 |
| 5a19b5b | 需求 2.7c——库管理页返回入口去重（顶栏唯一） | 其他 | v0.1 | test_vault_manager_actions_design.mjs | 已有防线 |
| df5f239 | 需求 2.7b 补漏——去掉重复标题、返回语义按优先级分档 | 其他 | v0.1 | test_settings_single_screen_back.mjs | 已有防线 |
| 6ac72fc | 需求 2.7 验收记录回填与 SyncPage 返回能力遗留说明 | 其他 | v0.1 | 根因已消除：验收记录性质，非代码 bug | 根因已消除 |
| 493088a | 库管理视图顶栏返回箭头与系统返回拦截（需求 2.7） | 其他 | v0.1 | test_vault_manager_actions_design.mjs | 已有防线 |
| 7e1b660 | 次级页面补顶栏返回按钮，去掉重复大标题 | 其他 | — | test_settings_single_screen_back.mjs | 已有防线 |
| a91dd64 | 保持布局切换时工作区连续 | 其他 | — | test_editor_experience_store.mjs | 已有防线 |
| 8da6380 | 库切换菜单/卡片照原型重排 | 其他 | v0.2 | test_vault_menu_design.mjs | 已有防线 |

## 不可自动化条目明细

> 以下条目因环境/真机/视觉限制无法自动化，依赖 EM 人工用例或用户真机验收。
> 每条标注不可自动化原因、依赖的 EM 用例编号，以及是否已有 Node 源码防线加固。

| 来源 | bug 摘要 | 不可自动化原因 | 人工依赖 | Node 加固 |
| --- | --- | --- | --- | --- |
| 87c54e6 | 双屏态栏边界未对齐折痕 | x86 模拟器无折痕，折痕几何为真机硬件特征 | EM-A3 真机验收 | — |
| d145e0f | WebView 重挂时的控制器崩溃 | 控制器崩溃需真机环境复现，模拟器不触发 | EM-C9 真机验收 | — |
| a849690 | requestFocus 150003 闪退 | ~~150003 为真机焦点错误码，模拟器不触发~~ 已被 2026-11-08 模拟器 jscrash 实证推翻（见 api_notes L-19），模拟器同样触发；真机焦点表现仍待验收 | EM-L1 真机验收 | 已有防线 |
| 295bd23 | 双屏收起目录后左缘残留分栏把手 | 部分需双屏形态（UI 防线已覆盖宽屏可达部分） | EM-A3 真机验收 | 已有防线 |
| 1f5b74a | 快切卡片外点击关闭 | 弹层点击外部需模拟器触控验证，自动化无法模拟点击弹层外部 | EM-E1 人工 | — |
| eba2b3d | 快切弹层布局 | 弹层布局需目视验证，像素级断言不可靠 | EM-E1 人工 | — |
| 984e3b9 | 文件树行光学补偿 | 光学对齐需目视验收，自动化无法判断视觉对齐 | EM-B2 人工 | — |
| f12d57a | 7 个对话框标题字号统一 | 字号视觉验收需目视，UI 自动化不做像素断言 | EM-G1 人工 | — |
| c24c6d6 | 双屏恢复等分栏宽 | 分栏宽度需双屏形态验证，模拟器无折痕双屏 | EM-A3 真机验收 | — |
| 98bc70d | moveToTrash 从未创建 .trash 根目录 | Node 防线已覆盖逻辑；UI 路径需模拟器验证删除后恢复 | EM-B3 人工 | 已有防线 |
| 44fd846 | 菜单弹层整屏撑开(faqs-arkui-95) | 菜单宽度需目视验证，弹层是否撑开是渲染效果 | EM-G2 人工 | 已有防线 |
| 75e242b | Aa 面板旋转越界定位 | 面板定位需旋转场景验证，模拟器旋转行为与真机不同 | EM-C3 人工 | — |
| 40d4d6a | Aa 面板窗口夹边偏移 | 面板偏移需目视验收 | EM-C3 人工 | — |
| 57a0fed | 双栏 Aa 面板越界 | 双栏场景需模拟器验证弹层位置 | EM-C3 人工 | — |
| b601800 | Aa 面板键盘遮挡 | 键盘避让需模拟器输入法弹出场景 | EM-C3 人工 | — |
| e33e175 | 单屏格式菜单右缘截断 | 截断需目视验收，渲染效果 | EM-H1 人工 | — |
| 8dc6b85 | v2 笔记左滑按钮 | 左滑手势模拟器不可靠，无法稳定模拟滑动手势 | EM-B3 人工 | — |
| 01d95b7 | 缩放控件移至独立底栏 | 控件位置需目视验收 | EM-D1 人工 | — |
| ad1f3d3 | 专注下点汉堡行为 | 专注模式需双屏形态验证交互 | EM-A3 真机验收 | 已有防线 |
| 3411760 | 专注模式下汉堡导航无效 | 专注模式需双屏形态验证交互 | EM-A3 真机验收 | 已有防线 |
| 8436215 | 模式切换失败 toast | toast 需模拟器目视验证 | EM-C1 人工 | — |
| 0ae5914 | 行号默认隐藏与主题切换 | 行号渲染需目视验收 | EM-C1 人工 | — |
| 13fb930 | 主题切换后行号消失 | 行号渲染需目视验收 | EM-C1 人工 | — |
| fb05048 | 格式栏遮挡笔记末行 | 遮挡需目视验收 | EM-C3 人工 | — |
| 2194851 | 断点切换重置阅读位置 | 需断点切换场景，模拟器断点模拟与真机不一致 | EM-A4 人工 | — |
| c475fd8 | 布局切换时阅读位置 | 需断点切换场景 | EM-A4 人工 | — |
| 1e77031 | 外层滚动时预览锚点定位 | 锚点定位需目视验收 | EM-D1 人工 | — |
| 3e50b6e | 系统返回先收起导航 | 需模拟器系统返回验证，UI 自动化无法模拟系统返回键 | EM-L2 人工 | 已有防线 |
| 本轮 2026-11-08 v1.46 46.6 | 真机键盘双重避让（dock 悬空 + 末行被裁） | x86 模拟器 IME 走 WM 层窗口收矮（等价 RESIZE），OFFSET 缺陷不可复现 | XT2 真机验收 | test_preview_block_selection.mjs |
| 本轮 2026-11-08 v1.46 46.8 | 键盘起落全页重排（46.6 RESIZE 副作用）与 OFFSET_WITH_CARET 上抬效果（无重排 / dock 贴键盘 / Web 内末行光标可见） | 模拟器 IME 等价 RESIZE，OFFSET_WITH_CARET 路径不可复现；Web 内 contenteditable 光标感知官方未记载 | XT2 真机验收 | test_preview_block_selection.mjs |

## 本轮新修复

> 补测试过程中发现并修复的 bug 在此登记。

| 来源 | bug 摘要 | 根因类别 | 防线 | 状态 |
| --- | --- | --- | --- | --- |
| 本轮 2026-11-08 v1.46 46.7（U-01，用户报告） | 长图分享主按钮文案固化「正在排版…」——`UtilityDialogAction` 的 label 同为按值参数（EM-B2 只修了 enabled） | 状态管理 | test_utility_dialog_shell.mjs, test_share_image_preview.mjs | 已修复（XT2 真机待验收） |
| 本轮 2026-11-08 v1.46 46.9（V-01，用户裁定） | 失败提示不携带底层错误（自设规则撤销）：Git 导入 / 同步与 ZIP 导入失败的用户可见文案补底层错误原文，令牌仍脱敏；另修 `test_import_vault_dialog_design.mjs` 一条 f140b44 起过期的 `requestFocus(focusReturnId)` 源级断言 | 观测性 / 测试防线 | test_sync_page_git_auth.mjs, test_import_vault_dialog_design.mjs, test_zip_import.mjs, test_error_feedback.mjs | 已修复（XT2 真机待验收） |
| 本轮 2026-11-14 v1.46 46.9 追加（用户裁定） | Git 认证错误无法从 hilog 诊断 | 缺少本地错误日志与回调上下文 | clone 日志含 libgit2 类别、allowed_types 和凭据有无；令牌脱敏，不上报 | unsigned arm64-v8a HAP 构建通过；设备侧 hilog、API24 / XT2 失败链路待验 |
| 本轮 2026-11-14 v1.53 53.13（用户报告，LAP-AL10 复现） | PDF 分享多出一张只有水印的「空白」尾页——流内水印 footer 被 `preparePdfPages` 当分页内容块，内容恰好填满页时水印 margin 顶过页底单独成页；修复为分页前转固定右下徽标（不参与 bounds）、仅末页滚动位置显示，长图水印不变 | 分页 / 文档流 | web/mdpreview/test/share_watermark.test.mjs, test_pdf_pagination.mjs | 已修复（XT2 真机待验收） |
