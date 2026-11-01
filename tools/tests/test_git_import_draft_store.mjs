import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/model/GitImportDraftStore.ets', import.meta.url));
const code = transformSync(source, { loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({ module: { exports: {} } });
vm.runInContext(code, context);
const { GitImportDraftStore } = context.module.exports;

test('Git import form transfers credentials once in memory and clears after consumption', () => {
  const draft = { remote: 'https://example.test/team/repo.git', branch: 'main', username: 'user', token: 'secret' };
  GitImportDraftStore.set(draft);
  assert.deepEqual(JSON.parse(JSON.stringify(GitImportDraftStore.consume())), draft);
  assert.equal(GitImportDraftStore.consume(), null);
});

test('explicit clear removes a pending Git form draft', () => {
  GitImportDraftStore.set({ remote: 'https://example.test/repo.git', branch: 'main', username: '', token: 'secret' });
  GitImportDraftStore.clear();
  assert.equal(GitImportDraftStore.consume(), null);
});
