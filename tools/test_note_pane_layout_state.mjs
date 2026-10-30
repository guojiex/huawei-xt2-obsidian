import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const breakpointSource = fs.readFileSync(new URL('../entry/src/main/ets/model/Breakpoint.ets', import.meta.url), 'utf8');
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
    activePane: 'left',
    sidebarCollapsed: false,
    referenceVisible: true,
    noteContentWidth: () => 600,
    noteContentRatio: () => 0.4
  }, overrides);
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
  assert.equal((shell.match(/this\.NoteWorkspaceContent\(/g) ?? []).length, 1);
  assert.equal((shell.match(/this\.NoteNavigation\(true\)/g) ?? []).length, 1);
  assert.equal((shell.match(/this\.NoteNavigation\(false\)/g) ?? []).length, 1);
  assert.match(shell, /if \(this\.breakpoint !== Breakpoint\.SM\) \{\s*this\.NoteNavigation\(false\)/);
  assert.match(shell, /if \(this\.breakpoint === Breakpoint\.SM\) \{\s*Column\(\) \{\s*this\.NoteNavigation\(true\)/);
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

test('md shows one full pane with navigation or two equal panes when collapsed', () => {
  const withNavigation = createHarness({ breakpoint: Breakpoint.MD });
  assert.equal(withNavigation.notePaneWidth('left'), '100%');
  assert.equal(withNavigation.notePaneWidth('right'), 0);
  assert.equal(withNavigation.notePaneVisible('left'), true);
  assert.equal(withNavigation.notePaneVisible('right'), false);

  const split = createHarness({ breakpoint: Breakpoint.MD, sidebarCollapsed: true });
  assert.equal(split.notePaneWidth('left'), '50%');
  assert.equal(split.notePaneWidth('right'), '50%');
  assert.equal(split.notePaneVisible('left'), true);
  assert.equal(split.notePaneVisible('right'), true);

  split.referenceVisible = false;
  assert.equal(split.notePaneWidth('left'), '100%');
  assert.equal(split.notePaneWidth('right'), 0);
  assert.equal(split.notePaneVisible('right'), false);
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
