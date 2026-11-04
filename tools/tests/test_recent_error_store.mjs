import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const storeSource = readSourceFile(new URL('../../entry/src/main/ets/model/RecentErrorStore.ets', import.meta.url));
const settingsSource = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const harnessCode = transformSync(`
${storeSource
  .replace(/^import .*\n/gm, '')
  .replace(/^export /gm, '')}
module.exports = {
  RecentErrorStore,
  formatRecentError,
  formatRecentErrorFeedback,
  formatRecentErrorsForCopy,
  parseRecentErrorSnapshot,
  serializeRecentErrorSnapshot
};
`, { loader: 'ts', format: 'cjs' }).code;

const mod = { exports: {} };
new Function('module', 'exports', harnessCode)(mod, mod.exports);
const {
  RecentErrorStore,
  formatRecentError,
  formatRecentErrorFeedback,
  formatRecentErrorsForCopy,
  parseRecentErrorSnapshot,
  serializeRecentErrorSnapshot
} = mod.exports;

const settingsMethodStart = settingsSource.indexOf('  private refreshRecentErrors(): void {');
const settingsMethodEnd = settingsSource.indexOf('\n  @Builder\n  AgentTab()', settingsMethodStart);
assert.ok(settingsMethodStart >= 0 && settingsMethodEnd > settingsMethodStart,
  'could not find recent-error settings methods');
const settingsMethodsCode = transformSync(`
class SettingsRecentErrorHarness {
  ${settingsSource.slice(settingsMethodStart, settingsMethodEnd).trim()}
}
module.exports = SettingsRecentErrorHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function makeStore(values) {
  const preferences = {
    getSync(key, defaultValue) {
      return values.has(key) ? values.get(key) : defaultValue;
    },
    putSync(key, value) {
      values.set(key, value);
    },
    flushSync() {}
  };
  return new RecentErrorStore({}, preferences);
}

test('persists fixed diagnostics across store recreation', () => {
  const values = new Map();
  const first = makeStore(values);
  assert.equal(first.recordFailure(
    'settings', 'build_commit_copy', 'clipboard_failure', 'not_completed', 'retry'
  ), true);

  const reopened = makeStore(values);
  const records = reopened.load();
  assert.equal(records.length, 1);
  assert.match(formatRecentError(records[0]), /复制构建提交号/);
  assert.match(formatRecentErrorsForCopy(records), /下一步：稍后重试/);
});

test('formats an actionable status-unknown failure without inventing a cause', () => {
  const message = formatRecentErrorFeedback(
    'note', 'save', 'unknown', 'status_unknown', 'check_status'
  );
  assert.match(message, /笔记 \/ 保存失败/);
  assert.match(message, /完成状态未确认/);
  assert.match(message, /原因未确定/);
  assert.match(message, /检查当前状态/);
  assert.equal(serializeRecentErrorSnapshot([{
    timestamp: 1,
    operation: 'note',
    phase: 'save',
    category: 'unknown',
    outcome: 'status_unknown',
    nextStep: 'check_status'
  }]).length > 0, true);
});

test('retains the newest twenty records and stays within the serialized size cap', () => {
  const values = new Map();
  const store = makeStore(values);
  for (let i = 0; i < RecentErrorStore.LIMIT + 1; i++) {
    assert.equal(store.recordFailure(
      'settings', 'recent_errors_copy', 'clipboard_failure', 'not_completed', 'retry'
    ), true);
  }

  const records = store.load();
  assert.equal(records.length, RecentErrorStore.LIMIT);
  const raw = values.get('latest');
  assert.ok(raw.length <= RecentErrorStore.MAX_SERIALIZED_LENGTH);
});

test('rejects unsupported snapshots and enum values', () => {
  assert.equal(parseRecentErrorSnapshot('{"schemaVersion":2,"records":[]}'), null);
  assert.equal(parseRecentErrorSnapshot('{"schemaVersion":1,"records":[{}]}'), null);
  assert.equal(parseRecentErrorSnapshot('x'.repeat(RecentErrorStore.MAX_SERIALIZED_LENGTH + 1)), null);
  assert.equal(serializeRecentErrorSnapshot([{
    timestamp: 1,
    operation: 'settings',
    phase: 'build_commit_copy',
    category: 'not-allowlisted',
    outcome: 'not_completed',
    nextStep: 'retry'
  }]), '');
});

test('keeps sensitive error details out of persisted, displayed, copied, and logged diagnostics', () => {
  const secrets = [
    'note-title: Private Title',
    'file-name: secret.md',
    'path: /private/vault/secret.md',
    'body: confidential note text',
    'word-count: 427',
    'tags: personal,finance',
    'token: ghp_private_example',
    'credential: user:password',
    'remote-url: https://user:token@example.com/private.git',
    'exception: request failed with private response'
  ];
  const rejectedValues = new Map();
  const injectedException = new Error(secrets.join('\n'));
  assert.equal(makeStore(rejectedValues).recordFailure(
    'settings', 'build_commit_copy', injectedException.message, 'not_completed', 'retry'
  ), false);
  assert.equal(rejectedValues.has('latest'), false);

  const values = new Map();
  const store = makeStore(values);
  const injectedRecord = {
    timestamp: Date.now(),
    operation: 'settings',
    phase: 'build_commit_copy',
    category: 'clipboard_failure',
    outcome: 'not_completed',
    nextStep: 'retry',
    noteTitle: secrets[0],
    fileName: secrets[1],
    path: secrets[2],
    body: secrets[3],
    wordCount: secrets[4],
    tags: secrets[5],
    token: secrets[6],
    credential: secrets[7],
    remoteUrl: secrets[8],
    errorMessage: secrets[9]
  };
  values.set('latest', JSON.stringify({ schemaVersion: 1, records: [injectedRecord] }));

  const records = store.load();
  assert.equal(records.length, 1);
  const pageText = formatRecentError(records[0]);
  const clipboardText = formatRecentErrorsForCopy(records);
  assert.equal(store.recordFailure(
    'settings', 'recent_errors_copy', 'clipboard_failure', 'not_completed', 'retry'
  ), true);
  const persistedText = values.get('latest');

  for (const secret of secrets) {
    assert.ok(!pageText.includes(secret));
    assert.ok(!clipboardText.includes(secret));
    assert.ok(!persistedText.includes(secret));
  }
  assert.match(pageText, /设置/);
  assert.match(clipboardText, /复制构建提交号/);
  assert.equal(formatRecentError({
    timestamp: secrets[0],
    operation: secrets[6],
    phase: 'build_commit_copy',
    category: 'clipboard_failure',
    outcome: 'not_completed',
    nextStep: 'retry'
  }), '诊断记录无效');

  const diagnosticsStart = settingsSource.indexOf('  private async copyBuildCommit()');
  const diagnosticsEnd = settingsSource.indexOf('  @Builder\n  AgentTab()', diagnosticsStart);
  const diagnosticsHandlers = settingsSource.slice(diagnosticsStart, diagnosticsEnd);
  assert.doesNotMatch(storeSource, /hilog\.|console\.(?:log|error)|error\.(?:message|stack)/);
  assert.doesNotMatch(diagnosticsHandlers, /hilog\.|console\.(?:log|error)|error\.(?:message|stack)|String\(error\)/);
});

test('settings displays and copies the same formatted recent records', () => {
  assert.match(settingsSource, /Text\(formatRecentError\(record\)\)/);
  assert.match(settingsSource, /formatRecentErrorsForCopy\(this\.recentErrors\)/);
  assert.match(settingsSource, /Text\('暂无错误记录'\)/);
  assert.match(settingsSource, /最近错误记录暂不可用/);
  assert.match(settingsSource, /已复制最近错误记录/);
  assert.match(settingsSource, /RecentErrorSection\(\)/);
});

test('recent-error clipboard failure stores only a fixed diagnostic and shows safe feedback', async () => {
  const secret = '/private/vault/note.md token=private-token';
  const calls = [];
  const toasts = [];
  const board = {
    async setData() { throw new Error(secret); }
  };
  const settingsModule = { exports: {} };
  vm.runInContext(settingsMethodsCode, vm.createContext({
    module: settingsModule,
    exports: settingsModule.exports,
    formatRecentErrorsForCopy,
    formatRecentError,
    pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain',
      getSystemPasteboard() { return board; },
      createData(type, value) { return { type, value }; }
    },
    promptAction: { showToast(value) { toasts.push(value.message); } }
  }));
  const page = new settingsModule.exports();
  page.recentErrors = [{
    timestamp: Date.now(),
    operation: 'settings',
    phase: 'build_commit_copy',
    category: 'clipboard_failure',
    outcome: 'not_completed',
    nextStep: 'retry'
  }];
  page.recentErrorStore = {
    recordFailure(...args) {
      calls.push(args);
      return true;
    },
    isAvailable() { return true; },
    load() { return page.recentErrors; }
  };

  await page.copyRecentErrors();

  assert.deepEqual(calls, [[
    'settings', 'recent_errors_copy', 'clipboard_failure', 'not_completed', 'retry'
  ]]);
  assert.deepEqual(toasts, ['复制失败，请稍后重试']);
  assert.ok(!JSON.stringify(calls).includes(secret));
  assert.ok(!toasts.join('\n').includes(secret));
});
