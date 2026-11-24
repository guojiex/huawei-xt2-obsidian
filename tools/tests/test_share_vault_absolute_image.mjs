import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = readSourceFile(new URL('../../entry/src/main/ets/model/NoteShareService.ets', import.meta.url));
const code = transformSync(source + '\nmodule.exports = NoteShareService;', {
  loader: 'ts',
  format: 'cjs'
}).code;

// 回归背景（2026-11-23 真机反馈）：zip 分享含 Obsidian 库内绝对路径图片
// （如 ![x](/50_assets/blog/media/xxx.jpg)）时抛「图片路径越界或属于内部目录」。
// 需求：单斜杠开头按库根解析，越界 / 内部目录守卫不放松。
const importStubs = {
  '@kit.BasicServicesKit': { zlib: {} },
  '@ohos.file.fs': {},
  '../common/AtomicWrite': { atomicWriteText: async () => {} },
  '../common/NoteDisplayName': { noteDisplayName: (name) => name },
  './VaultRegistry': { VaultRegistry: class VaultRegistry {} }
};
const context = vm.createContext({
  module: { exports: {} },
  require: (name) => importStubs[name]
});
vm.runInContext(code, context);
const NoteShareService = context.module.exports;

test('vault-absolute image references resolve from the vault root', () => {
  assert.equal(
    NoteShareService.resolveImagePath('blog/foo.md', '/50_assets/blog/media/14622903471800.jpg'),
    '50_assets/blog/media/14622903471800.jpg');
  assert.equal(NoteShareService.resolveImagePath('foo.md', '/50_assets/x.jpg'), '50_assets/x.jpg');
});

test('vault-absolute references keep the traversal and internal-directory guards', () => {
  assert.throws(() => NoteShareService.resolveImagePath('foo.md', '//example.test/x.jpg'),
    /相对路径/);
  assert.throws(() => NoteShareService.resolveImagePath('foo.md', '/..'),
    /越出当前知识库/);
  assert.throws(() => NoteShareService.resolveImagePath('foo.md', '/a/../..'),
    /越出当前知识库/);
  assert.throws(() => NoteShareService.resolveImagePath('foo.md', '/.obsidian/x.jpg'),
    /内部目录/);
  assert.throws(() => NoteShareService.resolveImagePath('foo.md', '/'),
    /不能为空/);
});

test('rewrite keeps vault-absolute images reachable for root and nested notes', () => {
  const archiveImages = new Map([
    ['50_assets/blog/media/p.jpg', '50_assets/blog/media/p.jpg']
  ]);

  const nested = NoteShareService.rewriteMarkdownImages(
    '![x](/50_assets/blog/media/p.jpg)', 'blog/foo.md', archiveImages);
  assert.equal(nested, '![x](../50_assets/blog/media/p.jpg)');

  const atRoot = NoteShareService.rewriteMarkdownImages(
    '![x](/50_assets/blog/media/p.jpg)', 'foo.md', archiveImages);
  assert.equal(atRoot, '![x](50_assets/blog/media/p.jpg)');
});
