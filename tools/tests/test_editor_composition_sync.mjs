import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
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
    WorkspaceEditGuard: {
      mark(_pane, vaultId, path) { calls.push('guard-mark:' + vaultId + ':' + path); },
      clear(_pane, vaultId, path) { calls.push('guard-clear:' + vaultId + ':' + path); }
    },
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
    activePane: 'left',
    leftOpenRequestId: 1,
    rightOpenRequestId: 1
  });
  return { app, calls };
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
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

test('composition end alone does not mirror a possibly uncommitted input event', async () => {
  const { app, calls } = createHarness();
  app.leftComposing = true;

  app.onLeftCompositionChange(false);
  await new Promise((resolve) => setImmediate(resolve));

  assert.ok(!calls.some((call) => call.startsWith('right-set:')));
});

test('committed left change synchronizes after composition ended', async () => {
  const { app, calls } = createHarness();
  app.leftComposing = true;

  app.onLeftCompositionChange(false);
  await app.syncLeftContentToRight();

  assert.ok(calls.includes('right-set:left text'));
});

test('committed right change synchronizes after composition ended', async () => {
  const { app, calls } = createHarness();
  app.rightComposing = true;

  app.onRightCompositionChange(false);
  await app.syncRightContentToLeft();

  assert.ok(calls.includes('left-set:right text'));
});

test('left-to-right mirror drops content when the left note changes during the bridge read', async () => {
  const { app, calls } = createHarness();
  const content = deferred();
  app.editorBridge.getContent = () => {
    calls.push('left-read');
    return content.promise;
  };

  const syncing = app.syncLeftContentToRight();
  app.currentFilePath = 'next.md';
  app.leftOpenRequestId += 1;
  content.resolve('stale left text');
  await syncing;

  assert.deepEqual(calls, ['left-read']);
  assert.equal(app.rightEditorDirty, true);
});

test('right-to-left mirror drops content when the left note changes during the bridge read', async () => {
  const { app, calls } = createHarness();
  const content = deferred();
  app.rightEditorBridge.getContent = () => {
    calls.push('right-read');
    return content.promise;
  };

  const syncing = app.syncRightContentToLeft();
  app.currentFilePath = 'next.md';
  app.leftOpenRequestId += 1;
  content.resolve('stale right text');
  await syncing;

  assert.deepEqual(calls, ['right-read']);
  assert.equal(app.editorDirty, false);
  assert.equal(app.rightEditorDirty, true);
});

test('left-to-right mirror does not clear target state when its setContent completes late', async () => {
  const { app, calls } = createHarness();
  const write = deferred();
  app.rightEditorBridge.setContent = (text) => {
    calls.push('right-set:' + text);
    return write.promise;
  };

  const syncing = app.syncLeftContentToRight();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(calls.includes('right-set:left text'));
  app.rightFilePath = 'next.md';
  app.rightOpenRequestId += 1;
  write.resolve();
  await syncing;

  assert.ok(!calls.some((call) => call.startsWith('guard-clear:right:')));
  assert.equal(app.rightEditorDirty, true);
});

test('right-to-left mirror does not mark a new left target dirty when its setContent completes late', async () => {
  const { app, calls } = createHarness();
  const write = deferred();
  app.editorBridge.setContent = (text) => {
    calls.push('left-set:' + text);
    return write.promise;
  };

  const syncing = app.syncRightContentToLeft();
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(calls.includes('left-set:right text'));
  app.currentFilePath = 'next.md';
  app.leftOpenRequestId += 1;
  write.resolve();
  await syncing;

  assert.ok(!calls.some((call) => call.startsWith('guard-mark:left:')));
  assert.equal(app.editorDirty, false);
  assert.equal(app.rightEditorDirty, true);
});
