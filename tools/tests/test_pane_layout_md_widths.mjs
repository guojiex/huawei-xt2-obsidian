/**
 * md（物理双屏）布局栏宽回归。
 *
 * 背景：md 分支原来是硬编码「右栏 = 窗口宽 × 50% ×(1-目录进度)」，
 * 完全不读 contentRatio，所以设置页「恢复等分栏宽」在双屏下点了没有反应；
 * 「当前栏宽」显示的百分比又由另一套算法算出，与实际布局对不上。
 *
 * 这里断言三件事：
 * 1. mdPaneWidths 在默认比例下与原来的硬编码逐点一致（等屏观感不变）；
 * 2. 比例确实参与计算，因此重置到默认值一定看得见变化；
 * 3. 布局宽度与「当前栏宽」显示同源，md 下也有可拖动的分隔条。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

function loadPaneLayout() {
  const raw = readSourceFile(
    new URL('../../entry/src/main/ets/model/PaneLayout.ets', import.meta.url));
  const stripped = raw.replace(/^import[\s\S]*?from\s+'[^']+';\s*$/gm, '');
  const code = transformSync(stripped, { loader: 'ts', format: 'cjs' }).code;
  const sandbox = {
    module: { exports: {} },
    exports: {},
    Size: { paneMinW: 240, paneMinNavW: 200 },
    Space: { s4: 16 },
    Breakpoint: {
      SM: 'sm', MD: 'md', LG: 'lg',
      MD_THRESHOLD_VP: 600, LG_THRESHOLD_VP: 840
    }
  };
  vm.runInContext(code, vm.createContext(sandbox));
  return sandbox.module.exports;
}

const { mdPaneWidths, DEFAULT_CONTENT_RATIO } = loadPaneLayout();
const WIDTH_VP = 720;
const NAV_VP = 720 * 0.38;

test('默认比例 + 目录收起：左右各半，与原来的硬编码一致', () => {
  const widths = mdPaneWidths(WIDTH_VP, NAV_VP, 0, DEFAULT_CONTENT_RATIO);
  assert.equal(widths.nav, 0);
  assert.equal(widths.left, WIDTH_VP * 0.5);
  assert.equal(widths.right, WIDTH_VP * 0.5);
});

test('默认比例 + 目录推入：右栏收起、左栏占满剩余，与原来的硬编码一致', () => {
  const widths = mdPaneWidths(WIDTH_VP, NAV_VP, 1, DEFAULT_CONTENT_RATIO);
  assert.equal(widths.nav, NAV_VP);
  assert.equal(widths.right, 0);
  assert.ok(Math.abs(widths.left - (WIDTH_VP - NAV_VP)) < 0.001);
});

test('栏宽比例参与计算：拖窄左栏后重置为默认值必然改变宽度', () => {
  // 目录收起时可用宽 720vp，最小栏宽 240vp，可用比例区间约 [0.333, 0.667]。
  const dragged = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.36);
  assert.ok(Math.abs(dragged.left - WIDTH_VP * 0.36) < 0.001);
  const reset = mdPaneWidths(WIDTH_VP, NAV_VP, 0, DEFAULT_CONTENT_RATIO);
  assert.ok(reset.left - dragged.left > 1, '重置必须让左栏真的变宽');
  assert.ok(Math.abs(reset.left - reset.right) < 0.001, '重置后左右等分');
});

test('三段宽度守恒：目录 + 左 + 右 恒等于窗口宽', () => {
  for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
    for (const ratio of [0.36, DEFAULT_CONTENT_RATIO, 0.64]) {
      const widths = mdPaneWidths(WIDTH_VP, NAV_VP, progress, ratio);
      const total = widths.nav + widths.left + widths.right;
      assert.ok(Math.abs(total - WIDTH_VP) < 0.001,
        `progress=${progress} ratio=${ratio} total=${total}`);
    }
  }
});

test('极端比例被夹到最小栏宽，右栏不会被压没', () => {
  const widths = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.98);
  assert.ok(widths.right >= 240 - 0.001);
  assert.ok(widths.left >= 240 - 0.001);
});

test('v1.39 39.2/39.7: 字号放大时 md 双栏按放大后的内容下限钳制（1.3 → 312）', () => {
  // 720vp 内容区、ratio=0.98：1.0 字号时右栏夹到 240；1.3 字号时夹到 312。
  const standard = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.98, 1);
  assert.ok(standard.right >= 240 - 0.001);
  const scaled = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.98, 1.3);
  assert.ok(scaled.right >= 312 - 0.001, `right=${scaled.right}`);
  assert.ok(scaled.right > standard.right);
  // 1.75 封顶到 1.45 → 348；< 1 不缩小。
  const capped = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.98, 1.75);
  assert.ok(capped.right >= 348 - 0.001, `right=${capped.right}`);
  const shrunk = mdPaneWidths(WIDTH_VP, NAV_VP, 0, 0.98, 0.9);
  assert.ok(Math.abs(shrunk.right - standard.right) < 0.001);
});

test('窗口宽未知时返回 0，不产生负宽', () => {
  const widths = mdPaneWidths(0, NAV_VP, 1, DEFAULT_CONTENT_RATIO);
  assert.equal(widths.nav, 0);
  assert.equal(widths.left, 0);
  assert.equal(widths.right, 0);
});

test('越界进度按端点处理，不产生负宽', () => {
  const over = mdPaneWidths(WIDTH_VP, NAV_VP, 1.4, DEFAULT_CONTENT_RATIO);
  assert.equal(over.right, 0);
  const under = mdPaneWidths(WIDTH_VP, NAV_VP, -0.4, DEFAULT_CONTENT_RATIO);
  assert.equal(under.nav, 0);
});

const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function sliceBetween(startMarker, endMarker) {
  const start = indexSource.indexOf(startMarker);
  assert.ok(start >= 0, `未找到 ${startMarker}`);
  return indexSource.slice(start, indexSource.indexOf(endMarker, start));
}

test('真正生效的两栏宽度（notePaneWidth）在 md 下走统一算法，不再硬编码 50%', () => {
  const notePaneWidth = sliceBetween('private notePaneWidth(pane: string)', 'private notePaneVisible(');
  assert.match(notePaneWidth, /const widths: MdPaneWidths = this\.mdPaneWidth\(\)/);
  assert.match(notePaneWidth, /return this\.referenceVisible \? widths\.right : 0/);
  assert.doesNotMatch(notePaneWidth, /this\.windowWidthVp \* 0\.5 \* \(1 - this\.sidebarProgress\)/);
});

test('md 与 lg 共用同一个宽度来源，避免两套数字', () => {
  const mdPaneWidth = sliceBetween('private mdPaneWidth()', 'private notePaneWidth(');
  assert.match(mdPaneWidth, /mdPaneWidths\(this\.windowWidthVp, this\.noteNavigationWidth\(\),/);
});

test('“当前栏宽”与实际布局同源，重置后数字会跟着变', () => {
  const summary = sliceBetween('private settingsPaneWidthSummary()', 'private mdPaneWidth()');
  assert.match(summary, /const mdWidths: MdPaneWidths = this\.mdPaneWidth\(\)/);
  assert.match(summary, /leftWidth = this\.referenceVisible \? mdWidths\.left : contentWidth/);
  assert.doesNotMatch(summary, /totalWidth \* 0\.5 \* \(1 - this\.sidebarProgress\)/);
});

test('双屏也有正文分隔条：md 下能拖动，“恢复等分栏宽”才有东西可恢复', () => {
  const handle = sliceBetween('private contentHandleVisible()', 'private notePaneWidth(');
  assert.match(handle, /this\.breakpoint === Breakpoint\.LG \|\| this\.breakpoint === Breakpoint\.MD/);
  const body = sliceBetween('@Builder\n  NoteBody()', '@Builder\n  NoteWorkspaceContent');
  assert.match(body, /\.enabled\(this\.contentHandleVisible\(\)\)/);
});

test('重置分栏给出可见反馈，避免“点了没反应”与“点了没生效”混淆', () => {
  const reset = sliceBetween('private resetSplitLayout()', 'private setSidebarCollapsed(');
  assert.match(reset, /promptAction\.showToast/);
  assert.match(reset, /this\.contentRatio = DEFAULT_CONTENT_RATIO/);
  assert.match(reset, /\(this\.splitLayoutStore as SplitLayoutStore\)\.reset\(\)/);
});
