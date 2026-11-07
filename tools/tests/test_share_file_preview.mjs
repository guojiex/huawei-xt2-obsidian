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
const userErrorSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/UserErrorMessages.ets', import.meta.url));
const userErrorCode = transformSync(`
${userErrorSource.replace(/^export /gm, '')}
module.exports = { shareFailureMessage };
`, { loader: 'ts', format: 'cjs' }).code;
const userErrorModule = { exports: {} };
new Function('module', 'exports', userErrorCode)(userErrorModule, userErrorModule.exports);
const { shareFailureMessage } = userErrorModule.exports;

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
  vm.runInContext(dialogHarnessCode, vm.createContext({
    module, exports: module.exports, shareFailureMessage
  }));
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

  assert.equal(app.errorMessage,
    '系统分享交接未完成；接收端状态未知。原因未确定，请重试或选择其他格式。');
  assert.equal(app.sharing, false);
  assert.equal(closeCount, 0);
});

test('file preview back returns to the original range and confirm shares the prepared file', async () => {
  const { app, calls } = createIndexHarness();
  const registry = { id: 'registry' };
  app.openShareFilePreview('/share/notes.zip', 'notes.zip', 'ZIP', ['folder/note.md', 'assets/image.png'],
    '10_写作', 3, 2, 'folder', '10_写作', registry);

  const preview = app.shareFilePreviewCtl.options.builder;
  assert.equal(preview.fileName, 'notes.zip');
  assert.equal(preview.format, 'ZIP');
  assert.equal(preview.itemName, '10_写作');
  assert.equal(preview.noteCount, 3);
  assert.equal(preview.imageCount, 2);
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
  app.openShareFilePreview('', '笔记标题', 'Markdown / ZIP', [], '笔记标题', 0, 0, 'note', 'note.md', registry,
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
  assert.equal(dialog.errorMessage,
    '文件准备失败；知识库未修改。原因未确定，请检查访问状态和本地空间后重试。');
  assert.equal(dialog.preparing, false);
});

// 分享面板设计 §2/§4：文件详情＝「ZIP 分享 / Markdown 分享」标题 + 文件名 +
// 带图标清单 + 数量信息；外壳同导入库（UtilityDialogShell），底部＝返回 · 分享文件。
test('file detail follows the share panel design: shell, stage, list card, meta, and actions', () => {
  // 外壳与头部
  assert.match(dialogSource, /UtilityDialogShell\(\{/);
  assert.match(dialogSource, /title: this\.detailTitle\(\)/);
  assert.match(dialogSource, /return this\.format === 'ZIP' \? 'ZIP 分享' : 'Markdown 分享';/);
  assert.match(dialogSource, /headerIcon: 'doc'/);
  assert.match(dialogSource, /closeLabel: '关闭文件预览'/);
  assert.match(dialogSource, /preferredWidthVp: Size\.shareW/);
  // 摘要行：名称 · N 篇笔记 · M 张本地配图
  assert.match(dialogSource, /this\.itemName \+ ' · ' \+ this\.noteCount\.toString\(\) \+ ' 篇笔记'/);
  assert.match(dialogSource, /this\.imageCount\.toString\(\) \+ ' 张本地配图'/);
  // 预览台面（#sharePreview）：--nav 底、--small-r 圆角、--s4 内边距
  assert.match(dialogSource, /\.padding\(Space\.s4\)/);
  assert.match(dialogSource, /\.borderRadius\(Radius\.control\)/);
  assert.match(dialogSource, /\.backgroundColor\(\$r\('app\.color\.bg_secondary'\)\)/);
  // 文件清单（.share-files）：--line 描边卡片、--r 圆角、--s2 内边距、行高 --s10、最高 --window-min 一半
  assert.match(dialogSource, /constraintSize\(\{ maxHeight: Size\.menuMaxH \* 0\.5 \}\)/);
  assert.match(dialogSource, /\.padding\(Space\.s2\)/);
  assert.match(dialogSource, /\.border\(\{ width: 1, color: \$r\('app\.color\.line'\) \}\)/);
  assert.match(dialogSource, /\.borderRadius\(Radius\.menu\)/);
  assert.match(dialogSource, /constraintSize\(\{ minHeight: Space\.s10 \}\)/);
  // 数量信息（#shareMeta）：首段 1 个 ZIP / 1 个 Markdown 文件
  assert.match(dialogSource, /return this\.format === 'ZIP' \? '1 个 ZIP' : '1 个 Markdown 文件';/);
  assert.match(dialogSource, /this\.noteCount\.toString\(\) \+ ' 篇笔记'/);
  assert.match(dialogSource, /this\.imageCount\.toString\(\) \+ ' 张图片'/);
  // 底部操作：返回 · 分享文件（失败时重试生成），胶囊样式走 UtilityDialogAction
  assert.match(dialogSource, /'返回', 'secondary', this\.singleScreen/);
  assert.match(dialogSource, /this\.sharing \? '正在打开…' : '分享文件', 'primary'/);
  assert.match(dialogSource, /this\.preparing \? '正在重试…' : '重试生成', 'primary'/);
});
