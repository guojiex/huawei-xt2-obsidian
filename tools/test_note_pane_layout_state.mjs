import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url));
const breakpointSource = readSourceFile(new URL('../entry/src/main/ets/model/Breakpoint.ets', import.meta.url));
const breakpointCode = transformSync(breakpointSource, { loader: 'ts', format: 'cjs' }).code;
const breakpointModule = { exports: {} };
vm.runInContext(breakpointCode, vm.createContext({ module: breakpointModule, exports: breakpointModule.exports }));
const { Breakpoint } = breakpointModule.exports;

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${startMarker}`);
  return source.slice(start, end).trim();
}

const code = transformSync(`
class PaneLayoutHarness {
  ${method('  private notePaneWidth(pane: string): Length {', '\n  private notePaneVisible(')}
  ${method('  private notePaneVisible(pane: string): boolean {', '\n  private startNavigationDrag(')}
}
module.exports = PaneLayoutHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(overrides = {}) {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports, Breakpoint }));
  const app = new module.exports();
  Object.assign(app, {
    breakpoint: Breakpoint.SM,
    focused: false,
    singleLandscape: false,
    activePane: 'left',
    sidebarCollapsed: false,
    sidebarProgress: 1,
    referenceVisible: true,
    windowWidthVp: 1000,
    navigationWidthVp: 400,
    noteContentWidth() { return this.windowWidthVp - this.navigationWidthVp * this.sidebarProgress; },
    noteContentRatio: () => 0.4
  }, overrides);
  app.isSingleScreenLayout = () => app.breakpoint === Breakpoint.SM || app.singleLandscape;
  return app;
}

test('NoteBody keeps each workspace pane in one stable layout position', () => {
  const start = source.indexOf('  NoteBody() {');
  const end = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && end > start, 'could not find NoteBody builder');
  const body = source.slice(start, end);

  assert.equal((body.match(/this\.LeftWorkspacePane\(/g) ?? []).length, 1);
  assert.equal((body.match(/this\.RightWorkspacePane\(/g) ?? []).length, 1);
  assert.equal((body.match(/SplitHandle\(/g) ?? []).length, 1);
});

test('NoteWorkspaceShell keeps one workspace tree under every breakpoint', () => {
  const workspaceStart = source.indexOf('  NoteWorkspaceContent() {');
  const workspaceEnd = source.indexOf('\n  @Builder\n  NoteWorkspaceShell()', workspaceStart);
  const start = source.indexOf('  NoteWorkspaceShell() {');
  const end = source.indexOf('\n  @Builder\n  NoteBody()', start);
  assert.ok(workspaceStart >= 0 && workspaceEnd > workspaceStart, 'could not find workspace content builder');
  assert.ok(start >= 0 && end > start, 'could not find NoteWorkspaceShell builder');
  const workspace = source.slice(workspaceStart, workspaceEnd);
  const shell = source.slice(start, end);

  assert.equal((workspace.match(/this\.NoteBody\(/g) ?? []).length, 1);
  assert.equal((workspace.match(/this\.Appbar\(/g) ?? []).length, 1);
  assert.equal((workspace.match(/this\.Statusbar\(/g) ?? []).length, 1);
  assert.equal((workspace.match(/this\.SaveFeedback\(/g) ?? []).length, 1);
  assert.equal((shell.match(/this\.NoteWorkspaceContent\(/g) ?? []).length, 2);
  assert.match(shell, /if \(this\.isSingleScreenLayout\(\)\)[\s\S]*\} else \{/);
  assert.match(shell, /this\.NoteNavigation\(this\.breakpoint === Breakpoint\.SM\)/);
  assert.equal((shell.match(/this\.NoteNavigation\(false\)/g) ?? []).length, 1);
});

test('sm and focused modes keep only the active pane visible at full width', () => {
  const compact = createHarness({ activePane: 'right' });
  assert.equal(compact.notePaneWidth('left'), 0);
  assert.equal(compact.notePaneWidth('right'), '100%');
  assert.equal(compact.notePaneVisible('left'), false);
  assert.equal(compact.notePaneVisible('right'), true);

  const focused = createHarness({ breakpoint: Breakpoint.LG, focused: true, activePane: 'left' });
  assert.equal(focused.notePaneWidth('left'), '100%');
  assert.equal(focused.notePaneWidth('right'), 0);
  assert.equal(focused.notePaneVisible('left'), true);
  assert.equal(focused.notePaneVisible('right'), false);
});

test('md animates from one available pane to two panes as navigation collapses', () => {
  const withNavigation = createHarness({ breakpoint: Breakpoint.MD });
  assert.equal(withNavigation.notePaneWidth('left'), 600);
  assert.equal(withNavigation.notePaneWidth('right'), 0);
  assert.equal(withNavigation.notePaneVisible('left'), true);
  assert.equal(withNavigation.notePaneVisible('right'), true);

  const split = createHarness({ breakpoint: Breakpoint.MD, sidebarCollapsed: true, sidebarProgress: 0 });
  assert.equal(split.notePaneWidth('left'), 500);
  assert.equal(split.notePaneWidth('right'), 500);
  assert.equal(split.notePaneVisible('left'), true);
  assert.equal(split.notePaneVisible('right'), true);

  split.referenceVisible = false;
  assert.equal(split.notePaneWidth('left'), 1000);
  assert.equal(split.notePaneWidth('right'), 0);
  assert.equal(split.notePaneVisible('right'), false);
});

test('single-landscape layout keeps only the active pane full-width while navigation pushes it', () => {
  const landscape = createHarness({ breakpoint: Breakpoint.MD, singleLandscape: true, activePane: 'right' });
  assert.equal(landscape.notePaneWidth('left'), 0);
  assert.equal(landscape.notePaneWidth('right'), '100%');
  assert.equal(landscape.notePaneVisible('left'), false);
  assert.equal(landscape.notePaneVisible('right'), true);
});

test('lg preserves the saved split ratio and hides the right pane when collapsed', () => {
  const split = createHarness({ breakpoint: Breakpoint.LG });
  assert.equal(split.notePaneWidth('left'), 240);
  assert.equal(split.notePaneWidth('right'), 360);
  assert.equal(split.notePaneVisible('left'), true);
  assert.equal(split.notePaneVisible('right'), true);

  split.referenceVisible = false;
  assert.equal(split.notePaneWidth('left'), '100%');
  assert.equal(split.notePaneWidth('right'), 0);
  assert.equal(split.notePaneVisible('right'), false);
});
