import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(fileURLToPath(new URL('../../', import.meta.url)));
const readRepoFile = (relPath) => fs.readFileSync(path.join(repoRoot, relPath), 'utf8');

// v1.53 53.2：pdfPagination.mjs 是纯 ESM，直接 import（无 ArkTS / DOM 依赖）。
const paginationModule = await import(new URL('../../web/mdpreview/src/pdfPagination.mjs', import.meta.url));
const { computePdfPageTops, pdfBottomPadding, MAX_PDF_PAGES } = paginationModule;

test('MAX_PDF_PAGES 常量为 100（需求 53.1 页数上限）', () => {
  assert.equal(MAX_PDF_PAGES, 100);
});

test('空块数组与单页内容都只产生一页，从 0 开始', () => {
  assert.deepEqual(computePdfPageTops([], 990), [0]);
  assert.deepEqual(computePdfPageTops([{ top: 0, bottom: 100 }], 990), [0]);
});

test('块恰好填满一页不再开新页（边界 <=）', () => {
  assert.deepEqual(computePdfPageTops([{ top: 0, bottom: 990 }], 990), [0]);
  assert.deepEqual(computePdfPageTops([{ top: 0, bottom: 500 }, { top: 500, bottom: 990 }], 990), [0]);
});

test('放不下的块从其顶部开新页，不切断块（v1.53 拍板：逐页渲染）', () => {
  const tops = computePdfPageTops([
    { top: 0, bottom: 400 },
    { top: 400, bottom: 800 },
    { top: 800, bottom: 1200 }
  ], 990);
  assert.deepEqual(tops, [0, 800]);
});

test('单块自身超页高按页高硬切兜底（不抛错、不越界）', () => {
  const tops = computePdfPageTops([{ top: 0, bottom: 2500 }], 990);
  assert.deepEqual(tops, [0, 990, 1980]);
  assert.ok(2500 - tops[tops.length - 1] <= 990);
});

test('块顶等于当前页顶且超高时同样硬切', () => {
  const tops = computePdfPageTops([
    { top: 0, bottom: 100 },
    { top: 100, bottom: 1200 }
  ], 500);
  assert.deepEqual(tops, [0, 500, 1000]);
});

test('硬切后不足一页的尾部不再追加空页', () => {
  const tops = computePdfPageTops([{ top: 0, bottom: 1500 }], 990);
  assert.deepEqual(tops, [0, 990]);
});

test('页数超过上限 100 抛错并提示改用 Markdown / ZIP', () => {
  const bounds = [];
  for (let i = 0; i < 101; i++) {
    bounds.push({ top: i * 1000, bottom: i * 1000 + 500 });
  }
  assert.throws(() => computePdfPageTops(bounds, 990), /页数上限/);
});

test('无效输入：页高非正数、bounds 非数组、无效块跳过', () => {
  assert.throws(() => computePdfPageTops([], 0), /页高参数无效/);
  assert.throws(() => computePdfPageTops([], -1), /页高参数无效/);
  assert.throws(() => computePdfPageTops([], NaN), /页高参数无效/);
  assert.throws(() => computePdfPageTops(null, 990), /分页输入无效/);
  // 无效块（NaN / bottom <= top）跳过不中断
  assert.deepEqual(computePdfPageTops([
    { top: NaN, bottom: 100 },
    { top: 200, bottom: 200 },
    { top: 300, bottom: 100 },
    { top: 0, bottom: 50 }
  ], 990), [0]);
});

test('末页补白：内容不足一页时补齐整页高度（含 1px 舍入余量）', () => {
  // tops=[0]，页高 990，内容只有 400 → 补 590 + 1 舍入余量
  assert.equal(pdfBottomPadding([0], 990, 400), 591);
  // 内容恰好满页 → 只补舍入余量
  assert.equal(pdfBottomPadding([0], 990, 990), 1);
  // 内容超出末页需求 → 只补舍入余量
  assert.equal(pdfBottomPadding([0], 990, 1200), 1);
});

test('末页补白：多页场景按末页顶计算（流内 spacer，不叠加 #content padding）', () => {
  // 末页顶 800，页高 990 → 需要 1790；scrollHeight 1500 → 补 290 + 1
  assert.equal(pdfBottomPadding([0, 800], 990, 1500), 291);
  // scrollHeight 已覆盖 → 只补舍入余量
  assert.equal(pdfBottomPadding([0, 800], 990, 2000), 1);
});

test('末页补白：无效输入抛错', () => {
  assert.throws(() => pdfBottomPadding([], 990, 100), /分页结果为空/);
  assert.throws(() => pdfBottomPadding([0], 0, 100), /页高参数无效/);
  assert.throws(() => pdfBottomPadding([0], 990, -1), /内容高度无效/);
});

// ---------- 53.7 标题与下一块合并（对齐 v2 原型 previewPdfShare） ----------

test('mergeHeadingUnits：标题吞并紧随其后的块为一个分页单元', () => {
  const units = paginationModule.mergeHeadingUnits([
    { top: 0, bottom: 100, heading: false },
    { top: 100, bottom: 160, heading: true },
    { top: 160, bottom: 500, heading: false }
  ]);
  assert.deepEqual(units, [
    { top: 0, bottom: 100, heading: false },
    { top: 100, bottom: 500, heading: true }
  ]);
});

test('mergeHeadingUnits：连续标题链式合并（H1+H2+正文 → 一个单元）', () => {
  const units = paginationModule.mergeHeadingUnits([
    { top: 0, bottom: 40, heading: true },
    { top: 40, bottom: 80, heading: true },
    { top: 80, bottom: 400, heading: false }
  ]);
  assert.equal(units.length, 1);
  assert.deepEqual(units[0], { top: 0, bottom: 400, heading: true });
});

test('mergeHeadingUnits：末尾标题无后继保持原样；标题与水印（末块）合并', () => {
  // 标题是最后一个块：保持独立
  assert.deepEqual(paginationModule.mergeHeadingUnits([
    { top: 0, bottom: 100, heading: false },
    { top: 100, bottom: 140, heading: true }
  ]), [
    { top: 0, bottom: 100, heading: false },
    { top: 100, bottom: 140, heading: true }
  ]);
  // 标题后跟水印块：标题与水印合并（原型把 .share-watermark 作为末块参与）
  assert.deepEqual(paginationModule.mergeHeadingUnits([
    { top: 0, bottom: 800, heading: false },
    { top: 800, bottom: 840, heading: true },
    { top: 840, bottom: 870, heading: false }
  ]), [
    { top: 0, bottom: 800, heading: false },
    { top: 800, bottom: 870, heading: true }
  ]);
});

test('mergeHeadingUnits：纯正文恒等映射、不修改输入数组、无效块过滤', () => {
  const input = [
    { top: 0, bottom: 100, heading: false },
    { top: 100, bottom: 300, heading: false }
  ];
  const snapshot = JSON.stringify(input);
  assert.deepEqual(paginationModule.mergeHeadingUnits(input), input);
  assert.equal(JSON.stringify(input), snapshot, '不得修改输入数组');
  // 无效块（NaN / bottom <= top）跳过后再合并
  assert.deepEqual(paginationModule.mergeHeadingUnits([
    { top: NaN, bottom: 100, heading: true },
    { top: 0, bottom: 0, heading: true },
    { top: 50, bottom: 80, heading: true },
    { top: 80, bottom: 200, heading: false }
  ]), [
    { top: 50, bottom: 200, heading: true }
  ]);
  assert.throws(() => paginationModule.mergeHeadingUnits(null), /分页输入无效/);
});

test('mergeHeadingUnits + computePdfPageTops：页尾孤标题随正文走（53.7 分页行为）', () => {
  // 页高 500；正文块 0-460 后紧跟标题 460-500 与下一块 500-700：
  // 合并后标题不孤悬页尾，与下一块一起从新页 460 开始。
  const tops = computePdfPageTops(paginationModule.mergeHeadingUnits([
    { top: 0, bottom: 460, heading: false },
    { top: 460, bottom: 500, heading: true },
    { top: 500, bottom: 700, heading: false }
  ]), 500);
  assert.deepEqual(tops, [0, 460]);
});

// ---------- 源级断言（v1.53 53.1–53.5 接线与红线） ----------

test('源级：mdpreview index.ts 注册 preparePdfPages 并回传 pageCount / pageTops', () => {
  const indexTs = readRepoFile('web/mdpreview/src/index.ts');
  assert.match(indexTs, /preparePdfPages\(id: number, pageHeightVp: number\): void/);
  assert.match(indexTs, /async preparePdfPages\(id: number, pageHeightVp: number\)/);
  // 53.7：块收集带 heading 标记，先 mergeHeadingUnits 再 computePdfPageTops。
  assert.match(indexTs, /bounds\.push\(\{ top: top, bottom: top \+ childRect\.height, heading: \/\^H\[1-6\]\$\/\.test\(child\.tagName\) \}\)/);
  assert.match(indexTs, /mergeHeadingUnits\(bounds\)/);
  assert.match(indexTs, /computePdfPageTops\(units, pageHeightVp\)/);
  assert.match(indexTs, /pageCount: tops\.length/);
  assert.match(indexTs, /pageTops: JSON\.stringify\(tops\)/);
});

test('源级：rawfile 产物已同步标题合并规则（53.7）', () => {
  const bundle = readRepoFile('entry/src/main/resources/rawfile/mdpreview/index.html');
  // esbuild 混淆函数名，断言行为标记：块收集带 heading 标记（h1-h6 判定）。
  assert.ok(bundle.includes('H[1-6]'), 'rawfile mdpreview 产物缺少标题判定正则，请重跑 web/mdpreview 的 node build.mjs');
});

test('源级：rawfile 构建产物已同步 preparePdfPages（防 v1.50 产物 stale 复发）', () => {
  const bundle = readRepoFile('entry/src/main/resources/rawfile/mdpreview/index.html');
  assert.ok(bundle.includes('preparePdfPages'), 'rawfile mdpreview 产物缺少 preparePdfPages，请重跑 web/mdpreview 的 node build.mjs');
});

test('源级：PreviewWebView 协议含 preparePdfPages 与 pageTops 解析', () => {
  const preview = readRepoFile('entry/src/main/ets/components/PreviewWebView.ets');
  assert.match(preview, /preparePdfPages\(id: number, pageHeightVp: number\): void/);
  assert.match(preview, /preparePdfPages\(pageHeightVp: number\): Promise<PreviewCaptureResult>/);
  assert.match(preview, /result\['pageTops'\] as string/);
  assert.match(preview, /pageCount\?: number/);
});

test('源级：NotePdfDocumentService 走 PDF Kit 图片→PDF 路线且 syscap 检测', () => {
  const service = readRepoFile('entry/src/main/ets/model/NotePdfDocumentService.ets');
  assert.match(service, /canIUse\('SystemCapability\.OfficeService\.PDFService\.Core'\)/);
  assert.match(service, /createDocument\(/);
  assert.match(service, /insertBlankPage\(/);
  assert.match(service, /addImageObject\(/);
  assert.match(service, /saveDocument\(/);
  assert.match(service, /releaseDocument\(\)/);
  assert.equal(service.includes('ohos.permission.PRINT'), false);
});

test('源级：exportFromPageImages 删除 createDocument 自带的富余空白页（2026-11-11 实测）', () => {
  const service = readRepoFile('entry/src/main/ets/model/NotePdfDocumentService.ets');
  // 模拟器实测（PDF-1.7）：createDocument 自带一张初始空白页，逐图 insertBlankPage 后
  // 悬在文档末尾（末页 /Resources<<>> 全空白）→ 每本 PDF 多一张空白尾页。
  // 贴完图后按 getPageCount 富余量 deletePage；若实现不建初始页则 surplus 为 0 不删。
  assert.match(service, /getPageCount\(\)/);
  assert.match(service, /const surplus: number = document\.getPageCount\(\) - pageJpegs\.length;/);
  assert.match(service, /if \(surplus > 0\) \{\s*\n\s*document\.deletePage\(pageJpegs\.length, surplus\);/);
  // 删除动作必须发生在 saveDocument 之前。
  const cleanup = service.indexOf('const surplus: number');
  const del = service.indexOf('document.deletePage(');
  const save = service.indexOf('document.saveDocument(');
  assert.ok(cleanup > 0 && del > cleanup && save > del, 'surplus 清理须在 saveDocument 之前');
});

test('源级：Index 含 PDF 路由、捕获层 PDF 模式与分享面板 PDF 行', () => {
  const index = readRepoFile('entry/src/main/ets/pages/Index.ets');
  assert.match(index, /format === 'pdf' && scope === 'note'/);
  assert.match(index, /prepareNotePdfShare\(/);
  assert.match(index, /shareCapturePdfMode/);
  assert.match(index, /preparePdfPages\(this\.pdfPageHeightVp\)/);
  assert.match(index, /value: 'pdf', label: 'PDF 文档'/);
  assert.match(index, /NotePdfDocumentService\.isSupported\(\)/);
  assert.match(index, /uniformTypeDescriptor\.UniformDataType\.PDF/);
  assert.match(index, /writeJpegTo\(/);
});

test('源级：PDF 捕获页尺寸随窗口自适应且挂捕获层前重算（2026-11-11 修复）', () => {
  const index = readRepoFile('entry/src/main/ets/pages/Index.ets');
  // 固定 700×990.59 在窗口高 < 990.59vp 时分页高度永远补不齐；宽度上限 700 不变，
  // 比例恒 A4，高度取整消除 scrollHeight 取整歧义。
  assert.match(index, /private updatePdfPageSize\(\): void/);
  assert.match(index, /Math\.min\(700, widthByWindow, widthByHeight\)/);
  assert.match(index, /pdfPageHeightVp = Math\.round\(/);
  assert.doesNotMatch(index, /readonly pdfPageWidthVp/);
  assert.doesNotMatch(index, /readonly pdfPageHeightVp/);
  // 必须在置 shareCapturePdfMode / shareCaptureActive 挂捕获层之前重算尺寸。
  assert.match(index, /this\.updatePdfPageSize\(\);\s*\n\s*this\.shareCapturePdfMode = true;/);
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
  // 原型 pdf-specs 四枚胶囊
  for (const chip of ['A4 竖版', '浅色纸面', '按段落分页', '末页水印']) {
    assert.ok(dialog.includes(`this.SpecChip('${chip}')`), `缺少规格胶囊「${chip}」`);
  }
  // 原型 shareMeta：1 个 PDF + 文件名 + N 页
  assert.match(dialog, /'1 个 PDF'/);
  assert.match(dialog, /this\.pageUris\.length\.toString\(\) \+ ' 页'/);
  // 缩略图：逐页 Image + 「N / M」页码 + 第 N 页共 M 页读屏
  assert.match(dialog, /aspectRatio\(595 \/ 842\)/);
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

test('源级：Index PDF 链路先进分页预览弹窗，确认后才合成（53.7）', () => {
  const index = readRepoFile('entry/src/main/ets/pages/Index.ets');
  assert.match(index, /import \{ SharePdfPreviewDialog \} from '\.\.\/components\/SharePdfPreviewDialog';/);
  assert.match(index, /private sharePdfPreviewCtl: CustomDialogController \| null = null;/);
  assert.match(index, /private sharePdfPreviewSessionId: string = '';/);
  assert.match(index, /private sharePdfPreviewPages: string\[\] = \[\];/);
  // 捕获完成后进预览弹窗，捕获层卸下；导出不再内联在 prepareNotePdfShare
  assert.match(index, /this\.openSharePdfPreview\(itemName, notePath, sessionId, pageJpegs, vaultId\);/);
  const prepare = index.slice(index.indexOf('private async prepareNotePdfShare'),
    index.indexOf('private pdfFileNameOf'));
  assert.ok(prepare.length > 0, 'prepareNotePdfShare 区间未定位');
  assert.doesNotMatch(prepare, /exportFromPageImages/, 'prepareNotePdfShare 不得内联合成 PDF（53.7 改预览后确认）');
  assert.doesNotMatch(prepare, /openShareFilePreview\(/, 'prepareNotePdfShare 不得直接进文件预览');
  // onConfirm 内合成 PDF 并进入文件预览（精确 utd PDF）
  assert.match(index, /NotePdfDocumentService\.exportFromPageImages\(pages, pdfPath\);/);
  // 返回：清理会话回到分享面板
  assert.match(index, /private cleanupSharePdfPreview\(\): void/);
  assert.match(index, /NoteShareService\.removeTree\(VaultRegistry\.get\(\), sessionId\);\s*\n\s*\} catch \(error\) \{\s*\n\s*hilog\.warn\(DOMAIN, TAG, 'PDF 分页预览临时文件清理失败'\);/);
  assert.match(index, /this\.cleanupSharePdfPreview\(\);\s*\n\s*this\.openShareDialog\('note', notePath\);/);
  // 缩略图 URI 走 fileUri.getUriFromPath
  assert.match(index, /pageUris\.push\(fileUri\.getUriFromPath\(pageJpegs\[i\]\)\);/);
});

// ---------- 53.10 分段快照旧帧校验（XT2「一页渲染两页且重复」修复） ----------

test('源级：Index 分段快照带旧帧校验与重试（53.10）', () => {
  const index = readRepoFile('entry/src/main/ets/pages/Index.ets');
  // 逐字节比较 + readPixelsToBuffer 读帧 + 有界重试 + 明确报错
  assert.match(index, /private segmentBuffersIdentical\(a: ArrayBuffer, b: ArrayBuffer\): boolean/);
  assert.match(index, /await snapshot\.readPixelsToBuffer\(buffer\);/);
  assert.match(index, /private async captureSegmentVerified\(prevBuffer: ArrayBuffer \| null\)/);
  assert.match(index, /throw new Error\('分享预览渲染未更新，请重试'\);/);
  // 重试有界（4 次）且等待 180ms 后重拍
  assert.match(index, /const maxAttempts: number = 4;/);
  assert.match(index, /\}, 180\);/);
  // 长图与 PDF 两循环都走校验快照，不再直连 getComponentSnapshot
  const imageLoop = index.slice(index.indexOf('private async prepareNoteImageShare'),
    index.indexOf('/** PDF 捕获页尺寸自适应'));
  assert.ok(imageLoop.length > 0, 'prepareNoteImageShare 区间未定位');
  assert.match(imageLoop, /await this\.captureSegmentVerified\(prevSegmentBuffer\)/);
  assert.doesNotMatch(imageLoop, /getComponentSnapshot\(\)/, '长图循环不得绕过旧帧校验直连快照');
  const pdfLoop = index.slice(index.indexOf('private async prepareNotePdfShare'),
    index.indexOf('private pdfFileNameOf'));
  assert.ok(pdfLoop.length > 0, 'prepareNotePdfShare 区间未定位');
  assert.match(pdfLoop, /await this\.captureSegmentVerified\(prevPageBuffer\)/);
  assert.doesNotMatch(pdfLoop, /getComponentSnapshot\(\)/, 'PDF 循环不得绕过旧帧校验直连快照');
});

test('源级：web setShareCaptureScrollTop 滚动后给渲染服务留合成时间（53.10）', () => {
  const indexTs = readRepoFile('web/mdpreview/src/index.ts');
  const scrollFn = indexTs.slice(indexTs.indexOf('async setShareCaptureScrollTop'),
    indexTs.indexOf('async preparePdfPages'));
  assert.ok(scrollFn.length > 0, 'setShareCaptureScrollTop 区间未定位');
  // 双 rAF 之后仍有 64ms 沉淀，避免组件快照取到滚动前旧表面
  assert.match(scrollFn, /await nextRenderedFrame\(\)/);
  assert.match(scrollFn, /\}, 64\)/);
});
