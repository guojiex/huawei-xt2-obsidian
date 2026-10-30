import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const sessionSource = fs.readFileSync(new URL('../entry/src/main/ets/model/WorkspaceSessionStore.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async initializeWorkspaceSession(): Promise<void> {');
const end = source.indexOf('\n  private restoreWorkspaceScrollPositions(): void {', start);
assert.ok(start >= 0 && end > start, 'could not find Index.initializeWorkspaceSession');
const code = transformSync(`class WorkspaceSessionRestoreHarness {
  ${source.slice(start, end).trim()}
}; module.exports = WorkspaceSessionRestoreHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const helperStart = sessionSource.indexOf('export interface WorkspaceSession {');
const helperEnd = sessionSource.indexOf('\nexport class WorkspaceSessionStore', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find workspace session helpers');
const helperCode = transformSync(sessionSource.slice(helperStart, helperEnd).replace(/^export /gm, ''), {
  loader: 'ts',
  format: 'cjs'
}).code + '\nmodule.exports = { restoreWorkspacePane, workspaceSessionPaths };';
const helperModule = { exports: {} };
vm.runInContext(helperCode, vm.createContext({ module: helperModule, exports: helperModule.exports, JSON, Number }));
const { restoreWorkspacePane, workspaceSessionPaths } = helperModule.exports;

function session(overrides = {}) {
  return {
    schemaVersion: 1,
    vaultId: 'local',
    leftPath: '10_写作/old.md',
    rightPath: '20_样式/current.md',
    leftMode: 'edit',
    rightEditing: false,
    activePane: 'left',
    referenceVisible: true,
    sidebarCollapsed: true,
    drawerOpen: false,
    focused: false,
    sidebarTab: 'files',
    selectedChapterOffset: -1,
    leftEditorScrollTop: 0,
    leftPreviewScrollTop: 0,
    rightEditorScrollTop: 0,
    rightPreviewScrollTop: 0,
    ...overrides
  };
}

function createHarness({ session: savedSession = session(), vaultIds = ['local'], currentVaultId = 'local',
  validPaths = [], singleScreen = false, openLeft = true, openRight = true } = {}) {
  const events = [];
  const registry = {
    list: () => vaultIds.map((id) => ({ id })),
    currentId: () => currentVaultId,
    setCurrent: (id) => events.push(['set-current', id]),
    vaultDirOf: (id) => `/vaults/${id}`
  };
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => registry },
    FileTree: { allMarkdownFiles: () => validPaths },
    Breakpoint: { SM: 'sm' },
    restoreWorkspacePane,
    workspaceSessionPaths
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    pendingWorkspaceSession: savedSession,
    workspaceSessionRestoreStarted: false,
    workspaceSessionRestoring: false,
    workspaceSessionSavingEnabled: false,
    currentFilePath: 'stale-left.md',
    rightFilePath: 'stale-right.md',
    committedLeftPath: 'stale-left.md',
    committedRightPath: 'stale-right.md',
    breakpoint: 'md',
    isSingleScreenLayout: () => singleScreen,
    refreshFromRegistry: () => events.push(['refresh-registry']),
    setSidebarCollapsed: (value) => events.push(['sidebar-collapsed', value]),
    setDrawerOpen: (value) => events.push(['drawer-open', value]),
    readAndPush: async (path) => {
      events.push(['left', path]);
      if (path.length > 0 && openLeft instanceof Error) throw openLeft;
      return path.length === 0 || openLeft;
    },
    readRightAndPush: async (path) => {
      events.push(['right', path]);
      if (path.length > 0 && openRight instanceof Error) throw openRight;
      return path.length === 0 || openRight;
    },
    restoreWorkspaceScrollPositions: () => events.push(['restore-scroll']),
    applyRestoredChapterSelection: () => events.push(['restore-chapter']),
    scheduleWorkspaceSessionSave: () => events.push(['schedule-save'])
  });
  return { app, events };
}

test('a removed saved library clears both panes without opening paths from another library', async () => {
  const { app, events } = createHarness({
    session: session({ vaultId: 'deleted-vault' }),
    vaultIds: ['local'],
    validPaths: ['10_写作/old.md', '20_样式/current.md']
  });

  await app.initializeWorkspaceSession();

  assert.deepEqual(events.filter(([kind]) => kind === 'left' || kind === 'right'), [
    ['left', ''],
    ['right', '']
  ]);
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '');
  assert.equal(app.workspaceSessionSavingEnabled, false);
  assert.equal(events.some(([kind]) => kind === 'set-current'), false);
});

test('a moved or deleted pane falls back independently and does not match a same-name file elsewhere', async () => {
  const { app, events } = createHarness({
    validPaths: ['99_其他/old.md', '20_样式/current.md']
  });

  await app.initializeWorkspaceSession();

  assert.deepEqual(events.filter(([kind]) => kind === 'left' || kind === 'right'), [
    ['left', ''],
    ['right', '20_样式/current.md']
  ]);
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '20_样式/current.md');
  assert.equal(app.workspaceSessionSavingEnabled, true);
});

test('an unreadable pane clears locally while its readable sibling is restored', async () => {
  const { app, events } = createHarness({
    validPaths: ['10_写作/old.md', '20_样式/current.md'],
    openLeft: new Error('permission denied')
  });

  await app.initializeWorkspaceSession();

  assert.deepEqual(events.filter(([kind]) => kind === 'left' || kind === 'right'), [
    ['left', '10_写作/old.md'],
    ['left', ''],
    ['right', '20_样式/current.md']
  ]);
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '20_样式/current.md');
  assert.equal(app.workspaceSessionSavingEnabled, true);
});
