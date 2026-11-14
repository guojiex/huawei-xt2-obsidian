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
  assert.match(html, /<summary class="fav-head" id="openFavorites" title="展开 \/ 收起当前知识库收藏">/);
  assert.ok(html.includes('<span class="fav-head-label">收藏</span><small id="favCount"></small>'));
  assert.ok(html.includes('<div class="tree-section-label" aria-hidden="true">全部笔记</div>'));
  assert.match(html, /aria-label="收藏的笔记" class="fav-list" id="favList"/);
  // v1.62 同框：置顶区在收藏区上方；「全部笔记」标签只在两区都隐藏时才隐藏。
  assert.match(html, /#pinFolder\.hidden~#favoritesFolder\.hidden\+\.tree-section-label\{display:none\}/);
  assert.ok(html.indexOf('id="pinFolder"') < html.indexOf('id="favoritesFolder"'));
});

test('v2 file rows carry an end-of-row star toggle wired to toggleFavorite', () => {
  assert.match(html, /class="file-star" type="button" data-favorite="'\+n\.id\+'" aria-pressed="'\+isFavorite\(n\.id\)\+'"/);
  assert.match(html, /\$\('notes'\)\.querySelectorAll\('\[data-favorite\]'\)\.forEach\(b=>b\.onclick=e=>\{e\.stopPropagation\(\);toggleFavorite\(b\.dataset\.favorite\);\}\);/);
  assert.match(html, /\.file-star\[aria-pressed=true\]\{color:var\(--muted\)\}/);
  assert.match(html, /\.file-star\[aria-pressed=true\]:hover\{color:var\(--ink\)\}/);
  assert.match(html, /\.file-star svg\{width:var\(--s4\);height:var\(--s4\)\}/);
  assert.match(html, /\.file-star\[aria-pressed=true\] svg\{fill:currentColor\}/);
  // 指针设备降噪（Notion 式）：未收藏星标默认隐藏，行悬停 / 当前行 / 键盘焦点才出现；触屏设备常显。
  assert.match(html, /@media\(hover:hover\)\{\.file-star:not\(\[aria-pressed=true\]\):not\(:focus-visible\)\{opacity:0;pointer-events:none\}\.file-front:hover \.file-star,\.file-entry\[data-active=true\] \.file-star,\.file-star:focus-visible\{opacity:1;pointer-events:auto\}\}/);
});

test('favorites rows are single-line nav rows aligned with tree file titles', () => {
  // 第三稿：区头与目录树分区，行首字色块 + 标题 + 文件夹名，不复用树行的笔记图标。
  assert.match(html, /\.fav-row\{display:flex;align-items:center;min-height:var\(--s10\);padding:0 var\(--s1\) 0 var\(--s2\);border-radius:var\(--small-r\)\}/);
  assert.match(html, /\.fav-mono\{display:grid;place-items:center;flex:none;width:var\(--s6\);height:var\(--s6\)/);
  assert.match(html, /\.fav-name\{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis/);
  assert.match(html, /\.fav-folder\{flex:none;max-width:40%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis/);
  assert.doesNotMatch(html, /fav-origin|fav-copy/);
  assert.match(html, /\.fav-head\{list-style:none;padding-right:var\(--s1\)/);
  assert.match(html, /\.fav-head-caret\{display:grid;place-items:center;margin-left:auto;width:var\(--touch\)/);
  assert.match(html, /\.fav-unstar\{display:none;place-items:center;flex:none;width:var\(--touch\)/);
  assert.match(html, /\.fav-row:hover \.fav-folder,\.fav-row:focus-within \.fav-folder\{display:none\}/);
  assert.match(html, /\.fav-row:hover \.fav-unstar,\.fav-row:focus-within \.fav-unstar\{display:grid\}/);
  assert.match(html, /\.fav-list\{max-height:calc\(var\(--s10\) \* 5\.5\);overflow:auto;scrollbar-width:thin/);
  // 图标按钮 grid 居中并使用同一列宽，区头箭头、移出收藏与树行尾图标中心对齐。
  assert.match(html, /\.file-star\{display:grid;place-items:center;/);
  assert.match(html, /\.file-reference\{display:grid;place-items:center;/);
  assert.ok(html.includes('class="fav-mono" style="--tone:\'+favTone(n.folder)+\'" aria-hidden="true">\'+esc(mono)+\'</span>'));
  assert.ok(html.includes('<span class="fav-name">\'+esc(n.title)+\'</span><span class="fav-folder" aria-hidden="true">\'+esc(folder)+\'</span>'));
  assert.ok(html.includes('data-swipe-commit="unfavorite"'));
  assert.ok(html.includes('aria-label="打开收藏的笔记：\'+esc(n.title)+\'，位于 \'+esc(n.folder||\'根目录\')+\'"'));
  assert.ok(html.includes('favTone(n.folder)'));
});

test('favorites re-render joins the render() pipeline and stays per-vault isolated', () => {
  // v1.62 同框：置顶区刷新插在收藏区之前（renderStatsMenu 为 v1.59 并入）。
  assert.match(html, /renderVaultPicker\(\);renderTree\(\);renderTrash\(\);renderPins\(\);renderFavorites\(\);renderStatsMenu\(\);renderReference\(\);/);
  assert.match(html, /function visibleFavorites\(\)\{return favoriteIds\(\)\.map\(id=>notes\.find\(n=>n\.id===id&&n\.vault===activeVault&&!n\.deleted\)\)\.filter\(Boolean\);\}/);
  assert.match(html, /const favoritesByVault=\{local:\['tob','stream','reading_journal','idea','inbox'\],reading:\['reading_stream','reading_reading_journal'\]\};const favoritesFolderState=\{local:true,reading:true\};/);
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
  context.updatePaneChrome = () => {};
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

test('note-level more menus expose a favorite toggle for the pane note', () => {
  // 三个笔记级 ⋯ 菜单（移动端顶栏「当前笔记」组 / 桌面左栏 / 桌面右栏）各提供收藏切换；
  // 桌面左右栏跟随各自栏内笔记，移动端跟随激活栏笔记；无笔记时禁用。
  assert.ok(html.includes('id="mobileFavorite"'));
  assert.ok(html.includes('id="leftFavorite"'));
  assert.ok(html.includes('id="rightFavorite"'));
  assert.ok(html.includes("<span class=\"menu-label\">收藏此笔记</span>"));
  assert.ok(html.includes("$('mobileFavorite').onclick=()=>{$('mobileMore').open=false;if(activeNoteId())toggleFavorite(activeNoteId());};"));
  assert.ok(html.includes("$('leftFavorite').onclick=()=>{$('leftMore').open=false;if(current)toggleFavorite(current);};"));
  assert.ok(html.includes("$('rightFavorite').onclick=()=>{$('rightMore').open=false;if(reference)toggleFavorite(reference);};"));
  // 状态随 updatePaneChrome 刷新：aria-pressed + 标签（收藏此笔记 / 取消收藏此笔记），无笔记禁用
  assert.ok(html.includes("['mobileFavorite',activeNoteId()],['leftFavorite',current],['rightFavorite',reference]"));
  assert.ok(html.includes("favOn?'取消收藏此笔记':'收藏此笔记'"));
  // toggleFavorite 末尾补一次 updatePaneChrome，树星标点击后菜单标签不滞留旧态
  assert.ok(html.includes('renderTree();renderFavorites();updatePaneChrome();toast('));
});

test('favorite rows expose the same left-swipe actions as tree file rows', () => {
  // 收藏行左滑提供改名 / 移出收藏；滑到底只取消收藏，不把笔记移入回收站。
  assert.ok(html.includes('<div class="file-entry fav-entry" data-file-wrap="\'+n.id+\'"><div class="file-actions" inert>'));
  assert.ok(html.includes('<button data-file-action="rename" data-action-note="\'+n.id+\'">改名</button><button class="delete-file fav-remove" data-fav-remove="\'+n.id+\'">移出收藏</button>'));
  assert.ok(html.includes('data-swipe-commit="unfavorite"'));
  // v1.62：滑到底提交按 data-swipe-commit 分派 —— unpin 先于 unfavorite，其余走删除。
  assert.ok(html.includes("if(button.dataset.swipeCommit==='unpin')togglePin(button.dataset.note);else if(button.dataset.swipeCommit==='unfavorite')toggleFavorite(button.dataset.note);else deleteFile(button.dataset.note);"));
  // 改名与移出收藏仍复用现有文件操作与收藏切换流程。
  assert.ok(html.includes("$('favList').querySelectorAll('[data-file-action]').forEach(b=>b.onclick=()=>b.dataset.fileAction==='delete'?deleteFile(b.dataset.actionNote):openFileAction(b.dataset.fileAction,b.dataset.actionNote));"));
  assert.ok(html.includes("$('favList').querySelectorAll('[data-fav-open]').forEach(b=>{b.onclick=()=>{if(swipeSuppressed===b.dataset.note){swipeSuppressed=null;return;}selectNote(b.dataset.favOpen);};"));
  // 滑动互斥与 Esc 收起跨容器生效，触屏横向手势交给 JS、纵向手势留给列表滚动。
  assert.ok(html.includes('document.querySelectorAll(\'[data-file-wrap],[data-folder-wrap]\')'));
  assert.match(html, /\.fav-open\{[^}]*touch-action:pan-y;user-select:none\}/);
});
