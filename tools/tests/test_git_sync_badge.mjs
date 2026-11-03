import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

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
  currentVaultIsGit() { return this.gitVault; }
}
module.exports = GitSyncBadgeHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness({ gitVault = true, aheadCount = 0, fail = false } = {}) {
  const calls = [];
  const registry = {
    vaultDirOf(id) { calls.push(`path:${id}`); return `/isolated/${id}`; }
  };
  const module = { exports: {} };
  vm.runInContext(methodCode, vm.createContext({
    module,
    exports: module.exports,
    VaultRegistry: { get: () => registry },
    GitNativeService: {
      repositoryState(path) {
        calls.push(`state:${path}`);
        if (fail) throw new Error('test failure');
        return { aheadCount };
      }
    }
  }));
  const app = new module.exports();
  Object.assign(app, { currentVaultId: 'repo', gitVault, gitAheadCommitCount: 7 });
  return { app, calls };
}

test('Git home badge reflects local commits ahead of origin/xt2 without network work', () => {
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

test('repository errors clear stale badge state instead of showing a false count', () => {
  const { app } = createHarness({ fail: true });
  app.refreshGitAheadCommitCount();
  assert.equal(app.gitAheadCommitCount, 0);
});

test('badge data remains available but its top-bar and menu UI are hidden for v1.23', () => {
  const { app } = createHarness({ aheadCount: 123 });
  app.gitAheadCommitCount = 123;
  assert.equal(app.gitAheadBadgeLabel(), '99+');
  assert.match(source, /Text\(this\.gitAheadCommitCount\.toString\(\) \+ ' 个待推送'\)/);
  assert.match(source, /this\.GitSyncButton\(\)/);
  assert.match(source, /const GIT_UI_ENABLED: boolean = false/);
  assert.match(source, /if \(GIT_UI_ENABLED && this\.currentVaultIsGit\(\)\) \{\s*this\.GitAheadBadge\(\)/);
  assert.match(source, /if \(GIT_UI_ENABLED && this\.currentVaultIsGit\(\)\) \{\s*this\.GitSyncButton\(\)/);
});

test('badge refresh runs when Index appears and when its registry snapshot changes', () => {
  assert.match(source, /this\.currentVaultId = reg\.currentId\(\)[\s\S]*?this\.refreshGitAheadCommitCount\(\);/);
  assert.match(source, /onPageShow\(\): void \{[\s\S]*?this\.refreshGitAheadCommitCount\(\);/);
});
