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
    context,
    calls,
    writes,
    currentFilePath: 'left.md',
    currentVaultId: 'local',
    rightFilePath: 'right.md',
    editorBridge: leftEditor,
    rightEditorBridge: rightEditor,
    leftComposing: false,
    rightComposing: false,
    committedLeftPath: 'left.md',
    committedRightPath: 'right.md',
    committedLeftVaultId: 'local',
    committedRightVaultId: 'local',
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
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
  app.committedRightPath = app.currentFilePath;
  app.leftComposing = true;

  assert.equal(await app.flushSave(app.currentFilePath, app.currentVaultId, app.rightEditorBridge), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
});

test('left composition that begins during the editor read prevents the pending write', async () => {
  const app = createHarness();
  app.editorBridge.getContent = async () => {
    app.leftComposing = true;
    app.calls.push('left-read');
    return 'uncommitted candidate';
  };

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, ['left-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.lastSavedText, 'saved-left');
});

test('right composition that begins during the editor read prevents the pending write', async () => {
  const app = createHarness();
  app.rightEditorBridge.getContent = async () => {
    app.rightComposing = true;
    app.calls.push('right-read');
    return 'uncommitted candidate';
  };

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightLastSavedText, 'saved-right');
});

test('composition that begins in either shared-note editor during the read blocks the save', async () => {
  const app = createHarness();
  app.rightFilePath = app.currentFilePath;
  app.committedRightPath = app.currentFilePath;
  app.rightEditorBridge.getContent = async () => {
    app.leftComposing = true;
    app.calls.push('right-read');
    return 'uncommitted candidate';
  };

  assert.equal(await app.flushSave(app.currentFilePath, app.currentVaultId, app.rightEditorBridge), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
});

test('a save cannot read an editor while the visible target has not finished loading', async () => {
  const app = createHarness();
  app.currentFilePath = 'next.md';

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
});

test('an unmarked stale left editor value is rejected instead of overwriting the opened note', async () => {
  const app = createHarness();
  app.editorDirty = false;

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, ['left-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.lastSavedText, 'saved-left');
});

test('an unmarked stale right editor value is rejected instead of overwriting the opened note', async () => {
  const app = createHarness();
  app.rightEditorDirty = false;

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightLastSavedText, 'saved-right');
});

test('a save read that becomes stale during a note switch cannot write or replace the new baseline', async () => {
  const app = createHarness();
  let resolveContent;
  app.editorBridge.getContent = () => new Promise((resolve) => { resolveContent = resolve; });

  const saving = app.flushSave();
  await Promise.resolve();
  app.currentFilePath = 'next.md';
  app.committedLeftPath = 'next.md';
  app.leftOpenRequestId++;
  app.lastSavedText = 'next baseline';
  resolveContent('old pane candidate');

  assert.equal(await saving, false);
  assert.deepEqual(app.writes, []);
  assert.equal(app.lastSavedText, 'next baseline');
});

test('a completed old-target write cannot replace shared editor state after a newer note opens', async () => {
  const app = createHarness();
  let finishWrite;
  let notifyWriteStarted;
  const writeStarted = new Promise((resolve) => { notifyWriteStarted = resolve; });
  app.editorBridge.getContent = async () => 'old pane candidate';
  const context = app.context;
  context.NoteService.saveNote = (...args) => {
    app.writes.push(args);
    notifyWriteStarted();
    return new Promise((resolve) => { finishWrite = resolve; });
  };

  const saving = app.flushSave();
  await writeStarted;
  app.currentFilePath = 'next.md';
  app.committedLeftPath = 'next.md';
  app.leftOpenRequestId++;
  app.lastSavedText = 'next baseline';
  finishWrite();

  assert.equal(await saving, true);
  assert.equal(app.writes[0][2], 'left.md');
  assert.equal(app.lastSavedText, 'next baseline');
});
