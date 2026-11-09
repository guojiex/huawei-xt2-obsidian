import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const previewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url));
const settingsSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareImageSettingsDialog.ets', import.meta.url));

function extract(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return source.slice(start, end);
}

const settingsMethods = transformSync(`
class ShareImageSettingsHarness {
  ${extract(settingsSource, '  private selectTheme(', '\n  @Builder')}
  constructor() {
    this.theme = 'light';
    this.widthId = 'phone';
    this.closed = 0;
    this.confirmed = [];
    this.cancelled = 0;
    this.controller = { close: () => { this.closed++; } };
    // v1.42 宽度预设分段后 confirm 同时回传 (widthId, theme)
    this.onConfirm = (widthId, theme) => this.confirmed.push([widthId, theme]);
    this.onCancel = () => { this.cancelled++; };
  }
}
module.exports = ShareImageSettingsHarness;
`, { loader: 'ts', format: 'cjs' }).code;

const previewThemeMethods = transformSync(`
class PreviewThemeHarness {
  ${extract(previewSource, '  private effectiveTheme(): string {', '\n  aboutToAppear(): void {')}
  ${extract(previewSource, '  onThemeChanged(): void {', '\n  onEditableChanged(): void {')}
  constructor() {
    this.theme = 'light';
    this.themeOverride = '';
    this.applied = [];
    this.bridge = { setTheme: theme => this.applied.push(theme) };
  }
}
module.exports = PreviewThemeHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(code) {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  return new module.exports();
}

test('share image appearance defaults to light and can be changed before capture', () => {
  const dialog = createHarness(settingsMethods);
  assert.equal(dialog.theme, 'light');
  dialog.selectTheme('dark');
  dialog.selectTheme('unknown');
  dialog.confirm();
  assert.equal(dialog.theme, 'dark');
  assert.equal(dialog.confirmed.length, 1);
  assert.equal(dialog.confirmed[0][0], 'phone');
  assert.equal(dialog.confirmed[0][1], 'dark');
  assert.equal(dialog.closed, 1);
});

test('canceling appearance selection returns through its callback without generating an image', () => {
  const dialog = createHarness(settingsMethods);
  dialog.cancel();
  assert.equal(dialog.confirmed.length, 0);
  assert.equal(dialog.cancelled, 1);
  assert.equal(dialog.closed, 1);
});

test('explicit share theme overrides system theme while ordinary previews still follow it', () => {
  const preview = createHarness(previewThemeMethods);
  preview.theme = 'dark';
  preview.themeOverride = 'light';
  preview.onThemeChanged();
  assert.equal(preview.applied.at(-1), 'light');

  preview.themeOverride = 'dark';
  preview.onThemeOverrideChanged();
  assert.equal(preview.applied.at(-1), 'dark');

  preview.themeOverride = '';
  preview.onThemeChanged();
  assert.equal(preview.applied.at(-1), 'dark');
});

test('image settings feed the selected theme into the hidden capture preview', () => {
  assert.match(indexSource, /if \(format === 'image' && scope === 'note'\) \{\s*this\.openShareImageSettings\(vault\.id, path, itemName\);/);
  // v1.42 起长图设置并入统一预览弹窗：主题/宽度经 onGenerate 回调即时重新生成
  assert.match(indexSource,
    /onGenerate: async \(widthId: string, theme: string\): Promise<ShareImagePreviewImage> => \{\s*this\.shareCaptureWidthId = widthId;\s*this\.shareCaptureTheme = theme;/);
  assert.match(indexSource, /await this\.prepareNoteImageShare\(/);
  assert.match(indexSource,
    /onCancel: \(\): void => \{\s*this\.cancelShareImageCapture\(\);\s*this\.cleanupShareImagePreview\(\);\s*this\.openShareDialog\('note', notePath\);/);
  assert.match(indexSource, /initialTheme: this\.shareCaptureTheme/);
  assert.match(settingsSource, /Text\('图片外观'\)/);
  assert.match(settingsSource, /Text\('浅色'\)|'浅色'/);
  assert.match(settingsSource, /Text\('深色'\)|'深色'/);
  assert.match(settingsSource, /只影响本次生成的长图，不改变应用主题/);
});
