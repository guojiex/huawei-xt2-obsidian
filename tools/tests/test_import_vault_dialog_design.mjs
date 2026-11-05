import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const dialogSource = readSourceFile(new URL('../../entry/src/main/ets/components/ImportVaultDialog.ets', import.meta.url));
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const syncSource = readSourceFile(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url));
const vaultManagerSource = readSourceFile(new URL('../../entry/src/main/ets/components/VaultManagerView.ets', import.meta.url));
const utilityShellSource = readSourceFile(new URL('../../entry/src/main/ets/components/UtilityDialogShell.ets', import.meta.url));

function extract(startMarker, endMarker) {
  const start = dialogSource.indexOf(startMarker);
  const end = dialogSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate ImportVaultDialog method ${startMarker}`);
  return dialogSource.slice(start, end).trim();
}

const harnessCode = transformSync(`
class ImportVaultDialogHarness {
  ${extract('  private setWorking(', '\n  private isGiteeRemote(')}
  ${extract('  private isGiteeRemote(', '\n  private clearGitCredentials(')}
  ${extract('  private clearGitCredentials(', '\n  private toggleGitTokenVisibility(')}
  ${extract('  private toggleGitTokenVisibility(', '\n  private close(')}
  ${extract('  private close(', '\n  aboutToDisappear(')}
  ${extract('  aboutToDisappear(): void {', '\n  private chooseSource(')}
  ${extract('  private chooseSource(', '\n  private hasPicked(')}
  ${extract('  private hasPicked(', '\n  private continueGit(')}
  ${extract('  private continueGit(', '\n  @Builder')}
  constructor() {
    this.source = 'local';
    this.working = false;
    this.pickedName = '';
    this.directoryState = 'unselected';
    this.directoryStatus = '';
    this.associating = false;
    this.busyChanges = [];
    this.gitRemote = '';
    this.gitBranch = 'main';
    this.gitUsername = '';
    this.gitToken = '';
    this.showGitToken = false;
    this.gitAuthHint = '';
    this.closed = 0;
    this.drafts = [];
    this.calls = [];
    this.pickResult = null;
    this.pickError = false;
    this.associateResult = false;
    this.controller = { close: () => { this.closed++; } };
    this.onContinueGit = draft => this.drafts.push(draft);
    this.onCancel = () => { this.cancelled = true; };
    this.onBusyChange = busy => this.busyChanges.push(busy);
    this.onChooseDirectory = async () => {
      this.calls.push('choose');
      if (this.pickError) {
        throw new Error('private picker detail');
      }
      return this.pickResult;
    };
    this.onAssociateDirectory = async () => { this.calls.push('associate'); return this.associateResult; };
  }
}
module.exports = ImportVaultDialogHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const module = { exports: {} };
  vm.runInContext(harnessCode, vm.createContext({ module, exports: module.exports }));
  return new module.exports();
}

/** harness 跑在 vm realm 里，数组跨 realm 直接 deepEqual 会失败，先做一次 JSON 往返。 */
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

test('import dialog exposes local and Git sources and defaults to local', () => {
  assert.match(dialogSource, /title: '导入库'/);
  assert.match(dialogSource, /closeLabel: '关闭导入库'/);
  assert.match(dialogSource, /subtitle: '关联已有的 Markdown 笔记目录'/);
  assert.match(dialogSource, /@State source: string = 'local'/);
  const content = dialogSource.slice(
    dialogSource.indexOf('  DialogContent() {'),
    dialogSource.indexOf('  @Builder\n  DialogFooter()')
  );
  assert.match(content, /this\.SourceTab\('本地目录', 'local'\)/);
  assert.match(content, /this\.SourceTab\('Git 仓库', 'git'\)/);
  assert.match(dialogSource, /\.onClick\(\(\) => \{ this\.chooseSource\(value\); \}\)/);
  assert.match(dialogSource, /\.scrollBar\(BarState\.Off\)\s*\.margin\(\{ top: Space\.s4 \}\)/);
});

test('source tabs ignore changes while the import dialog is busy', () => {
  const dialog = createHarness();
  dialog.chooseSource('git');
  assert.equal(dialog.source, 'git');
  dialog.working = true;
  dialog.chooseSource('local');
  assert.equal(dialog.source, 'git');
});

test('local directory card exposes three states and the non-copy/remove boundary', () => {
  assert.match(dialogSource, /return this\.directoryState === 'failed' \? '未获得目录授权' : '选择笔记目录'/);
  assert.match(dialogSource, /return '系统授权目录 · 关联后直接读写'/);
  assert.match(dialogSource, /没有登记知识库，可重新选择目录。/);
  assert.match(dialogSource, /return this\.directoryState === 'failed' \? '重试' : '选择'/);
  assert.match(dialogSource, /this\.DirectoryFact\('link', '直接使用原目录', '不复制文件，笔记改动直接写回该目录'\)/);
  assert.match(dialogSource, /this\.DirectoryFact\('check', '移除只解除关联', '原目录和其中的文件都会保留'\)/);
  assert.match(dialogSource, /\.focusable\(!this\.working\)[\s\S]*?\.id\('import-directory-card'\)[\s\S]*?\.accessibilityText\(this\.directoryCardAccessibilityText\(\)\)/);
  assert.doesNotMatch(dialogSource, /selection\.uri|rootUri/);
  assert.match(dialogSource, /void this\.pickDirectory\(\)/);
});

test('existing Git libraries stay listed and can still be selected locally', () => {
  assert.match(vaultManagerSource, /ForEach\(this\.vaults, \(v: VaultEntry\)/);
  assert.match(vaultManagerSource, /this\.Tag\(v\.rootKind === 'external' \? '本地目录' : \(v\.type === 'git' \? 'Git' : '本地'\)/);
  assert.match(vaultManagerSource, /this\.onSetCurrent\(v\.id\)/);
  assert.match(vaultManagerSource, /每个库在应用中独立管理/);
  assert.doesNotMatch(vaultManagerSource, /各自独立同步/);
});

test('Git source collects provider credentials in the dialog and documents safe storage', () => {
  assert.match(dialogSource, /Text\('连接远端 Git 仓库'\)/);
  assert.match(dialogSource, /Text\('仓库地址'\)/);
  assert.match(dialogSource, /placeholder: 'https:\/\/github\.com\/用户名\/仓库\.git'/);
  assert.match(dialogSource, /Text\('分支'\)/);
  assert.match(dialogSource, /if \(this\.isGiteeRemote\(\)\) \{[\s\S]*?Text\('用户名'\)/);
  assert.match(dialogSource, /TextInput\(\{ placeholder: 'Gitee 用户名', text: this\.gitUsername \}\)/);
  assert.match(dialogSource, /TextInput\(\{ placeholder: '私有仓库访问令牌', text: this\.gitToken \}\)/);
  assert.match(dialogSource, /\.type\(this\.showGitToken \? InputType\.Normal : InputType\.Password\)/);
  assert.match(dialogSource, /accessibilityText\(this\.showGitToken \? '隐藏访问令牌' : '显示访问令牌'\)/);
  assert.match(dialogSource, /GitHub 使用 Bearer；Gitee 使用用户名和令牌/);
  assert.match(dialogSource, /成功后存入本机安全存储，关闭弹窗会清空输入。不会写入地址、日志或普通设置，可在同步页更换/);
  assert.match(dialogSource, /UtilityDialogAction\(this\.working \? '处理中…' : '导入 Git 仓库', 'primary',\s*this\.singleScreen, this\.gitRemote\.trim\(\)\.length > 0 && !this\.working/);
  assert.match(dialogSource, /username: username,\s*token: this\.gitToken/);
  assert.match(syncSource, /TextInput\(\{ placeholder: '私有库填 Access Token/);
  assert.match(indexSource, /onContinueGit: \(draft: GitImportDraft\): void => \{\s*void this\.openGitSyncPage\(draft\);/);
  assert.match(indexSource, /GitImportDraftStore\.set\(draft\);[\s\S]*?router\.pushUrl\(\{ url: 'pages\/SyncPage' \}\)/);
  assert.match(indexSource, /cancel: \(\): void => \{\s*if \(!this\.importVaultDialogBusy\) \{\s*clearImportDraft\(\);/);
  assert.match(indexSource, /onCancel: clearImportDraft/);
});

test('Git handoff keeps credentials in memory and clears dialog state before navigation', () => {
  const dialog = createHarness();
  dialog.continueGit();
  assert.equal(dialog.closed, 0);
  assert.equal(dialog.drafts.length, 0);

  dialog.gitRemote = '  https://gitee.com/team/notes.git  ';
  dialog.gitBranch = '  release  ';
  dialog.gitToken = 'synthetic-token';
  dialog.continueGit();
  assert.equal(dialog.closed, 0, 'Gitee token requires its username');
  assert.equal(dialog.drafts.length, 0);
  assert.match(dialog.gitAuthHint, /填写对应用户名/);

  dialog.gitUsername = ' synthetic-user ';
  dialog.continueGit();
  assert.equal(dialog.closed, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(dialog.drafts[0])), {
    remote: 'https://gitee.com/team/notes.git',
    branch: 'release',
    username: 'synthetic-user',
    token: 'synthetic-token'
  });
  assert.equal(dialog.gitUsername, '');
  assert.equal(dialog.gitToken, '');
  assert.equal(dialog.showGitToken, false);

  dialog.working = true;
  dialog.continueGit();
  assert.equal(dialog.closed, 1);
  assert.equal(dialog.drafts.length, 1);
});

test('closing or dismissing the import dialog clears credentials and visibility state', () => {
  const dialog = createHarness();
  dialog.gitUsername = 'synthetic-user';
  dialog.gitToken = 'synthetic-token';
  dialog.showGitToken = true;
  dialog.close();
  assert.equal(dialog.gitUsername, '');
  assert.equal(dialog.gitToken, '');
  assert.equal(dialog.showGitToken, false);
  assert.equal(dialog.closed, 1);
  assert.equal(dialog.cancelled, true);

  dialog.gitToken = 'another-synthetic-token';
  dialog.showGitToken = true;
  dialog.aboutToDisappear();
  assert.equal(dialog.gitToken, '');
  assert.equal(dialog.showGitToken, false);
});

test('picked directory lives in dialog @State, not in a @Prop the parent cannot refresh', () => {
  // CustomDialog 的 @Prop 不随父组件状态刷新：父在弹窗打开后置位的值传不进来，
  // 「关联此目录」会一直是灰的。弹窗必须自己持有选中状态。
  assert.doesNotMatch(dialogSource, /@Prop hasDirectorySelection|@Prop directoryName|@Prop busy/);
  assert.match(dialogSource, /@State pickedName: string = ''/);
  assert.match(dialogSource, /@State directoryState: string = 'unselected'/);
  assert.match(dialogSource, /@State directoryStatus: string = ''/);
  assert.match(dialogSource, /@State working: boolean = false/);
  assert.match(dialogSource, /UtilityDialogAction\(this\.associating \? '正在关联…' : '关联此目录', 'primary',\s*this\.singleScreen, this\.hasPicked\(\) && !this\.working/);
  assert.match(indexSource, /onChooseDirectory: \(\): Promise<string \| null> => this\.chooseExternalDirectory\(\)/);
  assert.match(indexSource, /onAssociateDirectory: \(\): Promise<boolean> => this\.associateExternalDirectory\(\)/);
  assert.match(indexSource, /onBusyChange: \(busy: boolean\): void => \{ this\.importVaultDialogBusy = busy; \}/);
  assert.match(indexSource, /onWillDismiss: \(action: DismissDialogAction\): void => \{\s*if \(!this\.importVaultDialogBusy\) \{\s*action\.dismiss\(\);/);
  assert.match(indexSource, /this\.pendingExternalDirectory = null;\s*this\.showFailureFeedback\('authorization', 'permission', 'unknown', 'status_unknown'/);
  assert.match(indexSource, /restoreImportFocus\(\);[\s\S]*?this\.importVaultDialogBusy = false;\s*this\.importVaultCtl\?\.close\(\)/);
  assert.match(indexSource, /vault-manager-import-button/);
  assert.match(vaultManagerSource, /\.focusable\(true\)\s*\.id\('vault-manager-import-button'\)/);
  assert.doesNotMatch(indexSource, /importHasDirectorySelection|importDirectoryName/);
  assert.match(utilityShellSource, /\.onClick\(onClick\)\s*\.focusable\(keyboardFocusable && enabled\)/);
});

test('directory pick updates the dialog state and releases the busy guard', async () => {
  const dialog = createHarness();
  dialog.pickResult = null;
  await dialog.pickDirectory();
  assert.equal(dialog.pickedName, '', 'cancelled pick must not enable the associate button');
  assert.equal(dialog.hasPicked(), false);
  assert.equal(dialog.directoryState, 'unselected');
  assert.equal(dialog.directoryStatus, '已取消选择');
  assert.equal(dialog.working, false);
  assert.deepEqual(plain(dialog.calls), ['choose']);

  dialog.pickResult = '笔记';
  await dialog.pickDirectory();
  assert.equal(dialog.pickedName, '笔记');
  assert.equal(dialog.directoryState, 'selected');
  assert.equal(dialog.directoryStatus, '');
  assert.equal(dialog.hasPicked(), true);
  assert.equal(dialog.working, false);

  dialog.pickResult = null;
  await dialog.pickDirectory();
  assert.equal(dialog.pickedName, '笔记', 'cancel after selection must preserve the previous directory');
  assert.equal(dialog.directoryState, 'selected');
  assert.equal(dialog.directoryStatus, '已取消选择');
});

test('picker failure shows a retry state without exposing the raw error', async () => {
  const dialog = createHarness();
  dialog.pickError = true;
  await dialog.pickDirectory();
  assert.equal(dialog.directoryState, 'failed');
  assert.equal(dialog.directoryStatus, '目录授权未完成；没有登记知识库，请重新选择目录。');
  assert.equal(dialog.hasPicked(), false);
  assert.equal(dialog.directoryStatus.includes('private picker detail'), false);
  assert.deepEqual(plain(dialog.busyChanges), [true, false]);
});

test('pending picker locks duplicate taps and dialog dismissal until it returns', async () => {
  const dialog = createHarness();
  let finishPick;
  dialog.onChooseDirectory = () => {
    dialog.calls.push('choose');
    return new Promise(resolve => { finishPick = resolve; });
  };

  const picking = dialog.pickDirectory();
  assert.equal(dialog.working, true);
  dialog.close();
  await dialog.pickDirectory();
  assert.equal(dialog.closed, 0, 'dismissal must not race an active picker');
  assert.deepEqual(plain(dialog.calls), ['choose'], 'a second tap must not open another picker');

  finishPick(null);
  await picking;
  assert.equal(dialog.directoryState, 'unselected');
  assert.equal(dialog.directoryStatus, '已取消选择');
  assert.equal(dialog.working, false);
  assert.deepEqual(plain(dialog.busyChanges), [true, false]);
});

test('associate runs only after a pick and stays open when the parent reports failure', async () => {
  const dialog = createHarness();
  await dialog.associateDirectory();
  assert.deepEqual(plain(dialog.calls), [], 'associate must not run without a picked directory');
  assert.equal(dialog.working, false);

  dialog.pickedName = '笔记';
  dialog.directoryState = 'selected';
  dialog.associateResult = false;
  await dialog.associateDirectory();
  assert.deepEqual(plain(dialog.calls), ['associate']);
  assert.equal(dialog.working, false, 'a failed associate must release the busy guard so it can be retried');
  assert.equal(dialog.associating, false);
  assert.equal(dialog.directoryState, 'failed');
  assert.match(dialog.directoryStatus, /没有登记知识库，原目录未改写/);
  assert.equal(dialog.pickedName, '笔记', 'failure keeps the chosen display name available for context');
  assert.equal(dialog.closed, 0, 'the dialog stays open; the parent owns closing on success');
});

test('narrow and short windows keep the dialog within bounds and scroll the content area', () => {
  assert.match(dialogSource, /preferredWidthVp: Size\.importDialogW/);
  assert.match(dialogSource, /singleScreen: this\.singleScreen/);
  assert.match(dialogSource, /\.constraintSize\(\{ maxHeight: Math\.max\(0, this\.windowHeightVp - Space\.s8 \* 6\) \}\)/);
  assert.match(dialogSource, /UtilityDialogShell\(\{[\s\S]*?scrollContent: false,[\s\S]*?content: this\.DialogContent,[\s\S]*?footer: this\.DialogFooter/);
  assert.match(dialogSource, /\.focusable\(!this\.working\)[\s\S]*?\.id\('import-directory-card'\)/);
  assert.match(dialogSource, /UtilityDialogAction\('取消', 'secondary', this\.singleScreen, !this\.working/);
  assert.match(indexSource, /singleScreen: importSheet,[\s\S]*?windowWidthVp: this\.windowWidthVp,\s*windowHeightVp: this\.windowHeightVp/);
  assert.match(indexSource, /alignment: importSheet \? DialogAlignment\.Bottom : DialogAlignment\.Center/);
  assert.match(indexSource, /requestFocus\(focusReturnId\)/);
});
