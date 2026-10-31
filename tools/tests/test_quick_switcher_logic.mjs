import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/components/QuickSwitcher.ets', import.meta.url), 'utf8');

function extractMethod(signature, nextMarker, modifier = 'private') {
  const prefix = modifier.length > 0 ? `  ${modifier} ${signature}` : `  ${signature}`;
  const start = source.indexOf(prefix);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find QuickSwitcher method ${signature}`);
  return source.slice(start, end).trim();
}

const methods = [
  extractMethod('aboutToDisappear(): void {', '\n  private setSearchMode', ''),
  extractMethod('runFullTextSearch(query: string, requestId: number): Promise<void> {', '\n  // 外层 Row', 'private async'),
  extractMethod('visiblePaths(): string[] {', '\n  private fileName'),
  extractMethod('fileName(path: string): string {', '\n  /** 快切主标题'),
  extractMethod('displayName(path: string): string {', '\n  private isDuplicate'),
  extractMethod('isDuplicate(path: string): boolean {', '\n  build()')
];
const code = transformSync(`class QuickSwitcherHarness {\n${methods.join('\n')}\n}; module.exports = QuickSwitcherHarness;`,
  { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const context = vm.createContext({ module: { exports: {} }, clearTimeout });
  vm.runInContext(code, context);
  return new context.module.exports();
}

test('filters current-vault paths by case-insensitive file name or relative path', () => {
  const app = createHarness();
  app.filePaths = ['20_样式/FoldedNeedle.md', '2026/周报.md', '根目录.md'];
  app.recentPaths = ['根目录.md'];
  app.query = '  NEEDLE ';
  assert.deepEqual(Array.from(app.visiblePaths()), ['20_样式/FoldedNeedle.md']);

  app.query = '2026/周';
  assert.deepEqual(Array.from(app.visiblePaths()), ['2026/周报.md']);
  app.query = ' ';
  assert.deepEqual(Array.from(app.visiblePaths()), ['根目录.md']);
});

test('hides Markdown extensions and identifies duplicate file names by full path', () => {
  const app = createHarness();
  app.filePaths = ['left/Shared.md', 'right/Shared.md', '独立条目.MARKDOWN'];

  assert.equal(app.displayName('独立条目.MARKDOWN'), '独立条目');
  assert.equal(app.displayName('left/Shared.md'), 'Shared');
  assert.equal(app.isDuplicate('left/Shared.md'), true);
  assert.equal(app.isDuplicate('独立条目.MARKDOWN'), false);
});

test('ignores stale search progress and results after the query has changed', async () => {
  const app = createHarness();
  app.searchRequestId = 4;
  app.fullTextResults = [{ path: 'new.md', excerpt: 'current result' }];
  app.fullTextSearching = true;
  app.fullTextProgress = '正在搜索…';
  let reportProgress;
  let finishSearch;
  app.searchContent = (_query, onProgress) => {
    reportProgress = onProgress;
    return new Promise((resolve) => { finishSearch = resolve; });
  };

  const pending = app.runFullTextSearch('old query', 3);
  app.searchRequestId = 5;
  reportProgress(1, 10);
  finishSearch([{ path: 'old.md', excerpt: 'stale result' }]);
  await pending;

  assert.deepEqual(Array.from(app.fullTextResults, (item) => item.path), ['new.md']);
  assert.equal(app.fullTextSearching, true);
  assert.equal(app.fullTextProgress, '正在搜索…');
});

test('does not replace current search state with an old request failure', async () => {
  const app = createHarness();
  app.searchRequestId = 7;
  app.fullTextResults = [{ path: 'current.md', excerpt: 'current' }];
  app.fullTextSearching = false;
  app.fullTextError = '';
  app.searchContent = async () => { throw new Error('stale failure'); };

  await app.runFullTextSearch('old query', 6);
  assert.deepEqual(Array.from(app.fullTextResults, (item) => item.path), ['current.md']);
  assert.equal(app.fullTextError, '');
});

test('clears the debounce timer and invalidates pending requests when the panel closes', () => {
  const app = createHarness();
  app.searchTimer = setTimeout(() => {}, 10000);
  app.searchRequestId = 9;

  app.aboutToDisappear();
  assert.equal(app.searchTimer, -1);
  assert.equal(app.searchRequestId, 10);
});
