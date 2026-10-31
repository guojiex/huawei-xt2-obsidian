import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteImageShareService.ets', import.meta.url), 'utf8');
const start = source.indexOf('  static pageTops(scrollHeight: number, viewportHeight: number): number[] {');
const end = source.indexOf('\n  static createSession(', start);
assert.ok(start >= 0 && end > start, 'could not find NoteImageShareService.pageTops');
const pageTopsMethod = source.slice(start, end).trim();
const code = transformSync(`class NoteImageShareService { static readonly MAX_PAGES: number = 500; ${pageTopsMethod} }; module.exports = NoteImageShareService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const context = vm.createContext({ module: { exports: {} } });
vm.runInContext(code, context);
const { pageTops } = context.module.exports;

test('page tops cover one page and exact viewport boundaries without an empty trailing page', () => {
  assert.deepEqual(Array.from(pageTops(1, 710)), [0]);
  assert.deepEqual(Array.from(pageTops(710, 710)), [0]);
  assert.deepEqual(Array.from(pageTops(711, 710)), [0, 710]);
});

test('page tops cover the final partial page in the existing six-page API26 probe', () => {
  assert.deepEqual(Array.from(pageTops(3808, 710)), [0, 710, 1420, 2130, 2840, 3550]);
});

test('page tops reject invalid dimensions and page counts beyond the sharing limit', () => {
  for (const [scrollHeight, viewportHeight] of [[0, 710], [710, 0], [Infinity, 710], [710, NaN]]) {
    assert.throws(() => pageTops(scrollHeight, viewportHeight), /页面尺寸/);
  }
  assert.equal(pageTops(500 * 710, 710).length, 500);
  assert.throws(() => pageTops(500 * 710 + 1, 710), /分享上限/);
});
