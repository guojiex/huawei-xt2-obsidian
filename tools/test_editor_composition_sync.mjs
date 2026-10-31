import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url));
const methodNames = [
  ['syncLeftContentToRight', '  private async syncLeftContentToRight(): Promise<void> {', '\n  private async syncRightContentToLeft()'],
  ['syncRightContentToLeft', '  private async syncRightContentToLeft(): Promise<void> {', '\n  private onLeftCompositionChange('],
  ['onLeftCompositionChange', '  private onLeftCompositionChange(composing: boolean): void {', '\n  private onRightCompositionChange('],
  ['onRightCompositionChange', '  private onRightCompositionChange(composing: boolean): void {', '\n  /**\n   * 切换当前打开的文件']
];
const methods = methodNames.map(([name, startMarker, endMarker]) => {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index.${name}`);
  return source.slice(start, end).trim();
});
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
  refreshSharedEditability() {}
  pushPreview(text) { this.calls.push('left-preview:' + text); }
  pushRightPreview(text) { this.calls.push('right-preview:' + text); }
  updateChapterEntries() {}
}; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness() {
  const calls = [];
  const leftEditor = {
    ready: true,
    async getContent() { calls.push('left-read'); return 'left text'; },
    async setContent(text) { calls.push('left-set:' + text); }
  };
  const rightEditor = {
    ready: true,
    async getContent() { calls.push('right-read'); return 'right text'; },
    async setContent(text) { calls.push('right-set:' + text); }
  };
  const context = vm.createContext({
    module: { exports: {} },
    DOMAIN: 0,
    TAG: 'test',
    VaultRegistry: { get: () => ({}) },
    WikiLinkService: { files: () => [] },
    WikiLinkParser: { renderForPreview: (text) => text },
    WorkspaceEditGuard: { mark() {}, clear() {} },
    hilog: { warn() {} }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    calls,
    currentFilePath: 'shared.md',
    currentVaultId: 'local',
    rightFilePath: 'shared.md',
    editorBridge: leftEditor,
    rightEditorBridge: rightEditor,
    leftComposing: false,
    rightComposing: false,
    rightEditorDirty: true,
    editorDirty: false,
    activePane: 'left'
  });
  return { app, calls };
}

test('left-to-right mirroring does not set content in an editor still composing', async () => {
  const { app, calls } = createHarness();
  app.rightComposing = true;

  await app.syncLeftContentToRight();

  assert.ok(calls.includes('right-preview:left text'));
  assert.ok(!calls.some((call) => call.startsWith('right-set:')));
  assert.equal(app.rightEditorDirty, true);
});

test('right-to-left mirroring does not set content in an editor still composing', async () => {
  const { app, calls } = createHarness();
  app.leftComposing = true;

  await app.syncRightContentToLeft();

  assert.ok(calls.includes('left-preview:right text'));
  assert.ok(!calls.some((call) => call.startsWith('left-set:')));
  assert.equal(app.rightEditorDirty, false);
});

test('ending composition synchronizes the latest left source to the right editor', async () => {
  const { app, calls } = createHarness();
  app.leftComposing = true;

  app.onLeftCompositionChange(false);
  await new Promise((resolve) => setImmediate(resolve));

  assert.ok(calls.includes('right-set:left text'));
});

test('ending composition synchronizes the latest right source to the left editor', async () => {
  const { app, calls } = createHarness();
  app.rightComposing = true;

  app.onRightCompositionChange(false);
  await new Promise((resolve) => setImmediate(resolve));

  assert.ok(calls.includes('left-set:right text'));
});
