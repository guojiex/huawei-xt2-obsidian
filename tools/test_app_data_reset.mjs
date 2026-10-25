import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { TextDecoder } from 'node:util';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/model/AppDataResetService.ets', import.meta.url), 'utf8');
const code = transformSync(source.replace(/^import .*;\n/gm, ''), { loader: 'ts', format: 'cjs' }).code;

function fixture({ aliases = ['vault:local:token', 'vault:pending-import:token', 'other:asset'], queryError = 0, removalError = 0, clearError = false } = {}) {
  const calls = [];
  const asset = {
    Tag: { RETURN_TYPE: 'return', ALIAS: 'alias', SECRET: 'secret' },
    ReturnType: { ATTRIBUTES: 1 },
    querySync(query) {
      assert.equal(query.get('return'), 1); assert.ok(!query.has('secret'));
      calls.push('query');
      if (queryError) throw { code: queryError };
      return aliases.map(alias => new Map([['alias', new Uint8Array(Buffer.from(alias))]]));
    },
    removeSync(query) {
      assert.equal(query.size, 1);
      calls.push('remove:' + Buffer.from(query.get('alias')).toString());
      if (removalError) throw { code: removalError };
    }
  };
  const context = { module: { exports: {} }, asset, util: { TextDecoder: class { decodeToString(bytes) { return new TextDecoder().decode(bytes); } } }, Uint8Array };
  vm.runInNewContext(code, context);
  const fakeUiContext = { getApplicationContext() { return { async clearUpApplicationData() {
    calls.push('clear'); if (clearError) throw new Error('injected clear failure');
  } }; } };
  return { calls, reset: () => context.module.exports.AppDataResetService.reset(fakeUiContext) };
}

test('removes only app Git aliases, including pending import, before clearing data', async () => {
  const f = fixture(); await f.reset();
  assert.deepEqual(f.calls, ['query', 'remove:vault:local:token', 'remove:vault:pending-import:token', 'clear']);
});
test('no credentials is a valid fresh installation state', async () => {
  const f = fixture({ queryError: 24000002 }); await f.reset(); assert.deepEqual(f.calls, ['query', 'clear']);
});
test('credential query failure prevents data clearing', async () => {
  const f = fixture({ queryError: 24000001 }); await assert.rejects(f.reset(), /读取/); assert.ok(!f.calls.includes('clear'));
});
test('credential removal failure prevents data clearing', async () => {
  const f = fixture({ removalError: 24000008 }); await assert.rejects(f.reset(), /清除/); assert.ok(!f.calls.includes('clear'));
});
test('already absent credentials do not prevent reset', async () => {
  const f = fixture({ removalError: 24000002 }); await f.reset(); assert.equal(f.calls.at(-1), 'clear');
});
test('system reset rejection is returned to the UI instead of claiming success', async () => {
  const f = fixture({ clearError: true }); await assert.rejects(f.reset(), /injected clear failure/);
});
