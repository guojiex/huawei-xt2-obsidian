import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function extract(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find source block ${startMarker}`);
  return source.slice(start, end).trim();
}

const methods = [
  extract('  private async flushRightSave(', '\n  private scheduleRightSave()'),
  extract('  private async flushSave(', '\n  /** Persist visible workspace content')
];
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
  sharedNoteEditor() { return this.rightEditorBridge; }
}; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness() {
  const calls = [];
  const leftEditor = {
    ready: true,
    async getContent() { calls.push('left-read'); return 'uncommitted candidate'; }
  };
  const rightEditor = {
    ready: true,
    async getContent() { calls.push('right-read'); return 'uncommitted candidate'; }
  };
  const writes = [];
  const context = vm.createContext({
    module: { exports: {} },
    clearTimeout() {},
    DOMAIN: 0,
    TAG: 'test',
    NoteService: { async saveNote(...args) { writes.push(args); } },
    VaultRegistry: { get: () => ({}) },
    WorkspaceEditGuard: { clear() {} },
    shouldShowSaveFeedback: () => false,
    promptAction: { showToast() {} },
    hilog: { warn() {} }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    calls,
    writes,
    currentFilePath: 'left.md',
    currentVaultId: 'local',
    rightFilePath: 'right.md',
    editorBridge: leftEditor,
    rightEditorBridge: rightEditor,
    leftComposing: false,
    rightComposing: false,
    saveTimer: -1,
    rightSaveTimer: -1,
    saveFeedbackRevision: 0,
    lastSavedText: 'saved-left',
    rightLastSavedText: 'saved-right',
    editorDirty: true,
    rightEditorDirty: true,
    topView: 'note'
  });
  return app;
}

test('left autosave does not read or write while its IME composition is active', async () => {
  const app = createHarness();
  app.leftComposing = true;

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
  assert.equal(app.lastSavedText, 'saved-left');
});

test('right autosave does not read or write while its IME composition is active', async () => {
  const app = createHarness();
  app.rightComposing = true;

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightLastSavedText, 'saved-right');
});

test('a shared note is not saved from either pane while either pane composes', async () => {
  const app = createHarness();
  app.rightFilePath = app.currentFilePath;
  app.leftComposing = true;

  assert.equal(await app.flushSave(app.currentFilePath, app.currentVaultId, app.rightEditorBridge), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
});
