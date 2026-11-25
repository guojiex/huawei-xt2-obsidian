import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// v1.94 收口后的 PDF 分享防线（2026-11-25）：旧位图链路（pdfPagination.mjs 自研分页 /
// preparePdfPages 协议 / NotePdfDocumentService + NotePdfExportDevice 位图合成）已随
// 验收通过删除，本文件只锁仍存活的官方引擎接线、捕获层、预览弹窗、长图共用链路
// 与权限红线。旧链路的防线由 test_pdf_engine.mjs 的 doesNotMatch 断言接管。

const repoRoot = path.resolve(fileURLToPath(new URL('../../', import.meta.url)));
const readRepoFile = (relPath) => fs.readFileSync(path.join(repoRoot, relPath), 'utf8');

test('源级：ShareFlowPanel 含 PDF 路由、捕获层 PDF 模式与分享面板 PDF 行', () => {
  const index = readRepoFile('entry/src/main/ets/components/ShareFlowPanel.ets');
  assert.match(index, /format === 'pdf' && scope === 'note'/);
  assert.match(index, /prepareNotePdfShare\(/);
  assert.match(index, /shareCapturePdfMode/);
  assert.match(index, /value: 'pdf', label: 'PDF 文档'/);
  assert.match(index, /NotePdfEngineService\.isSupported\(\)/);
  assert.match(index, /uniformTypeDescriptor\.UniformDataType\.PDF/);
  // 写 JPEG 是长图路径的职责（v1.94：PDF 位图路线已下线，改走官方引擎）
  const imageService = readRepoFile('entry/src/main/ets/model/NoteImageShareService.ets');
  assert.match(imageService, /writeJpegTo/);
  assert.doesNotMatch(index, /writeJpegTo/, 'PDF 位图路线已下线，ShareFlowPanel 不应再写 JPEG');
});

test('源级：v1.94 PDF 捕获层视口尺寸 + 官方引擎不依赖捕获视口（94.2~94.3）', () => {
  const index = readRepoFile('entry/src/main/ets/components/ShareFlowPanel.ets');
  // 目标尺寸常量：固定 700vp（A4 竖版），页高按 700×842/595≈990.59 取整
  assert.match(index, /const PDF_TARGET_PAGE_WIDTH_VP: number = 700;/);
  assert.match(index, /const PDF_TARGET_PAGE_HEIGHT_VP: number = Math\.round\(/);
  // 尺寸字段仍是 @State（改尺寸要触发 build 重跑，PreviewWebView 才会真正 resize）
  assert.match(index, /@State pdfPageWidthVp: number = PDF_TARGET_PAGE_WIDTH_VP;/);
  assert.match(index, /@State pdfPageHeightVp: number = PDF_TARGET_PAGE_HEIGHT_VP;/);
  assert.doesNotMatch(index, /private pdfPageWidthVp/, '捕获页尺寸不得再是普通字段（改值不触发重排）');
  assert.doesNotMatch(index, /private pdfPageHeightVp/, '捕获页尺寸不得再是普通字段（改值不触发重排）');
  // 挂捕获层前先应用目标尺寸
  assert.match(index, /this\.applyPdfPageSize\(PDF_TARGET_PAGE_WIDTH_VP, PDF_TARGET_PAGE_HEIGHT_VP\);\s*\n\s*this\.shareCapturePdfMode = true;/);
  // v1.94：纸宽由 PdfConfiguration 决定（Chromium 按纸宽重排），捕获层尺寸只影响屏幕渲染视口，
  // 故 v1.93 的「视口比对 + 自动降级」机制随自研分页一并下线
  assert.doesNotMatch(index, /private pdfViewportMatches\(/);
  assert.doesNotMatch(index, /private adaptivePdfPageSize\(/);
  assert.doesNotMatch(index, /private async tryPreparePdfPages\(/);
  assert.doesNotMatch(index, /private async preparePdfPagesAfterResize\(/);
  // 捕获层：PDF 模式用页尺寸（而非窗口尺寸）且不裁剪
  assert.match(index, /\.width\(this\.shareCapturePdfMode \? this\.pdfPageWidthVp : '100%'\)/);
  assert.match(index, /\.height\(this\.shareCapturePdfMode \? this\.pdfPageHeightVp : '100%'\)/);
  assert.match(index, /\.clip\(false\)/);
});

test('红线：module.json5 零新增权限（硬约束 13；打印框架路线已否决）', () => {
  const moduleJson = readRepoFile('entry/src/main/module.json5');
  assert.equal(moduleJson.includes('ohos.permission.PRINT'), false);
  const permissionsBlock = moduleJson.match(/"requestPermissions"\s*:\s*\[([\s\S]*?)\]/);
  assert.ok(permissionsBlock, 'module.json5 缺 requestPermissions 块');
  const allowed = new Set(['ohos.permission.INTERNET', 'ohos.permission.FILE_ACCESS_PERSIST']);
  const declared = [...permissionsBlock[1].matchAll(/"name"\s*:\s*"(ohos\.permission\.[A-Z_]+)"/g)]
    .map((match) => match[1]);
  assert.ok(declared.length > 0, 'requestPermissions 未解析到任何权限声明');
  for (const name of declared) {
    assert.ok(allowed.has(name), `requestPermissions 出现例外之外的权限：${name}`);
  }
});

// ---------- 53.7 分页预览弹窗（对齐 v2 原型 previewPdfShare） ----------

test('源级：SharePdfPreviewDialog 规格胶囊 / 缩略图 / 分享按钮（53.7）', () => {
  const dialog = readRepoFile('entry/src/main/ets/components/SharePdfPreviewDialog.ets');
  assert.match(dialog, /export struct SharePdfPreviewDialog/);
  // 原型 pdf-specs 四枚胶囊（v1.94：「按段落分页」改为「印刷级分页」——官方引擎走
  // Chromium print 管线的 CSS Fragmentation，不再是自研块级贪心分页）
  for (const chip of ['A4 竖版', '浅色纸面', '印刷级分页', '末页水印']) {
    assert.ok(dialog.includes(`this.SpecChip('${chip}')`), `缺少规格胶囊「${chip}」`);
  }
  // 原型 shareMeta：1 个 PDF + 文件名 + N 页
  assert.match(dialog, /'1 个 PDF'/);
  assert.match(dialog, /this\.pageUris\.length\.toString\(\) \+ ' 页'/);
  // 缩略图：逐页 Image + 「N / M」页码 + 第 N 页共 M 页读屏
  // v1.94：缩略图由 PDF Kit 从真实 PDF 页渲染，恒 A4 比例（595/842），
  // 不再有 53.12 的逐页宽高比数据
  assert.match(dialog, /aspectRatio\(595 \/ 842\)/);
  assert.match(dialog, /\$r\('app\.color\.bg_paper'\)/);
  assert.doesNotMatch(dialog, /pageAspects/, '官方引擎产物恒 A4，弹窗不得残留逐页宽高比数据');
  assert.match(dialog, /Size\.pdfThumbW/);
  assert.match(dialog, /' \/ ' \+ this\.pageUris\.length\.toString\(\)/);
  assert.match(dialog, /'第 ' \+ \(index \+ 1\)\.toString\(\) \+ ' 页，共 '/);
  assert.match(dialog, /ForEach\(this\.pageUris/);
  // 主按钮「分享 PDF」与返回
  assert.match(dialog, /'分享 PDF'/);
  assert.match(dialog, /'正在生成…'/);
  // 颜色 / 圆角 / 间距 / 字号只走 token 与主题资源（硬约束 17）
  assert.equal(/#[0-9a-fA-F]{3,8}/.test(dialog), false, '组件内不得散写十六进制颜色');
  assert.equal(/Color\.(?!Transparent)[A-Z]/.test(dialog), false, '组件内不得散写 Color 枚举');
});

test('源级：PDF 预览会话在 SharePdfPreviewFlow，弹窗控制器在 ShareFlowPanel struct（53.7 拆分 + 2026-11-18 XT2 无响应根因修复）', () => {
  const index = readRepoFile('entry/src/main/ets/components/ShareFlowPanel.ets');
  const flow = readRepoFile('entry/src/main/ets/model/SharePdfPreviewFlow.ets');
  // Panel：导入流程类与弹窗组件并持有实例 + struct 成员控制器
  assert.match(index, /import \{ SharePdfPreviewFlow, SharePdfPreviewRequest \} from '\.\.\/model\/SharePdfPreviewFlow';/);
  assert.match(index, /import \{ SharePdfPreviewDialog \} from '\.\/SharePdfPreviewDialog';/);
  assert.match(index, /private sharePdfPreviewFlow: SharePdfPreviewFlow = new SharePdfPreviewFlow\(\);/);
  // 官方约束：CustomDialogController 仅作为 @Component struct 成员、struct 内赋值才有效；
  // 普通类里 new 出来的 open() 静默不显示（XT2 真机 PDF 分享无响应根因，2026-11-18）
  assert.match(index, /private sharePdfPreviewCtl: CustomDialogController \| null = null;/);
  assert.doesNotMatch(flow, /new CustomDialogController/, '普通类不得创建/持有弹窗控制器');
  assert.doesNotMatch(flow, /SharePdfPreviewDialog/, '普通类不得组装弹窗 builder');
  // 捕获完成后进预览弹窗，捕获层卸下；导出不再内联在 prepareNotePdfShare
  // v1.94：签名改为传预览缩略图与已生成的 PDF 产物路径（官方引擎路线）
  assert.match(index, /this\.openSharePdfPreview\(itemName, notePath, sessionId, previewImages, pdfPath, vaultId\);/);
  const prepare = index.slice(index.indexOf('private async prepareNotePdfShare'),
    index.indexOf('private pdfFileNameOf'));
  assert.ok(prepare.length > 0, 'prepareNotePdfShare 区间未定位');
  assert.doesNotMatch(prepare, /exportFromPageImages/, 'prepareNotePdfShare 不得内联合成 PDF（53.7 改预览后确认）');
  assert.doesNotMatch(prepare, /openShareFilePreview\(/, 'prepareNotePdfShare 不得直接进文件预览');
  // Flow：会话记录 / 清理，无弹窗逻辑；官方引擎产物恒 A4，不再携带逐页宽高比
  assert.match(flow, /export class SharePdfPreviewFlow/);
  assert.match(flow, /export class SharePdfPreviewRequest/);
  assert.doesNotMatch(flow, /pageAspects/, '官方引擎产物恒 A4，会话不得残留逐页宽高比数据');
  // v1.94：官方引擎路线下 PDF 在预览前已生成，flow 不再合成，只返回已有产物路径
  assert.match(flow, /pdfPath: string = '';/);
  assert.match(flow, /async composePdf\(\): Promise<string> \{/);
  assert.doesNotMatch(flow, /exportFromPageImages/);
  // Panel onConfirm：返回产物 → 关闭 → 进文件预览；onCancel：清理 → 回分享面板
  assert.match(index, /const pdfPath: string = await this\.sharePdfPreviewFlow\.composePdf\(\);/);
  assert.match(index, /this\.sharePdfPreviewCtl\?\.close\(\);\s*\n\s*request\.onComposed\(pdfPath\);/);
  assert.match(index, /this\.sharePdfPreviewFlow\.cleanup\(\);\s*\n\s*request\.onCancelled\(\);/);
  assert.match(index, /this\.sharePdfPreviewCtl\.open\(\);/);
  // 返回：清理会话回到分享面板（removeTree + 失败告警）
  assert.match(flow, /NoteShareService\.removeTree\(VaultRegistry\.get\(\), sessionId\);\s*\n\s*\} catch \(error\) \{\s*\n\s*hilog\.warn\(DOMAIN, TAG, 'PDF 分页预览临时文件清理失败'\);/);
  // Panel 接线：合成完成进文件预览（精确 utd PDF）、取消回分享面板
  assert.match(index, /onComposed: \(composedPath: string\): void => \{\s*\n\s*this\.openShareFilePreview\(composedPath, this\.pdfFileNameOf\(itemName\), 'PDF', \[\]/);
  assert.match(index, /uniformTypeDescriptor\.UniformDataType\.PDF\);/);
  assert.match(index, /onCancelled: \(\): void => \{\s*\n\s*this\.openShareDialog\('note', notePath\);/);
  // 缩略图 URI 走 fileUri.getUriFromPath（v1.94：源为 PDF Kit 渲染的预览缩略图）
  assert.match(flow, /pageUris\.push\(fileUri\.getUriFromPath\(request\.previewImages\[i\]\)\);/);
});

// ---------- 53.10 分段快照旧帧校验（XT2「一页渲染两页且重复」修复） ----------

test('源级：ShareFlowPanel 分段快照带旧帧校验与重试（53.10）', () => {
  const index = readRepoFile('entry/src/main/ets/components/ShareFlowPanel.ets');
  // 逐字节比较 + readPixelsToBuffer 读帧 + 有界重试 + 明确报错
  assert.match(index, /private segmentBuffersIdentical\(a: ArrayBuffer, b: ArrayBuffer\): boolean/);
  assert.match(index, /await snapshot\.readPixelsToBuffer\(buffer\);/);
  assert.match(index, /private async captureSegmentVerified\(prevBuffer: ArrayBuffer \| null,\s*snapshotScale: number\)/);
  assert.match(index, /throw new Error\('分享预览渲染未更新，请重试'\);/);
  // 重试有界（4 次）且等待 180ms 后重拍
  assert.match(index, /const maxAttempts: number = 4;/);
  assert.match(index, /\}, 180\);/);
  // v1.92：scale 必须透传进 get 的 options（PDF 位图路线下线后仅长图使用，固定 1.0）
  assert.match(index, /scale: snapshotScale/);
  assert.doesNotMatch(index, /const PDF_SNAPSHOT_SCALE/,
    'PDF 位图路线已下线，不得残留 PDF 快照 scale 常量');
  // 长图与 PDF 两循环都走校验快照，不再直连 getComponentSnapshot
  const imageLoop = index.slice(index.indexOf('private async prepareNoteImageShare'),
    index.indexOf('private applyPdfPageSize'));
  assert.ok(imageLoop.length > 0, 'prepareNoteImageShare 区间未定位');
  // 长图固定 1.0：longImageGeometry 依赖原始截图尺寸推算 96MiB 预算，降 scale 会破坏长图几何
  assert.match(imageLoop, /await this\.captureSegmentVerified\(prevSegmentBuffer, 1\.0\)/);
  assert.doesNotMatch(imageLoop, /getComponentSnapshot\(\)/, '长图循环不得绕过旧帧校验直连快照');
  // v1.94：PDF 路径改走 ArkWeb 官方引擎，不再有逐页截图循环
  const pdfLoop = index.slice(index.indexOf('private async prepareNotePdfShare'),
    index.indexOf('private pdfFileNameOf'));
  assert.ok(pdfLoop.length > 0, 'prepareNotePdfShare 区间未定位');
  assert.doesNotMatch(pdfLoop, /captureSegmentVerified/, 'PDF 路径不得再走逐页截图');
  assert.doesNotMatch(pdfLoop, /getComponentSnapshot\(\)/, 'PDF 路径不得绕过旧帧校验直连快照');
  assert.match(pdfLoop, /NotePdfEngineService\.exportFromWeb\(controller, pdfPath\)/);
});

test('源级：web setShareCaptureScrollTop 滚动后给渲染服务留合成时间（53.10，P2 已回退）', () => {
  const indexTs = readRepoFile('web/mdpreview/src/index.ts');
  const scrollFn = indexTs.slice(indexTs.indexOf('async setShareCaptureScrollTop'),
    indexTs.indexOf('window.__mdpreview = api'));
  assert.ok(scrollFn.length > 0, 'setShareCaptureScrollTop 区间未定位');
  // 双 rAF 之后仍有 64ms 沉淀，避免组件快照取到滚动前旧表面。
  // v1.91 P2 曾删除此等待，真机复测旧帧重试率 0.8%→87%、墙钟 15.5s→43.4s，净亏已回退（2026-11-20）。
  // 数据与结论见 docs/engineering/分享预览渲染性能优化.md §3.3 / §4 P2。
  assert.match(scrollFn, /await nextRenderedFrame\(\)/);
  assert.match(scrollFn, /\}, 64\)/, '64ms 合成等待必须保留（P2 回退后恢复）');
});

test('红线：旧 PDF 位图链路源码与产物均已删除（2026-11-25 随 v1.94 验收收口清理）', () => {
  // 旧链路整链删除：自研分页纯函数 / preparePdfPages 协议 / 位图合成服务。
  // 需要旧实现时查 Git 历史（v1.94 收口前的提交）。
  assert.equal(fs.existsSync(path.join(repoRoot, 'web/mdpreview/src/pdfPagination.mjs')), false,
    'pdfPagination.mjs 应已删除');
  assert.equal(fs.existsSync(path.join(repoRoot, 'entry/src/main/ets/model/NotePdfDocumentService.ets')), false,
    'NotePdfDocumentService.ets 应已删除');
  assert.equal(fs.existsSync(path.join(repoRoot, 'entry/src/main/ets/model/NotePdfExportDevice.ets')), false,
    'NotePdfExportDevice.ets 应已删除');
  const indexTs = readRepoFile('web/mdpreview/src/index.ts');
  assert.doesNotMatch(indexTs, /preparePdfPages|pdfWatermarkBadge|sendPdfPagesResult/);
  const bundle = readRepoFile('entry/src/main/resources/rawfile/mdpreview/index.html');
  assert.doesNotMatch(bundle, /preparePdfPages/, 'rawfile 产物不得残留旧分页协议，请重跑 web/mdpreview 的 node build.mjs');
});
