import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const hideStart = source.indexOf('  private hideSaveFeedback(): void {');
const insetStart = source.indexOf('\n  private onFormatKeyboardInsetChanged', hideStart);
assert.ok(hideStart >= 0 && insetStart > hideStart,
  'could not find save feedback display methods');
const methods = source.slice(hideStart, insetStart).trim();
const code = transformSync(`class SaveFeedbackHarness { ${methods} }; module.exports = SaveFeedbackHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness() {
  const timers = new Map();
  const cleared = [];
  let nextTimerId = 1;
  const context = vm.createContext({
    module: { exports: {} },
    Motion: { durBase: 180 },
    setTimeout(callback, delay) {
      const id = nextTimerId++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      cleared.push(id);
      timers.delete(id);
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    saveFeedbackMounted: false,
    saveFeedbackOpacity: 0,
    saveFeedbackTimer: -1,
    saveFeedbackFadeTimer: -1
  });
  return { app, timers, cleared };
}

test('save feedback stays visible, then fades and unmounts on the existing timers', () => {
  const { app, timers } = createHarness();

  app.showSaveFeedback();

  assert.equal(app.saveFeedbackMounted, true);
  assert.equal(app.saveFeedbackOpacity, 1);
  assert.equal(timers.get(app.saveFeedbackTimer).delay, 3500);
  const visibleTimer = app.saveFeedbackTimer;
  const visibleCallback = timers.get(visibleTimer).callback;
  timers.delete(visibleTimer);
  visibleCallback();

  assert.equal(app.saveFeedbackMounted, true);
  assert.equal(app.saveFeedbackOpacity, 0);
  assert.equal(timers.get(app.saveFeedbackFadeTimer).delay, 180);
  const fadeTimer = app.saveFeedbackFadeTimer;
  const fadeCallback = timers.get(fadeTimer).callback;
  timers.delete(fadeTimer);
  fadeCallback();

  assert.equal(app.saveFeedbackMounted, false);
  assert.equal(app.saveFeedbackFadeTimer, -1);
});

test('replacing or hiding save feedback cancels its pending timer', () => {
  const { app, timers, cleared } = createHarness();

  app.showSaveFeedback();
  const firstTimer = app.saveFeedbackTimer;
  app.showSaveFeedback();
  const replacementTimer = app.saveFeedbackTimer;

  assert.notEqual(replacementTimer, firstTimer);
  assert.ok(cleared.includes(firstTimer));
  assert.equal(timers.has(firstTimer), false);
  assert.equal(timers.get(replacementTimer).delay, 3500);

  app.hideSaveFeedback();

  assert.ok(cleared.includes(replacementTimer));
  assert.equal(timers.size, 0);
  assert.equal(app.saveFeedbackMounted, false);
  assert.equal(app.saveFeedbackOpacity, 0);
});

test('save hint is docked in the bottom status bar row, not floating above the format dock', () => {
  const statusStart = source.indexOf('  Statusbar() {');
  const statusEnd = source.indexOf('\n  @Builder', statusStart);
  const workspaceStart = source.indexOf('  NoteWorkspaceContent() {');
  const workspaceEnd = source.indexOf('\n  @Builder', workspaceStart + 10);

  assert.ok(statusStart >= 0 && statusEnd > statusStart, 'could not find Statusbar builder');
  assert.ok(workspaceStart >= 0 && workspaceEnd > workspaceStart, 'could not find NoteWorkspaceContent builder');

  const statusBarBlock = source.slice(statusStart, statusEnd);
  const workspaceBlock = source.slice(workspaceStart, workspaceEnd);
  const totalCalls = source.match(/this\.SaveFeedback\(/g) ?? [];

  assert.equal(totalCalls.length, 1, 'SaveFeedback builder must be mounted exactly once');
  assert.ok(statusBarBlock.includes('this.SaveFeedback()'),
    'save hint must lead the bottom status bar row');
  assert.equal(statusBarBlock.indexOf('this.SaveFeedback()') < statusBarBlock.indexOf('Blank()'), true,
    'save hint sits on the left of the word count');
  assert.equal(workspaceBlock.includes('this.SaveFeedback()'), false,
    'save hint must not overlay the editor workspace above the format dock');
});
