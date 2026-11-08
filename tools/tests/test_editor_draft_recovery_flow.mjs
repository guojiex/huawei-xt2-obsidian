import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function method(marker, nextMarker) {
  const start = source.indexOf(marker);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${marker}`);
  return source.slice(start, end).trim();
}

const methods = [
  method('  private isCurrentLeftOpenTarget(', '\n  private isCurrentRightOpenTarget('),
  method('  private isCurrentRightOpenTarget(', '\n  /**\n   * 读取笔记全文'),
  method('  private reportDraftRecovery(', '\n  private async refreshBacklinks()'),
  method('  private async readAndPush(', '\n  private async readRightAndPush('),
  method('  private async readRightAndPush(', '\n  private async loadRightFile(')
];
const code = transformSync(`class IndexHarness { ${methods.join('\n\n')} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    NoteService: { tryReadNote() { calls.push('formal-read'); return options.formalText ?? 'formal note'; } },
    NoteDraftService: {
      async recover(registry, vaultId, path, formalText) {
        calls.push(`draft-recover:${vaultId}:${path}`);
        if (options.recover) return await options.recover(formalText);
        return { recovered: false, conflict: false, content: formalText };
      }
    },
    VaultRegistry: { get: () => ({}) },
    WorkspaceEditGuard: { clear() {} },
    EditorNoteSession: class {
      constructor(vaultId, path, baseline, revision) {
        this.vaultId = vaultId;
        this.path = path;
        this.baseline = baseline;
        this.revision = revision;
      }
      isFor(vaultId, path) { return this.vaultId === vaultId && this.path === path; }
    },
    promptAction: { showToast(value) { calls.push(`toast:${value.message}`); } }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  const leftContent = [];
  const rightContent = [];
  Object.assign(app, {
    currentFilePath: 'note.md',
    rightFilePath: 'right.md',
    currentVaultId: 'vault-key',
    leftOpenRequestId: 4,
    rightOpenRequestId: 7,
    leftSession: null,
    rightSession: null,
    workspaceSessionRestoring: false,
    workspaceSessionSavingEnabled: false,
    activePane: 'left',
    topView: 'note',
    leftEditorScrollTop: 11,
    leftPreviewScrollTop: 12,
    rightEditorScrollTop: 21,
    rightPreviewScrollTop: 22,
    lastDraftRecoveryNoticeKey: '',
    editorBridge: {
      setNoteContext() {},
      async setContent(value) { calls.push('left-set'); leftContent.push(value); return 1; },
      restoreScrollTop() {}
    },
    rightEditorBridge: {
      setNoteContext() {},
      async setContent(value) { calls.push('right-set'); rightContent.push(value); return 1; },
      restoreScrollTop() {}
    },
    previewBridge: { resetDocument() {}, setNoteDir() {}, restoreScrollTop() {} },
    rightPreviewBridge: { resetDocument() {}, setNoteDir() {}, restoreScrollTop() {} },
    clearStaleSaveNotice() {},
    pushPreview(value) { calls.push(`left-preview:${value}`); },
    pushRightPreview(value) { calls.push(`right-preview:${value}`); },
    updateChapterEntries() {},
    async refreshSharedEditability() {},
    async refreshActiveChaptersFromBridge() {},
    applyRestoredChapterSelection() {},
    scheduleWorkspaceSessionSave() {},
    refreshBacklinks() {},
    scheduleSave() { calls.push('schedule-left-save'); },
    scheduleRightSave() { calls.push('schedule-right-save'); }
  });
  return { app, calls, leftContent, rightContent };
}

test('left pane restores a matching private draft over the formal baseline and schedules save', async () => {
  const { app, calls, leftContent } = createHarness({
    recover: async () => ({ recovered: true, conflict: false, content: 'recovered edit' })
  });

  assert.equal(await app.readAndPush('note.md', false, 4, 'vault-key', 7), true);
  assert.deepEqual(leftContent, ['recovered edit']);
  assert.equal(app.leftSession.baseline, 'formal note');
  assert.equal(app.editorDirty, true);
  assert.ok(calls.includes('left-preview:recovered edit'));
  assert.ok(calls.includes('schedule-left-save'));
  assert.ok(calls.includes('toast:已恢复上次未保存的修改'));
});

test('right pane restores a matching private draft and keeps the formal baseline', async () => {
  const { app, calls, rightContent } = createHarness({
    recover: async () => ({ recovered: true, conflict: false, content: 'right recovered edit' })
  });
  app.activePane = 'right';

  assert.equal(await app.readRightAndPush('right.md', 7, 'vault-key'), true);
  assert.deepEqual(rightContent, ['right recovered edit']);
  assert.equal(app.rightSession.baseline, 'formal note');
  assert.equal(app.rightEditorDirty, true);
  assert.ok(calls.includes('right-preview:right recovered edit'));
  assert.ok(calls.includes('schedule-right-save'));
});

test('a conflicting draft leaves the formal note visible and reports that the draft is retained', async () => {
  const { app, calls, leftContent } = createHarness({
    recover: async () => ({ recovered: false, conflict: true, content: 'formal note' })
  });

  assert.equal(await app.readAndPush('note.md', false, 4, 'vault-key', 7), true);
  assert.deepEqual(leftContent, ['formal note']);
  assert.equal(app.leftSession.baseline, 'formal note');
  assert.equal(app.editorDirty, false);
  assert.ok(calls.includes('toast:恢复草稿无法安全应用，已保留草稿'));
});

test('a late draft recovery cannot publish content after a newer note request', async () => {
  let completeRecovery;
  const { app, leftContent } = createHarness({
    recover: () => new Promise((resolve) => { completeRecovery = resolve; })
  });

  const opening = app.readAndPush('note.md', false, 4, 'vault-key', 7);
  await Promise.resolve();
  app.currentFilePath = 'newer.md';
  app.leftOpenRequestId++;
  completeRecovery({ recovered: true, conflict: false, content: 'stale draft' });

  assert.equal(await opening, false);
  assert.deepEqual(leftContent, []);
});
