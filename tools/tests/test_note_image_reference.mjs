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

const fullSource = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteImageService.ets', import.meta.url), 'utf8');

function loadFullImageService() {
  const sourceCode = transformSync(
    fullSource.replace(/^import .*;\n/gm, '') + '\nmodule.exports = NoteImageService;',
    { loader: 'ts', format: 'cjs' }
  ).code;
  const context = vm.createContext({
    module: { exports: {} },
    Date: { now: () => 123456 },
    dataSharePredicates: {
      DataSharePredicates: class {
        equalTo() { return this; }
      }
    },
    photoAccessHelper: {
      PhotoKeys: { URI: 'uri' },
      getPhotoAccessHelper() {
        return {
          async getAssets() {
            return {
              getCount: () => 1,
              async getFirstObject() { return { uri: 'photo://selected', displayName: 'source.png' }; },
              close() {}
            };
          }
        };
      }
    },
    fileIo: {
      OpenMode: { READ_ONLY: 0 },
      openSync: () => ({ fd: 17 }),
      statSync: () => ({ size: 3 }),
      closeSync() {}
    }
  });
  vm.runInContext(sourceCode, context);
  return context.module.exports;
}

test('same-millisecond image imports receive different attachment names', () => {
  const FullNoteImageService = loadFullImageService();
  const registry = { accessFor: () => ({ exists: () => false }) };
  const first = FullNoteImageService.uniqueFilename(registry, 'local', 'attachments', 'source.png', 'png');
  const second = FullNoteImageService.uniqueFilename(registry, 'local', 'attachments', 'source.png', 'png');
  assert.notEqual(first, second);
});

test('a writeNewBinary name conflict preserves the pre-existing attachment and returns no Markdown reference', async () => {
  const FullNoteImageService = loadFullImageService();
  const existingBytes = new Uint8Array([9, 8, 7]);
  const removeCalls = [];
  let selectedTarget = '';
  let persistedBytes = null;
  const access = {
    exists(path) { return path === '10_写作/attachments'; },
    stat(path) { return path === '10_写作/attachments' ? { isDir: true } : null; },
    ensureDir() {},
    async writeNewBinary(path) {
      selectedTarget = path;
      persistedBytes = existingBytes.slice(); // simulate a target appearing after the name check
      throw new Error('附件目标已存在');
    },
    remove(path) {
      removeCalls.push(path);
      persistedBytes = null;
    }
  };
  const registry = { accessFor: () => access };

  let result;
  await assert.rejects(async () => {
    result = await FullNoteImageService.importPickedImage(
      registry, {}, 'local', '10_写作/笔记.md', 'photo://picker');
  }, /附件目标已存在/);

  assert.match(selectedTarget, /^10_写作\/attachments\/image-/);
  assert.deepEqual(Array.from(persistedBytes), Array.from(existingBytes));
  assert.deepEqual(removeCalls, [], 'the caller must not delete a target after the access layer rejects a collision');
  assert.equal(result, undefined, 'a failed copy must not return a Markdown reference');

  const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const importAwaitIndex = indexSource.indexOf('const imported = await NoteImageService.importPickedImage(');
  const insertReferenceIndex = indexSource.indexOf('bridge.insertText(imported.markdownReference);');
  assert.ok(importAwaitIndex >= 0 && insertReferenceIndex > importAwaitIndex,
    'the editor inserts a Markdown reference only after the import promise resolves');
});
