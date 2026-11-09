import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const settingsSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareImageSettingsDialog.ets', import.meta.url));
const methodStart = indexSource.indexOf('  private activeSharePaneWidthVp(): number {');
const methodEnd = indexSource.indexOf('\n  /**', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find activeSharePaneWidthVp');

const methodCode = transformSync(`
class ShareImageWidthHarness {
  ${indexSource.slice(methodStart, methodEnd)}
}
module.exports = ShareImageWidthHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const module = { exports: {} };
  vm.runInContext(methodCode, vm.createContext({ module, exports: module.exports }));
  return new module.exports();
}

test('share capture follows the measured active pane, including the simple-mode pane', () => {
  const app = createHarness();
  app.experienceMode = 'professional';
  app.activePane = 'left';
  app.leftPaneWidthVp = 360;
  app.rightPaneWidthVp = 480;
  assert.equal(app.activeSharePaneWidthVp(), 360);

  app.experienceMode = 'simple';
  app.simpleWorkspacePane = () => 'right';
  assert.equal(app.activeSharePaneWidthVp(), 480);
});

test('share capture falls back to the layout width before pane measurement', () => {
  const app = createHarness();
  app.experienceMode = 'professional';
  app.activePane = 'right';
  app.rightPaneWidthVp = 0;
  app.notePaneWidth = () => 420;
  app.noteContentWidth = () => 700;
  assert.equal(app.activeSharePaneWidthVp(), 420);

  app.notePaneWidth = () => '100%';
  assert.equal(app.activeSharePaneWidthVp(), 700);
});

test('shareLayoutWidthVp maps phone/wide/pane to fixed or dynamic widths', () => {
  const app = createHarness();
  assert.equal(app.shareLayoutWidthVp('phone', 480), 360);
  assert.equal(app.shareLayoutWidthVp('wide', 480), 720);
  assert.equal(app.shareLayoutWidthVp('pane', 480), 480);
  assert.equal(app.shareLayoutWidthVp('pane', 350), 350);
});

test('settings dialog provides width segment with phone/wide/pane and capture uses the selected width', () => {
  assert.match(indexSource, /this\.shareCaptureWidthVp = this\.shareLayoutWidthVp\(this\.shareCaptureWidthId, paneWidthVp\)/);
  assert.match(indexSource, /this\.shareCaptureWidthVp = this\.shareLayoutWidthVp\(widthId, resolvedPaneWidthVp\)/);
  assert.match(indexSource, /\.width\(this\.shareCaptureWidthVp > 0 \? this\.shareCaptureWidthVp : '100%'\)/);
  assert.match(settingsSource, /this\.WidthOption\(ShareImageWidthPresets\.PHONE\)/);
  assert.match(settingsSource, /this\.WidthOption\(ShareImageWidthPresets\.WIDE\)/);
  assert.match(settingsSource, /this\.WidthOption\(ShareImageWidthPresets\.PANE\)/);
  assert.match(settingsSource, /ShareImageWidthPresets\.hintWithPx/);
  assert.match(indexSource, /initialWidthId: this\.shareCaptureWidthId/);
  assert.match(settingsSource, /onConfirm: \(widthId: string, theme: string\)/);
});
