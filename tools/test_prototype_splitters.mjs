import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const source = html.slice(html.indexOf('  var sideW ='), html.indexOf('  /* ---------- URL 同步'));
function fixture() {
  const attrs = { 'data-form': 'lg', 'data-view': 'note' }, nodes = new Map(), storage = new Map();
  const get = id => {
    if (!nodes.has(id)) {
      const classes = new Set(); let captured = false;
      nodes.set(id, { id, style: { setProperty(key, value) { this[key] = value; } }, handlers: {}, textContent: '',
        classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x) },
        addEventListener(type, handler) { this.handlers[type] = handler; },
        setPointerCapture() { captured = true; }, hasPointerCapture() { return captured; }, releasePointerCapture() { captured = false; },
        getBoundingClientRect() { return id === 'agentLayout' ? { left: 200, width: 800 } : { left: 100, width: 1000 }; }
      });
    }
    return nodes.get(id);
  };
  const splitters = ['splitterA', 'splitterB', 'agentSplitter'].map(get);
  const c = vm.createContext({ sideHidden: false, viewportRotated: false, viewportPreset: 'lg',
    getComputedStyle: () => ({ getPropertyValue: () => '240px' }),
    document: { getElementById: get, querySelectorAll: () => splitters },
    body: { getAttribute: key => attrs[key], classList: get('body').classList },
    localStorage: { setItem: (key, value) => storage.set(key, value), getItem: key => storage.get(key), removeItem: key => storage.delete(key) }, drawHinges() {}
  });
  vm.runInContext(html.match(/var VIEWPORT_PRESETS = [^\n]+/)[0], c);
  vm.runInContext(html.match(/function viewportSpec\(preset, rotated\) \{[\s\S]*?\n  \}/)[0], c);
  vm.runInContext(source, c);
  vm.runInContext(html.match(/function currentSpans\(f\) \{[\s\S]*?\n  \}/)[0], c);
  const event = clientX => ({ clientX, pointerId: 1, preventDefault() {} });
  return { c, attrs, get, storage, run: s => vm.runInContext(s, c),
    drag(id, start, end) { const sp = get(id); sp.handlers.pointerdown(event(start)); sp.handlers.pointermove(event(end)); sp.handlers.pointerup(event(end)); }
  };
}
test('both workspaces inherit the same side width using their own layout coordinates', () => {
  const f = fixture(); f.run('applySplit()');
  f.drag('splitterA', 400, 450);
  assert.equal(f.get('sidebar').style.width, '38.333%');
  assert.equal(f.get('agentNav').style.width, '38.333%');
  f.attrs['data-view'] = 'agent'; f.run('applySplit()');
  f.drag('agentSplitter', 400, 432); // 32 / 800 = 4%, not the note layout's 3.2%.
  assert.equal(f.get('agentNav').style.width, '42.333%');
  f.attrs['data-view'] = 'note'; f.run('applySplit()');
  assert.equal(f.get('sidebar').style.width, '42.333%');
  assert.equal(f.get('splitterA').style.left, f.get('agentSplitter').style.left);
  assert.equal(f.get('editorPane').style.width, f.get('previewPane').style.width);
  assert.equal(f.storage.size, 1);
  f.run('sideW = 33.333; loadSplit(); applySplit()');
  assert.equal(f.get('agentNav').style.width, '42.333%');
});
test('Agent uses the same drag limits without touching the note edit/preview ratio', () => {
  const f = fixture(); f.attrs['data-view'] = 'agent';
  f.drag('agentSplitter', 400, 2000); assert.equal(f.run('sideW'), 46);
  f.drag('agentSplitter', 400, -2000); assert.ok(Math.abs(f.run('sideW') * 1061 / 100 - 240) < 1e-6);
  assert.equal(f.run('editW'), 66.666);
});
test('collapsed navigation rejects dragging and reopening inherits the saved width', () => {
  const f = fixture(); f.attrs['data-view'] = 'agent';
  f.run('sideW = 40; sideHidden = true; applySplit()');
  f.get('agentNav').classList.add('hidden'); f.drag('agentSplitter', 400, 480);
  assert.equal(f.run('sideW'), 40);
  f.get('agentNav').classList.remove('hidden'); f.run('applySplit()');
  assert.equal(f.get('agentNav').style.width, '40%');
  f.drag('agentSplitter', 400, 424); assert.equal(f.run('sideW'), 43);
});
test('md, sm and rotated layouts reject dragging and recover lg width', () => {
  const f = fixture(); f.attrs['data-view'] = 'agent'; f.run('sideW = 40; applySplit()');
  for (const form of ['md', 'sm']) {
    f.attrs['data-form'] = form; f.run('applySplit()');
    assert.equal(f.get('agentNav').style.width, '');
    f.drag('agentSplitter', 400, 480); assert.equal(f.run('sideW'), 40);
  }
  f.attrs['data-form'] = 'lg'; f.run('viewportRotated = true; applySplit()');
  f.drag('agentSplitter', 400, 480); assert.equal(f.run('sideW'), 40);
  f.run('viewportRotated = false; applySplit()'); assert.equal(f.get('agentNav').style.width, '40%');
});
test('Agent double-click and settings reset share note defaults and clear persistence', () => {
  const f = fixture(); f.attrs['data-view'] = 'agent'; f.drag('agentSplitter', 400, 432);
  f.get('agentSplitter').handlers.dblclick();
  assert.equal(f.storage.size, 0);
  assert.equal(f.get('agentNav').style.width, '33.333%');
  assert.equal(f.get('sidebar').style.width, '33.333%');
  f.drag('agentSplitter', 400, 432); f.get('resetSplitBtn').handlers.click();
  assert.equal(f.storage.size, 0); assert.equal(f.run('sideW'), 33.333);
});
test('hidden workspace splitters cannot mutate widths and Agent hinge spans match its two columns', () => {
  const f = fixture(); f.attrs['data-view'] = 'agent'; f.run('sideW = 40');
  f.drag('splitterA', 400, 480); f.drag('splitterB', 400, 480);
  assert.equal(f.run('sideW'), 40); assert.equal(f.run('editW'), 66.666);
  assert.equal(f.run('JSON.stringify(currentSpans("lg"))'), '[[0,40],[40,100]]');
  f.get('agentNav').classList.add('hidden');
  assert.equal(f.run('JSON.stringify(currentSpans("lg"))'), '[[0,100]]');
  f.attrs['data-view'] = 'settings'; f.drag('agentSplitter', 400, 480);
  assert.equal(f.run('sideW'), 40);
});

test('single-screen landscape defaults to one-third navigation and uses the shared drag control', () => {
  const f = fixture(); f.attrs['data-form'] = 'md'; f.attrs['data-single-landscape'] = 'true';
  f.run('viewportPreset = "sm"; viewportRotated = true; applySplit()');
  assert.equal(f.get('sidebar').style.width, '33.333%');
  assert.equal(f.get('editorPane').style.width, '66.667%');
  assert.equal(f.get('agentNav').style.width, '33.333%');
  f.drag('splitterA', 400, 440);
  assert.equal(f.run('sideW'), 37.333);
  f.attrs['data-view'] = 'agent'; f.drag('agentSplitter', 400, 416);
  assert.equal(f.get('agentNav').style.width, '39.333%');
  f.get('agentSplitter').handlers.dblclick();
  assert.equal(f.get('agentNav').style.width, '33.333%');
  assert.equal(f.get('sidebar').style.width, '33.333%');
  assert.equal(f.storage.size, 0);
});
test('single-screen landscape keeps edit/preview as one content pane even after hiding navigation', () => {
  const f = fixture(); f.attrs['data-form'] = 'md'; f.attrs['data-single-landscape'] = 'true';
  f.c.smMode = 'edit'; f.c.syncUrl = () => {}; f.c.ta = { blur() {} };
  f.c.document.querySelectorAll = selector => selector === '.seg' ? [] : ['splitterA', 'splitterB', 'agentSplitter'].map(f.get);
  f.run(html.match(/function applySmMode\(\) \{[\s\S]*?\n  \}/)[0]);
  f.run('viewportPreset = "sm"; viewportRotated = true; applySmMode(); applySplit()');
  assert.equal(f.get('editorPane').style.display, 'flex');
  assert.equal(f.get('previewPane').style.display, 'none');
  f.run('sideHidden = true; applySmMode(); applySplit()');
  assert.equal(f.get('editorPane').style.width, '100%');
  assert.equal(f.get('previewPane').style.display, 'none');
  f.run('smMode = "preview"; applySmMode(); applySplit()');
  assert.equal(f.get('editorPane').style.display, 'none');
  assert.equal(f.get('previewPane').style.display, 'flex');
  assert.equal(f.get('previewPane').style.width, '100%');
  f.drag('splitterB', 400, 440); assert.equal(f.run('editW'), 66.666);
});
test('rotating back clears split widths and the real dual-screen layout still uses its defaults', () => {
  const f = fixture(); f.attrs['data-form'] = 'md'; f.attrs['data-single-landscape'] = 'true';
  f.run('viewportPreset = "sm"; viewportRotated = true; sideW = 40; applySplit()');
  f.attrs['data-single-landscape'] = 'false'; f.attrs['data-form'] = 'sm';
  f.get('sidebar').style.width = '300px'; f.run('viewportRotated = false; applySplit()');
  assert.equal(f.get('editorPane').style.width, ''); assert.equal(f.get('previewPane').style.width, '');
  assert.equal(f.get('agentNav').style.width, ''); assert.equal(f.get('sidebar').style.width, '300px');
  f.attrs['data-form'] = 'md'; f.run('applySplit()');
  assert.equal(f.get('sidebar').style.width, ''); assert.equal(f.get('agentNav').style.width, '');
  f.drag('splitterA', 400, 450); assert.equal(f.run('sideW'), 40);
});

for (const view of ['note', 'agent']) test(`${view}: landscape dragging and restored ratios respect a 240vp minimum`, () => {
  const f = fixture(); f.attrs['data-view'] = view; f.attrs['data-form'] = 'md'; f.attrs['data-single-landscape'] = 'true';
  f.run('viewportPreset = "sm"; viewportRotated = true; applySplit()');
  const splitter = view === 'note' ? 'splitterA' : 'agentSplitter';
  f.drag(splitter, 400, -2000);
  assert.ok(Math.abs(f.run('sideW') * 780 / 100 - 240) < 1e-6);
  assert.ok((100 - f.run('sideW')) * 780 / 100 >= 240);
  f.drag(splitter, 400, 2000);
  assert.ok((100 - f.run('sideW')) * 780 / 100 >= 240);
  f.storage.set('xt2-proto-split', JSON.stringify({s:22,e:18}));
  f.run('loadSplit(); applySplit()');
  assert.ok(Math.abs(f.run('sideW') * 780 / 100 - 240) < 1e-6);
});
test('note edit and preview panes both keep 240vp when navigation is collapsed', () => {
  const f = fixture(); f.run('sideHidden = true');
  f.drag('splitterB', 400, -2000);
  assert.ok(Math.abs(f.run('editW') * 1061 / 100 - 240) < 1e-6);
  f.drag('splitterB', 400, 2000);
  assert.ok(Math.abs((100 - f.run('editW')) * 1061 / 100 - 240) < 1e-6);
});
test('loading saved proportions before rotating applies minimums only after the target geometry is known', () => {
  const f = fixture(); f.c.viewportPreset = 'sm';
  f.storage.set('xt2-proto-split', JSON.stringify({s:33.333,e:66.666}));
  f.run('loadSplit(); viewportPreset = "lg"; applySplit()');
  assert.equal(f.run('sideW'), 33.333);
  assert.equal(f.get('sidebar').style.width, '33.333%');
});

test('push animation rails use the current shared width in every layout', () => {
  const f = fixture();
  for (const [form, rotated, singleLandscape, width] of [
    ['sm',false,false,'var(--mobile-nav-width)'], ['md',false,false,'50%'],
    ['lg',false,false,'40%'], ['md',true,true,'40%']
  ]) {
    f.attrs['data-form'] = form; f.attrs['data-single-landscape'] = String(singleLandscape);
    f.c.viewportRotated = rotated; f.c.viewportPreset = singleLandscape ? 'sm' : form;
    f.run('sideW = 40; applySplit()');
    assert.equal(f.get('noteView').style['--navigation-width'], width);
    assert.equal(f.get('agentLayout').style['--navigation-width'], width);
  }
});
