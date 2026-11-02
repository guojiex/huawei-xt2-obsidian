import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
// md 分支的宽度由 PaneLayout.mdPaneWidths 统一计算，这里加载真实实现而不是复制一份公式。
const paneLayoutRaw = fs.readFileSync(
  new URL('../../entry/src/main/ets/model/PaneLayout.ets', import.meta.url), 'utf8');
const paneLayoutCode = transformSync(
  paneLayoutRaw.replace(/^import[\s\S]*?from\s+'[^']+';\s*$/gm, ''),
  { loader: 'ts', format: 'cjs' }
).code;
const paneLayoutSandbox = {
  module: { exports: {} },
  Size: { paneMinW: 240 },
  Space: { s4: 16 },
  Breakpoint: { SM: 'sm', MD: 'md', LG: 'lg', MD_THRESHOLD_VP: 600, LG_THRESHOLD_VP: 840 }
};
vm.runInContext(paneLayoutCode, vm.createContext(paneLayoutSandbox));
const { mdPaneWidths } = paneLayoutSandbox.module.exports;

const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methodStart = indexSource.indexOf('  private settingsPaneWidthSummary(): string {');
const methodEnd = indexSource.indexOf('\n  private mdPaneWidth(', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find Index.settingsPaneWidthSummary');
const method = indexSource.slice(methodStart, methodEnd).trim();
const code = transformSync(`class SettingsWidthHarness {
  noteNavigationWidth() { return this.navigationWidth; }
  noteContentRatio() { return this.contentRatio; }
  mdPaneWidth() {
    return mdPaneWidths(this.windowWidthVp, this.noteNavigationWidth(),
      this.sidebarProgress, this.contentRatio);
  }
  isSingleScreenLayout() { return this.breakpoint === Breakpoint.SM || this.singleLandscape; }
  ${method}
}; module.exports = SettingsWidthHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

const Breakpoint = { SM: 'sm', MD: 'md', LG: 'lg' };

function createHarness(options = {}) {
  const context = vm.createContext({ module: { exports: {} }, Breakpoint, mdPaneWidths });
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
  // 目录推入到一半：目录占 152/800，剩余 648 按等分再按「推入进度」收右栏 ——
  // 以前右栏按窗口宽算（200），现在按剩余内容宽算（162），三段始终守恒。
  assert.equal(app.settingsPaneWidthSummary(), '目录 19.0% · 左栏 60.8% · 右栏 20.3%');
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
