import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const shareFlowSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

// 2026-11-18 bug 修复：分享长图 / PDF 里 [[双链]] 被原样渲染成链接原文。
// 根因：预览链路渲染前经 WikiLinkParser.renderForPreviewWithSourceMap 展开双链
// （Index pushPreview / pushRightPreview），而分享捕获层直接把原始 Markdown 喂给
// 隐藏捕获 Web（bridge.setContent(markdown)），[[...]] 非标准 Markdown 语法，
// Web 侧 marked 原样输出，导致长图 / PDF 与预览所见不一致。
// 修复：捕获前统一走 renderForShareCapture（与预览同规则展开双链）。
// 本测试防止回归到「捕获层直喂原始 Markdown」。

test('分享捕获层经 renderForShareCapture 展开双链，与预览渲染同源', () => {
  const helper = shareFlowSource.match(
    /private renderForShareCapture\(registry: VaultRegistry, vaultId: string, notePath: string,\s*\n\s*markdown: string\): string \{[\s\S]*?\n  \}/);
  assert.ok(helper, '缺少 renderForShareCapture helper');
  const body = helper[0];
  assert.match(body, /WikiLinkParser\.renderForPreview\(markdown, notePath, WikiLinkService\.files\(registry, vaultId\)\)/,
    '捕获渲染必须走 WikiLinkParser.renderForPreview + WikiLinkService.files，与预览同源');
});

test('长图链路 setContent 前必须先展开双链，不得直喂原始 Markdown', () => {
  const imageShare = shareFlowSource.match(
    /private async prepareNoteImageShare\(vaultId: string, notePath: string,[\s\S]*?\n  \}/);
  assert.ok(imageShare, '缺少 prepareNoteImageShare');
  assert.match(imageShare[0],
    /bridge\.setContent\(this\.renderForShareCapture\(registry, vaultId, notePath, markdown\)\)/,
    '长图捕获的 setContent 必须经 renderForShareCapture');
  assert.doesNotMatch(imageShare[0], /bridge\.setContent\(markdown\)/,
    '长图捕获不得直喂原始 Markdown（双链会原样渲染）');
});

test('PDF 链路 setContent 前必须先展开双链，不得直喂原始 Markdown', () => {
  const pdfShare = shareFlowSource.match(
    /private async prepareNotePdfShare\(vaultId: string, notePath: string,[\s\S]*?\n  \}/);
  assert.ok(pdfShare, '缺少 prepareNotePdfShare');
  assert.match(pdfShare[0],
    /bridge\.setContent\(this\.renderForShareCapture\(registry, vaultId, notePath, markdown\)\)/,
    'PDF 捕获的 setContent 必须经 renderForShareCapture');
  assert.doesNotMatch(pdfShare[0], /bridge\.setContent\(markdown\)/,
    'PDF 捕获不得直喂原始 Markdown（双链会原样渲染）');
});

test('ShareFlowPanel 已导入 WikiLinkParser 与 WikiLinkService', () => {
  assert.match(shareFlowSource, /import \{ WikiLinkParser \} from '\.\.\/model\/WikiLinkParser';/);
  assert.match(shareFlowSource, /import \{ WikiLinkService \} from '\.\.\/model\/WikiLinkService';/);
});

test('预览侧双链展开规则未被改动（pushPreview / pushRightPreview 同源基准）', () => {
  const previewPush = indexSource.match(
    /private pushPreview\(text: string, force: boolean = false\): void \{[\s\S]*?\n  \}/);
  assert.ok(previewPush, '缺少 pushPreview');
  assert.match(previewPush[0],
    /WikiLinkParser\.renderForPreviewWithSourceMap\(text, this\.currentFilePath, files\)/,
    '预览仍须按 WikiLinkParser 展开双链，分享捕获才谈得上与其同源');
  const rightPush = indexSource.match(
    /private pushRightPreview\(text: string, force: boolean = false\): void \{[\s\S]*?\n  \}/);
  assert.ok(rightPush, '缺少 pushRightPreview');
  assert.match(rightPush[0],
    /WikiLinkParser\.renderForPreviewWithSourceMap\(text, this\.rightFilePath, files\)/,
    '右栏预览仍须按 WikiLinkParser 展开双链');
});
