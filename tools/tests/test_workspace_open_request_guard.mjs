import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { test } from 'node:test';

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
  extract('  private isCurrentLeftOpenTarget(', '\n  private isCurrentRightOpenTarget('),
  extract('  private isCurrentRightOpenTarget(', '\n  /**\n   * 读取笔记全文'),
  extract('  private reportDraftRecovery(', '\n  private async refreshBacklinks()'),
  extract('  private async readAndPush(', '\n  private async readRightAndPush('),
  extract('  private async readRightAndPush(', '\n  private async loadRightFile('),
  extract('  private async loadRightFile(', '\n  private async flushRightSave('),
  extract('  private async loadFile(', '\n  /**\n   * 立刻把编辑器当前内容落盘')
];
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
}; module.exports = IndexHarness;`, { loader: 'ts', format: 'cjs' }).code;

function createContext() {
  const module = { exports: {} };
  const calls = [];
  const restoredTransitions = [];
  let transitionRevision = 0;
  const context = vm.createContext({
    module,
    JSON,
    DOMAIN: 0,
    TAG: 'test',
    hilog: { warn() {}, error() {} },
    NoteService: { tryReadNote: (_registry, vault, path) => `${vault}:${path}` },
    NoteDraftService: {
      async recover(_registry, _vaultId, _path, formalText) {
        return { recovered: false, conflict: false, content: formalText };
      }
    },
    VaultRegistry: { get: () => ({}) },
    WorkspaceEditGuard: { clear() {}, mark() {} },
    EditorNoteSession: class {
      constructor(vaultId, path, baseline, revision) {
        this.vaultId = vaultId;
        this.path = path;
        this.baseline = baseline;
        this.revision = revision;
      }
      isFor(vaultId, path) { return this.vaultId === vaultId && this.path === path; }
    },
    promptAction: { showToast: ({ message }) => calls.push('toast:' + message) }
  });
  vm.runInContext(code, context);
  const app = new module.exports();
  app.editorBridge = {
    beginDocumentTransition: () => ++transitionRevision,
    restoreDocumentTransition: (revision) => restoredTransitions.push(revision),
    setNoteContext() {}
  };
  app.rightEditorBridge = {
    beginDocumentTransition: () => ++transitionRevision,
    restoreDocumentTransition: (revision) => restoredTransitions.push(revision),
    setNoteContext() {}
  };
  return { context, calls, app, restoredTransitions };
}

test('a slower earlier left-pane open cannot publish its note after a newer request', async () => {
  const { app, calls, restoredTransitions } = createContext();
  const flushes = new Map();
  const reads = [];
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'a.md',
    rightFilePath: '',
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
    workspaceOpenRequests: 0,
    resetSaveFeedback() {},
    flushSave: (path) => new Promise((resolve) => flushes.set(path, resolve)),
    flushRightSave: async () => true,
    readAndPush: async (path) => { reads.push(path); return true; },
    scheduleSave() {},
    scheduleWorkspaceSessionSave() {},
    recordPaneOpened: (_vault, path) => calls.push('recent:' + path)
  });

  const openingB = app.loadFile('b.md');
  await Promise.resolve();
  const openingC = app.loadFile('c.md');
  await Promise.resolve();

  flushes.get('b.md')(true);
  await openingC;
  flushes.get('a.md')(true);
  await openingB;

  assert.deepEqual(reads, ['c.md']);
  assert.equal(app.currentFilePath, 'c.md');
  assert.equal(app.workspaceOpenRequests, 0);
  assert.deepEqual(calls, ['recent:c.md']);
  assert.deepEqual(restoredTransitions, []);
});

test('a failed left-pane open rolls the editor notification revision back with the visible note', async () => {
  const { app, restoredTransitions } = createContext();
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'a.md',
    rightFilePath: '',
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
    workspaceOpenRequests: 0,
    resetSaveFeedback() {},
    flushSave: async () => false,
    flushRightSave: async () => true,
    scheduleSave() {},
    scheduleWorkspaceSessionSave() {}
  });

  await app.loadFile('b.md');

  assert.equal(app.currentFilePath, 'a.md');
  assert.deepEqual(restoredTransitions, [1]);
  assert.equal(app.workspaceOpenRequests, 0);
});

test('a failed right-pane open rolls the editor notification revision back with the visible note', async () => {
  const { app, restoredTransitions } = createContext();
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'left.md',
    rightFilePath: 'right-a.md',
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
    workspaceOpenRequests: 0,
    resetSaveFeedback() {},
    flushRightSave: async () => false,
    scheduleWorkspaceSessionSave() {}
  });

  await app.loadRightFile('right-b.md');

  assert.equal(app.rightFilePath, 'right-a.md');
  assert.deepEqual(restoredTransitions, [1]);
  assert.equal(app.workspaceOpenRequests, 0);
});

test('a stale bridge setContent completion cannot publish preview and is refused by save-time revision checks', async () => {
  const { app, context, calls } = createContext();
  let resolveSetContent;
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'a.md',
    rightFilePath: '',
    leftOpenRequestId: 4,
    rightOpenRequestId: 0,
    leftSession: null,
    workspaceSessionRestoring: false,
    workspaceSessionSavingEnabled: true,
    topView: 'note',
    editorBridge: {
      setNoteContext() {},
      setContent: (text) => {
        calls.push('set:' + text);
        return new Promise((resolve) => { resolveSetContent = resolve; });
      },
      restoreScrollTop() {}
    },
    previewBridge: {
      resetDocument: () => calls.push('preview-reset'),
      setNoteDir: () => calls.push('preview-dir'),
      restoreScrollTop() {}
    },
    pushPreview: () => calls.push('preview-push'),
    clearStaleSaveNotice() {},
    refreshSharedEditability: async () => {},
    refreshActiveChaptersFromBridge: async () => {},
    applyRestoredChapterSelection() {},
    scheduleWorkspaceSessionSave() {},
    refreshBacklinks() {}
  });
  context.WorkspaceEditGuard = { clear: () => calls.push('guard-clear') };

  const opening = app.readAndPush('a.md', false);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, ['guard-clear', 'set:local:a.md']);
  app.currentFilePath = 'b.md';
  app.leftOpenRequestId = 5;
  resolveSetContent(9);

  assert.equal(await opening, false);
  // 会话镜像编辑器现实：编辑器确实持有 a.md 的第 9 代内容，会话如实记录；
  // 但它已不是当前目标（b.md），保存链的 isFor 校验会拒绝这次写入，预览也不再发布。
  assert.equal(app.leftSession.path, 'a.md');
  assert.equal(app.leftSession.revision, 9);
  assert.ok(!calls.includes('preview-push'));
  assert.ok(!app.leftSession.isFor('local', 'b.md'));
});

test('an implicit right-pane refresh cannot publish content after a newer right target opens', async () => {
  const { app, context, calls } = createContext();
  let resolveSetContent;
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'left.md',
    rightFilePath: 'right-a.md',
    leftOpenRequestId: 0,
    rightOpenRequestId: 4,
    rightSession: null,
    workspaceSessionRestoring: false,
    workspaceSessionSavingEnabled: true,
    topView: 'note',
    rightEditorBridge: {
      setNoteContext() {},
      setContent: (text) => {
        calls.push('set-right:' + text);
        return new Promise((resolve) => { resolveSetContent = resolve; });
      },
      restoreScrollTop() {}
    },
    rightPreviewBridge: {
      resetDocument: () => calls.push('right-preview-reset'),
      setNoteDir: () => calls.push('right-preview-dir'),
      restoreScrollTop() {}
    },
    pushRightPreview: () => calls.push('right-preview-push'),
    clearStaleSaveNotice() {},
    refreshSharedEditability: async () => {},
    refreshActiveChaptersFromBridge: async () => {},
    applyRestoredChapterSelection() {},
    scheduleWorkspaceSessionSave() {}
  });
  context.WorkspaceEditGuard = { clear: () => calls.push('guard-clear') };

  const opening = app.readRightAndPush('right-a.md');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, ['guard-clear', 'set-right:local:right-a.md']);
  app.rightFilePath = 'right-b.md';
  app.rightOpenRequestId = 5;
  resolveSetContent(9);

  assert.equal(await opening, false);
  // 同左栏：会话如实记录被取代的加载（right-a.md@9），保存链按 isFor 拒绝写入。
  assert.equal(app.rightSession.path, 'right-a.md');
  assert.equal(app.rightSession.revision, 9);
  assert.ok(!calls.includes('right-preview-push'));
  assert.ok(!app.rightSession.isFor('local', 'right-b.md'));
});
