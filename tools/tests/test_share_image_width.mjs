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

test('capture Web width and image settings both use the follow-current-pane mode', () => {
  assert.match(indexSource, /this\.shareCaptureWidthVp = this\.activeSharePaneWidthVp\(\)/);
  assert.match(indexSource, /\.width\(this\.shareCaptureWidthVp > 0 \? this\.shareCaptureWidthVp : '100%'\)/);
  assert.match(settingsSource, /Text\('跟随当前栏'\)/);
  assert.match(settingsSource, /排版宽度沿用当前笔记栏/);
});
