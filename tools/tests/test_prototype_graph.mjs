/*
 * v2.4 关系图谱设计稿契约测试。
 *
 * 锁五件事：
 * 1. 结构 —— #graphPage 全屏视图（顶栏返回 + 视角分段 + 画布）、更多菜单「应用」组入口、.window.graph-open 布局；
 * 2. 数据 —— graphData 只取当前库非删除笔记、边为解析后的 resolved 双链、去重去自环、度数累计、不跨库；
 * 3. 渲染 —— 节点带 data-graph-note、当前节点 current、孤岛 orphan、本篇图 dim 非邻域、空态；
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
  assert.match(section, /id="graphGlobalTab"[^>]*>全库</);
  assert.match(section, /id="graphLocalTab"[^>]*>本篇</);
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

test('graphLayout clusters linked notes closer than unlinked notes', () => {
  const f = fixture();
  const r = f.run('(function(){const p=graphLayout(graphData(),640,440);const a=p.get("a"),b=p.get("b"),c=p.get("c");return {ab:Math.hypot(a.x-b.x,a.y-b.y),ac:Math.hypot(a.x-c.x,a.y-c.y),bc:Math.hypot(b.x-c.x,b.y-c.y)};})()');
  assert.ok(r.ab < r.ac, `linked a-b (${r.ab.toFixed(1)}) should be closer than a-c (${r.ac.toFixed(1)})`);
  assert.ok(r.ab < r.bc, `linked a-b (${r.ab.toFixed(1)}) should be closer than b-c (${r.bc.toFixed(1)})`);
});

test('renderGraph shows empty state when the vault has no notes', () => {
  const f = fixture({ notes: [] });
  f.run('renderGraph()');
  assert.ok(f.get('graphCanvas').innerHTML.includes('当前库暂无笔记'));
});

// —— 2026-11-22 交互增补：悬停高亮 / 节点拖拽 / 画布平移缩放 ——
test('graph markup is focusable, labeled and wrapped in a pan/zoom viewport group', () => {
  const f = fixture();
  f.run('renderGraph()');
  const out = f.get('graphCanvas').innerHTML;
  assert.ok(out.includes('<g class="graph-view">'), 'canvas content sits inside the viewport group');
  assert.match(out, /tabindex="0" role="button" aria-label="打开笔记：[^"]+" transform=/, 'nodes carry button semantics and stay keyboard reachable');
  assert.match(out, /data-graph-source="a" data-graph-target="b"/, 'edges carry endpoint ids for live position sync');
});

test('graph interaction wiring and constants stay guarded in the source', () => {
  assert.match(html, /function wireGraphInteractions\(/);
  assert.match(html, /function graphRelax\(rounds,pinnedId\)/);
  assert.match(html, /function graphHighlight\(id\)/);
  assert.match(html, /canvas\.addEventListener\('wheel'/);
  assert.match(html, /\{passive:false\}\)/, 'wheel zoom must be able to preventDefault');
  assert.match(html, /Math\.min\(3,Math\.max\(0\.4,s\.view\.scale\*factor\)\)/, 'zoom clamped to 0.4–3');
  assert.match(html, /drag\.moved<8/, 'tap vs drag separated by a movement threshold');
  assert.match(html, /\.graph-canvas\{[^}]*cursor:grab/);
  assert.match(html, /\.graph-node\.focus-dim\{opacity:\.3\}/);
  assert.match(html, /\.graph-node\.near circle,\.graph-node:focus circle\{stroke-width:2\.5\}/);
  assert.match(html, /paint-order:stroke/, 'node labels carve a paper halo so edges pass underneath text');
  assert.match(html, /function graphRadii\(/, 'radius table shared by layout and rendering');
  assert.match(html, /const min=rad\.get\(nodes\[i\]\.id\)\+rad\.get\(nodes\[j\]\.id\)\+20/, 'collision keeps node clearance');
});

test('graphLayout collision pass keeps dense graphs from overlapping', () => {
  const dense = ['a', 'b', 'c', 'd', 'e'].map((id) => ({ id, vault: 'local', folder: '', title: id.toUpperCase(), text: ['a', 'b', 'c', 'd', 'e'].filter((o) => o !== id).map((o) => `[[${o.toUpperCase()}]]`).join(' '), deleted: false }));
  const f = fixture({ notes: dense });
  const r = f.run('(function(){const d=graphData(),p=graphLayout(d,640,440),rad=graphRadii(d);let min=Infinity;for(let i=0;i<d.nodes.length;i++)for(let j=i+1;j<d.nodes.length;j++){const a=p.get(d.nodes[i].id),b=p.get(d.nodes[j].id);min=Math.min(min,Math.hypot(a.x-b.x,a.y-b.y)-rad.get(d.nodes[i].id)-rad.get(d.nodes[j].id));}return min;})()');
  assert.ok(r >= 19.5, `K5 layout keeps node clearance ≥ 20 (got ${r.toFixed(2)})`);
});

test('graph interactions bind once and support tap, drag, pan, zoom and reset', () => {
  const f = fixture();
  const canvas = f.get('graphCanvas');
  const listeners = {};
  const svgStub = {
    getScreenCTM() { return { inverse() { return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }; } }; },
    setPointerCapture() {},
  };
  canvas.querySelector = (sel) => sel === 'svg' ? svgStub : { attrs: {}, dataset: {}, setAttribute(k, v) { this.attrs[k] = v; } };
  canvas.querySelectorAll = () => [];
  canvas.addEventListener = (k, fn) => { (listeners[k] ??= []).push(fn); };
  f.context.DOMPoint = class {
    constructor(x, y) { this.x = x; this.y = y; }
    matrixTransform(m) { return { x: this.x * m.a + m.e, y: this.y * m.d + m.f }; }
  };
  let selections = 0;
  let closes = 0;
  f.context.selectNote = () => { selections += 1; };
  f.context.closeGraph = () => { closes += 1; };

  f.run('renderGraph()');
  const s = f.run('graphInteractions');
  assert.ok(s && s.svg === svgStub, 'interaction state wired to the rendered svg');
  assert.ok(listeners['pointerdown'] && listeners['pointermove'] && listeners['pointerup'] && listeners['wheel'] && listeners['dblclick'], 'pointer, wheel and dblclick handlers bound');

  // 点按（位移小于阈值）打开笔记并退出图谱
  const nodeG = { dataset: { graphNote: 'a' } };
  const onNode = { target: { closest: (sel) => sel === '.graph-node' ? nodeG : null } };
  listeners['pointerdown'][0]({ ...onNode, clientX: 300, clientY: 200, pointerId: 1 });
  assert.equal(f.run('graphInteractions.drag.id'), 'a');
  listeners['pointerup'][0]({});
  assert.equal(selections, 1, 'tap selects the note');
  assert.equal(closes, 1, 'tap exits the graph view');

  // 拖拽（位移超阈值）只挪节点，不触发打开
  listeners['pointerdown'][0]({ ...onNode, clientX: 300, clientY: 200, pointerId: 1 });
  listeners['pointermove'][0]({ clientX: 420, clientY: 260, pointerId: 1 });
  listeners['pointerup'][0]({});
  assert.equal(selections, 1, 'drag beyond threshold must not open the note');
  assert.equal(closes, 1);

  // 拖空白平移画布
  const onBlank = { target: { closest: () => null } };
  listeners['pointerdown'][0]({ ...onBlank, clientX: 100, clientY: 100, pointerId: 1 });
  assert.ok(canvas.classList.contains('grabbing'), 'pan shows the grabbing cursor state');
  listeners['pointermove'][0]({ clientX: 160, clientY: 140, pointerId: 1 });
  let view = f.run('graphInteractions.view');
  assert.equal(view.x, 60);
  assert.equal(view.y, 40);
  assert.match(f.run('graphInteractions.viewG').attrs.transform, /translate\(60\.00,40\.00\) scale\(1\.0000\)/, 'viewport group transform follows the pan');
  listeners['pointerup'][0]({});
  assert.ok(!canvas.classList.contains('grabbing'));

  // 滚轮以光标为中心缩放，并夹在 0.4–3
  listeners['wheel'][0]({ deltaY: -100, clientX: 320, clientY: 220, preventDefault() {} });
  view = f.run('graphInteractions.view');
  assert.ok(Math.abs(view.scale - 1.161834) < 1e-3, 'wheel zooms toward the cursor');
  assert.ok(Math.abs(view.x - 17.923) < 0.05 && Math.abs(view.y - 10.87) < 0.05);
  for (let i = 0; i < 20; i++) listeners['wheel'][0]({ deltaY: -1000, clientX: 320, clientY: 220, preventDefault() {} });
  assert.equal(f.run('graphInteractions.view.scale'), 3, 'zoom clamps at 3x');

  // 双击空白复位视口
  listeners['dblclick'][0]({ target: { closest: () => null } });
  view = f.run('graphInteractions.view');
  assert.deepEqual({ x: view.x, y: view.y, scale: view.scale }, { x: 0, y: 0, scale: 1 }, 'double click resets the viewport');

  // 重绘只重建状态，不重复绑事件；视口随重绘复位
  f.run('renderGraph()');
  assert.equal(listeners['pointerdown'].length, 1, 'listeners bind once per canvas');
  view = f.run('graphInteractions.view');
  assert.deepEqual({ x: view.x, y: view.y, scale: view.scale }, { x: 0, y: 0, scale: 1 }, 're-render resets the viewport');
});
