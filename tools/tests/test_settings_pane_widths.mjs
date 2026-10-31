import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methodStart = indexSource.indexOf('  private settingsPaneWidthSummary(): string {');
const methodEnd = indexSource.indexOf('\n  private notePaneWidth(', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find Index.settingsPaneWidthSummary');
const method = indexSource.slice(methodStart, methodEnd).trim();
const code = transformSync(`class SettingsWidthHarness {
  noteNavigationWidth() { return this.navigationWidth; }
  noteContentRatio() { return this.contentRatio; }
  isSingleScreenLayout() { return this.breakpoint === Breakpoint.SM || this.singleLandscape; }
  ${method}
}; module.exports = SettingsWidthHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

const Breakpoint = { SM: 'sm', MD: 'md', LG: 'lg' };

function createHarness(options = {}) {
  const context = vm.createContext({ module: { exports: {} }, Breakpoint });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    windowWidthVp: 1200,
    breakpoint: Breakpoint.LG,
    singleLandscape: false,
    sidebarCollapsed: false,
    focused: false,
    referenceVisible: true,
    activePane: 'left',
    sidebarProgress: 1,
    navigationWidth: 400,
    contentRatio: 0.5,
    ...options
  });
  return app;
}

test('wide layout reports navigation and both equal content columns', () => {
  assert.equal(createHarness().settingsPaneWidthSummary(), '目录 33.3% · 左栏 33.3% · 右栏 33.3%');
});

test('collapsed wide layout reports live content split ratios', () => {
  const app = createHarness({ sidebarCollapsed: true, contentRatio: 0.65 });
  assert.equal(app.settingsPaneWidthSummary(), '目录 0.0% · 左栏 65.0% · 右栏 35.0%');
});

test('medium layout reports navigation and the single visible note pane', () => {
  const app = createHarness({
    windowWidthVp: 800,
    breakpoint: Breakpoint.MD,
    navigationWidth: 304
  });
  assert.equal(app.settingsPaneWidthSummary(), '目录 38.0% · 左栏 62.0% · 右栏 0.0%');
});

test('collapsed medium layout reports the two visible equal panes', () => {
  const app = createHarness({
    windowWidthVp: 800,
    breakpoint: Breakpoint.MD,
    sidebarCollapsed: true,
    sidebarProgress: 0,
    navigationWidth: 304
  });
  assert.equal(app.settingsPaneWidthSummary(), '目录 0.0% · 左栏 50.0% · 右栏 50.0%');
});

test('single-screen layout reports only its active pane', () => {
  const app = createHarness({ breakpoint: Breakpoint.SM, activePane: 'right' });
  assert.equal(app.settingsPaneWidthSummary(), '目录 0.0% · 左栏 0.0% · 右栏 100.0%');
});

test('focus layout reports the active pane at full width', () => {
  const app = createHarness({ focused: true, activePane: 'right' });
  assert.equal(app.settingsPaneWidthSummary(), '目录 0.0% · 左栏 0.0% · 右栏 100.0%');
});

test('single-landscape layout reports the active pane without counting overlay navigation', () => {
  const app = createHarness({ singleLandscape: true, activePane: 'right' });
  assert.equal(app.settingsPaneWidthSummary(), '目录 0.0% · 左栏 0.0% · 右栏 100.0%');
});

test('medium navigation transition reports the currently visible pane widths', () => {
  const app = createHarness({
    windowWidthVp: 800,
    breakpoint: Breakpoint.MD,
    sidebarProgress: 0.5,
    navigationWidth: 304
  });
  assert.equal(app.settingsPaneWidthSummary(), '目录 19.0% · 左栏 56.0% · 右栏 25.0%');
});

test('a single visible wide pane reports the unused right column as zero', () => {
  const app = createHarness({ referenceVisible: false });
  assert.equal(app.settingsPaneWidthSummary(), '目录 33.3% · 左栏 66.7% · 右栏 0.0%');
});

test('unmeasured windows use a placeholder instead of fabricated widths', () => {
  assert.equal(createHarness({ windowWidthVp: 0 }).settingsPaneWidthSummary(), '—');
});

test('SettingsView displays the summary supplied by Index', () => {
  const settingsSource = fs.readFileSync(
    new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url), 'utf8');
  assert.match(settingsSource, /@Prop paneWidthSummary: string = '—';/);
  assert.match(settingsSource, /this\.InfoRow\('当前栏宽', this\.paneWidthSummary, false\)/);
  assert.match(indexSource, /paneWidthSummary: this\.settingsPaneWidthSummary\(\)/);
});
