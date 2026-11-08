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
  extract('  private async persistEditorDraftSnapshot(', '\n  private async refreshBacklinks()'),
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

function makeSession(vaultId, path, baseline, revision) {
  return {
    vaultId,
    path,
    baseline,
    revision,
    isFor(otherVaultId, otherPath) {
      return this.vaultId === otherVaultId && this.path === otherPath;
    }
  };
}

function createHarness(options = {}) {
  const calls = [];
  const draftCalls = [];
  const leftEditor = {
    ready: true,
    async getContentSnapshot() { calls.push('left-read'); return { text: 'uncommitted candidate', revision: 1 }; }
  };
  const rightEditor = {
    ready: true,
    async getContentSnapshot() { calls.push('right-read'); return { text: 'uncommitted candidate', revision: 1 }; }
  };
  const writes = [];
  const context = vm.createContext({
    module: { exports: {} },
    clearTimeout() {},
    DOMAIN: 0,
    TAG: 'test',
    NoteService: { async saveNote(...args) { writes.push(args); } },
    NoteDraftService: {
      async persist(...args) {
        draftCalls.push(['persist', ...args.slice(1)]);
        if (options.draftPersist !== undefined) {
          return await options.draftPersist(...args);
        }
        return options.draftPersistResult === undefined ? true : options.draftPersistResult;
      },
      async clearIfMatches(...args) { draftCalls.push(['clear', ...args.slice(1)]); }
    },
    VaultRegistry: { get: () => ({}) },
    WorkspaceEditGuard: { clear() {} },
    shouldShowSaveFeedback: () => false,
    promptAction: { showToast() {} },
    hilog: { warn() {}, error() {} }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    context,
    calls,
    draftCalls,
    writes,
    currentFilePath: 'left.md',
    currentVaultId: 'local',
    rightFilePath: 'right.md',
    editorBridge: leftEditor,
    rightEditorBridge: rightEditor,
    leftComposing: false,
    rightComposing: false,
    leftSession: makeSession('local', 'left.md', 'saved-left', 1),
    rightSession: makeSession('local', 'right.md', 'saved-right', 1),
    saveTimer: -1,
    rightSaveTimer: -1,
    saveFeedbackRevision: 0,
    editorDirty: true,
    rightEditorDirty: true,
    topView: 'note',
    clearStaleSaveNotice() {},
    showSaveFeedback() {},
    showFailureFeedback(_operation, _phase, _category, _outcome, _nextStep, detail) {
      calls.push('failure-feedback:' + detail);
    },
    refreshBacklinks() {},
    handleEditorSaveError() { calls.push('save-error'); },
    showEditorMismatchRecovery(_vault, path) { calls.push('mismatch:' + path); }
  });
  return app;
}

test('left autosave does not read or write while its IME composition is active', async () => {
  const app = createHarness();
  app.leftComposing = true;

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, 'saved-left');
});

test('right autosave does not read or write while its IME composition is active', async () => {
  const app = createHarness();
  app.rightComposing = true;

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightSession.baseline, 'saved-right');
});

test('right pane saves a recovery draft before the vault write and clears it after success', async () => {
  const app = createHarness();

  assert.equal(await app.flushRightSave(), true);
  assert.equal(app.writes.length, 1);
  assert.deepEqual(app.draftCalls.map((call) => [call[0], ...call.slice(1, 3)]), [
    ['persist', 'local', 'right.md'],
    ['clear', 'local', 'right.md']
  ]);
  assert.equal(app.draftCalls[0][3], 'saved-right');
  assert.equal(app.draftCalls[0][4], 'uncommitted candidate');
  assert.equal(app.rightSession.baseline, 'uncommitted candidate');
  assert.equal(app.rightEditorDirty, false);
});

test('right pane keeps pending edits when the recovery draft cannot be persisted', async () => {
  const app = createHarness({ draftPersistResult: false });

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, [
    'right-read',
    'failure-feedback:恢复草稿未能安全写入；正式笔记未保存，当前编辑仍保留。请稍后重试。'
  ]);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightSession.baseline, 'saved-right');
  assert.equal(app.rightEditorDirty, true);
});

test('right pane keeps its persisted recovery draft when the formal write fails', async () => {
  const app = createHarness();
  app.context.NoteService.saveNote = async (...args) => {
    app.writes.push(args);
    throw new Error('controlled vault write failure');
  };

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.draftCalls.map((call) => call[0]), ['persist']);
  assert.equal(app.rightSession.baseline, 'saved-right');
  assert.equal(app.rightEditorDirty, true);
  assert.deepEqual(app.calls, ['right-read', 'save-error']);
});

test('a shared note is not saved from either pane while either pane composes', async () => {
  const app = createHarness();
  app.rightFilePath = app.currentFilePath;
  app.rightSession = makeSession('local', app.currentFilePath, 'saved-right', 1);
  app.leftComposing = true;

  assert.equal(await app.flushSave(app.currentFilePath, app.currentVaultId, app.rightEditorBridge), false);
  assert.deepEqual(app.calls, []);
  assert.deepEqual(app.writes, []);
});

test('left composition that begins during the editor read prevents the pending write', async () => {
  const app = createHarness();
  app.editorBridge.getContentSnapshot = async () => {
    app.leftComposing = true;
    app.calls.push('left-read');
    return { text: 'uncommitted candidate', revision: 1 };
  };

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, ['left-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, 'saved-left');
});

test('right composition that begins during the editor read prevents the pending write', async () => {
  const app = createHarness();
  app.rightEditorBridge.getContentSnapshot = async () => {
    app.rightComposing = true;
    app.calls.push('right-read');
    return { text: 'uncommitted candidate', revision: 1 };
  };

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightSession.baseline, 'saved-right');
});

test('unchanged mixed line endings do not block switching or rewrite the original note', async () => {
  const app = createHarness();
  app.editorDirty = false;
  app.leftSession = makeSession('local', 'left.md', 'first\r\nsecond\nthird', 1);
  app.editorBridge.getContentSnapshot = async () => ({ text: 'first\r\nsecond\r\nthird', revision: 1 });
  assert.equal(await app.flushSave(), true);
  assert.deepEqual(app.writes, []);
  assert.deepEqual(app.draftCalls, []);
  assert.equal(app.leftSession.baseline, 'first\r\nsecond\nthird');
});

test('unchanged mixed line endings do not block switching in the right pane', async () => {
  const app = createHarness();
  app.rightEditorDirty = false;
  app.rightSession = makeSession('local', 'right.md', 'first\r\nsecond\nthird', 1);
  app.rightEditorBridge.getContentSnapshot = async () => ({ text: 'first\r\nsecond\r\nthird', revision: 1 });
  assert.equal(await app.flushRightSave(), true);
  assert.deepEqual(app.writes, []);
  assert.deepEqual(app.draftCalls, []);
});

test('composition that begins in either shared-note editor during the read blocks the save', async () => {
  const app = createHarness();
  app.rightFilePath = app.currentFilePath;
  app.rightSession = makeSession('local', app.currentFilePath, 'saved-right', 1);
  app.rightEditorBridge.getContentSnapshot = async () => {
    app.leftComposing = true;
    app.calls.push('right-read');
    return { text: 'uncommitted candidate', revision: 1 };
  };

  assert.equal(await app.flushSave(app.currentFilePath, app.currentVaultId, app.rightEditorBridge), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
});

test('a save cannot reach the vault without an active session for the target note', async () => {
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
  assert.deepEqual(app.calls, ['left-read', 'mismatch:left.md']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, 'saved-left');
});

test('an unmarked stale right editor value is rejected instead of overwriting the opened note', async () => {
  const app = createHarness();
  app.rightEditorDirty = false;

  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, ['right-read', 'mismatch:right.md']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightSession.baseline, 'saved-right');
});

test('a save read that becomes stale during a note switch cannot write or replace the new baseline', async () => {
  const app = createHarness();
  let resolveSnapshot;
  app.editorBridge.getContentSnapshot = () => new Promise((resolve) => { resolveSnapshot = resolve; });

  const saving = app.flushSave();
  await Promise.resolve();
  app.leftSession = makeSession('local', 'next.md', 'next baseline', 2);
  resolveSnapshot({ text: 'old pane candidate', revision: 1 });

  assert.equal(await saving, false);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, 'next baseline');
});

test('a session swap during draft persistence prevents the old save from reaching the vault', async () => {
  let finishDraft;
  const app = createHarness({
    draftPersist: () => new Promise((resolve) => { finishDraft = resolve; })
  });

  const saving = app.flushSave();
  await new Promise((resolve) => setTimeout(resolve, 0));
  app.leftSession = makeSession('local', 'next.md', 'next baseline', 2);
  finishDraft(true);

  assert.equal(await saving, false);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, 'next baseline');
});

test('a completed old-target write cannot replace shared editor state after a newer note opens', async () => {
  const app = createHarness();
  let finishWrite;
  let notifyWriteStarted;
  const writeStarted = new Promise((resolve) => { notifyWriteStarted = resolve; });
  app.editorBridge.getContentSnapshot = async () => ({ text: 'old pane candidate', revision: 1 });
  const context = app.context;
  context.NoteService.saveNote = (...args) => {
    app.writes.push(args);
    notifyWriteStarted();
    return new Promise((resolve) => { finishWrite = resolve; });
  };

  const saving = app.flushSave();
  await writeStarted;
  app.leftSession = makeSession('local', 'next.md', 'next baseline', 2);
  finishWrite();

  assert.equal(await saving, true);
  assert.equal(app.writes[0][2], 'left.md');
  assert.equal(app.leftSession.baseline, 'next baseline');
});
