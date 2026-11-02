import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';
import { renderMarkdownWithSourceBlocks } from '../../web/mdpreview/src/sourceMapping.mjs';
import { splitFrontmatter } from '../../web/mdpreview/src/renderer.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const { marked } = require('marked');
marked.setOptions({ gfm: true, breaks: false });

const previewSource = readSourceFile(new URL('../../web/mdpreview/src/index.ts', import.meta.url));
const replaceStart = previewSource.indexOf('function replaceSourceBlock(block: HTMLElement): void {');
const replaceEnd = previewSource.indexOf("\ncontentElement.addEventListener('compositionstart'", replaceStart);
assert.ok(replaceStart >= 0 && replaceEnd > replaceStart, 'could not find replaceSourceBlock');
const replaceFunction = previewSource.slice(replaceStart, replaceEnd);

const source = '\uFEFF---\r\ntitle: 保持\r\nreference: [[Target|显示名]]\r\n---\r\n\r\n' +
  '# 未编辑标题\r\n\r\n待编辑段落\r\n\r\n```yaml\r\nraw: [[Target]]\r\n```\r\n\r\n%%未编辑%%\r\n';
const originalWikiLink = '[[Target|显示名]]';
const renderedWikiLink = '<a class="wiki-link" href="#wikilink:">显示名</a>';
const sourceWikiStart = source.indexOf(originalWikiLink);
const display = source.slice(0, sourceWikiStart) + renderedWikiLink +
  source.slice(sourceWikiStart + originalWikiLink.length);
const edits = [{
  displayStart: sourceWikiStart,
  displayEnd: sourceWikiStart + renderedWikiLink.length,
  sourceStart: sourceWikiStart,
  sourceEnd: sourceWikiStart + originalWikiLink.length
}];

function renderMappedBlocks(displayText, sourceText, sourceEdits) {
  const displayBody = splitFrontmatter(displayText).body;
  const sourceBody = splitFrontmatter(sourceText).body;
  const displayOffset = displayText.length - displayBody.length;
  const sourceOffset = sourceText.length - sourceBody.length;
  const lineOffset = displayText.slice(0, displayOffset).split('\n').length - 1;
  return renderMarkdownWithSourceBlocks(
    displayBody, lineOffset, sourceOffset, sourceEdits, displayOffset
  );
}

function createReplaceHarness(markdown, blocks) {
  const module = { exports: {} };
  const code = transformSync(
    `let sourceText = ${JSON.stringify(markdown)};
     function serializeEditedBlock(block) { return block.serialized; }
     function notifyEditableContentChange() { notifications++; }
     let notifications = 0;
     ${replaceFunction}
     module.exports = {
       replaceSourceBlock,
       getSourceText: () => sourceText,
       getNotifications: () => notifications
     };`,
    { loader: 'ts', format: 'cjs' }
  ).code;
  vm.runInNewContext(code, {
    module,
    document: { querySelectorAll: () => blocks }
  });
  return module.exports;
}

test('preview blocks map back to original ranges after a preceding WikiLink display expansion', () => {
  const rendered = renderMappedBlocks(display, source, edits);
  const target = rendered.blocks.find((block) =>
    source.slice(block.sourceStart, block.sourceEnd).includes('待编辑段落')
  );

  assert.ok(target);
  assert.equal(source.slice(target.sourceStart, target.sourceEnd), '待编辑段落');
  assert.equal(source.slice(target.sourceEnd).startsWith('\r\n\r\n```yaml\r\nraw: [[Target]]'), true);
});

test('CRLF source offsets remain exact without preview source edits', () => {
  const body = splitFrontmatter(source).body;
  const sourceOffset = source.length - body.length;
  const lineOffset = source.slice(0, sourceOffset).split('\n').length - 1;
  const rendered = renderMarkdownWithSourceBlocks(body, lineOffset, sourceOffset);
  const target = rendered.blocks.find((block) =>
    source.slice(block.sourceStart, block.sourceEnd).includes('待编辑段落')
  );

  assert.ok(target);
  assert.equal(source.slice(target.sourceStart, target.sourceEnd), '待编辑段落');
});

test('editing one mapped preview block preserves all other Markdown bytes and shifts later ranges', () => {
  const rendered = renderMappedBlocks(display, source, edits);
  const mappedBlocks = rendered.blocks.map((block) => ({
    dataset: {
      sourceFrom: String(block.sourceStart),
      sourceTo: String(block.sourceEnd)
    }
  }));
  const targetIndex = rendered.blocks.findIndex((block) =>
    source.slice(block.sourceStart, block.sourceEnd).includes('待编辑段落')
  );
  assert.ok(targetIndex >= 0);

  const target = mappedBlocks[targetIndex];
  target.serialized = '改写后的段落';
  const originalRange = rendered.blocks[targetIndex];
  const previous = source.slice(originalRange.sourceStart, originalRange.sourceEnd);
  const preservedTrailingBreaks = /(?:\r?\n)*$/.exec(previous)?.[0] ?? '';
  const replacement = target.serialized + preservedTrailingBreaks;
  const delta = replacement.length - (originalRange.sourceEnd - originalRange.sourceStart);
  const harness = createReplaceHarness(source, mappedBlocks);

  harness.replaceSourceBlock(target);

  const updated = harness.getSourceText();
  assert.equal(updated,
    source.slice(0, originalRange.sourceStart) + replacement + source.slice(originalRange.sourceEnd));
  assert.equal(updated.slice(0, originalRange.sourceStart), source.slice(0, originalRange.sourceStart));
  assert.equal(updated.slice(originalRange.sourceStart + replacement.length),
    source.slice(originalRange.sourceEnd));
  assert.equal(target.dataset.sourceTo, String(originalRange.sourceStart + replacement.length));
  assert.equal(harness.getNotifications(), 1);

  for (let index = targetIndex + 1; index < mappedBlocks.length; index++) {
    assert.equal(mappedBlocks[index].dataset.sourceFrom,
      String(rendered.blocks[index].sourceStart + delta));
    assert.equal(mappedBlocks[index].dataset.sourceTo,
      String(rendered.blocks[index].sourceEnd + delta));
  }
});

test('invalid source ranges leave Markdown and edit notifications untouched', () => {
  const block = { dataset: { sourceFrom: '-1', sourceTo: String(source.length) } };
  const harness = createReplaceHarness(source, [block]);

  harness.replaceSourceBlock(block);

  assert.equal(harness.getSourceText(), source);
  assert.equal(harness.getNotifications(), 0);
});
