import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

import { resolveSourcePath } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { buildSync } = require('esbuild');
const tokensBundle = buildSync({
  entryPoints: [resolveSourcePath(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url))],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  write: false,
  external: ['@kit.ArkUI'],
  resolveExtensions: ['.ets', '.ts', '.js'],
  loader: { '.ets': 'ts' }
}).outputFiles[0].text;
const tokensModule = { exports: {} };
new Function('module', 'exports', 'require', tokensBundle)(tokensModule, tokensModule.exports, (id) => {
  assert.equal(id, '@kit.ArkUI');
  return { curves: { cubicBezierCurve: () => ({}) } };
});
const { Size, Space } = tokensModule.exports;
const minimumPaneWidth = Size.paneMinW;
const splitterWidth = Space.s4;
const bundle = buildSync({
  entryPoints: [resolveSourcePath(new URL('../../entry/src/main/ets/model/PaneLayout.ets', import.meta.url))],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  write: false,
  external: ['@kit.ArkUI'],
  resolveExtensions: ['.ets', '.ts', '.js'],
  loader: { '.ets': 'ts' }
}).outputFiles[0].text;
const layoutModule = { exports: {} };
new Function('module', 'exports', 'require', bundle)(layoutModule, layoutModule.exports, (id) => {
  assert.equal(id, '@kit.ArkUI');
  return { curves: { cubicBezierCurve: () => ({}) } };
});
const {
  DEFAULT_CONTENT_RATIO,
  MAX_NAV_RATIO,
  MIN_NAV_RATIO,
  clampContentRatio,
  clampNavigationWidth,
  contentMinVp,
  fontScaleK,
  isSingleLandscapeWindow,
  navMinVp,
  navigationWidth
} = layoutModule.exports;

test('single-landscape recognition uses the md width and short landscape window bounds', () => {
  assert.equal(isSingleLandscapeWindow(600, 599.999), true);
  assert.equal(isSingleLandscapeWindow(839.999, 599), true);
  assert.equal(isSingleLandscapeWindow(599.999, 400), false);
  assert.equal(isSingleLandscapeWindow(840, 500), false);
  assert.equal(isSingleLandscapeWindow(800, 600), false);
  assert.equal(isSingleLandscapeWindow(800, 810), false);
});

test('navigation width uses the default ratio for an invalid saved ratio', () => {
  assert.equal(navigationWidth(1200, 0.5, 2, 2), 400);
});

test('navigation width stays within the configured ratio limits on a wide window', () => {
  const minimum = navigationWidth(1200, MIN_NAV_RATIO, 2, 2);
  const maximum = navigationWidth(1200, MAX_NAV_RATIO, 2, 2);

  assert.equal(minimum, 1200 * MIN_NAV_RATIO);
  assert.equal(maximum, 1200 * MAX_NAV_RATIO);
});

test('two wide content panes keep the 240vp minimum at the narrowest supported lg width', () => {
  const width = 840;
  const nav = navigationWidth(width, MAX_NAV_RATIO, 2, 2);
  const paneWidth = (width - nav - 2 * splitterWidth) / 2;

  assert.equal(nav, 328);
  assert.equal(minimumPaneWidth, 240);
  assert.equal(paneWidth, minimumPaneWidth);
});

test('single-landscape navigation uses the 200vp nav role minimum (v1.39 39.1)', () => {
  const width = 600;
  const nav = navigationWidth(width, 1 / 3, 1, 1);

  // v1.39 39.1：目录栏按角色取 200vp 基准（原来与内容栏同为 240vp）。
  assert.equal(nav, Size.paneMinNavW);
  assert.equal(nav, 200);
  assert.ok(width - nav - splitterWidth >= minimumPaneWidth);
});

test('content ratio preserves the 240vp pane minimum when both panes can fit', () => {
  const contentWidth = 1200;
  const minimumRatio = minimumPaneWidth / contentWidth;

  assert.equal(clampContentRatio(0.1, contentWidth), minimumRatio);
  assert.equal(clampContentRatio(0.9, contentWidth), 1 - minimumRatio);
  assert.equal(clampContentRatio(0.1, 840), minimumPaneWidth / 840);
  assert.equal(clampContentRatio(0.9, 840), 1 - minimumPaneWidth / 840);
});

test('content ratio returns its safe default when panes cannot both reach the minimum', () => {
  assert.equal(clampContentRatio(0.1, 480), DEFAULT_CONTENT_RATIO);
  assert.equal(clampContentRatio(0.9, 0), DEFAULT_CONTENT_RATIO);
});

test('navigation clamp handles a nonpositive window width without producing a negative size', () => {
  // v1.39 39.1：非正窗口宽的兜底返回目录栏角色下限 200vp。
  assert.equal(clampNavigationWidth(200, 0, 1, 1), Size.paneMinNavW);
  assert.equal(clampNavigationWidth(200, -1, 2, 2), Size.paneMinNavW);
});

test('v1.39 39.1/39.2: role minimums scale by k=clamp(fontSizeScale,1,1.45), rounded up', () => {
  assert.equal(fontScaleK(0.8), 1);
  assert.equal(fontScaleK(1), 1);
  assert.equal(fontScaleK(1.3), 1.3);
  assert.equal(fontScaleK(1.75), 1.45);
  assert.equal(navMinVp(1), 200);
  assert.equal(contentMinVp(1), 240);
  // 需求文档 39.2 参考值表：目录 / 正文与参考。
  assert.equal(navMinVp(1.15), 230);
  assert.equal(contentMinVp(1.15), 276);
  assert.equal(navMinVp(1.3), 260);
  assert.equal(contentMinVp(1.3), 312);
  assert.equal(navMinVp(1.45), 290);
  assert.equal(contentMinVp(1.45), 348);
  // 超过 1.45（关怀模式 / fontSizeMaxScale 1.75）不再加大；< 1 不缩小。
  assert.equal(navMinVp(1.75), 290);
  assert.equal(contentMinVp(1.75), 348);
  assert.equal(navMinVp(0.9), 200);
  assert.equal(contentMinVp(0.9), 240);
});

test('v1.39 39.5: three-pane nav maximum tightens by the saved content ratio', () => {
  // 1107vp（XT2 三屏）：r=0.5 时比例上限 46% 先命中；
  // r=0.6 时参考栏需要 240/0.4=600，上限收紧到 1107−600−32=475，比例不变且每栏 ≥ 240。
  const evenMax = clampNavigationWidth(1107, 1107, 2, 2, 1, 0.5);
  assert.ok(Math.abs(evenMax - 1107 * MAX_NAV_RATIO) < 0.001);
  const tiltedMax = clampNavigationWidth(1107, 1107, 2, 2, 1, 0.6);
  assert.ok(Math.abs(tiltedMax - (1107 - 600 - 2 * splitterWidth)) < 0.001);
  assert.ok(tiltedMax < evenMax);
  // 单内容栏（Agent / 单屏横屏）不受比例影响。
  assert.equal(clampNavigationWidth(1107, 1107, 1, 1, 1, 0.6),
    clampNavigationWidth(1107, 1107, 1, 1, 1, 0.5));
});

test('v1.39 39.2/39.4: 1.45 font scale raises clamp floors and lg 1107vp still fits all panes', () => {
  // k=1.45：目录下限 290、内容栏下限 348。
  const navMin = clampNavigationWidth(0, 1107, 2, 2, 1.45, 0.5);
  assert.equal(navMin, 290);
  const tiltedNavMin = clampContentRatio(0.9, 700, 1.45);
  assert.ok(Math.abs(tiltedNavMin - (1 - 348 / 700)) < 0.001);
  assert.ok(Math.abs(clampContentRatio(0.05, 700, 1.45) - 348 / 700) < 0.001);
  // 39.4：lg 三栏在 1.45 倍字号下默认比例仍放得下（左栏钳制到恰好 348）。
  const nav = navigationWidth(1107, MAX_NAV_RATIO, 2, 2, 1.45, 0.5);
  const left = (1107 - nav - 2 * splitterWidth) * 0.5;
  assert.ok(Math.abs(left - 348) < 0.001, `left=${left}`);
  assert.ok(nav >= 290);
  // 39.4：md 双屏 709vp @1.45，目录 0.38 比例低于下限时被抬到 290（290+348=638 ≤ 709）。
  assert.equal(navigationWidth(709, 0.38, 1, 1, 1.45), 290);
});
