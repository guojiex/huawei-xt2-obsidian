import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { resolveVaultImagePath } from '../../web/mdpreview/src/renderer.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteImageService.ets', import.meta.url), 'utf8');
const start = source.indexOf('  static selectedUri(');
const end = source.indexOf('\n  private static imageExtension(', start);
assert.ok(start >= 0 && end > start, 'could not find NoteImageService import reference methods');

const code = transformSync(`class NoteImageService { ${source.slice(start, end).trim()} }; module.exports = NoteImageService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const context = vm.createContext({
  module: { exports: {} }
});
vm.runInContext(code, context);
const NoteImageService = context.module.exports;

test('uses the first selected image URI and treats picker cancellation as empty', () => {
  assert.equal(NoteImageService.selectedUri([]), '');
  assert.equal(NoteImageService.selectedUri(['photo://first', 'photo://second']), 'photo://first');
});

test('a note-relative attachment reference resolves from the note directory after reload', () => {
  const notePath = '10_写作/笔记.md';
  const assetPath = '10_写作/attachments/image-123-测试 图片 #1%.jpg';
  const markdown = NoteImageService.markdownReference(notePath, assetPath);
  const match = /^!\[图片\]\(<(.+)>\)$/.exec(markdown);

  assert.equal(markdown,
    '![图片](<attachments/image-123-%E6%B5%8B%E8%AF%95%20%E5%9B%BE%E7%89%87%20%231%25.jpg>)');
  assert.ok(match);
  assert.equal(resolveVaultImagePath('10_写作', match[1]), assetPath);
});

test('a copied image is accepted only when its non-empty byte size matches', () => {
  assert.doesNotThrow(() => NoteImageService.validateCopiedSize(64, 64));
  assert.throws(() => NoteImageService.validateCopiedSize(64, 32), /图片副本不完整/);
  assert.throws(() => NoteImageService.validateCopiedSize(0, 0), /图片副本不完整/);
});
