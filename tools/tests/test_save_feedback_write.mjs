import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const resetStart = source.indexOf('  private resetSaveFeedback(): void {');
const resetEnd = source.indexOf('\n  private hideSaveFeedback()', resetStart);
assert.ok(resetStart >= 0 && resetEnd > resetStart, 'could not find Index.resetSaveFeedback');
const resetSaveFeedbackMethod = source.slice(resetStart, resetEnd).trim();
const draftHelperStart = source.indexOf('  private async persistEditorDraftSnapshot(');
const draftHelperEnd = source.indexOf('\n  private async refreshBacklinks()', draftHelperStart);
assert.ok(draftHelperStart >= 0 && draftHelperEnd > draftHelperStart, 'could not find Index draft helpers');
const draftHelperMethods = source.slice(draftHelperStart, draftHelperEnd).trim();
const start = source.indexOf('  private async flushSave(targetPath: string | null = null, targetVaultId: string = \'\',');
const end = source.indexOf('\n  /** Persist visible workspace content', start);
assert.ok(start >= 0 && end > start, 'could not find Index.flushSave');
const flushSaveMethod = source.slice(start, end).trim();
const code = transformSync(`class IndexHarness { ${resetSaveFeedbackMethod} ${draftHelperMethods} ${flushSaveMethod} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
  const expectedVersions = [];
  let app;
  const editor = {
    ready: true,
    async getContent() {
      calls.push('read');
      if (options.readFails) {
        throw new Error('controlled editor read failure');
      }
      return options.content ?? 'new content';
    }
  };
  const context = vm.createContext({
    module: { exports: {} },
    DOMAIN: 0,
    TAG: 'test',
    VaultRegistry: { get: () => ({}) },
    NoteService: {
      async saveNote(registry, vaultId, path, content, expectedContent) {
        calls.push('write');
        expectedVersions.push(expectedContent);
        if (options.onWrite) {
          options.onWrite(app);
        }
        if (options.writeFails) {
          throw new Error('controlled note write failure');
        }
      }
    },
    NoteDraftService: {
      async persist(registry, vaultId, path, baseText, content) {
        calls.push('draft-persist');
        if (options.draftWriteFails) {
          throw new Error('controlled draft write failure');
        }
        return !options.draftConflict;
      },
      async clearIfMatches() {
        calls.push('draft-clear');
        if (options.draftClearFails) {
          throw new Error('controlled draft cleanup failure');
        }
      }
    },
    WorkspaceEditGuard: { mark() {}, clear() {} },
    shouldShowSaveFeedback(value) {
      return value.contentReadSucceeded && value.writeSucceeded && value.feedbackEnabled &&
        value.saveRevisionCurrent && value.noteViewActive && value.targetCurrent;
    },
    promptAction: { showToast(value) { calls.push(`toast:${value.message}`); } },
    hilog: { warn() { calls.push('warn'); } }
  });
  vm.runInContext(code, context);
  app = new context.module.exports();
  Object.assign(app, {
    currentFilePath: 'note.md',
    currentVaultId: 'local',
    rightFilePath: '',
    saveTimer: -1,
    saveFeedbackRevision: 0,
    lastSavedText: options.lastSavedText ?? 'old content',
    editorDirty: true,
    committedLeftPath: 'note.md',
    committedLeftVaultId: 'local',
    committedRightPath: '',
    committedRightVaultId: '',
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
    topView: 'note',
    editorBridge: editor,
    showSaveFeedback() { calls.push('save-success'); },
    hideSaveFeedback() { calls.push('hide-success'); },
    clearStaleSaveNotice() {},
    handleEditorSaveError() { calls.push('toast:保存失败'); },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); },
    refreshBacklinks() {}
  });
  return { app, calls, expectedVersions };
}

test('successful changed content shows feedback only after the note write resolves', async () => {
  const { app, calls, expectedVersions } = createHarness();

  assert.equal(await app.flushSave(), true);
  assert.deepEqual(calls, ['read', 'draft-persist', 'write', 'draft-clear', 'save-success']);
  assert.deepEqual(expectedVersions, ['old content']);
  assert.equal(app.lastSavedText, 'new content');
});

test('a rejected note write returns failure and never shows success feedback', async () => {
  const { app, calls } = createHarness({ writeFails: true });

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(calls, ['read', 'draft-persist', 'write', 'toast:保存失败']);
  assert.equal(app.lastSavedText, 'old content');
  assert.equal(app.editorDirty, true);
});

test('editor read failure and unchanged content both skip the write and success feedback', async () => {
  const readFailure = createHarness({ readFails: true });
  assert.equal(await readFailure.app.flushSave(), false);
  assert.deepEqual(readFailure.calls, ['read', 'warn', 'toast:保存失败，请稍后重试']);

  const unchanged = createHarness({ content: 'old content' });
  assert.equal(await unchanged.app.flushSave(), true);
  assert.deepEqual(unchanged.calls, ['read']);
});

test('a note that changes while the write is pending does not get success feedback', async () => {
  const { app, calls } = createHarness({
    onWrite(current) { current.currentFilePath = 'other.md'; }
  });

  assert.equal(await app.flushSave(), true);
  assert.deepEqual(calls, ['read', 'draft-persist', 'write', 'draft-clear']);
  assert.equal(app.lastSavedText, 'old content');
});

test('editing while the write is pending invalidates that save feedback', async () => {
  const { app, calls } = createHarness({
    onWrite(current) { current.resetSaveFeedback(); }
  });

  assert.equal(await app.flushSave(), true);
  assert.deepEqual(calls, ['read', 'draft-persist', 'write', 'hide-success', 'draft-clear']);
  assert.equal(app.lastSavedText, 'new content');
});

test('a failed draft write blocks the formal write and preserves pending editor state', async () => {
  const { app, calls } = createHarness({ draftWriteFails: true });

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(calls, ['read', 'draft-persist', 'toast:恢复草稿写入失败，笔记尚未保存']);
  assert.equal(app.lastSavedText, 'old content');
  assert.equal(app.editorDirty, true);
});

test('a conflicting recovery draft is not replaced by an automatic save', async () => {
  const { app, calls } = createHarness({ draftConflict: true });

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(calls, ['read', 'draft-persist', 'toast:恢复草稿无法安全更新，已暂停保存']);
  assert.equal(app.lastSavedText, 'old content');
  assert.equal(app.editorDirty, true);
});

test('draft cleanup failure does not report a failed formal save', async () => {
  const { app, calls } = createHarness({ draftClearFails: true });

  assert.equal(await app.flushSave(), true);
  assert.deepEqual(calls, ['read', 'draft-persist', 'write', 'draft-clear', 'warn', 'save-success']);
  assert.equal(app.lastSavedText, 'new content');
  assert.equal(app.editorDirty, false);
});
