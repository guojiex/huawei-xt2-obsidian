/*
 * Git 同步逐行差异——native 数据层 + ArkTS 接线契约测试（v1.75 数据链，v1.76 全屏页形态）。
 *
 * 锁五件事：
 * 1. native getFileDiffs 用 git_diff 提取 HEAD↔工作区差异、处理 untracked、过滤二进制/trash、有上限与导出；
 * 2. 两份 Index.d.ts 类型同步（getFileDiffs + Git2FileDiff 等）；
 * 3. GitNativeService.fileDiffs 包装 + GitSyncDialog 手风琴展开/统计/读屏/按需取数；
 * 4. 隐私红线：diff 路径与正文不进 hilog（native 与 ETS 均无日志化 diff 文本）；
 * 5. v1.76：GitSyncDialog 为全屏 @Component（无 CustomDialog shell），Index 以 topView='gitsync' 路由。
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
  // v1.76：点选改为右栏查看，读屏文案从「展开」改为「查看」。
  assert.match(dialog, /\.accessibilityText\(\(this\.expandedDiffPath === change\.path \? '收起' : '查看'\)/);
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
  assert.match(dialog, /backgroundColor\(this\.expandedDiffPath === change\.path\s*\?\s*\$r\('app\.color\.brand_bg'\)/);
  // ESC still closes, via onDismiss callback (no controller.close)
  assert.match(dialog, /event\.keyCode === KeyCode\.KEYCODE_ESCAPE/);
  assert.ok(!/controller\?\.close\(\)/.test(dialog));
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
