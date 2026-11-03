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
const handlersStart = script.indexOf(
  "for(const [kind,id]of [['nav','navSplitter'],['content','contentSplitter']]){",
  logicEnd
);
const handlersEnd = script.indexOf('\nlet settingsOpen=', handlersStart);
assert.ok(logicEnd > logicStart && handlersStart > logicEnd && handlersEnd > handlersStart,
  'prototype must retain the split-control logic and its event handlers');
const code = script.slice(logicStart, logicEnd) + script.slice(handlersStart, handlersEnd);

function fixture() {
  const listeners = {};
  const nodes = new Map();
  let now = 0;
  let saved = 0;
  let sideVisible = true;
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
    nodes.set(id, {
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
    });
  }
  const document = {
    head: { appendChild(element) { this.style = element; } },
    createElement() { return {}; },
    getElementById(id) { return nodes.get(id); },
    addEventListener(type, listener) { (listeners[type] ??= []).push(listener); }
  };
  const widths = { nav: 1 / 3, content: 0.5 };
  let splitDrag = null;
  const context = vm.createContext({
    document,
    window: { addEventListener() {} },
    navigator: {},
    ResizeObserver: class { observe() {} },
    performance: { now: () => now },
    setTimeout: () => 1,
    clearTimeout() {},
    localStorage: { removeItem() {} },
    getComputedStyle: () => ({ getPropertyValue: (key) => key === '--s4' ? '16px' : '240px' }),
    $: (id) => nodes.get(id),
    widths,
    get splitDrag() { return splitDrag; },
    set splitDrag(value) { splitDrag = value; },
    splitMetrics: () => ({ w: 1200, min: 240, side: sideVisible, referenceVisible: true }),
    splitRange: (kind, metrics) => ({
      min: metrics.min,
      max: metrics.w - (kind === 'nav' && metrics.referenceVisible ? 2 : 1) * metrics.min
    }),
    splitActive: (kind) => kind === 'nav' ? sideVisible : !sideVisible,
    clampWidth: (value, range) => Math.max(range.min, Math.min(range.max, value)),
    resizeSplit(kind, pixels) {
      const metrics = { w: 1200, min: 240, side: sideVisible, referenceVisible: true };
      const range = { min: 240, max: 1200 - (kind === 'nav' && sideVisible ? 480 : 240) };
      widths[kind] = Math.max(range.min, Math.min(range.max, pixels)) / metrics.w;
    },
    applySplits() {},
    endSplit() {
      if (!splitDrag) return;
      splitDrag.handle.classList.remove('dragging');
      nodes.get('window').classList.remove('splitting');
      splitDrag.handle.releasePointerCapture(splitDrag.pointer);
      splitDrag = null;
      saved++;
    },
    resetSplits() {
      splitDrag = null;
      widths.nav = 1 / 3;
      widths.content = 0.5;
    },
    saveWidths() { saved++; }
  });
  vm.runInContext(`${code}\npaintSplit('nav');`, context);
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
    paint(kind) { vm.runInContext(`paintSplit('${kind}');`, context); },
    setSideVisible(value) { sideVisible = value; },
    setNow(value) { now = value; },
    saved: () => saved
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
  assert.equal(f.widths.nav, 0.2);
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
