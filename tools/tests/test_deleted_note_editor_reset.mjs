import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

function extractMethod(signature, nextMarker, modifier = 'private async') {
  const start = source.indexOf(`  ${modifier} ${signature}`);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${signature}`);
  return source.slice(start, end).trim();
}

const deletePathMethod = extractMethod('doDeletePath(relPath: string): Promise<void> {', '\n  /** 注册表操作失败');
const trashFileMethod = extractMethod('doTrashFile(relPath: string): Promise<void> {', '\n  /** 撤销条：弹出');
const undoRestoreMethod = extractMethod('undoTrashRestore(): Promise<void> {', '\n  /** 回收站视图「恢复」', 'private async');
const classSource = `class IndexHarness { ${deletePathMethod}\n${trashFileMethod}\n${undoRestoreMethod} }; module.exports = IndexHarness;`;
const code = transformSync(classSource, { loader: 'ts', format: 'cjs' }).code;

function createHarness(options = {}) {
  const calls = [];
  const shownUndos = [];
  const feedbackCalls = [];
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => ({}) },
    NoteService: {
      async deletePath(_registry, vaultId, path) {
        calls.push(`delete:${vaultId}:${path}`);
      }
    },
    TrashService: {
      async moveToTrash(_registry, vaultId, path) {
        calls.push(`trash:${vaultId}:${path}`);
        return path;
      },
      async restore(_registry, vaultId, path) {
        calls.push(`restore:${vaultId}:${path}`);
        if (options.restoreFails) {
          throw new Error('controlled restore conflict');
        }
      }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: options.currentFilePath ?? '',
    rightFilePath: options.rightFilePath ?? '',
    trashSeq: 0,
    async flushWorkspaceSaves() {
      calls.push('flush');
      return options.flushSucceeds ?? true;
    },
    resetSaveFeedback() { calls.push('reset-feedback'); },
    async readAndPush(path) { calls.push(`clear-left:${path}`); },
    async readRightAndPush(path) { calls.push(`clear-right:${path}`); },
    refreshFileTree() { calls.push('refresh-tree'); },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); },
    recordFailureFeedback(operation, phase, category, outcome, nextStep, detail, code, message) {
      feedbackCalls.push({ operation, phase, category, outcome, nextStep, detail, code, message });
      return options.echoFeedbackDetail ? detail : '安全失败反馈';
    },
    showUndo(message, snapshot) {
      calls.push('show-undo');
      shownUndos.push({ message, snapshot });
      app.undoSnap = snapshot;
    },
    hideUndo() { calls.push('hide-undo'); },
    loadFile(path) { calls.push(`load-left:${path}`); },
    loadRightFile(path) { calls.push(`load-right:${path}`); }
  });
  return { app, calls, shownUndos, feedbackCalls };
}

test('permanent deletion clears the left editor after deleting its selected subtree', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'folder/current.md', rightFilePath: 'keep.md' });
  await app.doDeletePath('folder');

  assert.deepEqual(calls, ['flush', 'reset-feedback', 'delete:local:folder', 'clear-left:', 'refresh-tree']);
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, 'keep.md');
});

test('moving the selected right note to trash clears its editor while preserving the left note', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'keep.md', rightFilePath: 'folder/current.md' });
  await app.doTrashFile('folder/current.md');

  assert.deepEqual(calls, [
    'flush', 'reset-feedback', 'trash:local:folder/current.md', 'clear-right:', 'refresh-tree', 'show-undo'
  ]);
  assert.equal(app.currentFilePath, 'keep.md');
  assert.equal(app.rightFilePath, '');
  assert.equal(app.undoSnap.vaultId, 'local');
  assert.equal(app.undoSnap.relPath, 'folder/current.md');
  assert.equal(app.undoSnap.wasCurrent, false);
  assert.equal(app.undoSnap.wasRight, true);

  await app.undoTrashRestore();
  assert.deepEqual(calls, [
    'flush', 'reset-feedback', 'trash:local:folder/current.md', 'clear-right:', 'refresh-tree', 'show-undo',
    'hide-undo', 'restore:local:folder/current.md', 'refresh-tree', 'load-right:folder/current.md'
  ]);
});

test('deleting an unrelated path leaves both editor buffers alone', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'keep.md', rightFilePath: 'also-keep.md' });
  await app.doDeletePath('other-folder');

  assert.deepEqual(calls, ['delete:local:other-folder', 'refresh-tree']);
  assert.equal(app.currentFilePath, 'keep.md');
  assert.equal(app.rightFilePath, 'also-keep.md');
});

test('undoing a right-only note deletion restores that note in the right pane', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'keep.md' });
  app.undoSnap = { vaultId: 'local', relPath: 'folder/removed.md', wasCurrent: false, wasRight: true };
  await app.undoTrashRestore();

  assert.deepEqual(calls, [
    'hide-undo', 'restore:local:folder/removed.md', 'refresh-tree', 'load-right:folder/removed.md'
  ]);
  assert.equal(app.trashSeq, 1);
});

test('undoing a note shared by both panes reopens it through the left shared-note path once', async () => {
  const { app, calls } = createHarness();
  app.undoSnap = { vaultId: 'local', relPath: 'shared.md', wasCurrent: true, wasRight: true };
  await app.undoTrashRestore();

  assert.deepEqual(calls, ['hide-undo', 'restore:local:shared.md', 'refresh-tree', 'load-left:shared.md']);
});

test('a restore conflict keeps the file untouched and replaces undo with a no-action notice', async () => {
  const { app, calls, shownUndos } = createHarness({ restoreFails: true });
  app.undoSnap = { vaultId: 'local', relPath: 'folder/removed.md', wasCurrent: true, wasRight: false };

  await app.undoTrashRestore();

  assert.deepEqual(calls, ['hide-undo', 'restore:local:folder/removed.md', 'show-undo']);
  assert.deepEqual(shownUndos, [{ message: '安全失败反馈', snapshot: null }]);
  assert.equal(app.undoSnap, null);
  assert.equal(app.trashSeq, 0);
});

test('a restore failure surfaces the real reason in the notice and the diagnostic record', async () => {
  const { app, calls, shownUndos, feedbackCalls } = createHarness({
    restoreFails: true,
    echoFeedbackDetail: true
  });
  app.undoSnap = { vaultId: 'local', relPath: 'folder/removed.md', wasCurrent: true, wasRight: false };

  await app.undoTrashRestore();

  assert.deepEqual(calls, ['hide-undo', 'restore:local:folder/removed.md', 'show-undo']);
  assert.deepEqual(shownUndos, [{ message: 'controlled restore conflict', snapshot: null }]);
  assert.deepEqual(feedbackCalls.map((recorded) => ({
    operation: recorded.operation,
    phase: recorded.phase,
    detail: recorded.detail,
    code: recorded.code,
    message: recorded.message
  })), [{
    operation: 'file',
    phase: 'restore_trash',
    detail: 'controlled restore conflict',
    code: -1,
    message: 'controlled restore conflict'
  }]);
  assert.equal(app.trashSeq, 0);
});
