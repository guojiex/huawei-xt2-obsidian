import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methodStart = source.indexOf('  private parseChapterEntries(text: string): ChapterEntry[] {');
const methodEnd = source.indexOf('\n  private updateChapterEntries(', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find Index.parseChapterEntries');
const method = source.slice(methodStart, methodEnd).trim();
const code = transformSync(`class IndexHarness { ${method} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function parseChapterEntries(text) {
  const context = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, context);
  return Array.from(new context.module.exports().parseChapterEntries(text), (entry) => ({
    index: entry.index,
    level: entry.level,
    title: entry.title,
    offset: entry.offset
  }));
}

test('chapters skip BOM-prefixed CRLF frontmatter and keep body source offsets', () => {
  const text = '\uFEFF---\r\ntitle: sample\r\n# metadata comment\r\n...\r\n# Heading\r\n';
  const entries = parseChapterEntries(text);

  assert.deepEqual(entries, [{ index: 0, level: 1, title: 'Heading', offset: text.indexOf('# Heading') }]);
});

test('chapters skip frontmatter closed by a second YAML separator', () => {
  const text = '---\ntitle: sample\n# metadata comment\n---\n## Body\n';
  const entries = parseChapterEntries(text);

  assert.deepEqual(entries.map((entry) => [entry.level, entry.title, entry.offset]), [
    [2, 'Body', text.indexOf('## Body')]
  ]);
});

test('body separators, fenced code, setext headings, and duplicate headings keep their order', () => {
  const text = '# Same\n\n---\n\nTitle\n===\n\n```md\n# Fenced\n```\n# Same\n';
  const entries = parseChapterEntries(text);

  assert.deepEqual(entries.map((entry) => [entry.level, entry.title, entry.offset]), [
    [1, 'Same', text.indexOf('# Same')],
    [1, 'Title', text.indexOf('Title')],
    [1, 'Same', text.lastIndexOf('# Same')]
  ]);
});

test('an unclosed frontmatter block does not hide later headings', () => {
  const text = '---\ntitle: unfinished\n# Body heading\n';
  const entries = parseChapterEntries(text);

  assert.ok(entries.some((entry) => entry.title === 'Body heading' && entry.offset === text.indexOf('# Body heading')));
});
