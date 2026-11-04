import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const start = source.indexOf('  private showEditorMismatchRecovery(');
const end = source.indexOf('\n  private showStaleSaveConflict(', start);
assert.ok(start >= 0 && end > start);
const code = transformSync(`class Harness { ${source.slice(start, end)} }; module.exports = Harness;`,
  { loader: 'ts', format: 'cjs' }).code;

function fixture() {
  let resolveDialog;
  const dialogs = [], reloads = [];
  const context = vm.createContext({ module: { exports: {} }, $r: value => value,
    promptAction: { showToast() {} } });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  app.getUIContext = () => ({ getPromptAction: () => ({ showDialog(options) {
    dialogs.push(options);
    return new Promise(resolve => { resolveDialog = resolve; });
  } }) });
  app.reloadStaleVaultNote = async (vault, path) => { reloads.push([vault, path]); };
  return { app, dialogs, reloads, respond: index => resolveDialog({ index }) };
}

test('mismatch preserves the editor unless user explicitly chooses to reload', async () => {
  const f = fixture();
  f.app.showEditorMismatchRecovery('vault', 'a.md');
  f.app.showEditorMismatchRecovery('vault', 'a.md');
  assert.equal(f.dialogs.length, 1);
  assert.match(f.dialogs[0].message, /未保存/);
  f.respond(0);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.reloads, []);
  f.app.showEditorMismatchRecovery('vault', 'a.md');
  f.respond(1);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.reloads, [['vault', 'a.md']]);
});
