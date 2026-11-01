import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../web/mdeditor/src/index.ts', import.meta.url));
const start = source.indexOf('function applyMarkdownFormat(kind: string): void {');
const end = source.indexOf('\nconst api: MdEditorApi = {', start);
assert.ok(start >= 0 && end > start, 'could not find applyMarkdownFormat');
const method = source.slice(start, end).trim();

function createHarness(formatChange) {
  const code = transformSync(`function run(view, isEditable, kind) {
    const toggleMarkdownFormat = () => (${JSON.stringify(formatChange)});
    function applyCodeBlockFormat() {}
    ${method}
    applyMarkdownFormat(kind);
  }
  module.exports = run;`, { loader: 'ts', format: 'cjs' }).code;
  const context = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, context);
  return context.module.exports;
}

test('format action restores editor focus even when the selected format is already active', () => {
  const run = createHarness(null);
  const calls = [];
  run({
    state: {},
    dispatch() { calls.push('dispatch'); },
    focus() { calls.push('focus'); }
  }, true, 'paragraph');

  assert.deepEqual(calls, ['focus']);
});

test('format action applies the mapped selection and returns focus to the editor', () => {
  const change = { changes: { from: 0, to: 1, insert: '# a' }, selection: { anchor: 2, head: 3 } };
  const run = createHarness(change);
  const calls = [];
  run({
    state: {},
    dispatch(transaction) { calls.push(['dispatch', transaction]); },
    focus() { calls.push(['focus']); }
  }, true, 'h1');

  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [
    ['dispatch', { changes: change.changes, selection: change.selection, scrollIntoView: true, userEvent: 'input' }],
    ['focus']
  ]);
});
