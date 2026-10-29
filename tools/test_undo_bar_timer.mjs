import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const tokenSource = fs.readFileSync(new URL('../entry/src/main/ets/common/Tokens.ets', import.meta.url), 'utf8');

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  private ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${signature}`);
  return source.slice(start, end).trim();
}

const showUndoMethod = extractMethod('showUndo(msg: string, snap: UndoSnap | null): void {', '\n  /** 撤销条：收起');
const hideUndoMethod = extractMethod('hideUndo(): void {', '\n  /** 撤销条「撤销」');
const motionStart = tokenSource.indexOf('export class Motion {');
const motionEnd = tokenSource.indexOf('\n}', motionStart);
assert.ok(motionStart >= 0 && motionEnd > motionStart, 'could not find Motion token class');
const motionClass = tokenSource.slice(motionStart, motionEnd + 2).replace('export class', 'class');
const code = transformSync(`${motionClass}\nclass IndexHarness { ${showUndoMethod}\n${hideUndoMethod} }; module.exports = { Motion, IndexHarness };`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness() {
  const timers = [];
  let nextTimerId = 1;
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout(callback, delay) {
      const timer = { id: nextTimerId++, callback, delay, cleared: false };
      timers.push(timer);
      return timer.id;
    },
    clearTimeout(id) {
      const timer = timers.find((entry) => entry.id === id);
      if (timer) {
        timer.cleared = true;
      }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports.IndexHarness();
  Object.assign(app, { undoTimer: -1, undoVisible: false, undoMsg: '', undoSnap: null });
  return { app, timers, Motion: context.module.exports.Motion };
}

test('undo notice uses the five-second token and hides when that timer expires', () => {
  const { app, timers, Motion } = createHarness();
  const snapshot = { vaultId: 'local', relPath: 'removed.md', wasCurrent: true, wasRight: false };

  app.showUndo('已移入回收站', snapshot);

  assert.equal(app.undoMsg, '已移入回收站');
  assert.equal(app.undoSnap, snapshot);
  assert.equal(app.undoVisible, true);
  assert.equal(Motion.snack, 5000);
  assert.equal(timers[0].delay, Motion.snack);
  assert.equal(app.undoTimer, timers[0].id);

  timers[0].callback();

  assert.equal(app.undoTimer, -1);
  assert.equal(app.undoVisible, false);
});

test('replacing an undo notice cancels its timer and manual dismissal cancels the replacement', () => {
  const { app, timers } = createHarness();
  app.showUndo('first', null);
  app.showUndo('second', null);

  assert.equal(timers[0].cleared, true);
  assert.equal(timers[1].delay, 5000);
  assert.equal(app.undoMsg, 'second');
  assert.equal(app.undoTimer, timers[1].id);

  app.hideUndo();

  assert.equal(timers[1].cleared, true);
  assert.equal(app.undoTimer, -1);
  assert.equal(app.undoVisible, false);
});
