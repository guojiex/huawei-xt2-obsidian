import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const start = source.indexOf('  private async resetData(): Promise<void> {');
const end = source.indexOf('\n\n  aboutToAppear(): void {', start);
assert.ok(start >= 0 && end > start, 'could not find SettingsView.resetData');
const code = transformSync(`class SettingsResetHarness {
  ${source.slice(start, end).trim()}
}; module.exports = SettingsResetHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness({ resetError = null, resetting = false } = {}) {
  const calls = [];
  const abilityContext = { id: 'settings-ability-context' };
  const context = vm.createContext({
    module: { exports: {} },
    getContext(view) {
      calls.push(['get-context', view]);
      return abilityContext;
    },
    AppDataResetService: {
      async reset(receivedContext) {
        calls.push(['reset', receivedContext]);
        if (resetError !== null) {
          throw resetError;
        }
      }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, { resetting, resetError: 'previous reset error' });
  return { app, calls, abilityContext };
}

test('successful reset passes the SettingsView context and keeps the shutdown state', async () => {
  const { app, calls, abilityContext } = createHarness();

  await app.resetData();

  assert.equal(app.resetting, true);
  assert.equal(app.resetError, '');
  assert.equal(calls.length, 2);
  assert.equal(calls[0][0], 'get-context');
  assert.equal(calls[0][1], app);
  assert.equal(calls[1][0], 'reset');
  assert.equal(calls[1][1], abilityContext);
});

test('a reset already in progress cannot start another service request', async () => {
  const { app, calls } = createHarness({ resetting: true });

  await app.resetData();

  assert.deepEqual(calls, []);
  assert.equal(app.resetting, true);
  assert.equal(app.resetError, 'previous reset error');
});

test('a reset failure re-enables the action and shows the existing error message', async () => {
  const { app, calls } = createHarness({ resetError: new Error('injected reset failure') });

  await app.resetData();

  assert.equal(calls[1][0], 'reset');
  assert.equal(app.resetting, false);
  assert.equal(app.resetError, '重置未完成，部分访问令牌可能已清除。injected reset failure');
});
