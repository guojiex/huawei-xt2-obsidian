import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url));
// 2026-11-13 起 GitHub/Gitee 判定与认证赋值收敛到 git/GitRemoteAuth.ets 单一真源，
// harness 把它剥掉 import/export 后内联进同一脚本作用域；独立模块用只剥 import 的版本。
const gitAuthRaw = readSourceFile(new URL('../../entry/src/main/ets/git/GitRemoteAuth.ets', import.meta.url))
  .replace(/^import .*;\n/gm, '');
const gitAuthSource = gitAuthRaw.replace(/^export /gm, '');

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate SyncPage method ${startMarker}`);
  return source.slice(start, end).trim();
}

const classCode = transformSync(
  'const GIT_IMPORTING_SUFFIX = \'__importing\';\n' +
  gitAuthSource + '\n' +
  'class SyncPageGitAuthHarness {\n' +
  method('  private async doClone(): Promise<void> {', '\n  private urlHasInlineCredentials(') + '\n' +
  method('  private urlHasInlineCredentials(', '\n  private refreshSyncStatus(') + '\n' +
  method('  private explainError(', '\n  private previewVaultId(): string {') + '\n' +
  `  previewVaultId() { return 'isolated-repo'; }
  appendLog(line) { this.logs.push(line); }
  onCloneDone(ok, message) { this.cloneResult = { ok, message }; }
  constructor() { this.logs = []; this.cloneResult = null; }
}
module.exports = SyncPageGitAuthHarness;
`, { loader: 'ts', format: 'cjs' }).code;

const actionCode = transformSync(
  gitAuthSource + '\n' +
  'class SyncPageActionHarness {\n' +
  method('  private syncFailureDetail(', '\n  private async performGitAction(') + '\n' +
  method('  private async performGitAction(', '\n  private onCloneDone(') + '\n' +
  method('  private explainError(', '\n  private previewVaultId(): string {') + '\n' +
  `  appendLog(line) { this.logs.push(line); }
}
module.exports = SyncPageActionHarness;
`, { loader: 'ts', format: 'cjs' }).code;

const gitAuthModule = (() => {
  const module = { exports: {} };
  vm.runInContext(
    transformSync(gitAuthRaw, { loader: 'ts', format: 'cjs' }).code,
    vm.createContext({ module, exports: module.exports })
  );
  return module.exports;
})();

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

function actionHarness(metadataFailures = [], failFirstAction = true) {
  const calls = [];
  const logs = [];
  const module = { exports: {} };
  const registry = {
    currentEntry() { return { id: 'repo', type: 'git' }; },
    vaultDirOf(id) { calls.push('path:' + id); return '/isolated/' + id; },
    updateGitAuthUsername() {
      calls.push('save-username');
      if (metadataFailures.includes('username')) throw new Error('private username metadata failure');
    },
    recordGitSync() {
      calls.push('record-sync');
      if (metadataFailures.includes('sync')) throw new Error('private sync metadata failure');
    }
  };
  vm.runInContext(actionCode, vm.createContext({
    module,
    exports: module.exports,
    VaultRegistry: { get: () => registry },
    GitNativeService: {
      async action(options) {
        calls.push('action:' + options.operation);
        if (failFirstAction && (options.operation === 'stage' || options.operation === 'commit' ||
          options.operation === 'fetch' || options.operation === 'push')) {
          if (calls.filter(call => call === 'action:' + options.operation).length === 1) {
            throw new Error('path=/private/vault/note.md token=private-token');
          }
        }
        return options.operation === 'fetch' ? 'updated' : '1234567890abcdef';
      },
      progressLabel() { return 'progress'; }
    },
    GitCredentialStore: {
      saveToken() {
        if (metadataFailures.includes('token')) throw new Error('private token metadata failure');
      }
    },
    promptAction: { showToast() {} }
  }));
  const page = new module.exports();
  Object.assign(page, {
    syncMode: true,
    syncVaultId: 'repo',
    syncRemote: 'https://github.com/team/repo.git',
    syncToken: 'private-token',
    syncUsername: '',
    commitMessage: 'controlled test',
    authorName: 'Test',
    authorEmail: 'test@example.invalid',
    busy: false,
    progressText: '',
    logs,
    refreshSyncStatus() { calls.push('refresh-status'); }
  });
  return { page, calls, logs };
}

test('Git action failures surface the underlying error with the token redacted and can be retried explicitly', async () => {
  const labels = new Map([
    ['stage', '暂存'],
    ['commit', '本地提交'],
    ['fetch', '获取远端状态'],
    ['push', '推送']
  ]);
  const successLogs = new Map([
    ['stage', '已暂存工作区更改'],
    ['commit', '本地提交完成'],
    ['fetch', '已获取 xt2 远端状态'],
    ['push', '已推送到 xt2']
  ]);
  for (const operation of labels.keys()) {
    const f = actionHarness();
    await f.page.performGitAction(operation);
    assert.equal(f.page.busy, false);
    assert.equal(f.page.progressText, '失败');
    assert.match(f.logs[0], new RegExp(labels.get(operation) + '失败；当前状态未确认'));
    assert.match(f.logs[0], /原因未确定/);
    assert.match(f.logs[0], /底层错误：path=\/private\/vault\/note\.md token=\[令牌已隐藏\]/);
    assert.match(f.logs[0], /刷新 Git 状态后再决定是否重试/);
    assert.ok(!f.logs.join('\n').includes('private-token'));
    assert.equal(f.calls.filter(call => call.startsWith('action:')).length, 1);

    await f.page.performGitAction(operation);
    assert.equal(f.calls.filter(call => call === 'action:' + operation).length, 2);
    assert.equal(f.page.busy, false);
    assert.equal(f.page.progressText, operation === 'push' ? '推送完成' : '完成');
    assert.ok(f.logs.some(line => line.includes(successLogs.get(operation))));
  }
});

test('remote success remains success when sync metadata persistence fails', async () => {
  for (const [operation, metadataFailures, expectedWarning] of [
    ['fetch', ['username', 'token'], '令牌未能安全保存'],
    ['push', ['username', 'token', 'sync'], '推送成功，但上次同步时间未能保存']
  ]) {
    const f = actionHarness(metadataFailures, false);
    f.page.syncToken = 'synthetic-private-token';

    await f.page.performGitAction(operation);

    assert.equal(f.page.busy, false);
    assert.equal(f.page.progressText, operation === 'push' ? '推送完成' : '完成',
      `${operation} logs=${JSON.stringify(f.logs)} calls=${JSON.stringify(f.calls)}`);
    assert.ok(f.logs.some(line => line.includes(expectedWarning)));
    assert.ok(f.logs.some(line => line.includes(operation === 'push' ? '已推送到 xt2' : '已获取 xt2')));
    assert.ok(f.logs.join('\n').includes('metadata failure'));
    assert.ok(!f.logs.join('\n').includes('synthetic-private-token'));
  }
});

test('failure copy carries the underlying error with token redaction (46.9)', () => {
  // performGitAction catch：分类结论 + 底层错误 + 重试提示
  assert.match(source, /'。底层错误：' \+ detail \+ '。请刷新 Git 状态后再决定是否重试。'/);
  // onCloneDone 失败分支：explainError 之后追加底层错误原文
  assert.match(source, /this\.explainError\(message\) \+ '。底层错误：' \+ message/);
  // onCloneDone 登记失败分支：先按 this.token 脱敏再携带
  assert.match(source, /detail\.split\(this\.token\)\.join\('\[令牌已隐藏\]'\)/);
  assert.match(source, /'Git 导入登记失败；当前库和导入目录状态未确认。底层错误：' \+ detail/);
  // refreshSyncStatus 失败分支携带底层错误
  assert.match(source, /'无法读取 Git 状态：' \+ \(err\.message \?\? String\(error\)\)/);
  // 三个元数据警告 catch 均携带底层错误
  assert.match(source, /'远端操作已完成，但用户名设置未能保存：' \+ this\.syncFailureDetail\(err\)/);
  assert.match(source, /'令牌未能安全保存；下次同步时需要重新填写：' \+ this\.syncFailureDetail\(err\)/);
  assert.match(source, /'推送成功，但上次同步时间未能保存：' \+ this\.syncFailureDetail\(err\)/);
  // 认证赋值走 GitRemoteAuth 单一真源（2026-11-13 收敛后）
  assert.match(source, /applyRemoteAuth\(options, url, username, token\)/);
  assert.match(source, /applyRemoteAuth\(options, this\.syncRemote, this\.syncUsername\.trim\(\), this\.syncToken\)/);
});

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
  assert.equal(gitAuthModule.isGitHubRemote('https://github.com/team/repo.git'), true);
  assert.equal(gitAuthModule.isGitHubRemote('https://WWW.GITHUB.COM:443/team/repo.git'), true);
  assert.equal(gitAuthModule.isGitHubRemote('https://github.com.attacker.example/team/repo.git'), false);
  assert.equal(gitAuthModule.isGitHubRemote('https://gitee.com/team/repo.git'), false);
  // GitSyncDialog 的 remoteLabel 是 host/path 形态，解析器必须兼容
  assert.equal(gitAuthModule.isGitHubRemote('github.com/team/repo'), true);
  assert.equal(gitAuthModule.isGiteeRemote('gitee.com/team/repo'), true);
  assert.equal(gitAuthModule.gitRemoteHost('user@github.com:443/o/r.git'), 'github.com');
});

test('applyRemoteAuth writes bearer for GitHub and Basic for others, skipping empty tokens', () => {
  const githubOptions = {};
  gitAuthModule.applyRemoteAuth(githubOptions, 'https://github.com/team/repo.git', 'user', 'tok');
  assert.equal(githubOptions.bearerToken, 'tok');
  assert.equal('username' in githubOptions, false);

  const giteeOptions = {};
  gitAuthModule.applyRemoteAuth(giteeOptions, 'https://gitee.com/team/repo.git', 'user', 'tok');
  assert.equal(giteeOptions.username, 'user');
  assert.equal(giteeOptions.password, 'tok');
  assert.equal('bearerToken' in giteeOptions, false);

  const emptyToken = {};
  gitAuthModule.applyRemoteAuth(emptyToken, 'https://github.com/team/repo.git', 'user', '');
  assert.deepEqual(Object.keys(emptyToken), []);
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
