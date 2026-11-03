import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const previewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareImagePreviewDialog.ets', import.meta.url));

test('long-image detail receives final PixelMap dimensions, selected appearance, and budget state', () => {
  assert.match(indexSource, /aspectRatio: geometry\.width \/ geometry\.height,\s*width: geometry\.width,\s*height: geometry\.height,\s*theme: this\.shareCaptureTheme,\s*scaled: geometry\.scale < 1/);
  assert.match(previewSource, /1 张长图 · '\s*\+\s*this\.image\.width\.toString\(\)\s*\+\s*' × '\s*\+\s*this\.image\.height\.toString\(\)\s*\+\s*' px · '/);
  assert.match(previewSource, /this\.image\.theme === 'dark' \? '深色' : '浅色'/);
  assert.match(previewSource, /为满足图片预算，长图已整体缩小至 '\s*\+\s*this\.image\.width\.toString\(\)\s*\+\s*' px 宽/);
});

test('output dimensions come from the PixelMap geometry passed directly to JPEG encoding', () => {
  assert.match(indexSource, /const completedImage: image\.PixelMap = longImage;\s*longImage = null;\s*await NoteImageShareService\.writeJpeg\(filePath, completedImage\)/);
  assert.match(indexSource, /width: geometry\.width,\s*height: geometry\.height/);
});
