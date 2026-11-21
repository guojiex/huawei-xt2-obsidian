import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

// v1.96：分享长图入口按内容预估隐藏（B 方案）。估算模型为纯静态类，
// esbuild transformSync + vm 执行（对齐 test_note_image_share_pagination.mjs 的 harness）。
const source = readSourceFile(new URL(
  '../../entry/src/main/ets/model/NoteImageShareEstimate.ets', import.meta.url));
const code = transformSync(source, { loader: 'ts', format: 'cjs' }).code;
const moduleObj = { exports: {} };
const context = vm.createContext({
  module: moduleObj,
  exports: moduleObj.exports,
  require: () => ({
    // NoteImageShareService 桩：只提供拒绝线常量（与源文件一致）
    NoteImageShareService: {
      MAX_PIXEL_MAP_BYTES: 96 * 1024 * 1024,
      MIN_IMAGE_WIDTH: 640
    }
  })
});
vm.runInContext(code, context);
const { NoteImageShareEstimate } = context.module.exports;

const RATIO = 96 * 1024 * 1024 / (4 * 640 * 640); // ≈ 61.44:1，dpr 在比值中抵消
const PHONE = 360;   // 'phone' 宽度偏好
const WIDE = 720;    // 'wide' 宽度偏好

test('96.1 maxHeightVp matches the longImageGeometry rejection line', () => {
  assert.equal(NoteImageShareEstimate.maxHeightVp(PHONE), RATIO * PHONE);
  assert.equal(NoteImageShareEstimate.maxHeightVp(WIDE), RATIO * WIDE);
  assert.ok(Math.abs(RATIO - 61.44) < 0.01);
});

test('96.1 normal-length note keeps the image option', () => {
  const note = '# 标题\n\n' +
    '这是一段正常长度的笔记内容，用来验证常规笔记不会被隐藏长图入口，也不会被误判为超长。'.repeat(40);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(note, PHONE), false);
});

test('96.1/96.2 v1.90-class overlong note hides the option at phone width only', () => {
  // v1.90 真机样本量级：约 4 万 CJK 字 → 63 页 PDF 的笔记
  const huge = '长'.repeat(40000);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(huge, PHONE), true);
  // 同一篇在宽版宽度下预估未超限 → 入口保留（宽度偏好决定）
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(huge, WIDE), false);
});

test('96.1 fail-open: empty note or invalid width never hides', () => {
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit('', PHONE), false);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit('长'.repeat(40000), 0), false);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit('长'.repeat(40000), -1), false);
});

test('96.1 code-heavy note counts non-wrapping code lines', () => {
  const fence = (n) => '```\n' + 'console.log(1);\n'.repeat(n) + '```\n';
  // 1200 行 × 25.9vp ≈ 31080 > 22118（360vp 拒绝线）
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(fence(1200), PHONE), true);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(fence(300), PHONE), false);
});

test('96.1 list items, headings and table rows each occupy at least one line', () => {
  const items = [];
  for (let i = 0; i < 800; i++) {
    items.push(`- 第${i}项`);
  }
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(items.join('\n'), PHONE), true);
  const headings = [];
  for (let i = 0; i < 800; i++) {
    headings.push(`## 小节${i}`);
  }
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(headings.join('\n'), PHONE), true);
  const rows = [];
  for (let i = 0; i < 800; i++) {
    rows.push(`|列${i}|值|`);
  }
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(rows.join('\n'), PHONE), true);
});

test('96.1 frontmatter and image-only lines contribute no height', () => {
  const withFm = '---\n' + '很长的元数据属性值'.repeat(2000) + '\n---\n\n短正文';
  assert.ok(NoteImageShareEstimate.estimateHeightVp(withFm, PHONE) < RATIO * PHONE);
  const withImages = '![图](a.png)\n\n短正文';
  assert.ok(NoteImageShareEstimate.estimateHeightVp(withImages, PHONE) < RATIO * PHONE);
});

test('96.3 calibrated spacing: paragraph margins, heading size and hr height are counted', () => {
  // 段落间距计入：两段比两行同段更高（margin 折叠后每段仍多出下边距）
  const twoParagraphs = NoteImageShareEstimate.estimateHeightVp('一\n\n二', PHONE);
  assert.ok(twoParagraphs > 2 * NoteImageShareEstimate.BODY_LINE_VP,
    `two paragraphs should exceed two bare body lines, got ${twoParagraphs}`);
  // 标题按真实字号与边距计（h1 = 32×1.35 + 上边距 12）
  const h1 = NoteImageShareEstimate.estimateHeightVp('# 标题', PHONE);
  assert.ok(h1 >= 32 * 1.35 + 12, `h1 should use heading metrics, got ${h1}`);
  // hr 按真实边距计（margin 32×2 + 1px），不再计 0；用 *** 避免首行 --- 被判 frontmatter
  const hr = NoteImageShareEstimate.estimateHeightVp('***\n', PHONE);
  assert.ok(hr > NoteImageShareEstimate.HR_TOP_VP, `hr should contribute margin, got ${hr}`);
});

test('96.3 real-device leak band: marginal v1.90-failure note now hides (calibration fix)', () => {
  // 2026-11-21 真机漏判回归：210 段 × 3 行短文，纯下界模型估算 ≈ 18648 < 22118 → 漏判
  // （真实渲染 ≈ 22848vp，高宽比 63.5 > 61.44，v1.90 阶段必失败）。
  // 校准后（段落间距 + 水印）估算 ≈ 22895 > 22118 → 隐藏。
  const paragraphs = [];
  for (let i = 0; i < 210; i++) {
    paragraphs.push('段'.repeat(52));
  }
  const note = paragraphs.join('\n\n');
  const bareLines = 210 * 3 * NoteImageShareEstimate.BODY_LINE_VP;
  const estimated = NoteImageShareEstimate.estimateHeightVp(note, PHONE);
  assert.ok(estimated > bareLines, `spacing must be included: ${estimated} vs ${bareLines}`);
  assert.equal(NoteImageShareEstimate.exceedsLongImageLimit(note, PHONE), true);
});

test('96.2 ShareFlowPanel gates the image row on the estimate (source-level)', () => {
  const panel = readSourceFile(new URL(
    '../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));
  // 门控接线：估算调用 + 条件不构建
  assert.ok(panel.includes('NoteImageShareEstimate.exceedsLongImageLimit'));
  assert.match(panel, /if \(!hideImageOption\) \{\s*\n\s*noteOptions\.push\(\{\s*\n\s*value: 'image'/);
  // fail-open：读取失败不隐藏（v1.96.3 起带 hilog 数值诊断）
  assert.match(panel, /catch \(error\) \{\s*\n\s*hideImageOption = false;/);
  assert.ok(panel.includes('v196 len='),
    'numeric estimate diagnostics must be logged (no note content, hard rule 16)');
  // 格式顺序保持：image → pdf → file → text
  const order = ['image', 'pdf', 'file', 'text']
    .map((v) => panel.indexOf(`value: '${v}'`));
  assert.ok(order.every((idx) => idx >= 0), 'four formats present');
  assert.ok(order[0] < order[1] && order[1] < order[2] && order[2] < order[3],
    'format order preserved');
  // openShareDialog 已改 async（await 估算读取）
  assert.match(panel, /private async openShareDialog\(scope: ShareLinkScope[\s\S]*?\): Promise<void> \{/);
});

test('v1.90 generation-time error message stays unchanged (regression guard)', () => {
  const service = readSourceFile(new URL(
    '../../entry/src/main/ets/model/NoteImageShareService.ets', import.meta.url));
  assert.ok(service.includes('笔记过长，无法生成清晰的单张长图；请改用 PDF / Markdown / ZIP'));
});
