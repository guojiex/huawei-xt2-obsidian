import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async flushSave(targetPath: string | null = null, targetVaultId: string = \'\',');
const end = source.indexOf('\n  /** Persist visible workspace content', start);
assert.ok(start >= 0 && end > start, 'could not find Index.flushSave');
const flushSaveMethod = source.slice(start, end).trim();
const code = transformSync(`class IndexHarness { ${flushSaveMethod} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
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
      async saveNote() {
        calls.push('write');
        if (options.onWrite) {
          options.onWrite(app);
        }
        if (options.writeFails) {
          throw new Error('controlled note write failure');
        }
      }
    },
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
    topView: 'note',
    editorBridge: editor,
    showSaveFeedback() { calls.push('save-success'); },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); },
    refreshBacklinks() {}
  });
  return { app, calls };
}

test('successful changed content shows feedback only after the note write resolves', async () => {
  const { app, calls } = createHarness();

  assert.equal(await app.flushSave(), true);
  assert.deepEqual(calls, ['read', 'write', 'save-success']);
  assert.equal(app.lastSavedText, 'new content');
});

test('a rejected note write returns failure and never shows success feedback', async () => {
  const { app, calls } = createHarness({ writeFails: true });

  assert.equal(await app.flushSave(), false);
  assert.deepEqual(calls, ['read', 'write', 'toast:保存失败']);
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
  assert.deepEqual(calls, ['read', 'write']);
});
