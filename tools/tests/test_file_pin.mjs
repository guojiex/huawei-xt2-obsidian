/*
 * v1.50 Pin 置顶（文件列表）—— 契约测试。
 *
 * 覆盖两层：
 *  1. 纯逻辑：FileTree.resort 的置顶权重（置顶最前高于目录、两种排序模式均生效、
 *     置顶组内按模式、父先于子不变式、陈旧置顶条目无副作用、目录行不受置顶影响）
 *     ——沿用 test_file_list_sort 的源码切片套路（FileTree 类体塞进 vm 跑）。
 *  2. 源级断言：FileTreeView 接线（PinStore 加载/保存、togglePin、SwipeBar 与
 *     PathActionsMenu 入口、行内 pin 标记、LazyForEach 键含置顶态）、
 *     FileTree PinStore 持久化（pinned_<vaultId>）、Icons.ets pin 图标注册。
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
  ['alpha/b.md', false],
  ['docs', true],
  ['docs/note.md', false],
  ['root.md', false],
  ['zed.md', false]
];

const MTIMES = new Map([
  ['alpha', 5],
  ['alpha/a.md', 10],
  ['alpha/b.md', 1],
  ['docs', 9],
  ['docs/note.md', 3],
  ['root.md', 8],
  ['zed.md', 2]
]);

const mtimeOf = (relPath) => MTIMES.get(relPath) ?? -1;

function visibleNodes() {
  return FileTree.scan(accessWith(TREE), ['alpha', 'docs']);
}

test('resort: name 模式下置顶笔记排同层最前（高于目录）', () => {
  const out = FileTree.resort(visibleNodes(), 'name', mtimeOf, ['zed.md']);
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'zed.md',
    'alpha', 'alpha/a.md', 'alpha/b.md',
    'docs', 'docs/note.md',
    'root.md'
  ]);
});

test('resort: mtime 模式下置顶权重同样生效（与排序模式正交）', () => {
  const out = FileTree.resort(visibleNodes(), 'mtime', mtimeOf, ['zed.md']);
  // 置顶 zed.md 最前；其余按 mtime：docs(9) > alpha(5)；
  // alpha 子层 a.md(10) > b.md(1) 降序。
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'zed.md',
    'docs', 'docs/note.md',
    'alpha', 'alpha/a.md', 'alpha/b.md',
    'root.md'
  ]);
});

test('resort: 子目录内置顶只影响该父层，父先于子不变式不破', () => {
  const out = FileTree.resort(visibleNodes(), 'name', mtimeOf, ['alpha/b.md']);
  // 根层原序（b.md 的置顶不外溢到根层）；alpha 子层 b.md 置顶后跳到 a.md 之前。
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'alpha', 'alpha/b.md', 'alpha/a.md',
    'docs', 'docs/note.md',
    'root.md', 'zed.md'
  ]);
});

test('resort: 多个置顶笔记组内按当前模式排（mtime 降序）', () => {
  const out = FileTree.resort(visibleNodes(), 'mtime', mtimeOf, ['root.md', 'zed.md']);
  // 置顶组：root.md(8) > zed.md(2) 降序；其余照旧（docs(9) > alpha(5)，a.md(10) > b.md(1)）。
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'root.md', 'zed.md',
    'docs', 'docs/note.md',
    'alpha', 'alpha/a.md', 'alpha/b.md'
  ]);
});

test('resort: 置顶与取消置顶往返一致（togglePin → rescan 从 scan 重新开始）', () => {
  // 真实链路：切换置顶后 rescan 重新 scan（规范序）再 resort；
  // 取消置顶 → 空 pinned + name 模式走快路径，恢复 scan 序。
  const pinned = FileTree.resort(visibleNodes(), 'name', mtimeOf, ['root.md']);
  assert.deepEqual(plain(pinned.map((n) => n.relPath)), [
    'root.md',
    'alpha', 'alpha/a.md', 'alpha/b.md',
    'docs', 'docs/note.md',
    'zed.md'
  ]);
  const restored = FileTree.resort(visibleNodes(), 'name', mtimeOf, []);
  assert.deepEqual(plain(restored.map((n) => n.relPath)),
    plain(visibleNodes().map((n) => n.relPath)));
});

test('resort: 陈旧置顶条目（已改名/删除）无副作用，name 快路径不触发重排', () => {
  const out = FileTree.resort(visibleNodes(), 'name', mtimeOf, ['gone/old.md', 'moved.md']);
  assert.deepEqual(plain(out.map((n) => n.relPath)),
    plain(visibleNodes().map((n) => n.relPath)));
});

test('resort: 置顶列表里的目录路径不产生权重（仅笔记文件行可置顶）', () => {
  // PinStore 允许任何字符串进来，但目录行不认：docs 仍在 alpha 之前按 name 序。
  const out = FileTree.resort(visibleNodes(), 'name', mtimeOf, ['docs']);
  assert.deepEqual(plain(out.map((n) => n.relPath)),
    plain(visibleNodes().map((n) => n.relPath)));
});

test('resort: 空树与空置顶不崩', () => {
  assert.deepEqual(plain(FileTree.resort([], 'name', mtimeOf, ['x.md'])), []);
  assert.deepEqual(plain(FileTree.resort([], 'mtime', mtimeOf, [])), []);
});

/* ---------------------------- 源级断言 ---------------------------- */

const fileTreeSource = source;
const fileTreeViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const iconsSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));

test('源级：FileTree 声明 PinStore 按库持久化（pinned_<vaultId>，坏值回退）', () => {
  assert.match(fileTreeSource, /export class PinStore/);
  assert.match(fileTreeSource, /'pinned_' \+ vaultId/);
  assert.match(fileTreeSource, /getSync\('pinned_' \+ vaultId, '\[\]'\)/);
  assert.match(fileTreeSource, /Array\.isArray\(parsed\) \? parsed : \[\];/);
});

test('源级：FileTreeView 接线置顶（加载/保存/切换/重排参数）', () => {
  assert.match(fileTreeViewSource, /@State pinned: string\[\] = \[\];/);
  assert.match(fileTreeViewSource, /private ensurePinStore\(\): void/);
  assert.match(fileTreeViewSource, /new PinStore\(VaultRegistry\.get\(\)\.abilityContext\(\)\)/);
  assert.match(fileTreeViewSource, /pins\.load\(this\.vaultId\)/);
  assert.match(fileTreeViewSource, /pins\.save\(this\.vaultId, next\)/);
  assert.match(fileTreeViewSource, /private togglePin\(node: TreeNode\): void/);
  assert.match(fileTreeViewSource, /if \(node\.isDir\) \{\s*return;\s*\}/);
  // rescan 的 resort 第 4 参传置顶集合
  assert.match(fileTreeViewSource, /\}, this\.pinned\);/);
});

test('源级：置顶双入口——SwipeBar 与 PathActionsMenu（目录行不出现）', () => {
  assert.match(fileTreeViewSource, /this\.isPinned\(n\.relPath\) \? '已置顶' : '置顶'/);
  assert.match(fileTreeViewSource, /this\.isPinned\(n\.relPath\) \? '取消置顶' : '置顶'/);
  assert.match(fileTreeViewSource, /if \(action === 'pin'\) \{/);
  // 防线：Icon( 实参不含 this.（icon 冻结），置顶标记图标照旧字面量
  assert.match(fileTreeViewSource, /Icon\('pin', 12, \$r\('app\.color\.text_tertiary'\)\)/);
});

test('源级：LazyForEach 键含置顶态（faqs-arkui-219：键不变行不刷新）', () => {
  assert.match(fileTreeViewSource,
    /this\.isPinned\(n\.relPath\) \? '\|pin' : ''/);
});

test('源级：Icons 注册 pin 图标（防线：不编造图标名）', () => {
  assert.match(iconsSource, /const P_PIN: string =/);
  assert.match(iconsSource, /name === 'pin'/);
});
