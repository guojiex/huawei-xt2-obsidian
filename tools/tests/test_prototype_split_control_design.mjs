import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const design = fs.readFileSync(new URL('../../docs/prototype/v2/设计说明.md', import.meta.url), 'utf8');
const script = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)]
  .map((match) => match[1])
  .find((source) => source.includes('/* split-control: snap, limit state, live readout */'));
assert.ok(script, 'prototype must include split-control behavior in an inline script');
const logicStart = script.indexOf('/* split-control: snap, limit state, live readout */');
const logicEnd = script.indexOf('const note=id=>', logicStart);
const stateStart = script.indexOf('let fontScale=1;');
const stateEnd = script.indexOf('function clampWidth', stateStart);
const handlersStart = script.indexOf(
  "for(const [kind,id]of [['nav','navSplitter'],['content','contentSplitter']]){",
  logicEnd
);
const handlersEnd = script.indexOf('\nlet settingsOpen=', handlersStart);
assert.ok(logicEnd > logicStart && handlersStart > logicEnd && handlersEnd > handlersStart,
  'prototype must retain the split-control logic and its event handlers');
assert.ok(stateStart > 0 && stateEnd > stateStart && stateStart < logicStart,
  'prototype must keep the font-scale state and the real split metrics before the split-control logic');
const code = script.slice(stateStart, stateEnd) + script.slice(logicStart, logicEnd) + script.slice(handlersStart, handlersEnd);

function fixture() {
  const listeners = {};
  const nodes = new Map();
  const fontVarValues = {};
  const cssVars = { '--s4': '16px', '--pane-min-nav': '200px', '--pane-min-content': '240px' };
  let now = 0;
  let saved = 0;
  let windowWidth = 1200;
  let splitDrag = null;
  let context;
  const makeClassList = () => {
    const values = new Set();
    return {
      add(...keys) { keys.forEach((key) => values.add(key)); },
      remove(...keys) { keys.forEach((key) => values.delete(key)); },
      contains(key) { return values.has(key); },
      toggle(key, enabled = !values.has(key)) {
        enabled ? values.add(key) : values.delete(key);
        return enabled;
      }
    };
  };
  for (const id of ['navSplitter', 'contentSplitter', 'window']) {
    const markup = id === 'window' ? '' :
      html.match(new RegExp(`<div id="${id}"[^>]*>([\\s\\S]*?)</div>`))?.[1] ?? '';
    const node = {
      id,
      attrs: {},
      classList: makeClassList(),
      innerHTML: markup,
      tipParts: { '.split-tip': { innerHTML: '' } },
      listeners: {},
      contains(target) { return target === this; },
      querySelector(selector) { return this.tipParts[selector]; },
      addEventListener(type, listener) { (this.listeners[type] ??= []).push(listener); },
      setAttribute(key, value) { this.attrs[key] = value; },
      removeAttribute(key) { delete this.attrs[key]; },
      setPointerCapture(id) { this.captured = id; },
      hasPointerCapture(id) { return this.captured === id; },
      releasePointerCapture() { this.captured = null; }
    };
    if (id === 'window') Object.defineProperty(node, 'clientWidth', { get: () => windowWidth });
    nodes.set(id, node);
  }
  const document = {
    head: { appendChild(element) { this.style = element; } },
    documentElement: { style: { setProperty(name, value) { fontVarValues[name] = value; } } },
    createElement() { return {}; },
    getElementById(id) { return nodes.get(id); },
    addEventListener(type, listener) { (listeners[type] ??= []).push(listener); }
  };
  const widths = { nav: 1 / 3, content: 0.5 };
  context = vm.createContext({
    document,
    window: { addEventListener() {} },
    navigator: {},
    ResizeObserver: class { observe() {} },
    performance: { now: () => now },
    setTimeout: () => 1,
    clearTimeout() {},
    localStorage: { removeItem() {} },
    getComputedStyle: () => ({ getPropertyValue: (key) => cssVars[key] ?? '' }),
    $: (id) => nodes.get(id),
    widths,
    phone: false,
    focused: false,
    referenceEnabled: true,
    viewport: 'wide',
    get splitDrag() { return splitDrag; },
    set splitDrag(value) { splitDrag = value; },
    clampWidth: (value, range) => Math.max(range.min, Math.min(range.max, value)),
    applySplits() {},
    updateSettingsContent() {},
    saveWidths() { saved++; }
  });
  vm.runInContext(code + "\npaintSplit('nav');", context);
  function fire(type, properties = {}) {
    const event = {
      target: properties.target || nodes.get('navSplitter'),
      pointerId: 1,
      pointerType: 'mouse',
      button: 0,
      clientX: 100,
      clientY: 100,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.propagationStopped = true; },
      stopImmediatePropagation() { this.stopped = true; },
      ...properties
    };
    for (const listener of event.target?.listeners?.[type] || []) listener(event);
    for (const listener of listeners[type] || []) listener(event);
    return event;
  }
  return {
    nodes,
    get widths() { return context.widths; },
    fire,
    paint(kind) { vm.runInContext("paintSplit('" + kind + "');", context); },
    eval(source) { return vm.runInContext(source, context); },
    setFontScale(value) { vm.runInContext('setFontScale(' + value + ');', context); },
    fontVar(name) { return fontVarValues[name]; },
    setWindowWidth(value) { windowWidth = value; },
    setSideVisible(value) {
      nodes.get('window').classList.toggle('nav-hidden', !value);
    },
    setReference(value) { context.referenceEnabled = value; },
    setNow(value) { now = value; },
    saved: () => saved,
    activeDrag: () => splitDrag ? splitDrag.kind : null
  };
}

test('split handles expose a visible grip, pointer hit areas and assistive value', () => {
  assert.match(html, /--split-hit:24px/);
  assert.match(html, /--split-hit:36px/);
  assert.match(html, /@media \(pointer:coarse\)/);
  assert.match(html, /@media \(prefers-reduced-motion:reduce\)/);
  assert.match(html, /@media \(forced-colors:active\)/);
  assert.match(html, /\.window\.phone \.split-control,\.window\.focus \.split-control\{display:none\}/);
  assert.match(script, /const splitKey='xt2-prototype-v2-widths'/);
  assert.match(design, /分栏调节条设计\.md/);
  assert.match(html, /role="separator" aria-orientation="vertical" aria-label="调整目录栏宽度"/);
  assert.match(html, /role="separator" aria-orientation="vertical" aria-label="调整正文与参考栏比例"/);
  const f = fixture();
  assert.match(f.nodes.get('navSplitter').innerHTML, /split-grip/);
  assert.equal(f.nodes.get('navSplitter').attrs['aria-valuetext'], '目录 33% · 正文 67%，默认比例');
  assert.match(f.nodes.get('navSplitter').tipParts['.split-tip'].innerHTML, /400 px/);
});

test('drag snaps to default, Alt bypasses snap, and Escape restores the drag start', () => {
  const f = fixture();
  f.fire('pointerdown', { clientX: 100 });
  f.fire('pointermove', { clientX: 110 });
  assert.equal(f.widths.nav, 1 / 3);
  f.fire('pointerup', { clientX: 110 });

  f.fire('pointerdown', { clientX: 100 });
  f.fire('pointermove', { clientX: 110, altKey: true });
  assert.equal(f.widths.nav, 410 / 1200);
  f.fire('keydown', { target: {}, key: 'Escape' });
  assert.equal(f.widths.nav, 1 / 3);
  assert.equal(f.nodes.get('navSplitter').attrs['aria-valuetext'].endsWith('已取消调整'), true);
});

test('keyboard supports large steps, limits and restoring defaults', () => {
  const f = fixture();
  f.fire('keydown', { key: 'End', shiftKey: false });
  assert.equal(f.widths.nav, 0.6);
  assert.match(f.nodes.get('navSplitter').attrs['aria-valuetext'], /已到最大宽度/);
  f.fire('keydown', { key: 'ArrowLeft', shiftKey: true });
  assert.equal(f.widths.nav, 656 / 1200);
  f.fire('keydown', { key: 'Home' });
  assert.equal(f.widths.nav, 200 / 1200);
  f.fire('keydown', { key: 'Enter' });
  assert.equal(f.widths.nav, 1 / 3);
  assert.ok(f.saved() >= 2);
});

test('two short touch taps restore the default ratio without dblclick', () => {
  const f = fixture();
  f.widths.nav = 0.4;
  f.setNow(1000);
  f.fire('pointerdown', { pointerType: 'touch', clientX: 100 });
  f.fire('pointerup', { pointerType: 'touch', clientX: 100 });
  f.setNow(1200);
  f.fire('pointerdown', { pointerType: 'touch', clientX: 101 });
  f.fire('pointerup', { pointerType: 'touch', clientX: 101 });
  assert.equal(f.widths.nav, 1 / 3);
  assert.match(f.nodes.get('navSplitter').attrs['aria-valuetext'], /已恢复默认/);
});

test('the content separator reports and adjusts its own two-pane ratio', () => {
  const f = fixture();
  f.setSideVisible(false);
  f.paint('content');
  const handle = f.nodes.get('contentSplitter');
  assert.equal(handle.attrs['aria-valuetext'], '左栏 50% · 右栏 50%，默认比例');
  assert.match(handle.tipParts['.split-tip'].innerHTML, /600 \/ 600 px/);
  f.fire('keydown', { target: handle, key: 'ArrowRight' });
  assert.equal(f.widths.content, 616 / 1200);
  assert.match(handle.attrs['aria-valuetext'], /左栏 51% · 右栏 49%/);
});

test('v1.38: split ranges are based on the window for nav and the area right of nav for content', () => {
  assert.match(script, /function splitBase\(kind,m\)\{return kind==='nav'\?m\.w:m\.available;\}/);
  assert.match(script, /function splitDefaultPixels\(kind,m\)\{return splitBase\(kind,m\)\*\(kind==='nav'\?1\/3:\.5\);\}/);
  assert.match(script, /const sideSize=side\?clampWidth\(widths\.nav\*w,splitRange\('nav',\{w,minNav,minContent,side,referenceVisible\}\)\):0/);
  assert.match(script, /sideSize,available:w-sideSize/);
  assert.match(script, /kind==='nav'\?m\.side:m\.referenceVisible\)&&splitRange\(kind,m\)\.max>=\(kind==='nav'\?m\.minNav:m\.minContent\)/);
  assert.doesNotMatch(script, /m\.referenceVisible&&!m\.side/);
  assert.match(script, /clampWidth\(widths\.content\*m\.available,splitRange\('content',m\)\)/);
  assert.doesNotMatch(script, /m\.side\?available\/2:/);
  assert.match(script, /widths\[kind\]\*splitBase\(kind,m\),range\)/);
  assert.match(script, /widths\[kind\]\*splitBase\(kind,m\),splitRange\(kind,m\)\)/);
});

test('v1.38: the three-column content separator reports and drags against the area right of nav', () => {
  const f = fixture();
  f.paint('content');
  const handle = f.nodes.get('contentSplitter');
  assert.equal(handle.attrs['aria-valuetext'], '左栏 50% · 右栏 50%，默认比例');
  assert.match(handle.tipParts['.split-tip'].innerHTML, /400 \/ 400 px/);
  f.widths.nav = 0.4;
  f.paint('content');
  assert.match(handle.tipParts['.split-tip'].innerHTML, /360 \/ 360 px/);
  f.fire('keydown', { target: handle, key: 'ArrowRight' });
  assert.equal(f.widths.content, 376 / 720);
  assert.match(handle.attrs['aria-valuetext'], /左栏 52% · 右栏 48%/);
});

test('v1.38: the three-column content separator clamps at pane minimum and maximum', () => {
  const f = fixture();
  const handle = f.nodes.get('contentSplitter');
  f.fire('keydown', { target: handle, key: 'End' });
  assert.equal(f.widths.content, 560 / 800);
  assert.match(handle.attrs['aria-valuetext'], /已到最大宽度（参考至少 240 px）/);
  f.fire('keydown', { target: handle, key: 'Home' });
  assert.equal(f.widths.content, 240 / 800);
  assert.match(handle.attrs['aria-valuetext'], /已到最小宽度（正文至少 240 px）/);
});

test('v1.38: only one split handle can enter a drag at a time', () => {
  const f = fixture();
  const content = f.nodes.get('contentSplitter');
  f.fire('pointerdown', { clientX: 100 });
  assert.equal(f.activeDrag(), 'nav');
  f.fire('pointerdown', { target: content, clientX: 500 });
  assert.equal(f.activeDrag(), 'nav');
  assert.equal(content.classList.contains('dragging'), false);
  f.fire('pointerup', { clientX: 110 });
  assert.equal(f.activeDrag(), null);
});

test('v1.39: pane minimums follow pane roles (nav 200, content and reference 240)', () => {
  assert.match(html, /--pane-min-nav:200px;--pane-min-content:240px/);
  assert.doesNotMatch(html, /--pane-min:240px/);
  const f = fixture();
  const navRange = f.eval("splitRange('nav', splitMetrics())");
  assert.equal(navRange.min, 200);
  assert.equal(navRange.max, 720);
  const contentRange = f.eval("splitRange('content', splitMetrics())");
  assert.equal(contentRange.min, 240);
  assert.equal(contentRange.max, 560);
});

test('v1.39: pane minimums scale with the system font size and clamp at 1.45', () => {
  const f = fixture();
  f.setFontScale(1.15);
  assert.equal(f.eval('splitMetrics().minNav'), 230);
  assert.equal(f.eval('splitMetrics().minContent'), 276);
  f.setFontScale(1.3);
  assert.equal(f.eval('splitMetrics().minNav'), 260);
  assert.equal(f.eval('splitMetrics().minContent'), 312);
  f.setFontScale(1.45);
  assert.equal(f.eval('splitMetrics().minNav'), 290);
  assert.equal(f.eval('splitMetrics().minContent'), 348);
  f.setFontScale(1.75);
  assert.equal(f.eval('splitMetrics().minNav'), 290);
  assert.equal(f.eval('splitMetrics().minContent'), 348);
  f.setFontScale(0.9);
  assert.equal(f.eval('splitMetrics().minNav'), 200);
  assert.equal(f.eval('splitMetrics().minContent'), 240);
});

test('v1.39: the font scale demo enlarges typography and never shrinks below the base size', () => {
  const f = fixture();
  f.setFontScale(1.15);
  assert.equal(f.fontVar('--body'), '18.4px');
  assert.equal(f.fontVar('--caption'), '13.8px');
  f.setFontScale(1.75);
  assert.equal(f.fontVar('--body'), '28px');
  assert.equal(f.fontVar('--heading'), '56px');
  f.setFontScale(0.9);
  assert.equal(f.fontVar('--body'), '16px');
  assert.equal(f.fontVar('--heading'), '32px');
});

test('v1.39: re-applying the font scale keeps saved pane ratios', () => {
  const f = fixture();
  f.widths.nav = 0.4;
  f.widths.content = 0.625;
  f.setFontScale(1.3);
  assert.equal(f.widths.nav, 0.4);
  assert.equal(f.widths.content, 0.625);
});

test('v1.39: target windows stay feasible at the largest supported font scale', () => {
  const f = fixture();
  f.setFontScale(1.45);
  f.setWindowWidth(1107);
  assert.equal(f.eval("splitActive('nav', splitMetrics())"), true);
  const lgNav = f.eval("splitRange('nav', splitMetrics())");
  assert.equal(lgNav.min, 290);
  assert.equal(lgNav.max, 411);
  const lgContent = f.eval("splitRange('content', splitMetrics())");
  assert.equal(lgContent.min, 348);
  assert.equal(lgContent.max, 390);

  f.setWindowWidth(709);
  f.setSideVisible(false);
  assert.equal(f.eval("splitActive('content', splitMetrics())"), true);
  const mdContent = f.eval("splitRange('content', splitMetrics())");
  assert.equal(mdContent.min, 348);
  assert.equal(mdContent.max, 361);

  f.setSideVisible(true);
  f.setReference(false);
  assert.equal(f.eval("splitActive('nav', splitMetrics())"), true);
  const mdNav = f.eval("splitRange('nav', splitMetrics())");
  assert.equal(mdNav.min, 290);
  assert.equal(mdNav.max, 361);

  f.setWindowWidth(780);
  f.setSideVisible(false);
  f.setReference(true);
  assert.equal(f.eval("splitActive('content', splitMetrics())"), true);
  const landscapeContent = f.eval("splitRange('content', splitMetrics())");
  assert.equal(landscapeContent.min, 348);
  assert.equal(landscapeContent.max, 432);
});

test('v1.39: the nav range preserves right-pane minimums and tightens by the content ratio', () => {
  const f = fixture();
  f.widths.content = 0.6;
  f.fire('keydown', { key: 'End' });
  assert.equal(f.widths.nav, 0.5);
  assert.match(f.nodes.get('navSplitter').attrs['aria-valuetext'], /已到最大宽度（正文与参考至少 240 px）/);
  f.fire('keydown', { key: 'Home' });
  assert.equal(f.widths.nav, 200 / 1200);
  assert.match(f.nodes.get('navSplitter').attrs['aria-valuetext'], /已到最小宽度（目录至少 200 px）/);
});

test('v1.39: the prototype exposes a system font scale demo that never persists to the URL', () => {
  assert.match(html, /<select id="fontScaleDemo" aria-label="系统字号演示"><option value="1">标准 1\.0<\/option><option value="1\.15">大 1\.15<\/option><option value="1\.3">更大 1\.3<\/option><option value="1\.45">特大 1\.45<\/option><option value="1\.75">关怀 1\.75<\/option><\/select>/);
  assert.match(script, /const f=parseFloat\(q\.get\('fontScale'\)\);if\(Number\.isFinite\(f\)&&f>0\)document\.body\.dataset\.fontScalePreview=String\(Math\.min\(1\.75,Math\.max\(0\.5,f\)\)\)/);
  assert.match(script, /\$\('fontScaleDemo'\)\.addEventListener\('change',\(\)=>setFontScale\(parseFloat\(\$\('fontScaleDemo'\)\.value\)\|\|1\)\)/);
  assert.match(script, /if\(document\.body\.dataset\.fontScalePreview\)\{const v=parseFloat\(document\.body\.dataset\.fontScalePreview\);let best=null;for\(const opt of \$\('fontScaleDemo'\)\.options\)if\(!best\|\|Math\.abs\(parseFloat\(opt\.value\)-v\)<Math\.abs\(parseFloat\(best\.value\)-v\)\)best=opt;if\(best\)best\.selected=true;setFontScale\(v\);\}/);
  const restoreStart = script.indexOf('function restoreUrl(){');
  const restoreSource = script.slice(restoreStart, script.indexOf('function scheduleUrl', restoreStart));
  assert.ok(restoreSource.startsWith('function restoreUrl(){'));
  assert.doesNotMatch(restoreSource, /fontScale/);
  assert.doesNotMatch(script, /put\('fontScale'/);
  assert.match(script, /不进 URL 状态机/);
});
