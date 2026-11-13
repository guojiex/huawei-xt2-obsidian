/*
 * v1.62 Pin 置顶区 —— 契约测试。
 *
 * v1.50 的「同层最前」语义已废弃（用户实测：已是本目录第一篇时置顶无可见变化），
 * 现行口径见 docs/releases/v1.62/需求文档.md。覆盖两层：
 *  1. 纯逻辑：FileTree.pinnedNotes（逆序 / 折叠文件夹可达 / 陈旧条目 / 删除恢复 /
 *     目录与重复路径 / 标题文件夹首字色板）+ notesOfEntries 一次快照同源 +
 *     resort 不再接受置顶权重（恢复 v1.49 纯规则）——沿用源码切片塞进 vm 跑。
 *  2. 源级断言：FileTreeView 置顶区接线（分区标签、取消置顶手势、toast、按库折叠键、
 *     referenceOnly 隐藏、树内 pin 标记保留）、PinStore 持久化、色板 token、
 *     零新增权限、笔记内容禁进埋点、Icons.ets pin 图标注册。
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
  ['alpha/b.markdown', false],
  ['docs', true],
  ['docs/note.md', false],
  ['docs/deep', true],
  ['docs/deep/x.md', false],
  ['root.md', false],
  ['zed.md', false]
];

const MTIMES = new Map([
  ['alpha', 5],
  ['alpha/a.md', 10],
  ['alpha/b.markdown', 1],
  ['docs', 9],
  ['docs/note.md', 3],
  ['docs/deep', 7],
  ['docs/deep/x.md', 4],
  ['root.md', 8],
  ['zed.md', 2]
]);
const mtimeOf = (relPath) => MTIMES.get(relPath) ?? -1;

/** 全量笔记（不受展开状态影响），原型 62.1 的置顶区数据源口径。 */
function allNotes() {
  return FileTree.notesOfEntries(TREE.map((e) => ({ name: e[0], isDir: e[1] })));
}

/* ------------------- 置顶区纯逻辑（62.1 / 62.4） ------------------- */

test('置顶区：数组逆序渲染＝最近置顶在前，不改数据结构', () => {
  const pinned = ['root.md', 'docs/note.md', 'alpha/a.md'];
  const rows = FileTree.pinnedNotes(allNotes(), pinned);
  assert.deepEqual(plain(rows.map((r) => r.relPath)),
    ['alpha/a.md', 'docs/note.md', 'root.md']);
  assert.deepEqual(pinned, ['root.md', 'docs/note.md', 'alpha/a.md']);
});

test('置顶区：已是所在目录第一篇也立即出现在顶部（v1.50 的核心缺陷）', () => {
  const rows = FileTree.pinnedNotes(allNotes(), ['alpha/a.md']);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].relPath, 'alpha/a.md');
  assert.equal(rows[0].folder, 'alpha');
  assert.equal(rows[0].title, 'a');
});

test('置顶区：折叠文件夹内的笔记不用展开树即可达', () => {
  // 展开集为空时 scan 看不到 docs/deep/x.md，置顶区必须仍能看到。
  const visible = FileTree.scan(accessWith(TREE), []);
  assert.equal(visible.some((n) => n.relPath === 'docs/deep/x.md'), false);
  const rows = FileTree.pinnedNotes(allNotes(), ['docs/deep/x.md']);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].folder, 'deep');
  assert.equal(rows[0].folderPath, 'docs/deep');
});

test('置顶区：陈旧条目（改名 / 移动 / 删除 / 永久删除）不显示且不自动清理', () => {
  const pinned = ['gone/old.md', 'moved.md', 'alpha/a.md'];
  const rows = FileTree.pinnedNotes(allNotes(), pinned);
  assert.deepEqual(plain(rows.map((r) => r.relPath)), ['alpha/a.md']);
  assert.deepEqual(pinned, ['gone/old.md', 'moved.md', 'alpha/a.md']);
});

test('置顶区：进回收站隐藏、恢复后自动回到原顺序（关系保留）', () => {
  const pinned = ['root.md', 'zed.md'];
  const withoutRoot = allNotes().filter((p) => p !== 'root.md');
  assert.deepEqual(plain(FileTree.pinnedNotes(withoutRoot, pinned).map((r) => r.relPath)), ['zed.md']);
  assert.deepEqual(plain(FileTree.pinnedNotes(allNotes(), pinned).map((r) => r.relPath)),
    ['zed.md', 'root.md']);
});

test('置顶区：目录路径与重复路径不产生行（仅当前库笔记文件）', () => {
  const rows = FileTree.pinnedNotes(allNotes(), ['docs', 'root.md', 'root.md', '']);
  assert.deepEqual(plain(rows.map((r) => r.relPath)), ['root.md']);
});

test('置顶区：标题剥后缀、根目录标注、首字大写、文件夹同色', () => {
  const rows = FileTree.pinnedNotes(allNotes(),
    ['zed.md', 'alpha/b.markdown', 'alpha/a.md', 'docs/note.md']);
  const byPath = Object.fromEntries(rows.map((r) => [r.relPath, r]));
  assert.equal(byPath['zed.md'].title, 'zed');
  assert.equal(byPath['zed.md'].folder, '根目录');
  assert.equal(byPath['zed.md'].folderPath, '');
  assert.equal(byPath['zed.md'].initial, 'Z');
  assert.equal(byPath['alpha/b.markdown'].title, 'b');
  assert.equal(byPath['alpha/b.markdown'].initial, 'B');
  assert.equal(byPath['alpha/a.md'].tone, byPath['alpha/b.markdown'].tone);
  for (const row of rows) {
    assert.ok(row.tone >= 0 && row.tone <= 4, '色板索引越界');
  }
});

test('置顶区：空置顶 / 空库不崩', () => {
  assert.deepEqual(plain(FileTree.pinnedNotes(allNotes(), [])), []);
  assert.deepEqual(plain(FileTree.pinnedNotes([], ['root.md'])), []);
  assert.equal(FileTree.notesOfEntries([]).length, 0);
  assert.equal(FileTree.notesOfEntries(
    [{ name: 'docs', isDir: true }]).length, 0);
});

/* ------------------- 树内排序恢复 v1.49（62.2） ------------------- */

test('resort：name 模式不受置顶影响，走快路径原样返回', () => {
  const nodes = FileTree.scan(accessWith(TREE), ['alpha', 'docs', 'docs/deep']);
  const out = FileTree.resort(nodes, 'name', mtimeOf);
  assert.equal(out, nodes, 'name 模式必须原样返回');
  assert.deepEqual(plain(out.map((n) => n.relPath)), plain(nodes.map((n) => n.relPath)));
});

test('resort：mtime 模式按时间降序，目录前文件后、父先于子不变式不破', () => {
  const nodes = FileTree.scan(accessWith(TREE), ['alpha', 'docs', 'docs/deep']);
  const out = FileTree.resort(nodes, 'mtime', mtimeOf);
  assert.deepEqual(plain(out.map((n) => n.relPath)), [
    'docs', 'docs/deep', 'docs/deep/x.md', 'docs/note.md',
    'alpha', 'alpha/a.md', 'alpha/b.markdown',
    'root.md', 'zed.md'
  ]);
  const seen = new Set();
  for (const n of out) {
    const parent = FileTree.parentOf(n.relPath);
    if (parent.length > 0) assert.ok(seen.has(parent), `父目录 ${parent} 未先于 ${n.relPath}`);
    seen.add(n.relPath);
  }
});

test('resort：签名已去掉 pinned 参数，比较器无置顶分支', () => {
  assert.match(source, /static resort\(nodes: TreeNode\[\], mode: FileListSortMode,\n    mtimeOf: \(relPath: string\) => number\): TreeNode\[\]/);
  assert.doesNotMatch(source, /compareSiblings\(a, b, mode, mtimeOf, pinned\)/);
  assert.doesNotMatch(source, /const aPinned: boolean/);
});

/* ---------------------------- 源级断言 ---------------------------- */

const fileTreeViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const iconsSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));
const tokensSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const moduleSource = readSourceFile(
  new URL('../../entry/src/main/module.json5', import.meta.url));

test('源级：PinStore 按库持久化置顶与置顶区折叠（默认展开、坏值回退）', () => {
  assert.match(source, /export class PinStore/);
  assert.match(source, /'pinned_' \+ vaultId/);
  assert.match(source, /getSync\('pinned_' \+ vaultId, '\[\]'\)/);
  assert.match(source, /Array\.isArray\(parsed\) \? parsed : \[\];/);
  assert.match(source, /getSync\('pinSectionOpen_' \+ vaultId, true\)/);
  assert.match(source, /putSync\('pinSectionOpen_' \+ vaultId, open\)/);
  assert.match(source, /return typeof raw === 'boolean' \? raw : true;/);
});

test('源级：置顶区与树同源一次 snapshot，行键独立、折叠按库记忆', () => {
  assert.match(fileTreeViewSource, /@State pinRows: PinnedNote\[\] = \[\];/);
  assert.match(fileTreeViewSource, /@State pinSectionOpen: boolean = true;/);
  assert.match(fileTreeViewSource, /const entries: VaultDirChild\[\] = access\.snapshot\(\);/);
  assert.match(fileTreeViewSource, /FileTree\.scanEntries\(entries, this\.expanded\)/);
  assert.match(fileTreeViewSource,
    /FileTree\.pinnedNotes\(FileTree\.notesOfEntries\(entries\), this\.pinned\)/);
  assert.match(fileTreeViewSource, /class PinRowDataSource implements IDataSource/);
  assert.match(fileTreeViewSource, /return 'pin-' \+ row\.relPath/);
  assert.match(fileTreeViewSource, /pins\.loadSectionOpen\(this\.vaultId\)/);
  assert.match(fileTreeViewSource, /pins\.saveSectionOpen\(this\.vaultId, next\)/);
});

test('源级：分区标签与行形态（置顶 / 全部笔记 / 首字色块 / 只对当前笔记变品牌色）', () => {
  assert.match(fileTreeViewSource, /!this\.referenceOnly && this\.pinRows\.length > 0/);
  assert.match(fileTreeViewSource, /this\.PinSection\(\)/);
  assert.match(fileTreeViewSource, /this\.AllNotesLabel\(\)/);
  assert.match(fileTreeViewSource, /Text\('置顶'\)/);
  assert.match(fileTreeViewSource, /Text\('全部笔记'\)/);
  assert.match(fileTreeViewSource, /\.letterSpacing\(Size\.pinLabelTracking\)/);
  assert.match(fileTreeViewSource, /\.width\(Size\.pinMonogram\)/);
  assert.match(fileTreeViewSource, /this\.pinToneFg\(row\.tone\)/);
  assert.match(fileTreeViewSource, /this\.pinToneBg\(row\.tone\)/);
  assert.match(fileTreeViewSource, /打开置顶的笔记：/);
  assert.match(fileTreeViewSource, /\.hitTestBehavior\(HitTestMode\.None\)/);
  // 置顶区行不加底色高亮（底色留给目录树）
  const pinRowBlock = fileTreeViewSource.slice(
    fileTreeViewSource.indexOf('  PinRow(row: PinnedNote)'),
    fileTreeViewSource.indexOf('  /** 置顶区左滑操作条'));
  assert.ok(pinRowBlock.length > 0, '找不到 PinRow 实现');
  assert.doesNotMatch(pinRowBlock, /brand_bg_solid/);
});

test('源级：取消置顶双入口与 toast（不复用树行删除手势）', () => {
  assert.match(fileTreeViewSource, /private togglePin\(node: TreeNode\): void/);
  assert.match(fileTreeViewSource, /if \(node\.isDir\) \{\s*return;\s*\}/);
  assert.match(fileTreeViewSource, /private togglePinPath\(relPath: string\): void/);
  assert.match(fileTreeViewSource, /pins\.save\(this\.vaultId, next\)/);
  assert.match(fileTreeViewSource, /'已置顶：'/);
  assert.match(fileTreeViewSource, /'已取消置顶：'/);
  assert.match(fileTreeViewSource, /promptAction\.showToast/);
  assert.match(fileTreeViewSource, /· 松手取消置顶/);
  assert.match(fileTreeViewSource, /actionAreaDistance: Size\.swipeDelExtra/);
  assert.match(fileTreeViewSource,
    /onAction: \(\): void => \{ this\.togglePinPath\(row\.relPath\); \}/);
  assert.match(fileTreeViewSource, /this\.pinRowActive\(row\.relPath\)/);
  assert.match(fileTreeViewSource, /取消置顶：/);
});

test('源级：树内入口与 pin 标记沿用 v1.50（LazyForEach 键含置顶态）', () => {
  assert.match(fileTreeViewSource, /this\.isPinned\(n\.relPath\) \? '已置顶' : '置顶'/);
  assert.match(fileTreeViewSource, /this\.isPinned\(n\.relPath\) \? '取消置顶' : '置顶'/);
  assert.match(fileTreeViewSource, /if \(action === 'pin'\) \{/);
  assert.match(fileTreeViewSource, /Icon\('pin', 12, \$r\('app\.color\.text_tertiary'\)\)/);
  assert.match(fileTreeViewSource, /this\.isPinned\(n\.relPath\) \? '\|pin' : ''/);
});

test('源级：颜色 / 尺寸只走 token，深浅色各有一套 callout 色板', () => {
  assert.match(tokensSource, /static readonly pinRowH: number/);
  assert.match(tokensSource, /static readonly pinMonogramRadius: number/);
  for (const theme of ['base', 'dark']) {
    const colors = readSourceFile(
      new URL(`../../entry/src/main/resources/${theme}/element/color.json`, import.meta.url));
    for (const name of ['cb_note', 'cb_tip', 'cb_warn', 'cb_purple', 'cb_gray']) {
      assert.match(colors, new RegExp(`"name": "${name}"`), `${theme} 缺 ${name}`);
      assert.match(colors, new RegExp(`"name": "${name}_bg"`), `${theme} 缺 ${name}_bg`);
    }
  }
});

test('源级：零新增权限 + 笔记标题 / 路径 / 篇数不进埋点', () => {
  const permissions = Array.from(moduleSource.matchAll(/"name":\s*"(ohos\.permission\.[A-Z_]+)"/g))
    .map((m) => m[1]);
  assert.deepEqual(permissions, [
    'ohos.permission.INTERNET',
    'ohos.permission.FILE_ACCESS_PERSIST'
  ]);
  assert.doesNotMatch(fileTreeViewSource, /hiAppEvent/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*row\.title/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*relPath/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*pinRows\.length/);
});

test('源级：Icons 注册 pin 图标（防线：不编造图标名）', () => {
  assert.match(iconsSource, /const P_PIN: string =/);
  assert.match(iconsSource, /name === 'pin'/);
});
