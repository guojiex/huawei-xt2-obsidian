import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const shareFlowSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${startMarker}`);
  return source.slice(start, end).trim();
}

const methodCode = transformSync(`
class GitSyncBadgeHarness {
  ${method('  private refreshGitAheadCommitCount(): void {', '\n  private gitAheadBadgeLabel()')}
  ${method('  private gitAheadBadgeLabel(): string {', '\n  private async openGitSyncPage(')}
}
module.exports = GitSyncBadgeHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness({
  gitVault = true,
  aheadCount = 0,
  trackingKnown = true,
  fail = false
} = {}) {
  const calls = [];
  const registry = {
    currentEntry() { return gitVault ? { id: 'repo', type: 'git', pushBranch: 'phone/notes' } : null; },
    vaultDirOf(id) { calls.push(`path:${id}`); return `/isolated/${id}`; }
  };
  const module = { exports: {} };
  vm.runInContext(methodCode, vm.createContext({
    module,
    exports: module.exports,
    VaultRegistry: { get: () => registry },
    GitNativeService: {
      repositoryState(path, branch) {
        calls.push(`state:${path}`);
        assert.equal(branch, 'phone/notes');
        if (fail) throw new Error('test failure');
        return { aheadCount, trackingKnown };
      }
    }
  }));
  const app = new module.exports();
  Object.assign(app, { currentVaultId: 'repo', gitVault, gitAheadCommitCount: 7 });
  return { app, calls };
}

test('Git home badge reflects local commits ahead of its configured branch without network work', () => {
  const { app, calls } = createHarness({ aheadCount: 3 });
  app.refreshGitAheadCommitCount();
  assert.equal(app.gitAheadCommitCount, 3);
  assert.equal(app.gitAheadBadgeLabel(), '3');
  assert.deepEqual(calls, ['path:repo', 'state:/isolated/repo']);
  assert.doesNotMatch(method('  private refreshGitAheadCommitCount(): void {', '\n  private gitAheadBadgeLabel()'), /GitNativeService\.action/);
});

test('non-Git vaults clear the badge without reading the Native repository state', () => {
  const { app, calls } = createHarness({ gitVault: false, aheadCount: 12 });
  app.refreshGitAheadCommitCount();
  assert.equal(app.gitAheadCommitCount, 0);
  assert.deepEqual(calls, []);
});

test('missing configured tracking references never produce a push badge', () => {
  const { app, calls } = createHarness({ aheadCount: 5, trackingKnown: false });
  app.refreshGitAheadCommitCount();
  assert.equal(app.gitAheadCommitCount, 0);
  assert.deepEqual(calls, ['path:repo', 'state:/isolated/repo']);
});

test('repository errors clear stale badge state instead of showing a false count', () => {
  const { app } = createHarness({ fail: true });
  app.refreshGitAheadCommitCount();
  assert.equal(app.gitAheadCommitCount, 0);
});

test('Git entry visibility does not gate remote-link sharing', () => {
  const { app } = createHarness({ aheadCount: 123 });
  app.gitAheadCommitCount = 123;
  assert.equal(app.gitAheadBadgeLabel(), '99+');
  // v1.31 31.4：单屏菜单待推送改为蓝底圆形计数徽标（gitAheadBadgeLabel），不再是链接样式小字
  assert.match(source, /Text\(this\.gitAheadBadgeLabel\(\)\)/);
  assert.match(source, /' 个提交待推送'/);
  assert.doesNotMatch(source, /' 个待推送'/);
  assert.match(source, /this\.GitSyncButton\(\)/);
  assert.match(source, /const GIT_ENTRY_UI_ENABLED: boolean = true/);
  assert.match(source, /if \(GIT_ENTRY_UI_ENABLED && this\.currentVaultIsGit\(\)\) \{\s*this\.GitAheadBadge\(\)/);
  assert.match(source, /if \(GIT_ENTRY_UI_ENABLED && this\.currentVaultIsGit\(\)\) \{\s*this\.GitSyncButton\(\)/);
  // openShareDialog（含分享范围与格式选项构建）已随分享域拆至 ShareFlowPanel
  const shareDialogStart = shareFlowSource.indexOf('  private openShareDialog(scope: ShareLinkScope');
  const shareDialog = shareFlowSource.slice(shareDialogStart,
    shareFlowSource.indexOf('\n  build() {', shareDialogStart));
  assert.match(shareDialog, /value: 'file', label: 'Markdown \/ ZIP'/);
  assert.match(shareDialog, /if \(vault\.type === 'git' && focusReturnId\.length === 0\) \{[\s\S]*?value: 'link'/);
  assert.doesNotMatch(shareDialog, /GIT_ENTRY_UI_ENABLED/);
});

test('badge refresh runs when Index appears and when its registry snapshot changes', () => {
  assert.match(source, /this\.currentVaultId = reg\.currentId\(\)[\s\S]*?this\.refreshGitAheadCommitCount\(\);/);
  assert.match(source, /onPageShow\(\): void \{[\s\S]*?this\.refreshGitAheadCommitCount\(\);/);
});

test('sync dialog does not restore entry focus while a busy dismiss is blocked', () => {
  assert.match(source, /cancel: \(\): void => \{\s*if \(!this\.gitSyncBusy\) \{\s*restoreFocus\(\);/);
  assert.match(source, /onWillDismiss: \(action: DismissDialogAction\): void => \{\s*if \(!this\.gitSyncBusy\) \{\s*action\.dismiss\(\);/);
});
