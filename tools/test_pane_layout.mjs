import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { buildSync } = require('esbuild');
const tokensBundle = buildSync({
  entryPoints: [new URL('../entry/src/main/ets/common/Tokens.ets', import.meta.url).pathname],
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
  entryPoints: [new URL('../entry/src/main/ets/model/PaneLayout.ets', import.meta.url).pathname],
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
  isSingleLandscapeWindow,
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

test('single-landscape navigation leaves at least 240vp for its content pane', () => {
  const width = 600;
  const nav = navigationWidth(width, 1 / 3, 1, 1);

  assert.equal(nav, minimumPaneWidth);
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
  assert.equal(clampNavigationWidth(200, 0, 1, 1), 240);
  assert.equal(clampNavigationWidth(200, -1, 2, 2), 240);
});
