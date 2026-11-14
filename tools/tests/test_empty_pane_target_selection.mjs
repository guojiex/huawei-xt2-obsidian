import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function extract(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find source block ${startMarker}`);
  return source.slice(start, end).trim();
}

const setActivePane = extract('  private setActivePane(', '\n  private recordPaneWidth(');
const onSelectFile = extract(
  '  private onSelectFile(relPath: string, targetPane: string = this.activePane, returnFocus: boolean = false): void {',
  '\n  private async closePaneNote('
);
const code = transformSync(`
class IndexHarness {
  ${setActivePane}
  ${onSelectFile}
}
module.exports = IndexHarness;
`, { loader: 'ts', format: 'cjs' }).code;

test('selecting an empty pane keeps it empty and file-list selection opens in that pane', () => {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  const app = new module.exports();
  const opened = [];
  Object.assign(app, {
    activePane: 'left',
    currentFilePath: 'notes/b.md',
    rightFilePath: '',
    rightPaneIntentionallyEmpty: false,
    isSingleScreenLayout: () => false,
    scheduleWorkspaceSessionSave() {},
    refreshSharedEditability() {},
    refreshActiveChaptersFromBridge() {},
    refreshBacklinks() {},
    loadFile(path) { opened.push('left:' + path); },
    loadRightFile(path) { opened.push('right:' + path); }
  });

  app.setActivePane('right', true);

  assert.equal(app.activePane, 'right');
  assert.equal(app.rightFilePath, '');
  assert.deepEqual(opened, []);

  app.onSelectFile('notes/a.md');

  assert.deepEqual(opened, ['right:notes/a.md']);
});

test('native empty-pane and right-pane taps preserve empty state and the sidebar follows active pane', () => {
  const emptyPane = extract('  EmptyPane(pane: string) {', '\n  /** 57.7：导航条避让高度');
  const rightPane = extract('  RightWorkspacePane() {', '\n  @Builder\n  EditorPane(');
  const navigation = extract('  NoteNavigation(asDrawer: boolean) {', '\n  @Builder\n  LeftWorkspacePane(');

  assert.match(emptyPane, /\.onClick\(\(\): void => \{ this\.setActivePane\(pane, true\); \}\)/);
  assert.match(emptyPane, /this\.activePane === pane \? '已选择' : '未选择'/);
  assert.match(rightPane, /this\.rightFilePath\.length === 0 && this\.activePane === 'right'/);
  assert.match(rightPane, /\.height\(Size\.paneSelectionIndicator\)[\s\S]*?\.backgroundColor\(\$r\('app\.color\.brand'\)\)/);
  assert.match(rightPane, /\.onClick\(\(\): void => \{ this\.setActivePane\('right', true\); \}\)/);
  assert.match(navigation, /currentFilePath: this\.activeFilePath\(\)/);
  assert.match(navigation, /onSelectFile: \(relPath: string\): void => \{ this\.onSelectFile\(relPath\); \}/);
});
