import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methods = [
  ['scheduleWorkspaceSessionSave', '  private scheduleWorkspaceSessionSave(): void {',
    '\n  private flushWorkspaceSessionSave(force: boolean = false): boolean'],
  ['saveWorkspaceSessionNow', '  private saveWorkspaceSessionNow(force: boolean = false): boolean {', '\n  private isSingleLandscape()']
].map(([name, startMarker, endMarker]) => {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index.${name}`);
  return source.slice(start, end).trim();
});
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
  activeFilePath() { return this.activePane === 'right' ? this.rightFilePath : this.currentFilePath; }
  ensureWorkspaceSessionStore() {}
}; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(overrides = {}) {
  const timer = { nextId: 1, pending: null };
  const saved = [];
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout(callback, delay) {
      timer.pending = { id: timer.nextId++, callback, delay };
      return timer.pending.id;
    },
    clearTimeout(id) {
      if (timer.pending?.id === id) {
        timer.pending = null;
      }
    },
    hilog: { warn() {} }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    workspaceSessionSavingEnabled: true,
    workspaceSessionRestoring: false,
    workspaceSessionSaveTimer: -1,
    workspaceOpenRequests: 0,
    topView: 'note',
    currentVaultId: 'local',
    currentFilePath: 'left.md',
    rightFilePath: 'right.md',
    committedLeftPath: 'left.md',
    committedRightPath: 'right.md',
    smMode: 'edit',
    rightEditing: false,
    activePane: 'left',
    referenceVisible: true,
    sidebarCollapsed: false,
    drawerOpen: false,
    focused: false,
    sidebarTab: 'files',
    chapterPath: '',
    chapterEntries: [],
    selectedChapterIndex: -1,
    leftEditorScrollTop: 0,
    leftPreviewScrollTop: 0,
    rightEditorScrollTop: 0,
    rightPreviewScrollTop: 0,
    workspaceSessionStore: {
      save(session) {
        saved.push(JSON.parse(JSON.stringify(session)));
        return true;
      }
    },
    ...overrides
  });
  return { app, saved, timer };
}

function firePendingTimer(timer) {
  assert.ok(timer.pending, 'expected a scheduled workspace-session save');
  const pending = timer.pending;
  timer.pending = null;
  pending.callback();
}

test('an in-flight note open cannot replace the saved session before it commits', () => {
  const { app, saved, timer } = createHarness({
    currentFilePath: 'pending.md',
    workspaceOpenRequests: 1
  });

  app.scheduleWorkspaceSessionSave();
  app.saveWorkspaceSessionNow();

  assert.equal(timer.pending, null);
  assert.equal(saved.length, 0);

  app.currentFilePath = 'left.md';
  app.workspaceOpenRequests = 0;
  app.scheduleWorkspaceSessionSave();
  assert.equal(timer.pending.delay, 450);
  firePendingTimer(timer);

  assert.equal(saved.length, 1);
  assert.equal(saved[0].leftPath, 'left.md');
});

test('a committed note path is saved after the debounce settles', () => {
  const { app, saved, timer } = createHarness({
    currentFilePath: 'new.md',
    committedLeftPath: 'new.md'
  });

  app.scheduleWorkspaceSessionSave();
  firePendingTimer(timer);

  assert.equal(saved.length, 1);
  assert.equal(saved[0].leftPath, 'new.md');
  assert.equal(saved[0].rightPath, 'right.md');
});

test('disabled, restoring, secondary-view, or library-less states do not schedule or write', () => {
  for (const overrides of [
    { workspaceSessionSavingEnabled: false },
    { workspaceSessionRestoring: true },
    { topView: 'settings' },
    { currentVaultId: '' }
  ]) {
    const { app, saved, timer } = createHarness(overrides);
    app.scheduleWorkspaceSessionSave();
    app.saveWorkspaceSessionNow();
    assert.equal(timer.pending, null);
    assert.equal(saved.length, 0);
  }
});

test('a library switch can persist an empty workspace snapshot from a secondary view', () => {
  const { app, saved } = createHarness({
    topView: 'vaults',
    currentVaultId: 'personal',
    currentFilePath: '',
    rightFilePath: '',
    committedLeftPath: '',
    committedRightPath: ''
  });

  assert.equal(app.saveWorkspaceSessionNow(true), true);
  assert.equal(saved.length, 1);
  assert.equal(saved[0].vaultId, 'personal');
  assert.equal(saved[0].leftPath, '');
  assert.equal(saved[0].rightPath, '');
});
