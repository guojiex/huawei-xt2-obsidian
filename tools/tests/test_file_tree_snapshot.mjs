/*
 * FileTree 快照驱动扫描的契约测试。
 *
 * 为什么单列一个文件：FileTree.ets 里同时挂着 ExpandStore（依赖 preferences / UIAbilityContext），
 * 整文件塞进 vm 会连带拉起 @kit.* 依赖，Node 侧跑不起来。这里沿用 test_file_tree_keyboard
 * 的做法——按源码片段切出 FileTree 类体，只验纯逻辑部分。
 *
 * 锁住的是 v1.5 的关键约定：**剪枝与排版不再碰 IO**，输入是 VaultAccess.snapshot()。
 * 只要有人偷偷把 listFileSync 塞回来，这里第一挂。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = fs.readFileSync(
  new URL('../../entry/src/main/ets/model/FileTree.ets', import.meta.url), 'utf8');
const start = source.indexOf('export class FileTree {');
const end = source.indexOf('/**\n * ExpandStore');
assert.ok(start >= 0 && end > start, '找不到 FileTree 类体');

/** 把类体拼成可执行的 CJS；hilog/TreeNode 等外部符号一并 stub 掉。 */
const code = transformSync(
  source.slice(start, end).replace('export class', 'class') +
  '\nmodule.exports = { FileTree };', { loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({ module: { exports: {} }, console });
vm.runInContext(code, context);
const { FileTree } = context.module.exports;

/** vm realm 出来的数组与主 realm 不同源，deepEqual 会因 realm 判不过。 */
function plain(values) {
  return JSON.parse(JSON.stringify(values));
}

/** 只实现 snapshot() 的最小 VaultAccess —— 证明 FileTree 不再需要路径或文件系统。 */
function accessWith(entries) {
  return {
    kind: 'sandbox',
    snapshot() {
      return entries.map((e) => ({ name: e[0], isDir: e[1] }));
    },
    allNotes() {
      return entries.filter((e) => !e[1]).map((e) => e[0]);
    },
    allDirs() {
      return entries.filter((e) => e[1]).map((e) => e[0]);
    }
  };
}

const TREE = [
  ['alpha', true],
  ['alpha/a.md', false],
  ['alpha/deep', true],
  ['alpha/deep/x.md', false],
  ['docs', true],
  ['docs/笔记.md', false],
  ['root.md', false]
];

test('scan hides descendants of collapsed directories', () => {
  const nodes = FileTree.scan(accessWith(TREE), []);
  assert.deepEqual(plain(nodes.map((n) => n.relPath)), ['alpha', 'docs', 'root.md']);
  assert.deepEqual(plain(nodes.map((n) => n.depth)), [0, 0, 0]);
});

test('scan reveals one more level per expanded directory', () => {
  const nodes = FileTree.scan(accessWith(TREE), ['alpha']);
  assert.deepEqual(plain(nodes.map((n) => n.relPath)), [
    'alpha', 'alpha/a.md', 'alpha/deep', 'docs', 'root.md'
  ]);
  // 目录子树整体排在文件之前 —— 与 VaultAccess.sortVaultTree 的排序一致
  assert.deepEqual(plain(nodes.map((n) => n.isDir)), [true, false, true, true, false]);
});

test('scan exposes only the display name, keeps relPath whole', () => {
  const nodes = FileTree.scan(accessWith(TREE), ['docs']);
  const note = nodes.find((n) => n.relPath === 'docs/笔记.md');
  assert.equal(note.name, '笔记.md');
  assert.equal(note.depth, 1);
});

test('scan stops at the documented depth cap instead of walking forever', () => {
  const deep = [];
  let path = 'd0';
  for (let i = 0; i < 12; i++) {
    deep.push([path, true]);
    path = path + '/d' + (i + 1);
  }
  const nodes = FileTree.scan(accessWith(deep), deep.map((e) => e[0]));
  const deepest = Math.max(...nodes.map((n) => n.depth));
  assert.equal(deepest < FileTree.MAX_DEPTH, true,
    'MAX_DEPTH 是 UI 线程的保护阀，超深目录不能被一路展开');
});

test('allNotesOf / allDirsOf delegate to the access layer, not to the expansion state', () => {
  const access = accessWith(TREE);
  assert.deepEqual(plain(FileTree.allNotesOf(access)), ['alpha/a.md', 'alpha/deep/x.md', 'docs/笔记.md', 'root.md']);
  assert.deepEqual(plain(FileTree.allDirsOf(access)), ['alpha', 'alpha/deep', 'docs']);
});

test('parentOf keeps the classical directory-only semantics', () => {
  assert.equal(FileTree.parentOf('a/b/c.md'), 'a/b');
  assert.equal(FileTree.parentOf('root.md'), '');
});
