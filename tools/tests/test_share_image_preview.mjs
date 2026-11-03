import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const previewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareImagePreviewDialog.ets', import.meta.url));

function extract(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return source.slice(start, end);
}

const previewMethods = transformSync(`
class ShareImagePreviewHarness {
  ${extract(previewSource, '  private async retry(): Promise<void> {', '\n  private async share()')}
  ${extract(previewSource, '  private async share(): Promise<void> {', '\n  build()')}
}
module.exports = ShareImagePreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createPreviewHarness() {
  const module = { exports: {} };
  vm.runInContext(previewMethods, vm.createContext({ module, exports: module.exports }));
  const dialog = new module.exports();
  dialog.sharing = false;
  dialog.retrying = false;
  dialog.errorMessage = '';
  return dialog;
}

test('long-image detail receives final PixelMap dimensions, selected appearance, and budget state', () => {
  assert.match(indexSource, /aspectRatio: geometry\.width \/ geometry\.height,\s*width: geometry\.width,\s*height: geometry\.height,\s*theme: this\.shareCaptureTheme,\s*scaled: geometry\.scale < 1/);
  assert.match(previewSource, /1 张长图 · '\s*\+\s*this\.image\.width\.toString\(\)\s*\+\s*' × '\s*\+\s*this\.image\.height\.toString\(\)\s*\+\s*' px · '/);
  assert.match(previewSource, /this\.image\.theme === 'dark' \? '深色' : '浅色'/);
  assert.match(previewSource, /为满足图片预算，长图已整体缩小至 '\s*\+\s*this\.image\.width\.toString\(\)\s*\+\s*' px 宽/);
  assert.match(previewSource, /图片宽度 · 跟随当前栏/);
  assert.match(previewSource, /图片外观 · '/);
  assert.match(previewSource, /改用 Markdown \/ ZIP/);
  assert.match(previewSource, /Icon\('image'/);
  assert.match(previewSource, /关闭长图预览/);
});

test('output dimensions come from the PixelMap geometry passed directly to JPEG encoding', () => {
  assert.match(indexSource, /const completedImage: image\.PixelMap = longImage;\s*longImage = null;\s*await NoteImageShareService\.writeJpeg\(filePath, completedImage\)/);
  assert.match(indexSource, /width: geometry\.width,\s*height: geometry\.height/);
});

test('Share Kit rejection remains visible in the long-image detail and can be retried', async () => {
  const dialog = createPreviewHarness();
  dialog.onConfirm = async () => { throw new Error('target unavailable'); };

  await dialog.share();

  assert.equal(dialog.errorMessage, 'target unavailable');
  assert.equal(dialog.sharing, false);

  let retries = 0;
  dialog.onRetry = async () => { retries++; };
  await dialog.retry();
  assert.equal(retries, 1);
  assert.equal(dialog.errorMessage, '');
  assert.equal(dialog.retrying, false);
});

test('failed long-image generation keeps its detail error and offers an alternative format', async () => {
  const dialog = createPreviewHarness();
  dialog.onRetry = async () => { throw new Error('本地图片缺失'); };

  await dialog.retry();

  assert.equal(dialog.errorMessage, '本地图片缺失');
  assert.equal(dialog.retrying, false);
  assert.match(indexSource, /onRetry: \(\): Promise<void> => \{\s*return this\.prepareNoteImageShare/);
});
