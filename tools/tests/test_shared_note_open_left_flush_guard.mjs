import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

const flushRightSave = (() => {
  const start = source.indexOf('  private async flushRightSave(');
  const end = source.indexOf('\n  private async loadFile(', start);
  assert.ok(start >= 0 && end > start, 'could not find flushRightSave source block');
  return source.slice(start, end).trim();
})();

const code = transformSync(`
class FlushRightSaveHarness {
  ${flushRightSave}
}
module.exports = FlushRightSaveHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function makeBridge(ready, text, revision) {
  return {
    ready,
    getContentSnapshot: async () => ({ text, revision })
  };
}

function makeSession(vaultId, path, baseline, revision) {
  return { isFor: (v, p) => v === vaultId && p === path, baseline, revision };
}

function runHarness(record) {
  const module = { exports: {} };
  const context = {
    module,
    exports: module.exports,
    WorkspaceEditGuard: { clear: (pane, vaultId, path) => record.workspaceGuardClears.push(pane) },
    NoteService: {
      saveNote: async (registry, vaultId, path, text, savedText) => {
        record.noteSaves.push({ vaultId, path, text, savedText });
      }
    },
    VaultRegistry: { get: () => 'registry-stub' },
    shouldShowSaveFeedback: () => false,
    hilog: { warn: () => {}, error: () => {} }
  };
  vm.runInContext(code, vm.createContext(context));
  return module.exports;
}

test('opening the right pane note into an empty left pane no longer flushes through the empty left bridge', async () => {
  // 场景（2026-11-18 用户反馈）：左栏空、右栏开 README.md，点左栏最近打开的 README。
  // loadFile 先把 currentFilePath 预写为 README.md 再 flushRightSave——修复前
  // targetPath === currentFilePath 使共享分支误判，sharedNoteEditor() 落到空左栏
  // （leftSession=null），会话守卫静默 return false，loadFile 无提示回滚＝点击无响应。
  const record = { workspaceGuardClears: [], noteSaves: [] };
  const Harness = runHarness(record);
  const app = new Harness();
  Object.assign(app, {
    applicationDataSnapshotInProgress: false,
    rightSaveTimer: -1,
    currentFilePath: 'README.md',
    rightFilePath: 'README.md',
    currentVaultId: 'vault-1',
    leftSession: null,
    rightSession: makeSession('vault-1', 'README.md', '正文', 7),
    leftComposing: false,
    rightComposing: false,
    editorDirty: false,
    rightEditorDirty: false,
    saveFeedbackRevision: 1,
    editorMismatchApprovalKey: '',
    editorBridge: makeBridge(true, '', -1),
    rightEditorBridge: makeBridge(true, '正文', 7),
    // 左栏无会话时不得咨询 sharedNoteEditor / 委托 flushSave。
    sharedNoteEditor: () => {
      throw new Error('sharedNoteEditor must not be consulted without a left session');
    },
    flushSave: async () => {
      throw new Error('flushSave must not be delegated without a left session');
    },
    persistEditorDraftSnapshot: async () => true,
    clearEditorDraftAfterSave: async () => {},
    clearStaleSaveNotice: () => {},
    showSaveFeedback: () => {},
    showFailureFeedback: () => {
      throw new Error('clean flush must not surface failure feedback');
    },
    showEditorMismatchRecovery: () => {
      throw new Error('clean flush must not trigger mismatch recovery');
    },
    refreshBacklinks: () => {}
  });

  // 右栏内容与基线一致（纯查看、无未保存编辑）：右栏自身会话路径直接放行。
  const ok = await app.flushRightSave('README.md', 'vault-1');
  assert.equal(ok, true, 'flush must succeed so loadFile can finish opening the note');
  assert.equal(app.rightEditorDirty, false);
  assert.deepEqual(record.noteSaves, []);
});

test('right pane with unsaved edits saves its own content when left pane is empty', async () => {
  const record = { workspaceGuardClears: [], noteSaves: [] };
  const Harness = runHarness(record);
  const app = new Harness();
  Object.assign(app, {
    applicationDataSnapshotInProgress: false,
    rightSaveTimer: -1,
    currentFilePath: 'README.md',
    rightFilePath: 'README.md',
    currentVaultId: 'vault-1',
    leftSession: null,
    rightSession: makeSession('vault-1', 'README.md', '旧正文', 7),
    leftComposing: false,
    rightComposing: false,
    editorDirty: false,
    rightEditorDirty: true,
    saveFeedbackRevision: 1,
    editorMismatchApprovalKey: '',
    editorBridge: makeBridge(true, '', -1),
    rightEditorBridge: makeBridge(true, '新正文', 7),
    sharedNoteEditor: () => {
      throw new Error('sharedNoteEditor must not be consulted without a left session');
    },
    flushSave: async () => {
      throw new Error('flushSave must not be delegated without a left session');
    },
    persistEditorDraftSnapshot: async () => true,
    clearEditorDraftAfterSave: async () => {},
    clearStaleSaveNotice: () => {},
    showSaveFeedback: () => {},
    showFailureFeedback: () => {
      throw new Error('save path must not surface failure feedback');
    },
    showEditorMismatchRecovery: () => {
      throw new Error('dirty save must not trigger mismatch recovery');
    },
    refreshBacklinks: () => {}
  });

  const ok = await app.flushRightSave('README.md', 'vault-1');
  assert.equal(ok, true);
  assert.equal(record.noteSaves.length, 1, 'right pane edits must be saved before the note loads on the left');
  assert.equal(record.noteSaves[0].text, '新正文');
  assert.equal(record.noteSaves[0].savedText, '旧正文');
  assert.equal(app.rightSession.baseline, '新正文');
});

test('genuine shared note (left session present) still delegates to the single active editor', async () => {
  const record = { workspaceGuardClears: [], noteSaves: [] };
  const Harness = runHarness(record);
  const app = new Harness();
  const delegations = [];
  Object.assign(app, {
    applicationDataSnapshotInProgress: false,
    rightSaveTimer: -1,
    currentFilePath: 'README.md',
    rightFilePath: 'README.md',
    currentVaultId: 'vault-1',
    leftSession: makeSession('vault-1', 'README.md', '正文', 3),
    rightSession: makeSession('vault-1', 'README.md', '正文', 7),
    leftComposing: false,
    rightComposing: false,
    editorBridge: makeBridge(true, '正文', 3),
    rightEditorBridge: makeBridge(true, '正文', 7),
    sharedNoteEditor: () => app.rightEditorBridge,
    flushSave: async (path, vaultId, bridge, showFeedback) => {
      delegations.push({ path, vaultId, bridge, showFeedback });
      return true;
    }
  });

  const ok = await app.flushRightSave('README.md', 'vault-1');
  assert.equal(ok, true);
  assert.equal(delegations.length, 1, 'a left session for the note must keep the shared delegation');
  assert.equal(delegations[0].bridge, app.rightEditorBridge);
  assert.equal(delegations[0].showFeedback, true);
});

test('source: flushRightSave delegation is guarded by the left pane session', () => {
  assert.match(
    source,
    /if \(targetPath === this\.currentFilePath && targetVaultId === this\.currentVaultId &&\s*\n\s*this\.leftSession !== null && this\.leftSession\.isFor\(targetVaultId, targetPath\)\) \{\s*\n\s*return await this\.flushSave\(targetPath, targetVaultId, this\.sharedNoteEditor\(\), showFeedback\);/
  );
});
