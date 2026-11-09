/*
 * v1.49 文件列表按时间排序 —— 契约测试。
 *
 * 覆盖两层：
 *  1. 纯逻辑：FileTree.resort（名称直通、mtime 降序、目录前文件后、平局名称升序稳定、
 *     父先于子不变式、stat 失败按最旧、折叠子树不消耗）——沿用 test_file_tree_snapshot
 *     的源码切片套路（FileTree 类体塞进 vm 跑，不碰 preferences/@kit）。
 *  2. 源级断言：FileTreeView 接线（sortMode @Watch + rescan 内 resort）、
 *     VaultSidebar 入口与持久化（FileListSortStore load/save、sort 按钮、传参）、
 *     Icons.ets sort 图标注册。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = readSourceFile(
  new URL('../../entry/src/main/ets/model/FileTree.ets', import.meta.url));
const start = source.indexOf('export class FileTree {');
const end = source.indexOf('/**\n * ExpandStore');
assert.ok(start >= 0 && end > start, '找不到 FileTree 类体');

const code = transformSync(
  source.slice(start, end).replace('export class', 'class') +
  '\nmodule.exports = { FileTree };', { loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({ module: { exports: {} }, console });
vm.runInContext(code, context);
const { FileTree } = context.module.exports;

function plain(values) {
  return JSON.parse(JSON.stringify(values));
}

function accessWith(entries) {
  return {
    kind: 'sandbox',
    snapshot() {
      return entries.map((e) => ({ name: e[0], isDir: e[1] }));
    },
    allNotes() { return []; },
    allDirs() { return []; }
  };
}

const TREE = [
  ['alpha', true],
  ['alpha/a.md', false],
  ['alpha/deep', true],
  ['alpha/deep/x.md', false],
  ['docs', true],
  ['docs/note.md', false],
  ['root.md', false]
];

const MTIMES = new Map([
  ['alpha', 5],
  ['alpha/a.md', 10],
  ['alpha/deep', 7],
  ['alpha/deep/x.md', 3],
  ['docs', 9],
  ['docs/note.md', 1],
  ['root.md', 8]
]);

const mtimeOf = (relPath) => MTIMES.get(relPath) ?? -1;

function visibleNodes() {
  return FileTree.scan(accessWith(TREE), ['alpha', 'docs', 'alpha/deep']);
}

test('resort: name 模式原样返回（scan 已排好）', () => {
  const nodes = visibleNodes();
  const out = FileTree.resort(nodes, 'name', mtimeOf);
  assert.deepEqual(plain(out.map((n) => n.relPath)),
    plain(nodes.map((n) => n.relPath)));
});

test('resort: mtime 模式目录前文件后，同组按 mtime 降序', () => {
  const out = FileTree.resort(visibleNodes(), 'mtime', mtimeOf);
  // 根层：目录 [docs(9), alpha(5)] 降序 → docs 先；文件 [root.md(8)] 随后。
  // alpha 子层：目录 [deep(7)] 在前、文件 [a.md(10)] 在后（分组先后不因 mtime 翻转）。
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'docs', 'docs/note.md',
    'alpha', 'alpha/deep', 'alpha/deep/x.md', 'alpha/a.md',
    'root.md'
  ]);
});

test('resort: 父目录永远在子项之前（扁平 DFS 结构不破）', () => {
  const out = FileTree.resort(visibleNodes(), 'mtime', mtimeOf);
  const seen = new Set();
  for (const n of out) {
    const parent = FileTree.parentOf(n.relPath);
    if (parent.length > 0) {
      assert.ok(seen.has(parent), `父目录 ${parent} 未先于 ${n.relPath} 出现`);
    }
    seen.add(n.relPath);
  }
});

test('resort: mtime 相同按名称升序稳定', () => {
  const entries = [
    ['b.md', false], ['a.md', false], ['zz', true], ['aa', true]
  ];
  const nodes = FileTree.scan(accessWith(entries), []);
  const sameTime = () => 42;
  const out = FileTree.resort(nodes, 'mtime', sameTime);
  assert.deepEqual(plain(out.map((n) => n.relPath)), ['aa', 'zz', 'a.md', 'b.md']);
});

test('resort: stat 失败（返回负值）按最旧处理，排序不崩', () => {
  const entries = [
    ['gone.md', false], ['fresh.md', false], ['mid.md', false]
  ];
  const nodes = FileTree.scan(accessWith(entries), []);
  const brokenStat = (relPath) => (relPath === 'gone.md' ? -1 : MTIMES.get(relPath) ?? -1);
  const out = FileTree.resort(nodes, 'mtime', brokenStat);
  // mid(默认 -1) 与 gone(-1) 都拿不到：按名称升序在尾部；fresh 有值在最前。
  assert.deepEqual(plain(out.map((n) => n.relPath)), ['fresh.md', 'gone.md', 'mid.md']);
});

test('resort: 折叠子树不进入输入，重排不凭空造行', () => {
  const collapsed = FileTree.scan(accessWith(TREE), []);
  const out = FileTree.resort(collapsed, 'mtime', mtimeOf);
  assert.deepEqual(plain(out.map((n) => n.relPath)), ['docs', 'alpha', 'root.md']);
  assert.equal(out.length, 3);
});

test('resort: 空树与全文件根不崩', () => {
  assert.deepEqual(plain(FileTree.resort([], 'mtime', mtimeOf)), []);
  const files = FileTree.scan(accessWith([['c.md', false], ['a.md', false]]), []);
  assert.deepEqual(plain(FileTree.resort(files, 'mtime', () => 1).map((n) => n.relPath)),
    ['a.md', 'c.md']);
});

/* ---------------------------- 源级断言 ---------------------------- */

const fileTreeSource = source;
const fileTreeViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const vaultSidebarSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url));
const iconsSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));

test('源级：FileTree 声明排序模式类型与偏好存储（默认 name，坏值回退）', () => {
  assert.match(fileTreeSource, /export type FileListSortMode = 'name' \| 'mtime';/);
  assert.match(fileTreeSource, /class FileListSortStore/);
  assert.match(fileTreeSource, /'sort_mode'/);
  assert.match(fileTreeSource, /return raw === 'mtime' \? 'mtime' : 'name';/);
});

test('源级：FileTreeView 接线 sortMode @Watch 并在 rescan 内重排', () => {
  assert.match(fileTreeViewSource,
    /@Prop @Watch\('onSortChanged'\) sortMode: string = 'name';/);
  assert.match(fileTreeViewSource, /private onSortChanged\(\): void \{\s*this\.rescan\(\);/);
  assert.match(fileTreeViewSource, /FileTree\.resort\(nodes, 'mtime'/);
  assert.match(fileTreeViewSource, /access\.stat\(relPath\)/);
  assert.match(fileTreeViewSource, /meta === null \? -1 : meta\.mtimeSec/);
});

test('源级：VaultSidebar 排序入口、菜单与持久化', () => {
  assert.match(vaultSidebarSource, /new FileListSortStore\(VaultRegistry\.get\(\)\.abilityContext\(\)\)/);
  assert.match(vaultSidebarSource, /\.load\(\)/);
  assert.match(vaultSidebarSource, /\.save\(mode\)/);
  assert.match(vaultSidebarSource, /id\('vault-sidebar-sort'\)/);
  assert.match(vaultSidebarSource, /builder: this\.SortMenu\(\)/);
  assert.match(vaultSidebarSource, /sortMode: this\.sortMode,/);
  assert.match(vaultSidebarSource, /按修改时间排序/);
});

test('源级：Icons 注册 sort 图标（防线：不编造图标名）', () => {
  assert.match(iconsSource, /const P_SORT: string =/);
  assert.match(iconsSource, /name === 'sort'/);
});
