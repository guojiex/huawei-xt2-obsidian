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

test('末页补白：内容不足一页时补齐整页高度', () => {
  // tops=[0]，页高 990，内容只有 400 → 补 590
  assert.equal(pdfBottomPadding([0], 990, 400, 0), 590);
  // 内容恰好满页 → 不补
  assert.equal(pdfBottomPadding([0], 990, 990, 0), 0);
  // 内容超出末页需求 → 不补
  assert.equal(pdfBottomPadding([0], 990, 1200, 0), 0);
});

test('末页补白：多页场景按末页顶计算（含现有 padding 叠加）', () => {
  // 末页顶 800，页高 990 → 需要 1790；scrollHeight 1500（已含现有 padding 20）→ 补 270 + 20
  assert.equal(pdfBottomPadding([0, 800], 990, 1500, 20), 310);
  // scrollHeight 已覆盖 → 只保留现有 padding
  assert.equal(pdfBottomPadding([0, 800], 990, 2000, 20), 20);
});

test('末页补白：无效输入抛错', () => {
  assert.throws(() => pdfBottomPadding([], 990, 100, 0), /分页结果为空/);
  assert.throws(() => pdfBottomPadding([0], 0, 100, 0), /页高参数无效/);
  assert.throws(() => pdfBottomPadding([0], 990, -1, 0), /内容高度无效/);
});

// ---------- 源级断言（v1.53 53.1–53.5 接线与红线） ----------

test('源级：mdpreview index.ts 注册 preparePdfPages 并回传 pageCount / pageTops', () => {
  const indexTs = readRepoFile('web/mdpreview/src/index.ts');
  assert.match(indexTs, /preparePdfPages\(id: number, pageHeightVp: number\): void/);
  assert.match(indexTs, /async preparePdfPages\(id: number, pageHeightVp: number\)/);
  assert.match(indexTs, /computePdfPageTops\(bounds, pageHeightVp\)/);
  assert.match(indexTs, /pageCount: tops\.length/);
  assert.match(indexTs, /pageTops: JSON\.stringify\(tops\)/);
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
