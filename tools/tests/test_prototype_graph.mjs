/*
 * v2.4 关系图谱设计稿契约测试。
 *
 * 锁五件事：
 * 1. 结构 —— #graphPage 全屏视图（顶栏返回 + 视角分段 + 画布）、更多菜单「应用」组入口、.window.graph-open 布局；
 * 2. 数据 —— graphData 只取当前库非删除笔记、边为解析后的 resolved 双链、去重去自环、度数累计、不跨库；
 * 3. 渲染 —— 节点带 data-graph-note、当前节点 current、孤岛 orphan、本地图 dim 非邻域、空态；
 * 4. URL —— view=graph 直达 flag、graphFocus 进 stateUrl / restoreUrl 校验；
 * 5. 红线 —— v2.4 CSS 只引用 token。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

// —— 源级结构断言 ——
test('graph page gains a full-screen section with header, focus tabs and canvas', () => {
  const section = html.match(/<section aria-labelledby="graphTitle"[^>]*>[\s\S]*?<\/section>/)[0];
  assert.match(section, /class="graph-page hidden" id="graphPage"/);
  assert.match(section, /id="closeGraph"/);
  assert.match(section, /id="graphTitle">关系图谱</);
  assert.match(section, /id="graphGlobalTab"[^>]*>全局</);
  assert.match(section, /id="graphLocalTab"[^>]*>本地</);
  assert.match(section, /class="graph-canvas" id="graphCanvas"/);
});

test('mobile more menu gains a graph entry after stats in the 应用 group', () => {
  assert.match(html, /id="mobileStatsMeta"><\/small><\/button>[\s\S]*?<button aria-controls="graphPage" id="mobileGraph" type="button">/);
  assert.match(html, /<span class="menu-label">关系图谱<\/span><\/button>/);
});

test('.window.graph-open hides sidebar/workspace like stats-open', () => {
  assert.match(html, /\.window\.graph-open>\.sidebar,\.window\.graph-open>\.workspace,\.window\.graph-open>\.split-control\{display:none!important\}/);
});

test('view=graph sets the direct-link flag and is consumed after openGraph is defined', () => {
  assert.match(html, /q\.get\('view'\)==='graph'\)window\.__initialViewGraph=true/);
  assert.match(html, /if\(window\.__initialViewGraph\)openGraph\(false\)/);
});

test('graph state is persisted and restored through the URL', () => {
  assert.match(html, /graphOpen\?'graph':settingsOpen\?'settings'/);
  assert.match(html, /if\(graphFocus==='local'\)put\('graphFocus','local'\)/);
  assert.match(html, /graphOpen=false;\$\('graphPage'\)\.classList\.add\('hidden'\);\$\('window'\)\.classList\.remove\('graph-open'\)/);
  assert.match(html, /graphFocus=params\.get\('graphFocus'\)==='local'\?'local':'global'/);
});

test('v2.4 CSS only references tokens, never scattered colors', () => {
  const start = html.indexOf('/* v2.4: relation graph */');
  assert.ok(start >= 0, 'v2.4 css block found');
  const end = html.indexOf('.stats-page{', start);
  assert.ok(end > start, 'v2.4 css block ends before stats-page');
  const css = html.slice(start, end);
  assert.ok(css.length > 200, 'v2.4 css block is substantial');
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'no raw hex colors');
  assert.doesNotMatch(css, /font-size:\s*\d+px/);
  assert.doesNotMatch(css, /:\s*(?:rgb|hsl)[a-z()0-9,\s%]/i, 'no raw color literals');
});

// —— 行为测试：最小 DOM 桩 + 真实 v2.4 代码 ——
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
      id, innerHTML: '', textContent: '', open: false, disabled: false, dataset: {}, attrs: {},
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
      { id: 'a', vault: 'local', folder: '', title: '笔记甲', text: '[[笔记乙]]', deleted: false },
      { id: 'b', vault: 'local', folder: '', title: '笔记乙', text: '[[笔记甲]]', deleted: false },
      { id: 'c', vault: 'local', folder: '', title: '笔记丙', text: '没有链接', deleted: false },
      { id: 'd', vault: 'other', folder: '', title: '他库笔记', text: '[[笔记甲]]', deleted: false },
    ],
    libraries: [{ id: 'local', name: '本地笔记', type: 'local', dir: 'vaults/local', files: 0 }],
    activeVault: 'local',
    current: 'a',
    graphFocus: 'global',
    syncUrl() {},
    selectNote(id) { ctx.selectedId = id; },
    closeGraph() { ctx.graphClosed = true; },
    activeNoteId() { return ctx.current; },
  };
  ctx.currentNotes = () => ctx.notes.filter((n) => n.vault === ctx.activeVault && !n.deleted);
  const context = vm.createContext(ctx);
  const run = (s) => vm.runInContext(s, context);
  // 原型基础解析函数（单行 function 声明，逐行装载）。
  run(lineOf('function markdownBody('));
  run(lineOf('function markdownFence('));
  run(lineOf('function closesMarkdownFence('));
  run(lineOf('function isMarkdownEscaped('));
  run(lineOf('function wikiTargetsIn('));
  run(lineOf('function resolveWikiTarget('));
  // v2.4 graphData + renderGraph（注释块到 setGraphFocus 前）。
  run(sliceFrom('// v2.4: relation graph', '\nfunction setGraphFocus('));
  return { get, run, context };
}

test('graphData builds current-vault nodes and deduped resolved edges', () => {
  const f = fixture();
  const d = f.run('graphData()');
  assert.deepEqual(d.nodes.map((n) => n.id).sort(), ['a', 'b', 'c'], 'excludes other-vault note d');
  assert.equal(d.edges.length, 1, 'a-b and b-a dedupe to one edge');
  assert.equal(d.edges[0].source, 'a');
  assert.equal(d.edges[0].target, 'b');
  const byId = new Map(d.nodes.map((n) => [n.id, n]));
  assert.equal(byId.get('a').degree, 1);
  assert.equal(byId.get('b').degree, 1);
  assert.equal(byId.get('c').degree, 0, 'orphan note has zero degree');
});

test('renderGraph renders nodes, edges, current and orphan states', () => {
  const f = fixture();
  f.run('renderGraph()');
  const out = f.get('graphCanvas').innerHTML;
  assert.ok(out.includes('data-graph-note="a"'));
  assert.ok(out.includes('data-graph-note="b"'));
  assert.ok(out.includes('data-graph-note="c"'));
  assert.ok(!out.includes('data-graph-note="d"'), 'other-vault note excluded');
  assert.ok(out.includes('class="graph-node current"'), 'current note highlighted');
  assert.ok(out.includes('class="graph-node orphan"'), 'orphan note marked');
  assert.equal((out.match(/class="graph-edge/g) || []).length, 1, 'one edge rendered');
});

test('local focus centers on current note and dims non-neighborhood nodes', () => {
  const f = fixture();
  f.run("graphFocus='local'");
  f.run('renderGraph()');
  const out = f.get('graphCanvas').innerHTML;
  assert.ok(out.includes('class="graph-node current"'), 'center is current');
  const cNode = out.match(/<g class="([^"]*)" data-graph-note="c"[^>]*>/)[0];
  assert.ok(cNode.includes('dim'), 'non-neighborhood node dimmed');
});

test('renderGraph shows empty state when the vault has no notes', () => {
  const f = fixture({ notes: [] });
  f.run('renderGraph()');
  assert.ok(f.get('graphCanvas').innerHTML.includes('当前库暂无笔记'));
});
