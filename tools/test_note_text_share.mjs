import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/model/NoteTextShareService.ets', import.meta.url), 'utf8');
const code = transformSync(source + '\nmodule.exports = NoteTextShareService;', {
  loader: 'ts',
  format: 'cjs'
}).code;
const context = vm.createContext({ module: { exports: {} } });
vm.runInContext(code, context);
const { createPreview } = context.module.exports;

test('frontmatter title replaces the filename, duplicate title is omitted, and common Markdown stays readable', () => {
  const result = createPreview('notes/fallback.md', [
    '---',
    'title: "Readable title"',
    'tags: [sample]',
    '---',
    '# Readable title',
    '',
    'A **bold** and *italic* word with [a link](https://example.test).',
    '',
    '- first',
    '1. second',
    '- [x] done',
    '- [ ] next'
  ].join('\n'));

  assert.equal(result.title, 'Readable title');
  assert.equal(result.content, [
    'Readable title',
    '',
    'A bold and italic word with a link (https://example.test).',
    '',
    '• first',
    '1. second',
    '☑ done',
    '☐ next'
  ].join('\n'));
  assert.deepEqual(Array.from(result.limitations), ['YAML 属性区不包含在文本中。']);
});

test('images, tables, formulas, and wiki links get readable text and explicit limitations', () => {
  const result = createPreview('sample.md', [
    '![diagram](assets/diagram.png)',
    '',
    '| Name | Value |',
    '| --- | --- |',
    '| A | ![cell](assets/cell.png) |',
    '| Cost | $5 |',
    '',
    'Formula $x^2$ and [[target|alias]].',
    '<img src="chart.png">'
  ].join('\n'));

  assert.match(result.content, /\[图片：diagram\]/);
  assert.match(result.content, /Name \| Value\nA \| \[图片：cell\]\nCost \| \$5/);
  assert.match(result.content, /Formula \$x\^2\$ and alias \(target\)/);
  assert.match(result.content, /\[图片\]/);
  assert.deepEqual(Array.from(result.limitations), [
    '图片以文字占位，不会随文本传递；需保留附件时请选择排版图片或 Markdown / ZIP。',
    '表格改为单元格文字排列，表格版式不会保留。',
    '公式保留原始表达式，公式排版不会保留。',
    '双链改为可读文字，链接目标放在括号中。'
  ]);
});

test('fenced code keeps its source text while fence markers and common inline formatting are removed', () => {
  const result = createPreview('code.md', [
    '```typescript',
    'const value = "**literal**";',
    '```',
    '',
    'Inline `code` stays readable.'
  ].join('\n'));

  assert.equal(result.content, 'code\n\nconst value = "**literal**";\n\nInline code stays readable.');
  assert.deepEqual(Array.from(result.limitations), []);
});

test('an unclosed frontmatter block remains visible and large text is not rejected by an invented local limit', () => {
  const unclosed = createPreview('sample.md', '---\ntitle: visible\nbody text');
  assert.match(unclosed.content, /title: visible/);
  assert.match(unclosed.content, /body text/);
  const emptyTitle = createPreview('fallback.md', "---\ntitle: ''\n---\nbody");
  assert.equal(emptyTitle.title, 'fallback');
  assert.equal(emptyTitle.content, 'fallback\n\nbody');

  const largeText = 'x'.repeat(200 * 1024);
  const large = createPreview('large.md', largeText);
  assert.equal(large.content.length, largeText.length + 'large\n\n'.length);
});
