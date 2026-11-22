/*
 * v2.1 标签浏览与过滤设计稿契约测试。
 *
 * 锁五件事：
 * 1. 结构 —— 侧栏「标签」分区（置顶 → 收藏 → 标签 → 全部笔记顺序）、药丸流、过滤条；
 * 2. 聚合口径 —— frontmatter tags + 正文行内 #tag（排除代码块 / 行内代码 / 公式）、小写去重、不跨库；
 * 3. 过滤行为 —— 点击药丸切换过滤、再点清除、无效标签丢弃、过滤行点击 selectNote；
 * 4. URL —— tag / tagsOpen 进 stateUrl，restoreUrl 校验标签存在否则丢弃；
 * 5. 红线 —— v2.1 CSS 只引用 token、过滤态隐藏「全部笔记」分区标签、tree-help 提示。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

// —— 源级结构断言 ——
test('sidebar gains a tag section between favorites and the full note tree', () => {
  const panel = html.match(/<section class="sidebar-panel" id="filesPanel">[\s\S]*?<\/section>/)[0];
  const order = ['id="pinFolder"', 'id="favoritesFolder"', 'id="tagsFolder"', 'id="tagFilterBar"', '全部笔记', 'id="notes"'];
  let cursor = -1;
  for (const marker of order) {
    const at = panel.indexOf(marker);
    assert.ok(at > cursor, `filesPanel marker order broken at ${marker}`);
    cursor = at;
  }
  assert.match(panel, /class="fav-head" id="openTags"/);
  assert.match(panel, /class="fav-list tag-cloud" id="tagList"/);
  assert.match(panel, /class="tag-filter-pill" id="tagFilterPill"/);
  assert.match(panel, /class="tag-filter-clear" id="tagFilterClear">清除筛选/);
});

test('filter bar replaces the all-notes section label and hides the swipe hint while filtering', () => {
  assert.match(html, /\.tag-filter:not\(\.hidden\)\+\.tree-section-label\{display:none\}/);
  assert.match(html, /\$\('tagFilterBar'\)\.classList\.toggle\('hidden',!filtering\);\$\('treeHelp'\)\.classList\.toggle\('hidden',filtering\)/);
});

test('tag state is persisted and restored through the URL', () => {
  assert.match(html, /if\(activeTagFilter\)put\('tag',activeTagFilter\);put\('tagsOpen',\$\('tagsFolder'\)\.open\?1:0\)/);
  assert.match(html, /if\(params\.has\('tag'\)\)\{const value=params\.get\('tag'\);activeTagFilter=tagIndex\(\)\.has\(value\)\?value:'';\}else activeTagFilter='';/);
  assert.match(html, /if\(params\.has\('tagsOpen'\)\)tagsFolderState\[activeVault\]=params\.get\('tagsOpen'\)==='1';/);
  // 切库清除过滤：标签集合按库不同。
  assert.match(html, /activeVault=id;activeTagFilter='';/);
});

test('render pipeline wires renderTags next to favorites and pins', () => {
  assert.match(html, /renderTrash\(\);renderPins\(\);renderFavorites\(\);renderTags\(\);renderStatsMenu\(\);/);
  assert.match(html, /\$\('tagList'\)\.querySelectorAll\('\[data-tag\]'\)\.forEach\(b=>b\.onclick=\(\)=>setTagFilter\(b\.dataset\.tag===activeTagFilter\?'':b\.dataset\.tag\)\)/);
  assert.match(html, /\$\('notes'\)\.querySelectorAll\('\[data-tag-open\]'\)\.forEach\(b=>b\.onclick=\(\)=>selectNote\(b\.dataset\.tagOpen\)\)/);
  assert.match(html, /\$\('tagFilterClear'\)\.onclick=\(\)=>setTagFilter\(''\)/);
});

test('v2.1 CSS only references tokens, never scattered colors', () => {
  const start = html.indexOf('/* v2.1: tag cloud + tag filter bar');
  assert.ok(start >= 0, 'v2.1 css block found');
  const css = html.slice(start, html.indexOf('/*', start + 10) === -1 ? html.indexOf('</style>', start) : Math.min(html.indexOf('</style>', start), html.indexOf('\n.tag-filter:not', start) + 400));
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
    favTone() { return 'var(--blue)'; },
    svg() { return ''; },
    folderPathsForVault() { return []; },
    buildTree() { return { files: [] }; },
    treeHtml() { return '<ul></ul>'; },
    bindFileSwipe() {}, bindFolderSwipe() {},
    swipeSuppressed: null, folderSwipeSuppressed: null,
    revealFileActions() {}, closeFileSwipes() {},
    openNewEntry() {}, openFolderShare() {}, openDeleteFolder() {}, openFolderAction() {}, openInPane() {},
    phone: false, draggedReference: '', clearReferenceDrag() {}, rememberEditorPosition() {},
  };
  ctx.currentNotes = () => ctx.notes.filter((n) => n.vault === ctx.activeVault && !n.deleted);
  const context = vm.createContext(ctx);
  const run = (s) => vm.runInContext(s, context);
  // 原型基础解析函数（单行 function 声明，逐行装载）。
  run(lineOf('function validTag('));
  run(lineOf('function markdownBody('));
  run(lineOf('function frontmatterTags('));
  // v2.1 聚合 + 过滤状态块（注释行到 setTagFilter 行）。
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

test('renderTags sorts pills by note count desc and reflects the active filter', () => {
  const f = fixture();
  f.run('renderTags()');
  assert.equal(f.get('tagCount').textContent, '3');
  assert.equal(f.get('tagsFolder').classList.contains('hidden'), false);
  const list = f.get('tagList').innerHTML;
  assert.ok(list.indexOf('#工作') < list.indexOf('#项目'), '工作(2) sorts before 项目(1)');
  // 同数标签按 localeCompare("zh")（拼音）排序。
  const sameCount = ['项目', '灵感'].sort((a, b) => a.localeCompare(b, 'zh'));
  assert.ok(list.indexOf('#' + sameCount[0]) < list.indexOf('#' + sameCount[1]),
    `同数按名称排序：${sameCount[0]} before ${sameCount[1]}`);
  assert.ok(list.includes('aria-pressed="false"'));
  // 进入过滤后，药丸 aria-pressed 翻转。
  f.run("setTagFilter('工作')");
  f.run('renderTags()');
  assert.ok(f.get('tagList').innerHTML.includes('aria-pressed="true"'));
});

test('setTagFilter toggles the filter, re-click clears, invalid tags are dropped', () => {
  const f = fixture();
  // 装载真实 renderTree，覆盖过滤条 / 提示切换全链路。
  f.run(sliceFrom('function renderTree(){', '\n}\n') + '\n}');
  f.run("setTagFilter('工作')");
  assert.equal(f.run('activeTagFilter'), '工作');
  assert.equal(f.get('tagFilterBar').classList.contains('hidden'), false);
  assert.ok(f.get('notes').innerHTML.includes('data-tag-open="a"'), '过滤分支已渲染');
  // 模拟再点同一药丸：dataset.tag === activeTagFilter → 传空清除。
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
