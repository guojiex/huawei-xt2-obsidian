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
const userErrorSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/UserErrorMessages.ets', import.meta.url));
const userErrorCode = transformSync(`
${userErrorSource.replace(/^export /gm, '')}
module.exports = { shareFailureMessage };
`, { loader: 'ts', format: 'cjs' }).code;
const userErrorModule = { exports: {} };
new Function('module', 'exports', userErrorCode)(userErrorModule, userErrorModule.exports);
const { shareFailureMessage } = userErrorModule.exports;

function extract(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return source.slice(start, end);
}

// 25.19 重构：retry/onRetry 改为 generatePreview/onGenerate（宽度、外观可切换后重生成），
// 分享交接不变（onConfirm → share）。harness 抽 generatePreview + share 两个方法。
const previewMethods = transformSync(`
type HarnessPreviewImage = {
  uri: string; aspectRatio: number; width: number; height: number;
  theme: string; scaled: boolean; widthId: string;
};
class ShareImagePreviewHarness {
  sharing: boolean = false;
  preparing: boolean = false;
  errorMessage: string = '';
  selectedWidthId: string = 'phone';
  selectedTheme: string = 'light';
  settingsChanged: boolean = false;
  previewImage: HarnessPreviewImage =
    { uri: '', aspectRatio: 1, width: 0, height: 0, theme: 'light', scaled: false, widthId: 'phone' };
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  onGenerate: (widthId: string, theme: string) => Promise<HarnessPreviewImage> =
    async (_widthId: string, _theme: string): Promise<HarnessPreviewImage> => {
      throw new Error('长图预览生成未连接');
    };
  ${extract(previewSource, '  private async generatePreview(): Promise<void> {', '\n  @Builder')}
}
module.exports = ShareImagePreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createPreviewHarness() {
  const module = { exports: {} };
  vm.runInContext(previewMethods, vm.createContext({
    module, exports: module.exports, shareFailureMessage
  }));
  return new module.exports();
}

test('long-image detail receives final PixelMap dimensions, selected appearance, and budget state', () => {
  assert.match(indexSource, /aspectRatio: geometry\.width \/ geometry\.height,\s*width: geometry\.width,\s*height: geometry\.height,\s*theme: this\.shareCaptureTheme,\s*scaled: geometry\.scale < 1/);
  assert.match(previewSource, /Text\('1 张长图'\)/);
  assert.match(previewSource, /this\.previewImage\.width\.toString\(\) \+ ' × ' \+ this\.previewImage\.height\.toString\(\) \+ ' px'/);
  assert.match(previewSource, /this\.previewImage\.theme === 'dark' \? '深色' : '浅色'/);
  assert.match(previewSource, /为满足图片预算，长图已整体缩小至 ' \+ this\.previewImage\.width\.toString\(\) \+ ' px 宽/);
  assert.match(previewSource, /Text\('宽度'\)/);
  assert.match(previewSource, /Text\('外观'\)/);
  assert.match(previewSource, /改用 Markdown \/ ZIP/);
  assert.match(previewSource, /headerIcon: 'image'/);
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

  assert.equal(dialog.errorMessage,
    '系统分享交接未完成；接收端状态未知。原因未确定，请重试或选择其他格式。');
  assert.equal(dialog.sharing, false);
});

test('failed long-image generation keeps its detail error and offers an alternative format', async () => {
  const dialog = createPreviewHarness();
  dialog.onGenerate = async () => { throw new Error('本地图片缺失'); };

  await dialog.generatePreview();

  assert.equal(dialog.errorMessage,
    '长图准备失败；原笔记未修改。原因未确定，请重试或改用 Markdown / ZIP。');
  assert.equal(dialog.preparing, false);
  assert.match(indexSource, /onGenerate: async \(widthId: string, theme: string\): Promise<ShareImagePreviewImage> => \{/);
  assert.match(indexSource, /const preview: ShareImagePreviewImage = await this\.prepareNoteImageShare\(/);
});

test('cancelled long-image generation surfaces no error', async () => {
  const dialog = createPreviewHarness();
  dialog.onGenerate = async () => { throw new Error('分享图片生成已取消'); };

  await dialog.generatePreview();

  assert.equal(dialog.errorMessage, '');
  assert.equal(dialog.preparing, false);
});

// 2026-11-08 修复回归：长图分享主按钮一直显示「正在排版…」——UtilityDialogAction 的
// label 是按值 string，全局 @Builder 多参按值传参不触发动态渲染（官方 arkts-builder
// 限制 3，同 EM-B2 的 enabled），首帧固化后不再随 preparing/sharing/errorMessage 刷新。
// 修复后 label 必须整体包在 UIUtils.makeBinding<string> 里。
test('primary action label is a makeBinding<string> callback so it leaves 正在排版 behind', () => {
  assert.match(previewSource, new RegExp(
    'UtilityDialogAction\\(\\s*' +
    'UIUtils\\.makeBinding<string>\\(\\(\\) =>\\s*' +
    'this\\.canSharePreview\\(\\) \\? \\(this\\.sharing \\? \'正在打开…\' : \'分享图片\'\\) :\\s*' +
    '\\(this\\.preparing \\? \'正在排版…\' : this\\.errorMessage\\.length > 0 \\? \'重试生成\' : \'生成预览\'\\)\\)',
    's'));
});
