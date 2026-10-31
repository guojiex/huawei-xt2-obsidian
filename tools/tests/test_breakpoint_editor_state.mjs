import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async refreshAfterBreakpointChange(');
const end = source.indexOf('\n  onBackPress(): boolean {', start);
assert.ok(start >= 0 && end > start, 'could not find breakpoint refresh method');

const code = transformSync(`
class BreakpointHarness {
  ${source.slice(start, end).trim()}
}
module.exports = BreakpointHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const module = { exports: {} };
vm.runInContext(code, vm.createContext({ module, exports: module.exports }));

test('breakpoint changes flush the current note without reloading editor content', async () => {
  const app = new module.exports();
  let flushCalls = 0;
  app.currentFilePath = '20_样式/样式支持清单.md';
  app.currentVaultId = 'local';
  app.flushSave = async (path, vaultId) => {
    flushCalls++;
    assert.equal(path, app.currentFilePath);
    assert.equal(vaultId, app.currentVaultId);
    return true;
  };
  app.readAndPush = () => {
    throw new Error('breakpoint changes must not reset editor selection');
  };

  await app.refreshAfterBreakpointChange(app.currentFilePath, app.currentVaultId);

  assert.equal(flushCalls, 1);
});

test('breakpoint changes do not flush after the note target has changed', async () => {
  const app = new module.exports();
  app.currentFilePath = '10_写作/基础排版.md';
  app.currentVaultId = 'local';
  app.flushSave = () => {
    throw new Error('stale breakpoint callback must not flush a different note');
  };

  await app.refreshAfterBreakpointChange('20_样式/样式支持清单.md', app.currentVaultId);
});
