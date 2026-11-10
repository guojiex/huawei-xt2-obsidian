import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

// v1.50 50.5: the prototype table bar must follow the active cell with a
// whole-block fallback, mirroring the native calculateAnchoredPopupLayout
// semantics (anchor center-x, clamped inside the window). The prototype has
// no DOM runtime here, so positionBlockBar is extracted and driven with
// minimal stubs.

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const start = html.indexOf('function positionBlockBar(){');
const end = html.indexOf('\n}', start) + 2;
const fnSource = html.slice(start, end);
assert.ok(start >= 0 && fnSource.includes('blockTarget.cell'), 'positionBlockBar keeps the v1.50 cell-aware version');

class ClassListStub {
  constructor(names = []) { this.set = new Set(names); }
  contains(n) { return this.set.has(n); }
  add(n) { this.set.add(n); }
  remove(n) { this.set.delete(n); }
}

function runCase({ cellRect, blockRect, winRect, limitRect = null, sheetHidden = true }) {
  const bar = { classList: new ClassListStub(), style: {}, offsetHeight: 10, offsetWidth: 100 };
  const cell = cellRect ? { isConnected: true, getBoundingClientRect: () => cellRect } : null;
  const block = { isConnected: true, getBoundingClientRect: () => blockRect };
  const sheet = {
    classList: new ClassListStub(sheetHidden ? ['hidden'] : []),
    getBoundingClientRect: () => limitRect ?? winRect
  };
  const env = {
    $: (id) => (id === 'blockBar' ? bar : id === 'window' ? { getBoundingClientRect: () => winRect } : id === 'blockSheet' ? sheet : null),
    blockTarget: { block, cell },
    closeBlockUi: () => {},
    window: { innerHeight: winRect.bottom, innerWidth: winRect.right }
  };
  const invoke = new Function(...Object.keys(env), `${fnSource}; return positionBlockBar();`);
  invoke(...Object.values(env));
  if (bar.classList.contains('hidden')) return { hidden: true };
  return { hidden: false, left: Number(bar.style.left.replace('px', '')), top: Number(bar.style.top.replace('px', '')) };
}

const win = { top: 0, bottom: 600, left: 0, right: 800 };

test('v1.50 the bar anchors the active cell below it, centered on the cell', () => {
  const result = runCase({
    cellRect: { top: 100, bottom: 140, left: 60, width: 80, height: 40 },
    blockRect: { top: 80, bottom: 300, left: 40, width: 700, height: 220 },
    winRect: win
  });
  assert.deepEqual(result, { hidden: false, left: 50, top: 144 });
});

test('v1.50 an offscreen active cell falls back to the whole-block rect', () => {
  const result = runCase({
    cellRect: { top: -200, bottom: -160, left: 60, width: 80, height: 40 },
    blockRect: { top: 10, bottom: 200, left: 40, width: 700, height: 190 },
    winRect: win
  });
  assert.deepEqual(result, { hidden: false, left: 340, top: 204 });
});

test('v1.50 a fully offscreen block hides the bar', () => {
  const result = runCase({
    cellRect: { top: -300, bottom: -260, left: 60, width: 80, height: 40 },
    blockRect: { top: -250, bottom: -50, left: 40, width: 700, height: 200 },
    winRect: win
  });
  assert.equal(result.hidden, true);
});

test('v1.50 a degenerate zero-size cell rect falls back to the block', () => {
  const result = runCase({
    cellRect: { top: 100, bottom: 100, left: 60, width: 0, height: 0 },
    blockRect: { top: 80, bottom: 300, left: 40, width: 700, height: 220 },
    winRect: win
  });
  assert.deepEqual(result, { hidden: false, left: 340, top: 304 });
});

test('v1.50 a missing cell anchors the whole block', () => {
  const result = runCase({
    cellRect: null,
    blockRect: { top: 80, bottom: 300, left: 40, width: 700, height: 220 },
    winRect: win
  });
  assert.deepEqual(result, { hidden: false, left: 340, top: 304 });
});

test('v1.50 a cell flush with the window bottom flips the bar above the cell', () => {
  const result = runCase({
    cellRect: { top: 560, bottom: 596, left: 300, width: 80, height: 36 },
    blockRect: { top: 500, bottom: 596, left: 40, width: 700, height: 96 },
    winRect: win
  });
  assert.deepEqual(result, { hidden: false, left: 290, top: 546 });
});
