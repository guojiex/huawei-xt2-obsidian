import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const hideStart = source.indexOf('  private hideSaveFeedback(): void {');
const marginStart = source.indexOf('  private saveFeedbackBottomMargin(): number {', hideStart);
const areaStart = source.indexOf('\n  private recordSaveFeedbackWorkspaceArea', marginStart);
assert.ok(hideStart >= 0 && marginStart > hideStart && areaStart > marginStart,
  'could not find save feedback display methods');
const methods = `${source.slice(hideStart, marginStart).trim()} ${source.slice(marginStart, areaStart).trim()}`;
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
    Space: { s3: 12 },
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
    saveFeedbackFadeTimer: -1,
    formatWindowArea: [0, 100, 1200, 800],
    saveFeedbackWorkspaceBottomVp: 900,
    keyboardInsetVp: () => 0
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

test('save feedback bottom margin clears the remaining keyboard inset after workspace resize', () => {
  const { app } = createHarness();

  assert.equal(app.saveFeedbackBottomMargin(), 12);

  app.keyboardInsetVp = () => 300;
  app.saveFeedbackWorkspaceBottomVp = 700;
  assert.equal(app.saveFeedbackBottomMargin(), 112);

  app.saveFeedbackWorkspaceBottomVp = 500;
  assert.equal(app.saveFeedbackBottomMargin(), 12);
});
