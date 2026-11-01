import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function extractMethod(signature, nextMarker) {
  const start = source.indexOf(`  private ${signature}`);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${signature}`);
  return source.slice(start, end).trim();
}

const switchFromNavigationMethod = extractMethod('switchVaultFromNavigation(id: string): void {', '\n  private async switchVault(');
const selectFileMethod = extractMethod('onSelectFile(relPath: string): void {', '\n  private openFileInOtherPane(');
const code = transformSync(`
class IndexHarness {
  ${switchFromNavigationMethod}
  ${selectFileMethod}
}
module.exports = IndexHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(singleScreen) {
  const module = { exports: {} };
  const calls = [];
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    DOMAIN: 0,
    TAG: 'Index',
    hilog: { info() {} }
  }));
  const app = new module.exports();
  Object.assign(app, {
    drawerOpen: true,
    sidebarCollapsed: false,
    smMode: 'preview',
    activePane: 'left',
    isSingleScreenLayout: () => singleScreen,
    isSingleLandscape: () => false,
    closeNoteNavigation() { calls.push('close-navigation'); },
    setDrawerOpen(open) { calls.push(`drawer:${open}`); this.drawerOpen = open; },
    doSwitchVault(id) { calls.push(`switch:${id}`); },
    loadFile(path) { calls.push(`left:${path}`); },
    loadRightFile(path) { calls.push(`right:${path}`); }
  });
  return { app, calls };
}

test('switching vault from single-screen navigation preserves the open file list', () => {
  const { app, calls } = createHarness(true);

  app.switchVaultFromNavigation('next-vault');

  assert.equal(app.drawerOpen, true);
  assert.deepEqual(calls, ['switch:next-vault']);
});

test('selecting a note from single-screen navigation closes the list and opens only that note', () => {
  const { app, calls } = createHarness(true);

  app.onSelectFile('notes/selected.md');

  assert.equal(app.drawerOpen, false);
  assert.equal(app.smMode, 'edit');
  assert.deepEqual(calls, ['drawer:false', 'left:notes/selected.md']);
});

test('a selected note opens in the active right pane after leaving single-screen navigation', () => {
  const { app, calls } = createHarness(true);
  app.activePane = 'right';

  app.onSelectFile('notes/right.md');

  assert.deepEqual(calls, ['drawer:false', 'right:notes/right.md']);
});

test('non-single-screen vault switching keeps its existing navigation-close callback path', () => {
  const { app, calls } = createHarness(false);

  app.switchVaultFromNavigation('next-vault');

  assert.equal(app.drawerOpen, true);
  assert.deepEqual(calls, ['close-navigation', 'switch:next-vault']);
});
