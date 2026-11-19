import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import vm from 'node:vm';
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

const readAndPushSource = extract('  private async readAndPush(', '\n  private async readRightAndPush(');
const methods = [
  extract('  private isCurrentLeftOpenTarget(', '\n  private isCurrentRightOpenTarget('),
  extract('  private isCurrentRightOpenTarget(', '\n  /**\n   * 读取笔记全文'),
  extract('  private reportDraftRecovery(', '\n  private async refreshBacklinks()'),
  readAndPushSource
];
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
}; module.exports = IndexHarness;`, { loader: 'ts', format: 'cjs' }).code;

function createContext() {
  const module = { exports: {} };
  const calls = [];
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
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: 'a.md',
    leftOpenRequestId: 1,
    rightOpenRequestId: 0,
    rightPaneIntentionallyEmpty: false,
    leftSession: null,
    rightSession: null,
    activePane: 'left',
    workspaceSessionRestoring: false,
    topView: 'note',
    editorBridge: {
      setNoteContext() {},
      setContent: (text) => { calls.push('set:' + text); return 7; },
      restoreScrollTop() {}
    },
    previewBridge: {
      resetDocument: () => calls.push('preview-reset'),
      setNoteDir: () => calls.push('preview-dir'),
      restoreScrollTop() {}
    },
    pushPreview: () => calls.push('preview-push'),
    clearStaleSaveNotice() {},
    updateChapterEntries() {},
    refreshSharedEditability: async () => {},
    refreshActiveChaptersFromBridge: async () => {},
    applyRestoredChapterSelection() {},
    scheduleWorkspaceSessionSave() {},
    refreshBacklinks() {}
  });
  return { app, calls };
}

test('v1.88 88.1：右栏为空时左栏打开不再自动镜像（双栏空态点击只进激活栏）', async () => {
  const { app, calls } = createContext();
  const rightOpens = [];
  app.rightFilePath = '';
  app.readRightAndPush = async (path) => { rightOpens.push(path); return true; };

  assert.equal(await app.readAndPush('a.md', true, 1, 'local', 0), true);

  assert.equal(app.rightFilePath, '');
  assert.deepEqual(rightOpens, []);
  assert.ok(calls.includes('set:local:a.md'));
});

test('v1.88 88.1：rightPaneIntentionallyEmpty 为 false 也不镜像（关掉对 flag 的依赖）', async () => {
  const { app } = createContext();
  const rightOpens = [];
  app.rightFilePath = '';
  app.rightPaneIntentionallyEmpty = false;
  app.readRightAndPush = async (path) => { rightOpens.push(path); return true; };

  await app.readAndPush('a.md', true, 1, 'local', 0);

  assert.equal(app.rightFilePath, '');
  assert.deepEqual(rightOpens, []);
});

test('v1.88 88.2：同篇双栏打开时右栏基线同步保留', async () => {
  const { app } = createContext();
  const rightOpens = [];
  app.rightFilePath = 'a.md';
  app.rightSession = { isFor: () => true, baseline: 'old' };
  app.readRightAndPush = async (path, requestId, vaultId) => {
    rightOpens.push(`${path}:${requestId}:${vaultId}`);
    return true;
  };

  await app.readAndPush('a.md', true, 1, 'local', 0);

  assert.deepEqual(rightOpens, ['a.md:0:local']);
});

test('v1.88 88.1 源级 tripwire：readAndPush 不再预写 rightFilePath', () => {
  assert.ok(!/this\.rightFilePath\s*=(?![=>])/.test(readAndPushSource),
    'readAndPush must not assign rightFilePath (auto-mirror removed in v1.88)');
});

test('v1.88 源级 tripwire：镜像条件（右栏空 + 未显式置空）不再存在', () => {
  assert.ok(!/rightFilePath\.length === 0[\s\S]{0,80}rightPaneIntentionallyEmpty/.test(readAndPushSource),
    'the "right pane empty && not intentionally empty" auto-mirror condition must not come back');
});
