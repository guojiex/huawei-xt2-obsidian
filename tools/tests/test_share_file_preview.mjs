import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const dialogSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareFilePreviewDialog.ets', import.meta.url));

const shareMethodStart = dialogSource.indexOf('  private async share(): Promise<void> {');
const shareMethodEnd = dialogSource.indexOf('\n  @Builder', shareMethodStart);
assert.ok(shareMethodStart >= 0 && shareMethodEnd > shareMethodStart, 'could not find ShareFilePreviewDialog.share');
const retryMethodStart = dialogSource.indexOf('  private async retryPreparation(): Promise<void> {');
const retryMethodEnd = dialogSource.indexOf('\n  @Builder', retryMethodStart);
assert.ok(retryMethodStart >= 0 && retryMethodEnd > retryMethodStart,
  'could not find ShareFilePreviewDialog.retryPreparation');

const dialogHarnessCode = transformSync(`
class ShareFilePreviewHarness {
  ${dialogSource.slice(shareMethodStart, shareMethodEnd)}
  ${dialogSource.slice(retryMethodStart, retryMethodEnd)}
}
module.exports = ShareFilePreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;

const openPreviewStart = indexSource.indexOf('  private openShareFilePreview(');
const openPreviewEnd = indexSource.indexOf('\n  private async shareLink(', openPreviewStart);
assert.ok(openPreviewStart >= 0 && openPreviewEnd > openPreviewStart, 'could not find Index.openShareFilePreview');

const indexHarnessCode = transformSync(`
class IndexSharePreviewHarness {
  ${indexSource.slice(openPreviewStart, openPreviewEnd)}
}
module.exports = IndexSharePreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createDialogHarness() {
  const module = { exports: {} };
  vm.runInContext(dialogHarnessCode, vm.createContext({ module, exports: module.exports }));
  const app = new module.exports();
  app.sharing = false;
  app.preparing = false;
  app.errorMessage = '';
  return app;
}

function createIndexHarness() {
  const calls = [];
  const module = { exports: {} };
  const context = vm.createContext({
    module,
    exports: module.exports,
    DialogAlignment: { Bottom: 'bottom', Center: 'center' },
    ShareFilePreviewDialog: (props) => props,
    uniformTypeDescriptor: { UniformDataType: { FILE: 'file' } },
    CustomDialogController: class {
      constructor(options) {
        this.options = options;
        this.opened = false;
      }

      open() {
        this.opened = true;
      }
    }
  });
  vm.runInContext(indexHarnessCode, context);
  const app = new context.module.exports();
  app.windowWidthVp = 1000;
  app.windowHeightVp = 700;
  app.isSingleScreenLayout = () => false;
  app.openShareDialog = (scope, path) => calls.push(['back', scope, path]);
  app.shareFile = async (...args) => calls.push(['share', ...args]);
  return { app, calls };
}

test('file preview lists its entries and remains open with a retryable error after Share Kit rejection', async () => {
  assert.match(dialogSource, /ForEach\(this\.entries/);
  assert.match(dialogSource, /Text\(path\)/);
  assert.match(dialogSource, /Text\(this\.fileName\)/);

  const app = createDialogHarness();
  let closeCount = 0;
  app.controller = { close: () => { closeCount++; } };
  app.onConfirm = async () => { throw new Error('target unavailable'); };

  await app.share();

  assert.equal(app.errorMessage, 'target unavailable');
  assert.equal(app.sharing, false);
  assert.equal(closeCount, 0);
});

test('file preview back returns to the original range and confirm shares the prepared file', async () => {
  const { app, calls } = createIndexHarness();
  const registry = { id: 'registry' };
  app.openShareFilePreview('/share/notes.zip', 'notes.zip', 'ZIP', ['folder/note.md', 'assets/image.png'],
    '1 篇笔记 · 2 个文件', 'folder', '10_写作', registry);

  const preview = app.shareFilePreviewCtl.options.builder;
  assert.equal(preview.fileName, 'notes.zip');
  assert.equal(preview.format, 'ZIP');
  assert.deepEqual(JSON.parse(JSON.stringify(preview.entries)), ['folder/note.md', 'assets/image.png']);
  assert.equal(app.shareFilePreviewCtl.options.alignment, 'center');
  assert.equal(app.shareFilePreviewCtl.opened, true);

  preview.onBack();
  await preview.onConfirm();

  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [
    ['back', 'folder', '10_写作'],
    ['share', '/share/notes.zip', 'notes.zip', 'file', registry]
  ]);
});

test('file preparation failure is shown in the detail and retries preparation instead of sharing an empty file', async () => {
  const { app } = createIndexHarness();
  const registry = { id: 'registry' };
  let retries = 0;
  app.openShareFilePreview('', 'note.md', 'Markdown / ZIP', [], '文件准备失败', 'note', 'note.md', registry,
    '缺少本地图片', async () => { retries++; });

  const preview = app.shareFilePreviewCtl.options.builder;
  assert.equal(preview.canShare, false);
  assert.equal(preview.initialError, '缺少本地图片');
  await preview.onRetryPreparation();
  assert.equal(retries, 1);

  const dialog = createDialogHarness();
  dialog.preparing = false;
  dialog.errorMessage = '';
  dialog.onRetryPreparation = async () => { throw new Error('存储空间不足'); };
  await dialog.retryPreparation();
  assert.equal(dialog.errorMessage, '存储空间不足');
  assert.equal(dialog.preparing, false);
});

test('file detail uses its format icon block and the close action returns to format selection', () => {
  assert.match(dialogSource, /Icon\('doc', Space\.s5/);
  assert.match(dialogSource, /backgroundColor\(\$r\('app\.color\.brand_bg'\)\)/);
  assert.match(dialogSource, /accessibilityText\('关闭文件预览'\)[\s\S]*?\.onClick\(\(\) => \{ this\.back\(\); \}\)/);
});
