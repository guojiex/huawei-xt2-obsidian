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

function extract(startMarker, endMarker) {
  const start = dialogSource.indexOf(startMarker);
  const end = dialogSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate ImportVaultDialog method ${startMarker}`);
  return dialogSource.slice(start, end).trim();
}

const harnessCode = transformSync(`
class ImportVaultDialogHarness {
  ${extract('  private isGiteeRemote(', '\n  private clearGitCredentials(')}
  ${extract('  private clearGitCredentials(', '\n  private toggleGitTokenVisibility(')}
  ${extract('  private toggleGitTokenVisibility(', '\n  private close(')}
  ${extract('  private close(', '\n  aboutToDisappear(')}
  ${extract('  aboutToDisappear(): void {', '\n  private chooseSource(')}
  ${extract('  private chooseSource(', '\n  @Builder')}
  constructor() {
    this.source = 'local';
    this.working = false;
    this.pickedName = '';
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
    this.associateResult = false;
    this.controller = { close: () => { this.closed++; } };
    this.onContinueGit = draft => this.drafts.push(draft);
    this.onCancel = () => { this.cancelled = true; };
    this.onChooseDirectory = async () => { this.calls.push('choose'); return this.pickResult; };
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
  assert.match(dialogSource, /Text\('导入库'\)/);
  assert.match(dialogSource, /accessibilityText\('关闭导入库'\)/);
  assert.match(dialogSource, /Text\('把已有的笔记，带进你的工作台。'\)/);
  assert.match(dialogSource, /@State source: string = 'local'/);
  const build = dialogSource.slice(dialogSource.indexOf('  build() {'));
  assert.match(build, /this\.SourceTab\('本地目录', 'local'\)/);
  assert.match(build, /this\.SourceTab\('Git 仓库', 'git'\)/);
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

test('local directory card shows selection affordance and the non-copy/remove boundary', () => {
  assert.match(dialogSource, /Text\('使用手机里的笔记目录'\)/);
  assert.match(dialogSource, /Icon\('folder', Space\.s6, \$r\('app\.color\.brand'\)\)/);
  assert.match(dialogSource, /this\.hasPicked\(\) \? this\.pickedName : '选择本地目录'/);
  assert.match(dialogSource, /从系统目录选择器中选择文件夹/);
  assert.match(dialogSource, /直接读写原目录，不复制文件。移除库只解除关联，原目录和文件保留。/);
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
  assert.match(dialogSource, /Text\(this\.working \? '处理中…' : '导入 Git 仓库'\)/);
  assert.match(dialogSource, /username: username,\s*token: this\.gitToken/);
  assert.match(syncSource, /TextInput\(\{ placeholder: '私有库填 Access Token/);
  assert.match(indexSource, /onContinueGit: \(draft: GitImportDraft\): void => \{\s*void this\.openGitSyncPage\(draft\);/);
  assert.match(indexSource, /GitImportDraftStore\.set\(draft\);[\s\S]*?router\.pushUrl\(\{ url: 'pages\/SyncPage' \}\)/);
  assert.match(indexSource, /cancel: \(\): void => \{\s*GitImportDraftStore\.clear\(\);/);
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
  assert.match(dialogSource, /@State working: boolean = false/);
  assert.match(dialogSource, /\.enabled\(this\.hasPicked\(\) && !this\.working\)/);
  assert.match(indexSource, /onChooseDirectory: \(\): Promise<string \| null> => this\.chooseExternalDirectory\(\)/);
  assert.match(indexSource, /onAssociateDirectory: \(\): Promise<boolean> => this\.associateExternalDirectory\(\)/);
  assert.doesNotMatch(indexSource, /importHasDirectorySelection|importDirectoryName|importVaultBusy/);
});

test('directory pick updates the dialog state and releases the busy guard', async () => {
  const dialog = createHarness();
  dialog.pickResult = null;
  await dialog.pickDirectory();
  assert.equal(dialog.pickedName, '', 'cancelled pick must not enable the associate button');
  assert.equal(dialog.hasPicked(), false);
  assert.equal(dialog.working, false);
  assert.deepEqual(plain(dialog.calls), ['choose']);

  dialog.pickResult = '笔记';
  await dialog.pickDirectory();
  assert.equal(dialog.pickedName, '笔记');
  assert.equal(dialog.hasPicked(), true);
  assert.equal(dialog.working, false);
});

test('associate runs only after a pick and stays open when the parent reports failure', async () => {
  const dialog = createHarness();
  await dialog.associateDirectory();
  assert.deepEqual(plain(dialog.calls), [], 'associate must not run without a picked directory');
  assert.equal(dialog.working, false);

  dialog.pickedName = '笔记';
  dialog.associateResult = false;
  await dialog.associateDirectory();
  assert.deepEqual(plain(dialog.calls), ['associate']);
  assert.equal(dialog.working, false, 'a failed associate must release the busy guard so it can be retried');
  assert.equal(dialog.closed, 0, 'the dialog stays open; the parent owns closing on success');
});

test('narrow and short windows keep the dialog within bounds and scroll the content area', () => {
  assert.match(dialogSource, /Math\.max\(0, Math\.min\(Size\.drawerW, this\.windowWidthVp - Space\.s6\)\)/);
  assert.match(dialogSource, /\.constraintSize\(\{ maxHeight: Math\.max\(0, this\.windowHeightVp - Space\.s8 \* 6\) \}\)/);
  assert.match(dialogSource, /\.constraintSize\(\{ maxHeight: this\.windowHeightVp \}\)/);
  assert.match(indexSource, /windowWidthVp: this\.windowWidthVp,\s*windowHeightVp: this\.windowHeightVp/);
});
