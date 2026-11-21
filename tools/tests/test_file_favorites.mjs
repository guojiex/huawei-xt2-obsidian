/*
 * v1.97 收藏列表 —— 契约测试。
 *
 * 口径见 docs/releases/v1.97/需求文档.md（设计规格真源：v1.54 §54.1–54.3 第三稿）。
 * 覆盖两层：
 *  1. 纯逻辑：FavoriteStore（按库持久化 / 坏值回退 / removePaths 永久删除清理 /
 *     retarget 改名移动 / 折叠默认展开）——源码切片 + 伪造 preferences 塞进 vm 跑；
 *     收藏行解析与置顶行同构（复用 FileTree.pinnedNotes），语义用例在 test_file_pin.mjs。
 *  2. 源级断言：FileTreeView 收藏区接线（四段布局顺序、行组件共用、左滑移出、
 *     树行星标字面量分支、行键 |fav）、Index 菜单入口与清理接线、Icons star 注册、
 *     零新增权限、笔记内容禁进埋点。
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
const start = source.indexOf('export class FavoriteStore');
assert.ok(start >= 0, '找不到 FavoriteStore 类体');

const code = transformSync(
  source.slice(start).replace('export class', 'class') +
  '\nmodule.exports = { FavoriteStore };', { loader: 'ts', format: 'cjs' }).code;

/** 伪造 preferences：内存 Map，接口面与 FavoriteStore 用到的完全一致。 */
function fakePrefs() {
  const map = new Map();
  return {
    getSync(key, def) { return map.has(key) ? map.get(key) : def; },
    putSync(key, value) { map.set(key, value); },
    flush() {}
  };
}

function makeStore(prefs) {
  const context = vm.createContext({
    module: { exports: {} },
    console,
    // FavoriteStore 的 catch 分支引用文件顶部的 DOMAIN / TAG 常量（不在切片内）。
    DOMAIN: 0,
    TAG: 'FileTree',
    preferences: { getPreferencesSync: () => prefs() },
    hilog: { error() {} },
    BusinessError: class {}
  });
  vm.runInContext(code, context);
  return context.module.exports.FavoriteStore;
}

/** vm realm 的数组与主 realm 原型不同，deepStrictEqual 会判不等，先过 JSON 归一。 */
function plain(values) {
  return JSON.parse(JSON.stringify(values));
}

function eq(actual, expected) {
  assert.deepEqual(plain(actual), expected);
}

/* ------------------- FavoriteStore 纯逻辑（97.3） ------------------- */

test('收藏：按库持久化，库间互不可见，数组顺序即收藏先后', () => {
  const FavoriteStore = makeStore(fakePrefs);
  const store = new FavoriteStore({});
  store.save('vaultA', ['a.md', 'b.md']);
  store.save('vaultB', ['c.md']);
  eq(store.load('vaultA'), ['a.md', 'b.md']);
  eq(store.load('vaultB'), ['c.md']);
  eq(store.load(''), []);
});

test('收藏：坏值 JSON 回退空数组，不抛异常', () => {
  const map = new Map([['favorites_bad', '{oops']]);
  const FavoriteStore = makeStore(() => ({
    getSync: (key, def) => (map.has(key) ? map.get(key) : def),
    putSync: (key, value) => map.set(key, value),
    flush() {}
  }));
  const store = new FavoriteStore({});
  eq(store.load('bad'), []);
});

test('收藏：preferences 打不开（构造失败）时全部读写为安全空操作', () => {
  const FavoriteStore = makeStore(() => { throw new Error('no prefs'); });
  const store = new FavoriteStore({});
  eq(store.load('vaultA'), []);
  store.save('vaultA', ['a.md']);
  store.removePaths('vaultA', ['a.md']);
  store.retarget('vaultA', 'a.md', 'b.md', false);
  assert.equal(store.loadSectionOpen('vaultA'), true);
  store.saveSectionOpen('vaultA', false);
});

test('收藏折叠：默认展开，按库记忆，坏值回退展开（97.1）', () => {
  const FavoriteStore = makeStore(fakePrefs);
  const store = new FavoriteStore({});
  assert.equal(store.loadSectionOpen('vaultA'), true);
  store.saveSectionOpen('vaultA', false);
  assert.equal(store.loadSectionOpen('vaultA'), false);
  assert.equal(store.loadSectionOpen('vaultB'), true);
  assert.equal(store.loadSectionOpen(''), true);
});

test('永久删除清理：removePaths 只删列出条目，其余保序保留（97.3，55.3 遗留补齐）', () => {
  const FavoriteStore = makeStore(fakePrefs);
  const store = new FavoriteStore({});
  store.save('vaultA', ['keep.md', 'gone.md', 'keep2.md']);
  store.removePaths('vaultA', ['gone.md', 'not-in-list.md']);
  eq(store.load('vaultA'), ['keep.md', 'keep2.md']);
  // 空列表 = 无操作
  store.removePaths('vaultA', []);
  eq(store.load('vaultA'), ['keep.md', 'keep2.md']);
  // 全没命中 = 不写盘（内容不变）
  store.removePaths('vaultA', ['nope.md']);
  eq(store.load('vaultA'), ['keep.md', 'keep2.md']);
});

test('改名 / 移动 retarget：文件整条替换，目录前缀一并改写，保序（54.3）', () => {
  const FavoriteStore = makeStore(fakePrefs);
  const store = new FavoriteStore({});
  store.save('vaultA', ['docs/x.md', 'root.md', 'docs/deep/y.md', 'other.md']);
  // 目录移动：docs → guides
  store.retarget('vaultA', 'docs', 'guides', true);
  eq(store.load('vaultA'), ['guides/x.md', 'root.md', 'guides/deep/y.md', 'other.md']);
  // 文件改名
  store.retarget('vaultA', 'root.md', 'renamed.md', false);
  eq(store.load('vaultA'), ['guides/x.md', 'renamed.md', 'guides/deep/y.md', 'other.md']);
  // 前缀必须是目录级：doc ≠ docs，不得误伤
  store.save('vaultB', ['docs/a.md', 'document.md']);
  store.retarget('vaultB', 'doc', 'd', true);
  eq(store.load('vaultB'), ['docs/a.md', 'document.md']);
  // 新旧同路径 = 无操作
  store.retarget('vaultB', 'docs/a.md', 'docs/a.md', false);
  eq(store.load('vaultB'), ['docs/a.md', 'document.md']);
});

/* ---------------------------- 源级断言 ---------------------------- */

const fileTreeViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const iconsSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));
const moduleSource = readSourceFile(
  new URL('../../entry/src/main/module.json5', import.meta.url));

test('源级：FavoriteStore 按库持久化收藏与折叠（默认展开、坏值回退）', () => {
  assert.match(source, /export class FavoriteStore/);
  assert.match(source, /'favorites_' \+ vaultId/);
  assert.match(source, /getSync\('favorites_' \+ vaultId, '\[\]'\)/);
  assert.match(source, /putSync\('favorites_' \+ vaultId, JSON\.stringify\(favorites\)\)/);
  assert.match(source, /getSync\('favSectionOpen_' \+ vaultId, true\)/);
  assert.match(source, /putSync\('favSectionOpen_' \+ vaultId, open\)/);
  assert.match(source, /removePaths\(vaultId: string, paths: string\[\]\): void/);
  assert.match(source, /retarget\(vaultId: string, oldPath: string, newPath: string, isDir: boolean\): void/);
});

test('源级：收藏区与置顶 / 树同源一次 snapshot，行组件共用不写两套（v1.62 承诺）', () => {
  assert.match(fileTreeViewSource, /@State favorites: string\[\] = \[\];/);
  assert.match(fileTreeViewSource, /@State favRows: PinnedNote\[\] = \[\];/);
  assert.match(fileTreeViewSource, /@State favSectionOpen: boolean = true;/);
  assert.match(fileTreeViewSource,
    /FileTree\.pinnedNotes\(FileTree\.notesOfEntries\(entries\), this\.favorites\)/);
  assert.match(fileTreeViewSource, /this\.SectionRow\(row, true\)/);
  assert.match(fileTreeViewSource, /this\.SectionRow\(row, false\)/);
  assert.match(fileTreeViewSource, /favs\.loadSectionOpen\(this\.vaultId\)/);
  assert.match(fileTreeViewSource, /favs\.saveSectionOpen\(this\.vaultId, next\)/);
  assert.match(fileTreeViewSource, /favs\.save\(this\.vaultId, next\)/);
});

test('源级：四段布局 置顶 → 收藏 → 全部笔记 → 树，referenceOnly 全隐藏', () => {
  const layout = fileTreeViewSource.slice(
    fileTreeViewSource.indexOf('      Column() {\n        if (!this.referenceOnly && this.pinRows.length > 0)'));
  assert.ok(layout.length > 0, '找不到 build 布局段');
  const iPin = layout.indexOf('this.PinSection()');
  const iFav = layout.indexOf('this.FavSection()');
  const iLabel = layout.indexOf('this.AllNotesLabel()');
  const iTree = layout.indexOf('this.TreeList()');
  assert.ok(iPin >= 0 && iFav > iPin && iLabel > iFav && iTree > iLabel, '四段顺序错误');
  assert.match(fileTreeViewSource, /!this\.referenceOnly && this\.favRows\.length > 0/);
  assert.match(fileTreeViewSource, /!this\.referenceOnly && \(this\.pinRows\.length > 0 \|\| this\.favRows\.length > 0\)/);
  assert.match(fileTreeViewSource, /Text\('收藏'\)/);
  assert.match(fileTreeViewSource, /打开收藏的笔记：/);
  assert.match(fileTreeViewSource, /收藏，' \+ this\.favRows\.length\.toString\(\) \+ ' 篇笔记/);
});

test('源级：收藏行键独立空间 + 悬停态进键（faqs-arkui-219）', () => {
  assert.match(fileTreeViewSource, /return 'fav-' \+ row\.relPath/);
  assert.match(fileTreeViewSource, /this\.favRowActive\(row\.relPath\) \? '\|act' : ''/);
  assert.match(fileTreeViewSource, /\(isPin \? 'pin-row-' : 'fav-row-'\) \+ this\.vaultId \+ ':' \+ row\.relPath/);
});

test('源级：移出收藏双入口与 toast（左滑滑到底 = 移出，非删除语义）', () => {
  assert.match(fileTreeViewSource, /private toggleFavoritePath\(relPath: string\): void/);
  assert.match(fileTreeViewSource, /'已收藏：'/);
  assert.match(fileTreeViewSource, /'已取消收藏：'/);
  assert.match(fileTreeViewSource, /· 松手移出/);
  assert.match(fileTreeViewSource, /Text\('移出收藏'\)/);
  assert.match(fileTreeViewSource,
    /onAction: \(\): void => \{ this\.toggleFavoritePath\(row\.relPath\); \}/);
  assert.match(fileTreeViewSource, /this\.favHoverPath = isHover \? row\.relPath : '';/);
});

test('源级：树行星标常显 muted + 字面量分支（97.2 口径修订，Z2 首帧固化）+ 行键 |fav', () => {
  assert.match(fileTreeViewSource, /if \(!n\.isDir && !this\.referenceOnly\) \{\s*Row\(\) \{\s*if \(this\.isFavorite\(n\.relPath\)\) \{\s*Icon\('starFilled', Space\.s4, \$r\('app\.color\.text_tertiary'\)\)\s*\} else \{\s*Icon\('star', Space\.s4, \$r\('app\.color\.text_tertiary'\)\)/);
  assert.match(fileTreeViewSource, /this\.isFavorite\(n\.relPath\) \? '\|fav' : ''/);
  assert.match(fileTreeViewSource, /\(this\.isFavorite\(n\.relPath\) \? '取消收藏：' : '收藏：'\) \+ n\.name/);
});

test('源级：Index「⋯」菜单入口 + 永久删除清理 + 改名 / 移动 retarget（97.2 / 97.3）', () => {
  assert.match(indexSource, /private favoriteStore: FavoriteStore \| null = null;/);
  assert.match(indexSource, /private ensureFavoriteStore\(\): void/);
  assert.match(indexSource, /private isFavoriteNote\(relPath: string\): boolean/);
  assert.match(indexSource, /private toggleFavoriteActiveNote\(\): void/);
  assert.match(indexSource, /MobileMoreMenuItem\('favorite', 'star',/);
  assert.match(indexSource, /'取消收藏此笔记' : '收藏此笔记'/);
  assert.match(indexSource, /removePaths\(this\.currentVaultId, \[relPath\]\)/);
  assert.match(indexSource, /removePaths\(this\.currentVaultId, outcome\.succeeded\)/);
  const retargetCount = (indexSource.match(/\(this\.favoriteStore as FavoriteStore\)\.retarget/g) ?? []).length;
  assert.equal(retargetCount, 2, '改名 / 移动两处都要 retarget 收藏关系');
});

test('源级：Icons 注册 star / starFilled（描边 / 填充），不编造图标名', () => {
  assert.match(iconsSource, /const P_STAR: string =/);
  assert.match(iconsSource, /name === 'star'/);
  assert.match(iconsSource, /name === 'starFilled'/);
  assert.match(iconsSource, /const FILLED_ICONS: string\[\] = \['sync', 'starFilled'\];/);
});

test('回归：图标路径常量禁止 -. 无前导零小数（scalePath 会拆坏路径导致图标不渲染）', () => {
  // 2026-11-21 用户真机反馈「收藏此笔记」菜单无图标：P_STAR 写了 -.61，scalePath 正则
  // 要求小数点前有数字，匹配不上就只缩放尾数 61，路径畸形 → Path 解析失败整颗不画。
  const constantLines = iconsSource.split('\n').filter((line) => /^const P_[A-Z_]+/.test(line.trim()) || /^\s*'[^']*' \+?$/.test(line));
  assert.ok(constantLines.length > 30, '应能收集到图标路径常量行');
  for (const line of constantLines) {
    assert.doesNotMatch(line, /-\.\d/, `路径常量含 -. 无前导零小数（scalePath 会拆坏）：${line.trim().slice(0, 60)}`);
    assert.doesNotMatch(line, /\s\.\d/, `路径命令含空格后 .小数（缺前导数字）：${line.trim().slice(0, 60)}`);
  }
});

test('源级：零新增权限 + 收藏标题 / 路径 / 篇数不进埋点', () => {
  const permissions = Array.from(moduleSource.matchAll(/"name":\s*"(ohos\.permission\.[A-Z_]+)"/g))
    .map((m) => m[1]);
  assert.deepEqual(permissions, [
    'ohos.permission.INTERNET',
    'ohos.permission.FILE_ACCESS_PERSIST'
  ]);
  assert.doesNotMatch(fileTreeViewSource, /hiAppEvent/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*relPath/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*favRows\.length/);
  assert.doesNotMatch(fileTreeViewSource, /hilog\.[^\n]*favorites/);
});
