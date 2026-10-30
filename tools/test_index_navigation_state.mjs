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
class NavigationHarness {
  ${method('  private setSidebarCollapsed(collapsed: boolean): void {', '\n  private setDrawerOpen(')}
  ${method('  private setDrawerOpen(open: boolean): void {', '\n  private closeNoteNavigation(')}
  ${method('  private syncNavigationForBreakpoint(): void {', '\n  private async refreshAfterBreakpointChange(')}
  ${method('  private isReferenceShown(): boolean {', '\n  private toggleFocus(')}
  ${method('  private toggleFocus(): void {', '\n  private previewActiveNoteInOtherPane(')}
  ${method('  private onHamburger(): void {', '\n  // ===== 库操作')}

  setActivePane(pane) {
    this.activePane = pane;
    this.activePaneChanges.push(pane);
  }
}
module.exports = NavigationHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(overrides = {}) {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports, Breakpoint }));
  const app = new module.exports();
  Object.assign(app, {
    topView: 'note',
    breakpoint: Breakpoint.SM,
    layoutBreakpoint: Breakpoint.SM,
    sidebarCollapsed: false,
    sidebarProgress: 1,
    drawerOpen: false,
    drawerProgress: 0,
    focused: false,
    activePane: 'left',
    referenceVisible: true,
    moreMenuOpen: true,
    paneMoreOpen: true,
    agentHamburgerSeq: 0,
    activePaneChanges: []
  }, overrides);
  return app;
}

test('sm hamburger toggles the drawer without changing desktop navigation state', () => {
  const app = createHarness({ sidebarCollapsed: true, sidebarProgress: 0 });

  app.onHamburger();
  assert.equal(app.drawerOpen, true);
  assert.equal(app.drawerProgress, 1);
  assert.equal(app.sidebarCollapsed, true);
  assert.equal(app.sidebarProgress, 0);

  app.onHamburger();
  assert.equal(app.drawerOpen, false);
  assert.equal(app.drawerProgress, 0);
});

test('md hamburger returns from the reference pane before reopening navigation', () => {
  const app = createHarness({
    breakpoint: Breakpoint.MD,
    layoutBreakpoint: Breakpoint.MD,
    sidebarCollapsed: true,
    sidebarProgress: 0,
    activePane: 'right'
  });

  app.onHamburger();
  assert.equal(app.activePane, 'left');
  assert.deepEqual(app.activePaneChanges, ['left']);
  assert.equal(app.sidebarCollapsed, false);
  assert.equal(app.sidebarProgress, 1);

  app.onHamburger();
  assert.equal(app.sidebarCollapsed, true);
  assert.equal(app.sidebarProgress, 0);
  assert.deepEqual(app.activePaneChanges, ['left']);
});

test('hamburger exits focused md mode, restores navigation, and returns to the left pane', () => {
  const app = createHarness({
    breakpoint: Breakpoint.MD,
    layoutBreakpoint: Breakpoint.MD,
    sidebarCollapsed: true,
    sidebarProgress: 0,
    focused: true,
    activePane: 'right'
  });

  app.onHamburger();
  assert.equal(app.focused, false);
  assert.equal(app.activePane, 'left');
  assert.equal(app.sidebarCollapsed, false);
  assert.equal(app.sidebarProgress, 1);
  assert.equal(app.moreMenuOpen, false);
  assert.equal(app.paneMoreOpen, false);
});

test('hamburger exits focused lg mode while preserving the active content pane', () => {
  const app = createHarness({
    breakpoint: Breakpoint.LG,
    layoutBreakpoint: Breakpoint.LG,
    sidebarCollapsed: true,
    sidebarProgress: 0,
    focused: true,
    activePane: 'right'
  });

  app.onHamburger();
  assert.equal(app.focused, false);
  assert.equal(app.activePane, 'right');
  assert.equal(app.sidebarCollapsed, false);
  assert.equal(app.sidebarProgress, 1);
  assert.deepEqual(app.activePaneChanges, []);
});

test('entering md collapses navigation only when a reference pane can be shown', () => {
  const app = createHarness({ breakpoint: Breakpoint.MD, referenceVisible: true });

  app.syncNavigationForBreakpoint();
  assert.equal(app.sidebarCollapsed, true);
  assert.equal(app.sidebarProgress, 0);

  app.layoutBreakpoint = Breakpoint.SM;
  app.sidebarCollapsed = false;
  app.sidebarProgress = 1;
  app.focused = true;
  app.syncNavigationForBreakpoint();
  assert.equal(app.sidebarCollapsed, false);
  assert.equal(app.sidebarProgress, 1);

  app.layoutBreakpoint = Breakpoint.MD;
  app.focused = false;
  app.sidebarCollapsed = false;
  app.sidebarProgress = 1;
  app.syncNavigationForBreakpoint();
  assert.equal(app.sidebarCollapsed, false);
  assert.equal(app.sidebarProgress, 1);
});

test('reference visibility follows compact, middle, and wide layout semantics', () => {
  const app = createHarness();

  assert.equal(app.isReferenceShown(), false);
  app.activePane = 'right';
  assert.equal(app.isReferenceShown(), true);
  app.breakpoint = Breakpoint.MD;
  app.sidebarCollapsed = false;
  assert.equal(app.isReferenceShown(), false);
  app.sidebarCollapsed = true;
  assert.equal(app.isReferenceShown(), true);
  app.focused = true;
  assert.equal(app.isReferenceShown(), false);
  app.breakpoint = Breakpoint.LG;
  assert.equal(app.isReferenceShown(), false);
  app.focused = false;
  assert.equal(app.isReferenceShown(), true);
  app.referenceVisible = false;
  assert.equal(app.isReferenceShown(), false);
});
