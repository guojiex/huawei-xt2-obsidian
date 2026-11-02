import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { test } from 'node:test';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

function extract(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find source block ${startMarker}`);
  return source.slice(start, end).trim();
}

const methods = [
  extract('  private async selectEditorExperience(', '\n  private setShowLineNumbers('),
  extract('  private async refreshSharedEditability(): Promise<void> {', '\n  private toggleActivePane()'),
  extract('  private previewBridgeForPane(pane: string): PreviewBridge {', '\n  private synchronizePreviewFollowContext('),
  extract('  private simpleWorkspacePane(): string {', '\n  @Builder\n  PaneModeButton('),
  extract('  private activeFilePath(): string {', '\n  private activeEditorBridge(): EditorBridge {')
];
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
  ensureEditorExperienceStore() {}
}; module.exports = IndexHarness;`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    promptAction: { showToast: ({ message }) => calls.push('toast:' + message) }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    calls,
    experienceMode: 'simple',
    leftComposing: false,
    rightComposing: false,
    workspaceOpenRequests: 0,
    leftOpenRequestId: 0,
    rightOpenRequestId: 0,
    sharedEditabilityGeneration: 0,
    currentVaultId: 'local',
    currentFilePath: 'left.md',
    rightFilePath: 'right.md',
    activePane: 'left',
    smMode: 'edit',
    rightEditing: false,
    editorExperienceStore: { save: (mode) => { calls.push('save:' + mode); return true; } },
    flushWorkspaceSaves: async () => { calls.push('flush'); return true; },
    refreshPreviewsForExperienceMode: async () => {},
    refreshSharedEditability: async () => { calls.push('refresh'); },
    notePaneWidth: () => 500,
    editorBridge: {
      ready: true,
      getContent: async () => 'left source',
      replaceContentFromPreview: async () => {},
      setEditable: async () => {},
      blur() {}
    },
    rightEditorBridge: {
      ready: true,
      getContent: async () => 'right source',
      replaceContentFromPreview: async () => {},
      setEditable: async () => {},
      blur() {}
    },
    previewBridge: { ready: true, requestEditableContent: async () => 'left source' },
    rightPreviewBridge: { ready: true, requestEditableContent: async () => 'right source' },
    leftSimplePreviewCommit: Promise.resolve(),
    rightSimplePreviewCommit: Promise.resolve()
  });
  return app;
}

test('a failed workspace flush keeps mode and preference unchanged', async () => {
  const app = createHarness();
  app.flushWorkspaceSaves = async () => { app.calls.push('flush'); return false; };

  await app.selectEditorExperience('professional');

  assert.equal(app.experienceMode, 'simple');
  assert.deepEqual(app.calls, ['flush', 'toast:笔记状态尚未就绪，编辑模式未更改']);
});

test('a pending note open prevents a mode switch from flushing an uncommitted target', async () => {
  const app = createHarness();
  app.workspaceOpenRequests = 1;

  await app.selectEditorExperience('professional');

  assert.equal(app.experienceMode, 'simple');
  assert.deepEqual(app.calls, ['toast:笔记正在切换，请稍后再切换编辑模式']);
});

test('composition that starts while flushing keeps the current mode and reports the block', async () => {
  const app = createHarness();
  app.flushWorkspaceSaves = async () => {
    app.calls.push('flush');
    app.leftComposing = true;
    return true;
  };

  await app.selectEditorExperience('professional');

  assert.equal(app.experienceMode, 'simple');
  assert.deepEqual(app.calls, ['flush', 'toast:请先完成当前输入，再切换编辑模式']);
});

test('switching mode retains the active note and leaves its text and scroll state untouched', async () => {
  const app = createHarness();
  app.activePane = 'right';
  app.leftEditorScrollTop = 120;
  app.rightEditorScrollTop = 280;
  app.lastSavedText = 'left source';
  app.rightLastSavedText = 'right source';
  const activePath = app.activeFilePath();

  await app.selectEditorExperience('professional');

  assert.equal(app.experienceMode, 'professional');
  assert.equal(app.activeFilePath(), activePath);
  assert.equal(app.leftEditorScrollTop, 120);
  assert.equal(app.rightEditorScrollTop, 280);
  assert.equal(app.lastSavedText, 'left source');
  assert.equal(app.rightLastSavedText, 'right source');
  assert.equal(app.leftOpenRequestId, 1);
  assert.equal(app.rightOpenRequestId, 1);
  assert.deepEqual(app.calls, ['flush', 'refresh', 'save:professional']);
});

test('a slow stale editability refresh cannot re-enable a pane after a newer mode state', async () => {
  const app = createHarness();
  app.refreshSharedEditability = Object.getPrototypeOf(app).refreshSharedEditability;
  let resolveOldRightDisable;
  const leftCalls = [];
  const rightCalls = [];
  let leftBlurCount = 0;
  let rightBlurCount = 0;
  app.experienceMode = 'professional';
  app.smMode = 'edit';
  app.rightEditing = false;
  app.editorBridge = {
    ready: true,
    setEditable: async (editable) => { leftCalls.push(editable); },
    blur: () => { leftBlurCount++; }
  };
  app.rightEditorBridge = {
    ready: true,
    setEditable: (editable) => {
      rightCalls.push(editable);
      if (editable === false && resolveOldRightDisable === undefined) {
        return new Promise((resolve) => { resolveOldRightDisable = resolve; });
      }
      return Promise.resolve();
    },
    blur: () => { rightBlurCount++; }
  };

  const oldRefresh = app.refreshSharedEditability();
  assert.deepEqual(rightCalls, [false]);
  app.smMode = 'preview';
  app.rightEditing = true;
  app.activePane = 'right';
  await app.refreshSharedEditability();
  resolveOldRightDisable();
  await oldRefresh;

  assert.deepEqual(leftCalls, [false]);
  assert.deepEqual(rightCalls, [false, true]);
  assert.equal(leftBlurCount, 1);
  assert.equal(rightBlurCount, 0);
});
