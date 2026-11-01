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

function extract(startMarker, endMarker) {
  const start = dialogSource.indexOf(startMarker);
  const end = dialogSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate ImportVaultDialog method ${startMarker}`);
  return dialogSource.slice(start, end).trim();
}

const harnessCode = transformSync(`
class ImportVaultDialogHarness {
  ${extract('  private chooseSource(', '\n  private continueGit')}
  ${extract('  private continueGit(): void {', '\n  @Builder')}
  constructor() {
    this.source = 'local';
    this.busy = false;
    this.gitRemote = '';
    this.gitBranch = 'main';
    this.closed = 0;
    this.drafts = [];
    this.controller = { close: () => { this.closed++; } };
    this.onContinueGit = draft => this.drafts.push(draft);
  }
}
module.exports = ImportVaultDialogHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const module = { exports: {} };
  vm.runInContext(harnessCode, vm.createContext({ module, exports: module.exports }));
  return new module.exports();
}

test('import dialog matches the v2 title, close action and shared segmented source control', () => {
  assert.match(dialogSource, /Text\('导入库'\)/);
  assert.match(dialogSource, /accessibilityText\('关闭导入库'\)/);
  assert.match(dialogSource, /Text\('把已有的笔记，带进你的工作台。'\)/);
  assert.match(dialogSource, /Row\(\{ space: Space\.s1 \}\) \{\s*this\.SourceTab\('本地目录', 'local'\)\s*this\.SourceTab\('Git 仓库', 'git'\)\s*\}/);
  assert.match(dialogSource, /\.padding\(Space\.s1\)\s*\.borderRadius\(Radius\.full\)\s*\.backgroundColor\(\$r\('app\.color\.bg_secondary'\)\)/);
  assert.match(dialogSource, /@State source: string = 'local'/);
});

test('local directory card shows selection affordance and the non-copy/remove boundary', () => {
  assert.match(dialogSource, /Text\('使用手机里的笔记目录'\)/);
  assert.match(dialogSource, /Icon\('folder', Space\.s6, \$r\('app\.color\.brand'\)\)/);
  assert.match(dialogSource, /this\.hasDirectorySelection \? this\.directoryName : '选择本地目录'/);
  assert.match(dialogSource, /从系统目录选择器中选择文件夹/);
  assert.match(dialogSource, /直接读写原目录，不复制文件。移除库只解除关联，原目录和文件保留。/);
  assert.match(dialogSource, /this\.onChooseDirectory\(\)/);
});

test('Git source follows the prototype form and leaves credentials to the existing secure SyncPage', () => {
  assert.match(dialogSource, /Text\('连接远端 Git 仓库'\)/);
  assert.match(dialogSource, /Text\('仓库地址'\)/);
  assert.match(dialogSource, /placeholder: 'https:\/\/github\.com\/用户名\/仓库\.git'/);
  assert.match(dialogSource, /Text\('分支'\)/);
  const gitForm = dialogSource.slice(dialogSource.indexOf("Text('仓库地址')"), dialogSource.indexOf("Text('GitHub / Gitee"));
  assert.equal((gitForm.match(/\.alignItems\(HorizontalAlign\.Start\)/g) || []).length, 2);
  assert.match(dialogSource, /Text\(this\.busy \? '处理中…' : '导入 Git 仓库'\)/);
  assert.doesNotMatch(dialogSource, /Access Token|用户名（Gitee|gitToken|gitUsername/);
  assert.match(dialogSource, /username: '',\s*token: ''/);
  assert.match(syncSource, /TextInput\(\{ placeholder: '私有库填 Access Token/);
  assert.match(syncSource, /TextInput\(\{ placeholder: '用户名（仅 Gitee/);
  assert.match(indexSource, /onContinueGit: \(draft: GitImportDraft\): void => \{\s*void this\.openGitSyncPage\(draft\);/);
});

test('Git handoff keeps remote and branch while guarding blank input and busy state', () => {
  const dialog = createHarness();
  dialog.continueGit();
  assert.equal(dialog.closed, 0);
  assert.equal(dialog.drafts.length, 0);

  dialog.gitRemote = '  https://github.com/team/notes.git  ';
  dialog.gitBranch = '  release  ';
  dialog.continueGit();
  assert.equal(dialog.closed, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(dialog.drafts[0])), {
    remote: 'https://github.com/team/notes.git',
    branch: 'release',
    username: '',
    token: ''
  });

  dialog.busy = true;
  dialog.continueGit();
  assert.equal(dialog.closed, 1);
  assert.equal(dialog.drafts.length, 1);
});

test('narrow and short windows keep the dialog within bounds and scroll the content area', () => {
  assert.match(dialogSource, /Math\.max\(0, Math\.min\(Size\.drawerW, this\.windowWidthVp - Space\.s6\)\)/);
  assert.match(dialogSource, /\.constraintSize\(\{ maxHeight: Math\.max\(0, this\.windowHeightVp - Space\.s8 \* 6\) \}\)/);
  assert.match(dialogSource, /\.constraintSize\(\{ maxHeight: this\.windowHeightVp \}\)/);
  assert.match(indexSource, /windowWidthVp: this\.windowWidthVp,\s*windowHeightVp: this\.windowHeightVp/);
});
