import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url));

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate SyncPage method ${startMarker}`);
  return source.slice(start, end).trim();
}

const classCode = transformSync(`
const IMPORTING_SUFFIX = '__importing';
class SyncPageGitAuthHarness {
  ${method('  private async doClone(): Promise<void> {', '\n  private isGitHubRemote(')}
  ${method('  private remoteHost(', '\n  private urlHasInlineCredentials(')}
  ${method('  private urlHasInlineCredentials(', '\n  private refreshSyncStatus(')}
  ${method('  private explainError(', '\n  /** 将导入到的库 id')}
  previewVaultId() { return 'isolated-repo'; }
  appendLog(line) { this.logs.push(line); }
  onCloneDone(ok, message) { this.cloneResult = { ok, message }; }
  constructor() { this.logs = []; this.cloneResult = null; }
}
module.exports = SyncPageGitAuthHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function harness({
  clonePathMismatch = false,
  cloneError = null,
  state = { clean: true, branch: 'main' }
} = {}) {
  const cloneCalls = [];
  const registryCalls = [];
  const toasts = [];
  const registry = {
    uniqueVaultId(id) { registryCalls.push('unique:' + id); return id + '-tmp'; },
    beginGitImport(finalId, tempId) { registryCalls.push(`begin:${finalId}:${tempId}`); },
    vaultDirOf(id) { registryCalls.push('path:' + id); return '/isolated/' + id; }
  };
  const module = { exports: {} };
  vm.runInContext(classCode, vm.createContext({
    module,
    exports: module.exports,
    VaultRegistry: { get: () => registry },
    GitNativeService: {
      async clone(options) {
        cloneCalls.push(options);
        if (cloneError !== null) throw cloneError;
        return clonePathMismatch ? '/unexpected/path' : options.targetPath;
      },
      repositoryState() { return state; },
      progressLabel() { return 'progress'; }
    },
    promptAction: { showToast: (toast) => toasts.push(toast.message) }
  }));
  const page = new module.exports();
  Object.assign(page, {
    repoUrl: '',
    branch: 'main',
    token: '',
    username: '',
    busy: false,
    progressText: '',
    logs: [],
    pendingFinalId: '',
    pendingTempId: '',
    appendLog(line) { this.logs.push(line); },
    onCloneDone(ok, message) {
      this.cloneResult = { ok, message };
      if (!ok) this.appendLog('导入失败：' + this.explainError(message));
    }
  });
  return { page, cloneCalls, registryCalls, toasts };
}

test('GitHub clone sends the token as bearer auth and omits username/password', async () => {
  const f = harness();
  f.page.repoUrl = 'https://github.com/team/repo.git';
  f.page.token = 'synthetic-token';

  await f.page.doClone();

  assert.equal(f.cloneCalls.length, 1);
  assert.equal(f.cloneCalls[0].bearerToken, 'synthetic-token');
  assert.equal('username' in f.cloneCalls[0], false);
  assert.equal('password' in f.cloneCalls[0], false);
  assert.equal(f.page.cloneResult.ok, true);
});

test('Gitee clone sends Basic credentials as username/password and requires a username', async () => {
  const f = harness();
  f.page.repoUrl = 'https://gitee.com/team/repo.git';
  f.page.username = 'synthetic-user';
  f.page.token = 'synthetic-token';

  await f.page.doClone();

  assert.equal(f.cloneCalls.length, 1);
  assert.equal(f.cloneCalls[0].username, 'synthetic-user');
  assert.equal(f.cloneCalls[0].password, 'synthetic-token');
  assert.equal('bearerToken' in f.cloneCalls[0], false);

  const missingUser = harness();
  missingUser.page.repoUrl = 'https://gitee.com/team/repo.git';
  missingUser.page.token = 'synthetic-token';
  await missingUser.page.doClone();
  assert.deepEqual(missingUser.cloneCalls, []);
  assert.match(missingUser.toasts[0], /需要填写用户名/);
});

test('credential-bearing URL components are rejected before Native clone', async () => {
  for (const url of [
    'https://user:token@github.com/team/repo.git',
    'https://gitee.com/team/repo.git?access_token=synthetic-token',
    'https://gitee.com/team/repo.git?AUTH=secret'
  ]) {
    const f = harness();
    f.page.repoUrl = url;
    await f.page.doClone();
    assert.deepEqual(f.cloneCalls, [], url);
    assert.match(f.toasts[0], /移除地址中的认证信息/);
  }
});

test('authentication failures stay actionable, redact the token, and do not register a library', async () => {
  const token = 'synthetic-secret-token';
  const f = harness({ cloneError: new Error('HTTP 401 token=' + token) });
  f.page.repoUrl = 'https://github.com/team/repo.git';
  f.page.token = token;

  await f.page.doClone();

  assert.equal(f.page.cloneResult.ok, false);
  assert.ok(!f.page.cloneResult.message.includes(token));
  assert.match(f.page.logs.join('\n'), /认证失败/);
  assert.ok(!f.page.logs.join('\n').includes(token));
  assert.equal(f.registryCalls.some((call) => call.startsWith('register:')), false);
  assert.equal(f.registryCalls.some((call) => call.startsWith('finish:')), false);
});

test('GitHub detection matches the host rather than an arbitrary containing domain', () => {
  const f = harness();
  assert.equal(f.page.isGitHubRemote('https://github.com/team/repo.git'), true);
  assert.equal(f.page.isGitHubRemote('https://WWW.GITHUB.COM:443/team/repo.git'), true);
  assert.equal(f.page.isGitHubRemote('https://github.com.attacker.example/team/repo.git'), false);
  assert.equal(f.page.isGitHubRemote('https://gitee.com/team/repo.git'), false);
});

test('common authentication, missing repository and network errors receive actionable messages', () => {
  const f = harness();
  assert.match(f.page.explainError('HTTP 401'), /认证失败/);
  f.page.repoUrl = 'https://github.com/team/repo.git';
  assert.match(f.page.explainError('HTTP 401'), /GitHub 认证失败/);
  assert.doesNotMatch(f.page.explainError('HTTP 401'), /Gitee 用户名/);
  f.page.repoUrl = 'https://gitee.com/team/repo.git';
  assert.match(f.page.explainError('HTTP 401'), /Gitee 认证失败/);
  assert.match(f.page.explainError('NotFound 404'), /仓库或分支不存在/);
  assert.match(f.page.explainError('ECONNREFUSED'), /网络不可达/);
  assert.equal(f.page.explainError('unclassified failure'), '原因未确定，请检查网络、仓库地址和当前库状态后重试');
});

test('clone refuses a mismatched returned directory or unexpected branch before success', async () => {
  const wrongPath = harness({ clonePathMismatch: true });
  wrongPath.page.repoUrl = 'https://github.com/team/repo.git';
  await wrongPath.page.doClone();
  assert.equal(wrongPath.page.cloneResult.ok, false);
  assert.match(wrongPath.page.cloneResult.message, /目录与隔离目标不一致/);

  const wrongBranch = harness({ state: { clean: true, branch: 'trunk' } });
  wrongBranch.page.repoUrl = 'https://github.com/team/repo.git';
  await wrongBranch.page.doClone();
  assert.equal(wrongBranch.page.cloneResult.ok, false);
  assert.match(wrongBranch.page.cloneResult.message, /分支或工作区状态校验失败/);
});
