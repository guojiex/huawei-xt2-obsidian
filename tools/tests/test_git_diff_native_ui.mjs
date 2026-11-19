/*
 * Git 同步逐行差异——native 数据层 + ArkTS 接线契约测试（v1.75 数据链，v1.76 全屏页形态）。
 *
 * 锁五件事：
 * 1. native getFileDiffs 用 git_diff 提取 HEAD↔工作区差异、处理 untracked、过滤二进制/trash、有上限与导出；
 * 2. 两份 Index.d.ts 类型同步（getFileDiffs + Git2FileDiff 等）；
 * 3. GitNativeService.fileDiffs 包装 + GitSyncDialog 手风琴展开/统计/读屏/按需取数；
 * 4. 隐私红线：diff 路径与正文不进 hilog（native 与 ETS 均无日志化 diff 文本）；
 * 5. v1.76：GitSyncDialog 为全屏 @Component（无 CustomDialog shell），Index 以 topView='gitsync' 路由；
 * 6. v1.87：同步页画布 / 白卡 / 状态行 / diff 查看器样式逐项对齐原型 sync CSS（nav 画布、396 左栏、纸底页脚）。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const nativeSrc = readSourceFile(new URL('../../native/git2_napi/src/libgit2_napi.c', import.meta.url));
const dtsMain = readSourceFile(new URL('../../entry/src/main/cpp/types/libgit2_napi/Index.d.ts', import.meta.url));
const dtsTest = readSourceFile(new URL('../../entry/src/ohosTest/cpp/types/libgit2_napi/Index.d.ts', import.meta.url));
const service = readSourceFile(new URL('../../entry/src/main/ets/git/GitNativeService.ets', import.meta.url));
const dialog = readSourceFile(new URL('../../entry/src/main/ets/components/GitSyncDialog.ets', import.meta.url));
const indexEts = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const tokens = readSourceFile(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));

test('native getFileDiffs uses HEAD vs worktree diff and handles all change kinds', () => {
  assert.match(nativeSrc, /git_diff_tree_to_workdir_with_index\(&diff, repository, tree, &diff_opts\)/);
  assert.match(nativeSrc, /git_diff_foreach\(diff, yaoshi_diff_file_cb, NULL, NULL, yaoshi_diff_line_cb, &collect\)/);
  assert.match(nativeSrc, /GIT_DIFF_LINE_ADDITION/);
  assert.match(nativeSrc, /GIT_DIFF_LINE_DELETION/);
  assert.match(nativeSrc, /GIT_DIFF_LINE_CONTEXT/);
  // untracked/added files read whole from disk as additions
  assert.match(nativeSrc, /git_blob_create_from_workdir\(&oid, repo, path\)/);
  assert.match(nativeSrc, /yaoshi_diff_collect_untracked\(&collect, repository\)/);
  // binary + trash filtered
  assert.match(nativeSrc, /GIT_DIFF_FLAG_BINARY/);
  assert.match(nativeSrc, /is_trash_path\(path\)/);
});

test('native enforces size/line limits and exports getFileDiffs', () => {
  assert.match(nativeSrc, /#define YAOSHI_DIFF_DEFAULT_MAX_FILES 50/);
  assert.match(nativeSrc, /#define YAOSHI_DIFF_DEFAULT_MAX_LINES 2000/);
  assert.match(nativeSrc, /f->truncated = true; return;/);
  assert.match(nativeSrc, /{"getFileDiffs", NULL, get_file_diffs,/);
  // repo open serialized with the same mutex as getRepositoryState
  assert.match(nativeSrc, /pthread_mutex_lock\(&g_clone_mutex\)/);
});

test('both Index.d.ts declare diff types and getFileDiffs identically', () => {
  assert.equal(dtsMain, dtsTest, 'main and ohosTest type declarations must be identical');
  for (const dts of [dtsMain, dtsTest]) {
    assert.match(dts, /getFileDiffs\(path: string, options\?: Git2DiffOptions\): Git2FileDiffs;/);
    assert.match(dts, /export interface Git2DiffLine \{/);
    assert.match(dts, /origin: '\+' \| '-' \| ' ';/);
    assert.match(dts, /export interface Git2FileDiff \{/);
    assert.match(dts, /truncated: boolean;/);
  }
});

test('GitNativeService wraps fileDiffs via dynamic native module', () => {
  assert.match(service, /Git2DiffOptions/);
  assert.match(service, /Git2FileDiffs/);
  assert.match(service, /static async fileDiffs\(path: string, options\?: Git2DiffOptions\): Promise<Git2FileDiffs>/);
  assert.match(service, /native\.getFileDiffs/);
});

test('GitSyncDialog: accordion expand, cached stats, on-demand fallback, no re-render of commit draft', () => {
  assert.match(dialog, /Git2FileDiff/);
  assert.match(dialog, /Git2DiffLine/);
  assert.match(dialog, /@State expandedDiffPath: string = ''/);
  assert.match(dialog, /@State diffVersion: number = 0/);
  assert.match(dialog, /private diffCache: Map<string, Git2FileDiff \| null>/);
  // one native call preloads all diffs from refreshLocalStatus
  assert.match(dialog, /void this\.loadFileDiffs\(\)/);
  assert.match(dialog, /GitNativeService\.fileDiffs\(/);
  // accordion: clicking the expanded path collapses it
  assert.match(dialog, /if \(this\.expandedDiffPath === path\) \{[\s\S]*?this\.expandedDiffPath = '';/);
  // cache hit avoids another native call; toggle never touches commitMessage
  assert.match(dialog, /const cached: Git2FileDiff \| null \| undefined = this\.diffCache\.get\(path\)/);
  const toggle = dialog.slice(dialog.indexOf('  private async toggleDiff'), dialog.indexOf('  private defaultCommitMessage'));
  assert.ok(!toggle.includes('commitMessage'), 'toggleDiff must not modify commit message draft');
});

test('GitSyncDialog: diff UI reuses tokens, announces delete/add, and never logs content', () => {
  assert.match(dialog, /@Builder\s+private DiffPanel/);
  assert.match(dialog, /@Builder\s+private DiffLineRow/);
  assert.match(dialog, /origin === '\+' \? \$r\('app\.color\.success_bg'\)/);
  assert.match(dialog, /origin === '-' \? \$r\('app\.color\.danger_bg'\)/);
  assert.match(dialog, /−|'删除行 '|'新增行 '/);
  // v1.76：点选改为右栏查看，读屏文案从「展开」改为「查看」。v1.79 单屏走纯信息文案，宽屏仍为查看/收起。
  assert.match(dialog, /this\.singleScreen\s*\n?\s*\? \(change\.status === 'A'/);
  assert.match(dialog, /: \(this\.expandedDiffPath === change\.path \? '收起' : '查看'\) \+ ' ' \+ change\.path/);
  // privacy: no logging of diff text/path anywhere in the dialog
  assert.ok(!/hilog\.[a-zA-Z]+\([^)]*line\.text/.test(dialog));
  assert.ok(!/console\.[a-zA-Z]+\([^)]*change\.path/.test(dialog));
  const diffFns = nativeSrc.slice(nativeSrc.indexOf('static void yaoshi_diff_push_line'),
    nativeSrc.indexOf('static napi_value get_file_diffs'));
  assert.ok(!/LOG|DLOG|HILOG|printf|fprintf/.test(diffFns), 'native diff helpers must not log content');
});

// ---- v1.76: full-screen sync page (topView='gitsync') ----
test('GitSyncDialog is a full-screen @Component, no CustomDialog shell', () => {
  assert.match(dialog, /@Component\s+export struct GitSyncDialog/);
  assert.ok(!/@CustomDialog/.test(dialog), 'no CustomDialog decorator');
  assert.ok(!/UtilityDialogShell\(\{/.test(dialog), 'no dialog shell builder call');
  assert.ok(!/controller\?/.test(dialog), 'no CustomDialogController field');
  // right-pane diff, left list selection
  assert.match(dialog, /@Builder\s+private DiffPane\(\)/);
  assert.match(dialog, /private selectedChange\(\): Git2FileChange \| null/);
  // v1.79：宽屏选中态保留品牌底色；单屏不选中（无右栏 diff）。
  assert.match(dialog, /backgroundColor\(!this\.singleScreen && this\.expandedDiffPath === change\.path\s*\?\s*\$r\('app\.color\.brand_bg'\)/);
  // ESC still closes, via onDismiss callback (no controller.close)
  assert.match(dialog, /event\.keyCode === KeyCode\.KEYCODE_ESCAPE/);
  assert.ok(!/controller\?\.close\(\)/.test(dialog));
});

test('v1.77 native sync page defaults to first diff and groups left pane into cards', () => {
  // 打开页面即选中首个缓存命中的差异文件，右栏不再是空白占位。
  assert.match(dialog, /private autoSelectFirstDiff\(\): void/);
  assert.match(dialog, /this\.diffVersion\+\+;\s*this\.autoSelectFirstDiff\(\);/);
  assert.match(dialog, /this\.expandedDiffPath = change\.path;\s*this\.activeFileDiff = cached;/);
  // 左栏两张白卡分组 + 提交者字段标注必填 + 主按钮禁用原因。
  assert.match(dialog, /Text\('推送概览'\)/);
  assert.match(dialog, /Text\('本地改动'\)/);
  assert.match(dialog, /Text\('提交者名称 · 必填'\)/);
  assert.match(dialog, /Text\('提交者邮箱 · 必填'\)/);
  assert.match(dialog, /Text\('填写提交者名称与邮箱后可提交并推送'\)/);
  // diff 卡头有状态徽章与增删统计；行号两列有独立底色，形成代码栏。
  const diffPanel = dialog.slice(dialog.indexOf('  private DiffPanel'),
    dialog.indexOf('  @Builder\n  private DiffLineRow'));
  assert.match(diffPanel, /Text\(change\.status\)/);
  assert.match(diffPanel, /this\.diffStatOf\(change\.path\)/);
  const lineRow = dialog.slice(dialog.indexOf('  private DiffLineRow'),
    dialog.indexOf('  @Builder\n  private BranchEditor'));
  assert.equal((lineRow.match(/\.backgroundColor\(\$r\('app\.color\.bg_secondary'\)\)/g) || []).length, 2);
});

test('Index routes gitsync as a full-screen topView with appbar back + focus restore', () => {
  assert.match(indexEts, /@State gitsyncReturnView: string = 'note';/);
  assert.match(indexEts, /this\.topView = 'gitsync';/);
  assert.match(indexEts, /this\.topView === 'gitsync'\s*\)\s*\{\s*return '同步到 Git';/);
  assert.match(indexEts, /else if \(this\.topView === 'gitsync'\)\s*\{\s*this\.GitSyncPane\(\)/);
  assert.match(indexEts, /@Builder\s+GitSyncPane\(\)/);
  assert.match(indexEts, /onDismiss: \(\): void => \{ this\.returnFromGitSync\(\); \}/);
  assert.match(indexEts, /private returnFromGitSync\(\): void/);
  assert.match(indexEts, /if \(this\.gitSyncBusy\)\s*\{\s*return;\s*\}/);
});

test('v1.79 single-screen sync page drops diff and scrolls the whole changes+commit flow', () => {
  // 单屏分支只有一个整页 Scroll(DialogContent)，不再渲染 DiffPane。
  const build = dialog.slice(dialog.indexOf('  build() {'));
  const singleBranch = build.slice(build.indexOf('if (this.singleScreen)'),
    build.indexOf('} else {'));
  assert.ok(singleBranch.includes('Scroll() { this.DialogContent() }'));
  assert.ok(!singleBranch.includes('this.DiffPane()'), 'no diff pane on single screen');
  // 宽屏分支仍渲染 DiffPane（v1.78 铺满 diff 不变）。
  const wideBranch = build.slice(build.indexOf('} else {'), build.indexOf('Column() {\n        this.DialogFooter'));
  assert.ok(wideBranch.includes('this.DiffPane()'), 'wide screens keep the diff pane');
  // 清单在单屏下不限高、内层滚动关闭、手势交父。
  assert.match(dialog, /\.height\(this\.singleScreen \? undefined\s*: Math\.min\(Size\.touch \* 4/);
  assert.match(dialog, /\.scrollBar\(this\.singleScreen \? BarState\.Off : BarState\.Auto\)/);
  assert.match(dialog, /scrollForward: this\.singleScreen \? NestedScrollMode\.PARENT_FIRST/);
  // 副文案在单屏下不再是「点文件在右侧核对正文」。
  assert.match(dialog, /this\.singleScreen \? '上报的本地改动' : '点文件在右侧核对正文'/);
});

// ---- v1.87: sync page canvas/cards aligned to prototype sync CSS ----
test('v1.87 sync page canvas: nav background, fixed side pane, footer as paper bar', () => {
  const build = dialog.slice(dialog.indexOf('  build() {'));
  // 画布 --nav 底（bg_navigation），内容全部落在白卡上。
  assert.match(build, /\.backgroundColor\(\$r\('app\.color\.bg_navigation'\)\)/);
  // 单屏整页滚动带 --s4 画布内缩（原型 phone 下 .sync-side padding --s4）。
  const singleBranch = build.slice(build.indexOf('if (this.singleScreen)'),
    build.indexOf('} else {'));
  assert.match(singleBranch, /\.padding\(Space\.s4\)/);
  // 宽屏左栏固定 396（Size.syncSideW = sidebarW * 1.65）+ 右侧 1px 分隔线，不再用 40% 弹性宽。
  const wideBranch = build.slice(build.indexOf('} else {'),
    build.indexOf('Column() {\n        this.DialogFooter'));
  assert.match(wideBranch, /\.width\(Size\.syncSideW\)/);
  assert.ok(!/width\('40%'\)/.test(wideBranch), 'side pane width is fixed, not 40%');
  assert.match(wideBranch, /\.border\(\{ width: \{ right: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  // 页脚：--paper 底（bg_card）+ 上分隔线 + padding --s3/--s5（原型 .sync-page-foot）。
  const footer = build.slice(build.indexOf('Column() {\n        this.DialogFooter'));
  assert.match(footer, /\.border\(\{ width: \{ top: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  assert.match(footer, /\.backgroundColor\(\$r\('app\.color\.bg_card'\)\)/);
  assert.match(footer, /\.padding\(\{ left: Space\.s5, right: Space\.s5, top: Space\.s3, bottom: Space\.s3 \}\)/);
  assert.match(tokens, /static readonly syncSideW: number = Size\.sidebarW \* 1\.65;/);
});

test('v1.87 sync page cards: bordered white cards, block heads, inner nav status card', () => {
  // 两张白卡都有 1px 边线（原型 .sync-card 描边），卡头 min-height --s12 + 底部分隔线 + 标题 600。
  assert.equal((dialog.match(/\.border\(\{ width: 1, color: \$r\('app\.color\.line'\) \}\)/g) || []).length, 2);
  assert.equal((dialog.match(/constraintSize\(\{ minHeight: Space\.s12 \}\)/g) || []).length, 2);
  assert.match(dialog, /Text\('推送概览'\)[\s\S]*?fontWeight\(Weight\.semibold\)/);
  assert.match(dialog, /Text\('本地改动'\)[\s\S]*?fontWeight\(Weight\.semibold\)/);
  // 状态行包进 --nav 底 + --small-r 圆角内卡（原型 .sync-block-body>.sync-card）。
  assert.match(dialog, /\.backgroundColor\(\$r\('app\.color\.bg_navigation'\)\)\n\s+\.borderRadius\(Radius\.control\)/);
  // 卡体 padding --s2/--s3/--s3（原型 .sync-block-body）。
  assert.match(dialog,
    /\.padding\(\{ left: Space\.s3, right: Space\.s3, top: Space\.s2, bottom: Space\.s3 \}\)/);
  // 状态行：标签宽 --s16、值 600、行高下限 calc(--s12 + --s1)、左 --s4 右 --s2（原型 .sync-row）。
  const statusRow = dialog.slice(dialog.indexOf('  private StatusRow'),
    dialog.indexOf('  private ChangeRow'));
  assert.match(statusRow, /\.width\(Space\.s16\)/);
  assert.match(statusRow, /fontWeight\(Weight\.semibold\)/);
  assert.match(statusRow, /constraintSize\(\{ minHeight: Space\.s12 \+ Space\.s1 \}\)/);
  assert.match(statusRow, /\.padding\(\{ left: Space\.s4, right: Space\.s2, top: Space\.s2, bottom: Space\.s2 \}\)/);
  // 文件行选中态：--s1 品牌色左边轨 + 文件名 600 + 统计品牌色（原型 .sync-file-toggle）。
  const changeRow = dialog.slice(dialog.indexOf('  private ChangeRow'),
    dialog.indexOf('  private DiffPane'));
  assert.match(changeRow, /\.border\(\{ width: \{ left: Space\.s1 \},/);
  assert.match(changeRow, /color: !this\.singleScreen && this\.expandedDiffPath === change\.path\s*\?\s*\$r\('app\.color\.brand'\)/);
  assert.match(changeRow, /fontWeight\(!this\.singleScreen && this\.expandedDiffPath === change\.path\s*\?\s*Weight\.semibold : FontWeight\.Normal\)/);
  assert.match(changeRow, /fontColor\(!this\.singleScreen && this\.expandedDiffPath === change\.path\s*\?\s*\$r\('app\.color\.brand'\)/);
});

test('v1.87 diff viewer: paper pane, header rules, numbered code columns', () => {
  // 右栏整体 --paper 底（原型 .sync-detail / .sync-file-diff 落在 --paper 上）。
  const diffPane = dialog.slice(dialog.indexOf('  private DiffPane'),
    dialog.indexOf('  private DiffPanel'));
  assert.match(diffPane, /fontWeight\(Weight\.semibold\)/);
  assert.match(diffPane, /\.backgroundColor\(\$r\('app\.color\.bg_card'\)\)/);
  // diff 卡头 padding --s3/--s5 + 底部分隔线（原型 .sync-diff-head）；查看器底 --paper。
  const diffPanel = dialog.slice(dialog.indexOf('  private DiffPanel'),
    dialog.indexOf('  @Builder\n  private DiffLineRow'));
  assert.match(diffPanel,
    /\.padding\(\{ left: Space\.s5, right: Space\.s5, top: Space\.s3, bottom: Space\.s3 \}\)\n\s+\.border\(\{ width: \{ bottom: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  assert.match(diffPanel, /\.backgroundColor\(\$r\('app\.color\.bg_card'\)\)/);
  // 行号两列各带右分隔线（原型 .dl-no border-right --line），底色列数不变。
  const lineRow = dialog.slice(dialog.indexOf('  private DiffLineRow'),
    dialog.indexOf('  @Builder\n  private BranchEditor'));
  assert.equal((lineRow.match(/\.border\(\{ width: \{ right: 1 \}, color: \$r\('app\.color\.line'\) \}\)/g) || []).length, 2);
  assert.equal((lineRow.match(/\.backgroundColor\(\$r\('app\.color\.bg_secondary'\)\)/g) || []).length, 2);
});
