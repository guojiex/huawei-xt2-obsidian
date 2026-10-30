import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private restoreWorkspaceScrollPositions(): void {');
const end = source.indexOf('\n  private applyRestoredChapterSelection(): void {', start);
assert.ok(start >= 0 && end > start, 'could not find Index.restoreWorkspaceScrollPositions');
const code = transformSync(`class ScrollRestoreHarness {
  ${source.slice(start, end).trim()}
}; module.exports = ScrollRestoreHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(calls, overrides = {}) {
  const context = vm.createContext({
    module: { exports: {} },
    DOMAIN: 1,
    TAG: 'Index',
    hilog: { warn: (...args) => calls.warnings.push(args) }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    leftEditorScrollTop: 12.5,
    leftPreviewScrollTop: 24.5,
    rightEditorScrollTop: 36.5,
    rightPreviewScrollTop: 48.5,
    editorBridge: { restoreScrollTop: (top) => calls.restored.push(['left-edit', top]) },
    previewBridge: { restoreScrollTop: (top) => calls.restored.push(['left-preview', top]) },
    rightEditorBridge: { restoreScrollTop: (top) => calls.restored.push(['right-edit', top]) },
    rightPreviewBridge: { restoreScrollTop: (top) => calls.restored.push(['right-preview', top]) },
    ...overrides
  });
  return app;
}

test('session restores each pane and mode scroll position to its matching bridge', () => {
  const calls = { restored: [], warnings: [] };
  const app = createHarness(calls);

  app.restoreWorkspaceScrollPositions();

  assert.deepEqual(calls.restored, [
    ['left-edit', 12.5],
    ['left-preview', 24.5],
    ['right-edit', 36.5],
    ['right-preview', 48.5]
  ]);
  assert.equal(calls.warnings.length, 0);
});

test('a left pane restore failure does not block restoring the right pane', () => {
  const calls = { restored: [], warnings: [] };
  const app = createHarness(calls, {
    editorBridge: {
      restoreScrollTop: () => {
        throw new Error('left editor unavailable');
      }
    }
  });

  app.restoreWorkspaceScrollPositions();

  assert.deepEqual(calls.restored, [
    ['right-edit', 36.5],
    ['right-preview', 48.5]
  ]);
  assert.equal(calls.warnings.length, 1);
  assert.equal(calls.warnings[0][2], '恢复左栏滚动位置失败');
});
