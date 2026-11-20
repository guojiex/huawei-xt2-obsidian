import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(fileURLToPath(new URL('../../', import.meta.url)));
const readRepoFile = (relPath) => fs.readFileSync(path.join(repoRoot, relPath), 'utf8');

const flow = readRepoFile('entry/src/main/ets/components/ShareFlowPanel.ets');
const device = readRepoFile('entry/src/main/ets/model/NotePdfEngineDevice.ets');
const service = readRepoFile('entry/src/main/ets/model/NotePdfEngineService.ets');
const previewFlow = readRepoFile('entry/src/main/ets/model/SharePdfPreviewFlow.ets');
const previewWebView = readRepoFile('entry/src/main/ets/components/PreviewWebView.ets');
const buildMjs = readRepoFile('web/mdpreview/build.mjs');
const dialog = readRepoFile('entry/src/main/ets/components/SharePdfPreviewDialog.ets');

// PDF 分支主体：从 prepareNotePdfShare 到下一个同缩进方法
const pdfShareBody = (() => {
  const start = flow.indexOf('private async prepareNotePdfShare');
  assert.ok(start > 0, 'prepareNotePdfShare 方法应存在');
  const end = flow.indexOf('\n  private ', start + 10);
  return flow.slice(start, end > 0 ? end : flow.length);
})();

// 长图分支主体：从 prepareNoteImageShare 到下一个同缩进方法
const imageShareBody = (() => {
  const start = flow.indexOf('private async prepareNoteImageShare');
  assert.ok(start > 0, 'prepareNoteImageShare 方法应存在');
  const end = flow.indexOf('\n  private ', start + 10);
  return flow.slice(start, end > 0 ? end : flow.length);
})();

test('v1.94：PDF 导出走 ArkWeb 官方引擎 createPdf（取代逐页截图合成）', () => {
  assert.match(device, /controller\.createPdf\(config\)/);
  assert.match(device, /data\.pdfArrayBuffer\(\)/);
  // 服务层负责编排与落盘
  assert.match(service, /exportFromWeb\(controller: webview\.WebviewController/);
  assert.match(flow, /NotePdfEngineService\.exportFromWeb\(controller, pdfPath\)/);
});

test('v1.94：PdfConfiguration 取 A4 纸型并开启背景打印', () => {
  assert.match(service, /A4_WIDTH_INCH: number = 8\.27/);
  assert.match(service, /A4_HEIGHT_INCH: number = 11\.69/);
  assert.match(device, /shouldPrintBackground: true/);
  assert.match(device, /scale: 1\.0/);
  // 四边页边距为 0
  assert.match(device, /marginTop: 0/);
  assert.match(device, /marginBottom: 0/);
  assert.match(device, /marginLeft: 0/);
  assert.match(device, /marginRight: 0/);
});

test('v1.94：PDF 分支不再调用自研分页与位图合成链路', () => {
  // 旧链路：preparePdfPages（自研分页）/ setShareCaptureScrollTop（逐页滚动）/
  // captureSegmentVerified（截图）/ exportFromPageImages（位图合成）
  assert.doesNotMatch(pdfShareBody, /preparePdfPages/);
  assert.doesNotMatch(pdfShareBody, /setShareCaptureScrollTop/);
  assert.doesNotMatch(pdfShareBody, /captureSegmentVerified/);
  assert.doesNotMatch(pdfShareBody, /exportFromPageImages/);
  assert.doesNotMatch(pdfShareBody, /pageJpegs/);
});

test('v1.94：长图路径仍走原有截图拼贴链路（官方引擎不覆盖长图）', () => {
  assert.match(imageShareBody, /captureSegmentVerified/);
  assert.match(imageShareBody, /setShareCaptureScrollTop/);
  assert.doesNotMatch(imageShareBody, /createPdf/);
  assert.doesNotMatch(imageShareBody, /exportFromWeb/);
});

test('v1.94：web 侧 print 媒体解除视口高度与滚动约束', () => {
  assert.match(buildMjs, /@media print/);
  // body 锁 height:100% + overflow:hidden 是视口应用布局，print 下必须解除，
  // 否则 Chromium 认为可视高度只有一屏，内容被截断成第一页
  assert.match(buildMjs, /html, body \{\s*height: auto; overflow: visible;/);
  assert.match(buildMjs, /#content \{\s*flex: none; height: auto; min-height: 0; overflow: visible;/);
});

test('v1.94：web 侧 print 媒体含印刷级分页控制规则', () => {
  assert.match(buildMjs, /break-after: avoid/);
  assert.match(buildMjs, /break-inside: avoid/);
  assert.match(buildMjs, /orphans: 2; widows: 2/);
});

test('v1.94：web 侧 print 媒体把水印从 fixed 徽标改回静态页脚', () => {
  // 视口态水印是 position:fixed 的末页徽标（53.13），print 下 fixed 会每页重复，
  // 必须显式改回 position:static + display:block
  assert.match(buildMjs, /#content \.share-watermark \{\s*position: static !important; display: block !important;/);
});

test('v1.94：预览缩略图来自真实 PDF 渲染（预览即产物）', () => {
  assert.match(device, /page\.getAreaPixelMap\(/);
  assert.match(service, /renderPreview\(pdfPath: string, outDir: string\)/);
  assert.match(flow, /NotePdfEngineService\.renderPreview\(pdfPath, sessionDir\)/);
  // 预览会话不再合成 PDF，只返回已生成的产物路径
  assert.match(previewFlow, /async composePdf\(\): Promise<string> \{/);
  assert.doesNotMatch(previewFlow, /exportFromPageImages/);
  assert.doesNotMatch(previewFlow, /NotePdfDocumentService/);
});

test('v1.94：PreviewWebView 交出 controller 句柄供官方引擎调用', () => {
  assert.match(previewWebView, /onControllerReady: \(controller: webview\.WebviewController\)/);
  assert.match(previewWebView, /this\.onControllerReady\(this\.controller\)/);
  assert.match(flow, /onControllerReady: \(controller: webview\.WebviewController\)/);
  assert.match(flow, /this\.shareCaptureController = controller/);
});

test('v1.94：预览弹窗规格标签改为印刷级分页', () => {
  assert.match(dialog, /SpecChip\('印刷级分页'\)/);
  assert.doesNotMatch(dialog, /SpecChip\('按段落分页'\)/);
});
