/*
 * v2.1 标签浏览与过滤设计稿契约测试（v2.11 改稿二：独立「标签」页签）。
 *
 * 锁六件事：
 * 1. 结构 —— 侧栏三页签（文件 → 标签 → 章节）；标签是独立 tagsPanel 整栏列表，
 *    不再占用 filesPanel 分区；过滤条仍在 filesPanel 树顶部；
 * 2. 聚合口径 —— frontmatter tags + 正文行内 #tag（排除代码块 / 行内代码 / 公式）、小写去重、不跨库；
 * 3. 过滤行为 —— 点标签行设置过滤并自动切回文件页签、再点同一行清除、无效标签丢弃、过滤行点击 selectNote；
 * 4. URL —— tag 进 stateUrl、side 支持 tags、restoreUrl 校验标签存在否则丢弃；tagsOpen 折叠键随页签方案删除；
 * 5. 红线 —— v2.1 CSS 只引用 token、过滤态隐藏「全部笔记」分区标签、tree-help 提示；
 * 6. 笔记内标签 chip —— 预览里的 chip 是按钮，点击切到文件视图并进入该标签过滤（含单屏展开侧栏）。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

// —— 源级结构断言 ——
test('sidebar gains a dedicated tags tab and full-height panel between files and chapters', () => {
  const tabs = html.match(/<div aria-label="侧栏内容" class="sidebar-tabs" role="group">[\s\S]*?<\/div>/)[0];
  const order = ['id="filesTab"', 'id="tagsTab"', 'id="chaptersTab"'];
  let cursor = -1;
  for (const marker of order) {
    const at = tabs.indexOf(marker);
    assert.ok(at > cursor, `tabs order broken at ${marker}`);
    cursor = at;
  }
  assert.match(tabs, /aria-controls="tagsPanel" aria-pressed="false" id="tagsTab">标签</);
  // 标签独立面板：计数标题 + 整栏滚动列表容器。
  const tagsPanel = html.match(/<section class="sidebar-panel hidden" id="tagsPanel">[\s\S]*?<\/section>/)[0];
  assert.match(tagsPanel, /class="nav-label tag-panel-title" id="tagPanelTitle">标签</);
  assert.match(tagsPanel, /aria-label="当前知识库标签" class="tag-panel" id="tagList"/);
  // filesPanel 不再有标签分区：置顶 → 收藏 → 过滤条 → 全部笔记 → 目录树。
  const filesPanel = html.match(/<section class="sidebar-panel" id="filesPanel">[\s\S]*?<\/section>/)[0];
  assert.ok(!filesPanel.includes('id="tagsFolder"'), '改稿二后 filesPanel 内不得残留标签分区');
  const fOrder = ['id="pinFolder"', 'id="favoritesFolder"', 'id="tagFilterBar"', '全部笔记', 'id="notes"'];
  cursor = -1;
  for (const marker of fOrder) {
    const at = filesPanel.indexOf(marker);
    assert.ok(at > cursor, `filesPanel marker order broken at ${marker}`);
    cursor = at;
  }
  assert.match(filesPanel, /class="tag-filter-pill" id="tagFilterPill"/);
  assert.match(filesPanel, /class="tag-filter-clear" id="tagFilterClear">清除筛选/);
});

test('tags panel css keeps list rows token-only and scrollable for the full sidebar height', () => {
  assert.match(html, /\.tag-panel-title\{display:flex;align-items:center;gap:var\(--s2\);padding:var\(--s3\) var\(--s2\) var\(--s1\);font-size:var\(--caption\);font-weight:500;letter-spacing:\.08em;color:var\(--muted\)\}/);
  assert.match(html, /\.tag-panel\{display:flex;flex-direction:column;gap:2px;flex:1;min-height:0;overflow:auto;scrollbar-width:thin;padding:var\(--s1\) 0 var\(--s2\)\}/);
  assert.match(html, /\.tag-row\{display:flex;align-items:center;gap:var\(--s2\);width:100%;min-height:var\(--s10\);padding:0 var\(--s2\)/);
  assert.match(html, /\.tag-row\[aria-pressed="true"\]\{background:var\(--blue-soft\)\}/);
  assert.match(html, /\.tag-row\[aria-pressed="true"\] \.tag-name\{color:var\(--blue\);font-weight:500\}/);
});

test('filter bar replaces the all-notes section label and hides the swipe hint while filtering', () => {
  assert.match(html, /\.tag-filter:not\(\.hidden\)\+\.tree-section-label\{display:none\}/);
  assert.match(html, /\.window\.tag-filtering #pinFolder,\.window\.tag-filtering #favoritesFolder\{display:none!important\}/);
  // 标签独立页签后不再需要 phone 折叠特例。
  assert.ok(!html.includes('.window.phone.tag-filtering #tagsFolder'));
  // tagsFolder 移出 filesPanel 后，兄弟 / 后代选择器不得误伤过滤条（:not(.tag-filter) 守护）。
  assert.match(html, /#pinFolder\.hidden~#favoritesFolder\.hidden\+\.tree-section-label:not\(\.tag-filter\)\{display:none\}/);
  assert.match(html, /\.sidebar:not\(:has\(\.favorites-folder:not\(\.hidden\)\)\) \.tree-section-label:not\(\.tag-filter\)\{display:none\}/);
  assert.match(html, /\$\('window'\)\.classList\.toggle\('tag-filtering',filtering\);\s*\n?\s*\$\('tagFilterBar'\)\.classList\.toggle\('hidden',!filtering\);\$\('treeHelp'\)\.classList\.toggle\('hidden',filtering\)/);
});

test('tag state is persisted and restored through the URL; tagsOpen collapse key is gone', () => {
  assert.match(html, /side:\['files','tags','chapters'\]/);
  assert.match(html, /if\(activeTagFilter\)put\('tag',activeTagFilter\);/);
  assert.match(html, /if\(params\.has\('tag'\)\)\{const value=params\.get\('tag'\);activeTagFilter=tagIndex\(\)\.has\(value\)\?value:'';\}else activeTagFilter='';/);
  assert.ok(!html.includes("put('tagsOpen'"), '页签方案删除折叠记忆键');
  assert.ok(!html.includes('tagsFolderState'), '折叠状态对象随分区一起删除');
  // 切库清除过滤：标签集合按库不同。
  assert.match(html, /activeVault=id;activeTagFilter='';/);
});

test('render pipeline refreshes the tags panel and wires tabs, rows and filter handlers', () => {
  assert.match(html, /renderTrash\(\);renderPins\(\);renderFavorites\(\);renderTags\(\);renderStatsMenu\(\);/);
  assert.match(html, /\$\('tagPanelTitle'\)\.textContent=entries\.length\?\('标签 · '\+entries\.length\+' 个'\):'标签';/);
  // 点标签行：设置过滤并自动切回文件页签；再点同一行清除过滤（留在标签页签）。
  assert.match(html, /\$\('tagList'\)\.querySelectorAll\('\[data-tag\]'\)\.forEach\(b=>b\.onclick=\(\)=>\{const next=b\.dataset\.tag===activeTagFilter\?'':b\.dataset\.tag;setTagFilter\(next\);if\(next&&sidebarView!=='files'\)setSidebarView\('files'\);\}\);/);
  assert.match(html, /\$\('notes'\)\.querySelectorAll\('\[data-tag-open\]'\)\.forEach\(b=>b\.onclick=\(\)=>selectNote\(b\.dataset\.tagOpen\)\)/);
  assert.match(html, /\$\('tagFilterClear'\)\.onclick=\(\)=>setTagFilter\(''\)/);
  // 三页签切换：aria-pressed 与面板 visibility 一一对应，文件页签动作只随文件页签显示。
  assert.match(html, /function setSidebarView\(view\)\{sidebarView=view;\$\('filesTab'\)\.setAttribute\('aria-pressed',String\(view==='files'\)\);\$\('tagsTab'\)\.setAttribute\('aria-pressed',String\(view==='tags'\)\);\$\('chaptersTab'\)\.setAttribute\('aria-pressed',String\(view==='chapters'\)\);\$\('filesPanel'\)\.classList\.toggle\('hidden',view!=='files'\);\$\('tagsPanel'\)\.classList\.toggle\('hidden',view!=='tags'\);\$\('chaptersPanel'\)\.classList\.toggle\('hidden',view!=='chapters'\);\$\('sidebarFileActions'\)\.classList\.toggle\('hidden',view!=='files'\);\}/);
  assert.match(html, /\$\('filesTab'\)\.onclick=\(\)=>setSidebarView\('files'\);\$\('tagsTab'\)\.onclick=\(\)=>setSidebarView\('tags'\);\$\('chaptersTab'\)\.onclick=\(\)=>setSidebarView\('chapters'\);/);
});

test('note tag chips filter the left list instead of opening block editing', () => {
  // 预览里的标签 chip 是按钮语义，携带 data-note-tag。
  assert.match(html, /function tagChip\(tag\)\{return '<button type="button" class="note-tag" contenteditable="false" data-note-tag="'\+esc\(tag\)\+'"/);
  assert.match(html, /aria-label="按标签筛选：#'\+esc\(tag\)\+'"/);
  // 点击 chip → 切文件视图、单屏展开侧栏 / 宽屏取消隐藏、进入标签过滤。
  assert.match(html, /function openTagFilter\(value\)\{/);
  assert.match(html, /if\(sidebarView!=='files'\)setSidebarView\('files'\)/);
  assert.match(html, /if\(phone\)\$\('window'\)\.classList\.add\('nav-open'\);else \$\('window'\)\.classList\.remove\('nav-hidden'\)/);
  // pointerdown 先于 contenteditable 的段落选中，click 保留给键盘 / 普通点击。
  assert.match(html, /article\.addEventListener\('pointerdown',event=>\{const noteTag=event\.target\.closest\('\[data-note-tag\]'\);if\(!noteTag\|\|!article\.contains\(noteTag\)\)return;event\.preventDefault\(\);event\.stopPropagation\(\);openTagFilter\(noteTag\.dataset\.noteTag\);\},true\)/);
  // 简单模式捕获阶段原本会把 chip 当段落打开块编辑器，必须先放行。
  assert.match(html, /const noteTag=tgt\.closest\('\[data-note-tag\]'\);if\(noteTag&&root\.contains\(noteTag\)\)return;/);
  assert.match(html, /if\(tgt\.closest&&tgt\.closest\('\[data-note-tag\]'\)\)return;/);
  // chip 的可点击样式只引用 token，不散写颜色。
  const chipCss = html.match(/button\.note-tag\{[^}]*\}/)?.[0] ?? '';
  assert.match(chipCss, /line-height:inherit/);
  assert.doesNotMatch(chipCss, /#[0-9a-fA-F]{3,8}\b/);
  const hoverCss = html.match(/button\.note-tag:hover\{[^}]*\}/)?.[0] ?? '';
  assert.match(hoverCss, /var\(--blue\)/);
  assert.match(hoverCss, /var\(--paper\)/);
});

test('v2.1 CSS only references tokens, never scattered colors', () => {
  const start = html.indexOf('/* v2.1: tag list rows + tag filter bar');
  assert.ok(start >= 0, 'v2.1 css block found');
  const end = html.indexOf('.fav-list{', start);
  assert.ok(end > start, 'v2.1 css block end found');
  const css = html.slice(start, end);
  assert.ok(css.length > 200, 'v2.1 css block is substantial');
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'no raw hex colors');
  assert.doesNotMatch(css, /font-size:\s*\d+px/);
  for (const decl of css.match(/(?:background|color|border)[^;}]*/g) ?? []) {
    if (/var\(/.test(decl)) continue;
    assert.doesNotMatch(decl, /:\s*(?:rgb|hsl)[a-z()0-9,\s%]/i, `no raw color literals: ${decl}`);
  }
});

// —— 行为测试：最小 DOM 桩 + 真实 v2.1 代码 ——
function lineOf(prefix) {
  const at = html.indexOf(prefix);
  assert.ok(at >= 0, `prototype line found: ${prefix}`);
  const end = html.indexOf('\n', at);
  return html.slice(at, end);
}

function sliceFrom(prefix, endMarker) {
  const at = html.indexOf(prefix);
  assert.ok(at >= 0, `prototype block found: ${prefix}`);
  const end = html.indexOf(endMarker, at);
  assert.ok(end > at, `prototype block end found: ${endMarker}`);
  return html.slice(at, end);
}

function fixture(initial = {}) {
  const nodes = new Map();
  const get = (id) => {
    if (!nodes.has(id)) nodes.set(id, {
      id, innerHTML: '', textContent: '', title: '', open: false, disabled: false,
      dataset: {}, attrs: {},
      classList: {
        values: new Set(),
        contains(k) { return this.values.has(k); },
        add(...ks) { ks.forEach((k) => this.values.add(k)); },
        remove(...ks) { ks.forEach((k) => this.values.delete(k)); },
        toggle(k, on) { const want = on === undefined ? !this.values.has(k) : !!on; if (want) this.values.add(k); else this.values.delete(k); return want; },
      },
      querySelectorAll() { return []; },
      setAttribute(k, v) { this.attrs[k] = v; },
      focus() {},
      addEventListener() {},
    });
    return nodes.get(id);
  };
  const ctx = {
    $: get,
    esc: (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;'),
    notes: initial.notes ?? [
      { id: 'a', vault: 'local', folder: '', title: '笔记一', text: '---\ntags:\n  - 工作\n  - 项目\n---\n\n正文里的 #灵感\n\n```js\nconst x = 1; // #代码\n```\n\n`#行内`\n\n$#公式$\n', deleted: false },
      { id: 'b', vault: 'local', folder: '日记', title: '笔记二', text: '来自 #工作 的想法\n', deleted: false },
      { id: 'c', vault: 'local', folder: '', title: '笔记三', text: '没有标签的笔记\n', deleted: false },
      { id: 'd', vault: 'other', folder: '', title: '他库笔记', text: '---\ntags:\n  - 工作\n---\n', deleted: false },
    ],
    libraries: [{ id: 'local', name: '本地笔记', type: 'local', dir: 'vaults/local', files: 0 }],
    activeVault: 'local',
    current: 'a',
    scheduleUrl() {},
    selectNote(id) { ctx.selectedId = id; },
    renderTree() { ctx.treeRenders = (ctx.treeRenders || 0) + 1; },
    setSidebarView(view) { ctx.sidebarView = view; },
    applySplits() { ctx.splits = (ctx.splits || 0) + 1; },
    favTone() { return 'var(--blue)'; },
    svg() { return ''; },
    folderPathsForVault() { return []; },
    buildTree() { return { files: [] }; },
    treeHtml() { return '<ul></ul>'; },
    bindFileSwipe() {}, bindFolderSwipe() {},
    swipeSuppressed: null, folderSwipeSuppressed: null,
    revealFileActions() {}, closeFileSwipes() {},
    openNewEntry() {}, openFolderShare() {}, openDeleteFolder() {}, openFolderAction() {}, openInPane() {},
    phone: false, focused: false, draggedReference: '', clearReferenceDrag() {}, rememberEditorPosition() {},
  };
  ctx.currentNotes = () => ctx.notes.filter((n) => n.vault === ctx.activeVault && !n.deleted);
  const context = vm.createContext(ctx);
  const run = (s) => vm.runInContext(s, context);
  // 原型基础解析函数（单行 function 声明，逐行装载）。
  run(lineOf('function validTag('));
  run(lineOf('function tagChip('));
  run(lineOf('function markdownBody('));
  run(lineOf('function frontmatterTags('));
  // v2.1 聚合 + 过滤状态块（注释行到 visiblePins 之前）。
  run(sliceFrom('// v2.1: tag aggregation', '\nfunction visiblePins()'));
  return { get, run, context };
}

test('noteTagList merges frontmatter and inline tags, skipping code, inline code and math', () => {
  const f = fixture();
  const tags = f.run('noteTagList(notes[0])');
  assert.deepEqual([...tags], ['工作', '项目', '灵感']);
});

test('tagIndex is per-vault and counts notes per tag', () => {
  const f = fixture();
  const index = f.run('tagIndex()');
  assert.equal(index.get('工作').length, 2);
  assert.equal(index.get('项目').length, 1);
  assert.equal(index.get('灵感').length, 1);
  // 他库笔记（d）不进入当前库聚合。
  assert.equal(f.run("notes.find(n=>n.id==='d') && tagIndex().has('他库')"), false);
  const ids = index.get('工作').map((n) => n.id).sort();
  assert.deepEqual([...ids], ['a', 'b']);
});

test('renderTags fills the panel title and sorted rows, reflecting the active filter', () => {
  const f = fixture();
  f.run('renderTags()');
  assert.equal(f.get('tagPanelTitle').textContent, '标签 · 3 个');
  const list = f.get('tagList').innerHTML;
  assert.ok(list.indexOf('#工作') < list.indexOf('#项目'), '工作(2) sorts before 项目(1)');
  // 同数标签按 localeCompare("zh")（拼音）排序。
  const sameCount = ['项目', '灵感'].sort((a, b) => a.localeCompare(b, 'zh'));
  assert.ok(list.indexOf('#' + sameCount[0]) < list.indexOf('#' + sameCount[1]),
    `同数按名称排序：${sameCount[0]} before ${sameCount[1]}`);
  assert.ok(list.includes('aria-pressed="false"'));
  // 进入过滤后，行 aria-pressed 翻转（页签内可见当前过滤目标）。
  f.run("setTagFilter('工作')");
  f.run('renderTags()');
  assert.ok(f.get('tagList').innerHTML.includes('aria-pressed="true"'));
});

test('renderTags degrades to a bare title and empty hint when the vault has no tags', () => {
  const f = fixture({ notes: [
    { id: 'x', vault: 'local', folder: '', title: '无标签', text: '正文\n', deleted: false },
  ] });
  f.run('renderTags()');
  assert.equal(f.get('tagPanelTitle').textContent, '标签');
  assert.ok(f.get('tagList').innerHTML.includes('fav-empty'), '空态文案存在');
  assert.ok(f.get('tagList').innerHTML.includes('还没有带标签的笔记'));
});

test('tagChip renders a keyboard-reachable filter button', () => {
  const f = fixture();
  const chip = f.run("tagChip('工作')");
  assert.match(chip, /^<button type="button" class="note-tag"/);
  assert.match(chip, /contenteditable="false"/);
  assert.match(chip, /data-note-tag="工作"/);
  assert.match(chip, /aria-label="按标签筛选：#工作"/);
  assert.match(chip, /title="按标签筛选：#工作"/);
  assert.doesNotMatch(chip, /<span/);
});

test('openTagFilter switches to files view, enters the filter and reveals the sidebar', () => {
  const f = fixture();
  f.context.sidebarView = 'tags';
  f.run('openTagFilter(\'工作\')');
  assert.equal(f.run('activeTagFilter'), '工作');
  assert.equal(f.context.sidebarView, 'files');
  assert.equal(f.get('window').classList.contains('nav-hidden'), false);
  assert.ok((f.context.splits || 0) >= 1, '布局在展开侧栏后重算');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), false);
  // 大小写不敏感地命中标签行的书写形式。
  f.run('openTagFilter(\'灵感\')');
  assert.equal(f.run('activeTagFilter'), '灵感');
  // 当前库不存在的标签忽略，不破坏已有过滤。
  f.run('openTagFilter(\'不存在\')');
  assert.equal(f.run('activeTagFilter'), '灵感');
});

test('setTagFilter toggles the filter, re-click clears, invalid tags are dropped', () => {
  const f = fixture();
  // 装载真实 renderTree，覆盖过滤条 / 提示切换全链路。
  f.run(sliceFrom('function renderTree(){', '\n}\n') + '\n}');
  f.run("setTagFilter('工作')");
  assert.equal(f.run('activeTagFilter'), '工作');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), false);
  assert.ok(f.get('notes').innerHTML.includes('data-tag-open="a"'), '过滤分支已渲染');
  // 模拟再点同一标签行：dataset.tag === activeTagFilter → 传空清除。
  f.run("setTagFilter('工作' === activeTagFilter ? '' : '工作')");
  assert.equal(f.run('activeTagFilter'), '');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), true);
  // 无效标签被丢弃，不进入过滤态。
  f.run("setTagFilter('不存在的标签')");
  assert.equal(f.run('activeTagFilter'), '');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), true);
});

test('renderTree renders the filtered flat list with current-note highlight', () => {
  const f = fixture();
  // 装载真实 renderTree（多行函数，切片到函数收尾）。
  f.run(sliceFrom('function renderTree(){', '\n}\n') + '\n}');
  f.run("activeTagFilter='工作'");
  f.run('renderTree()');
  const notesHtml = f.get('notes').innerHTML;
  assert.ok(notesHtml.includes('data-tag-open="a"'));
  assert.ok(notesHtml.includes('data-tag-open="b"'));
  assert.ok(!notesHtml.includes('data-tag-open="c"'), '无标签笔记不出现');
  assert.ok(!notesHtml.includes('data-tag-open="d"'), '他库笔记不出现');
  assert.ok(notesHtml.includes('data-current="true"'), '当前笔记高亮');
  assert.ok(notesHtml.includes('fav-mono'), '复用收藏行首字色块形态');
  assert.equal(f.get('tagFilterPill').textContent, '#工作');
  assert.equal(f.get('treeHelp').classList.contains('hidden'), true);
  // 清除过滤：回到完整树（treeHtml 桩），过滤条与提示复位。
  f.run("activeTagFilter=''");
  f.run('renderTree()');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), true);
  assert.equal(f.get('treeHelp').classList.contains('hidden'), false);
  assert.equal(f.get('notes').innerHTML, '<ul></ul>');
});
