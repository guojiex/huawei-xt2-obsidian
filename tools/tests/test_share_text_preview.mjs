import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const dialogSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareTextPreviewDialog.ets', import.meta.url));
const userErrorSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/UserErrorMessages.ets', import.meta.url));
const userErrorCode = transformSync(`
${userErrorSource.replace(/^export /gm, '')}
module.exports = { shareFailureMessage };
`, { loader: 'ts', format: 'cjs' }).code;
const userErrorModule = { exports: {} };
new Function('module', 'exports', userErrorCode)(userErrorModule, userErrorModule.exports);
const { shareFailureMessage } = userErrorModule.exports;

function extract(startMarker, endMarker) {
  const start = dialogSource.indexOf(startMarker);
  const end = dialogSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return dialogSource.slice(start, end);
}

// 2026-11-08 修复：25.19 分享面板重构在 retryPreparation 与 build() 之间插入了
// @Builder DialogContent / DialogFooter（ArkUI DSL，esbuild 解析不了 `Column({ … }) {`），
// 旧抽取区间 `retryPreparation → build()` 整文件炸在 transform。收窄到 `retryPreparation
// → @Builder`，harness 只抽纯 TS 方法。
const methods = transformSync(`
class ShareTextPreviewHarness {
  ${extract('  private async confirm(): Promise<void> {', '\n  private async retryPreparation()')}
  ${extract('  private async retryPreparation(): Promise<void> {', '\n  @Builder')}
}
module.exports = ShareTextPreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const module = { exports: {} };
  vm.runInContext(methods, vm.createContext({
    module, exports: module.exports, shareFailureMessage
  }));
  const dialog = new module.exports();
  dialog.sharing = false;
  dialog.preparing = false;
  dialog.errorMessage = '';
  dialog.contentDraft = 'share text';
  return dialog;
}

test('text Share Kit failure stays in the detail and leaves the text available for retry', async () => {
  const dialog = createHarness();
  dialog.onConfirm = async (content) => {
    assert.equal(content, 'share text');
    throw new Error('target unavailable');
  };

  await dialog.confirm();

  assert.equal(dialog.errorMessage, 'target unavailable');
  assert.equal(dialog.sharing, false);
});

test('text preparation failure can retry and replace the error detail', async () => {
  const dialog = createHarness();
  let retries = 0;
  dialog.onRetryPreparation = async () => { retries++; };

  await dialog.retryPreparation();

  assert.equal(retries, 1);
  assert.equal(dialog.errorMessage, '');
  assert.equal(dialog.preparing, false);
  assert.match(indexSource, /initialError: initialError,\s*onRetryPreparation: onRetryPreparation/);
  assert.match(indexSource, /onConfirm: \(content: string\): Promise<void> => \{ return this\.shareTextContent/);
});

test('text detail uses the shared utility shell on single-screen layouts', () => {
  // 25.19 起文本预览走 UtilityDialogShell（外壳限高 / 限宽由 shell 统一处理）
  assert.match(dialogSource, /UtilityDialogShell\(\{/);
  assert.match(dialogSource, /preferredWidthVp: Size\.shareW/);
  assert.match(dialogSource, /windowWidthVp: this\.windowWidthVp/);
  assert.match(dialogSource, /windowHeightVp: this\.windowHeightVp/);
  assert.match(indexSource, /alignment: shareSheet \? DialogAlignment\.Bottom : DialogAlignment\.Center/);
});

test('text detail uses its format icon block and the close action returns to format selection', () => {
  assert.match(dialogSource, /headerIcon: 'message'/);
  assert.match(dialogSource, /closeLabel: '关闭文本预览'/);
  assert.match(dialogSource, /title: '文本分享'/);
});
