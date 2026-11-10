/*
 * v1.54 收藏列表（设计稿）契约测试。
 *
 * 锁三件事：
 * 1. 原型结构 —— 收藏折叠区存在、文件行行尾星标入口存在、render() 全链路刷新收藏区；
 * 2. 纯逻辑 —— 按库隔离、排除已删除、收藏时间倒序（最新在前）、切换幂等；
 * 3. 红线 —— 永久删除清理收藏关系；favOpen 是唯一携带收藏状态的 URL 键。
 *
 * vm realm 出来的数组与主 realm 不同源，deepEqual 前先 JSON roundtrip
 * （做法同 test_file_tree_snapshot.mjs）。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import vm from 'vm';

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const plain = (value) => JSON.parse(JSON.stringify(value));

test('v2 files panel hosts a collapsible favorites section mirroring the trash folder', () => {
  assert.match(html, /<details class="favorites-folder hidden" id="favoritesFolder">/);
  assert.match(html, /id="openFavorites"[^>]*title="展开当前知识库收藏"/);
  assert.match(html, /<span class="tree-name">收藏<\/span><small id="favCount"><\/small>/);
  assert.match(html, /aria-label="收藏的笔记" class="fav-list" id="favList"/);
  assert.match(html, /\.favorites-folder\{flex:none;padding-bottom:var\(--s2\);border-bottom:var\(--stroke\) solid var\(--line\)\}/);
});

test('v2 file rows carry an end-of-row star toggle wired to toggleFavorite', () => {
  assert.match(html, /class="file-star" type="button" data-favorite="'\+n\.id\+'" aria-pressed="'\+isFavorite\(n\.id\)\+'"/);
  assert.match(html, /\$\('notes'\)\.querySelectorAll\('\[data-favorite\]'\)\.forEach\(b=>b\.onclick=e=>\{e\.stopPropagation\(\);toggleFavorite\(b\.dataset\.favorite\);\}\);/);
  assert.match(html, /\.file-star\[aria-pressed=true\]\{color:var\(--blue\)\}/);
  assert.match(html, /\.file-star\[aria-pressed=true\] svg\{fill:currentColor\}/);
});

test('favorites re-render joins the render() pipeline and stays per-vault isolated', () => {
  assert.match(html, /renderVaultPicker\(\);renderTree\(\);renderTrash\(\);renderFavorites\(\);renderReference\(\);/);
  assert.match(html, /function visibleFavorites\(\)\{return favoriteIds\(\)\.map\(id=>notes\.find\(n=>n\.id===id&&n\.vault===activeVault&&!n\.deleted\)\)\.filter\(Boolean\);\}/);
  assert.match(html, /const favoritesByVault=\{local:\['stream','inbox'\]\};const favoritesFolderState=\{local:true\};/);
  assert.match(html, /\$\('favoritesFolder'\)\.classList\.toggle\('hidden',items\.length===0\)/);
  assert.match(html, /setAttribute\('aria-label','收藏，'\+items\.length\+' 篇笔记'\)/);
});

test('purging a note drops it from favorites; favOpen is the only favorites URL key', () => {
  assert.match(html, /const vault=notes\[index\]\.vault,favorites=favoritesByVault\[vault\];if\(favorites\)\{const favoriteIndex=favorites\.indexOf\(id\);if\(favoriteIndex>=0\)favorites\.splice\(favoriteIndex,1\);\}/);
  assert.match(html, /put\('favOpen',\$\('favoritesFolder'\)\.open\?1:0\)/);
  assert.match(html, /if\(params\.has\('favOpen'\)\)favoritesFolderState\[activeVault\]=params\.get\('favOpen'\)==='1';/);
  const urlPuts = html.match(/put\('fav[^']*'/g) || [];
  assert.deepEqual(urlPuts, ["put('favOpen'"]);
});

test('favorites logic: per-vault isolation, deleted hidden, newest first, toggle idempotent', () => {
  const start = html.indexOf('function favoriteIds()');
  const end = html.indexOf('function renderFavorites()');
  assert.ok(start >= 0 && end > start, 'could not find favorites logic slice');
  const context = vm.createContext({
    notes: [
      { id: 'a', vault: 'v1', deleted: false, title: 'A' },
      { id: 'b', vault: 'v1', deleted: false, title: 'B' },
      { id: 'c', vault: 'v1', deleted: true, title: 'C' },
      { id: 'd', vault: 'v2', deleted: false, title: 'D' }
    ],
    activeVault: 'v1',
    favoritesByVault: { v1: ['b', 'a'] },
    renderFavoritesCount: 0,
    toasts: []
  });
  context.renderTree = () => {};
  context.renderFavorites = () => { context.renderFavoritesCount += 1; };
  context.toast = (message) => { context.toasts.push(message); };
  vm.runInContext(html.slice(start, end), context);
  const run = (expr) => plain(vm.runInContext(expr, context));

  // 按库隔离 + 排除已删除 + 收藏时间倒序（b 最新收藏在前）
  assert.deepEqual(run('visibleFavorites().map(n=>n.id)'), ['b', 'a']);
  assert.deepEqual(run('favoriteIds()'), ['b', 'a']);
  assert.equal(run('isFavorite("b")'), true);
  assert.equal(run('isFavorite("c")'), false);
  assert.equal(run('isFavorite("d")'), false);

  // 切库隔离：v2 无收藏
  vm.runInContext('activeVault = "v2"', context);
  assert.deepEqual(run('visibleFavorites()'), []);
  assert.equal(run('isFavorite("a")'), false);

  // 切回 v1：取消收藏立即移除并提示；重新收藏插到最前（最新在前）
  vm.runInContext('activeVault = "v1"', context);
  const before = context.renderFavoritesCount;
  vm.runInContext('toggleFavorite("a")', context);
  assert.deepEqual(run('favoriteIds()'), ['b']);
  assert.equal(context.toasts.at(-1), '已取消收藏：A');
  assert.equal(context.renderFavoritesCount, before + 1);
  vm.runInContext('toggleFavorite("a")', context);
  assert.deepEqual(run('favoriteIds()'), ['a', 'b']);
  assert.equal(context.toasts.at(-1), '已收藏：A');

  // 已删除笔记与他库笔记不可收藏，无副作用
  vm.runInContext('toggleFavorite("c")', context);
  vm.runInContext('toggleFavorite("d")', context);
  assert.deepEqual(run('favoriteIds()'), ['a', 'b']);
});
