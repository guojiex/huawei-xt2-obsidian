import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function extractMethod(signature, nextMarker, modifier) {
  const start = source.indexOf(`  ${modifier} ${signature}`);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${signature}`);
  return source.slice(start, end).trim();
}

const adoptVaultMethod = extractMethod('adoptExternalVaultSwitch(): Promise<void> {', '\n  /** 当前库名', 'private async');
const switchVaultMethod = extractMethod('switchVault(id: string): Promise<void> {', '\n  private doCreateVault', 'private async');
const createVaultMethod = extractMethod('doCreateVault(name: string): void {', '\n  private doRenameVault', 'private');
const code = transformSync(
  `class IndexHarness { ${adoptVaultMethod}\n${switchVaultMethod}\n${createVaultMethod} }; module.exports = IndexHarness;`,
  { loader: 'ts', format: 'cjs' }
).code;

function createHarness(options = {}) {
  const calls = [];
  const state = { currentId: options.registryCurrentId ?? 'local' };
  const registry = {
    currentId() { return state.currentId; },
    setCurrent(id) {
      calls.push(`set-current:${id}`);
      if (options.setCurrentFails) throw new Error('registry write failed');
      state.currentId = id;
    },
    createLocal(name) { calls.push(`create:${name}`); return { id: options.createdId ?? 'temporary' }; }
  };
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => registry }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    currentVaultId: options.currentVaultId ?? 'local',
    currentFilePath: options.currentFilePath ?? 'left.md',
    rightFilePath: options.rightFilePath ?? 'right.md',
    topView: options.topView ?? 'note',
    workspaceSessionSavingEnabled: options.workspaceSessionSavingEnabled ?? true,
    quickSwitchOpen: true,
    quickSwitchFiles: ['recent.md'],
    recentOpenPaths: ['recent.md'],
    drawerOpen: options.drawerOpen ?? false,
    // 36d9bdf 起 adoptExternalVaultSwitch 经 setDrawerOpen 同步 drawerProgress，不再直写 drawerOpen
    setDrawerOpen(open) { this.drawerOpen = open; },
    // v1.47 47.4 switchVault 先取目标库工作区会话：无历史会话走原「清空双栏」路径，
    // 有会话则经共用 applyWorkspaceSession 恢复目标库左右栏笔记与布局状态
    ensureWorkspaceSessionStore() {},
    workspaceSessionStore: { loadFor() { return options.session ?? null; } },
    applyWorkspaceSession(session) { calls.push(`apply-session:${session.vaultId}`); return true; },
    // 47.4 回滚路径经同步器恢复侧栏/抽屉并重放滚动位置
    setSidebarCollapsed(collapsed) { this.sidebarCollapsed = collapsed; },
    restoreWorkspaceScrollPositions() {},
    smMode: 'preview',
    async flushWorkspaceSaves() {
      calls.push('flush');
      if (options.flushPending) {
        return await options.flushPending;
      }
      return options.flushSucceeds ?? true;
    },
    stopWorkspaceSessionSaving() {
      calls.push('stop-session');
      this.workspaceSessionSavingEnabled = false;
    },
    scheduleWorkspaceSessionSave() { calls.push('schedule-session'); },
    async refreshSharedEditability() {},
    refreshFromRegistry() {
      calls.push('refresh');
      this.currentVaultId = registry.currentId();
    },
    async readAndPush(path) {
      calls.push(`clear-left:${path}`);
      if (path.length === 0 && options.clearLeftFails) {
        throw new Error('controlled left workspace clear failure');
      }
      if (path === 'source.md' && options.restoreLeftFails) {
        throw new Error('controlled left workspace restore failure');
      }
      return true;
    },
    async readRightAndPush(path) {
      calls.push(`clear-right:${path}`);
      return true;
    },
    flushWorkspaceSessionSave(force) { calls.push(`save-session:${force}`); return true; },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); },
    showFailureFeedback(operation, phase, category, outcome, nextStep, detail) {
      calls.push(`failure:${operation}:${phase}:${category}:${outcome}:${nextStep}:${detail}`);
    }
  });
  if (options.stubSwitch) {
    app.switchVault = (id) => { calls.push(`switch:${id}`); };
  }
  return { app, calls, state };
}

test('creating a local vault uses the normal switch flow', () => {
  const { app, calls, state } = createHarness({ topView: 'vaults', stubSwitch: true });
  app.doCreateVault('temporary');

  assert.deepEqual(calls, ['create:temporary', 'switch:temporary']);
  assert.equal(state.currentId, 'local');
});

test('switching vaults clears both persistent editor buffers, including from a secondary view', async () => {
  const { app, calls, state } = createHarness({ topView: 'vaults' });
  await app.switchVault('temporary');

  assert.deepEqual(calls, [
    'stop-session', 'set-current:temporary', 'refresh', 'clear-left:', 'clear-right:', 'save-session:true'
  ]);
  assert.equal(state.currentId, 'temporary');
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '');
  assert.equal(app.quickSwitchOpen, false);
  assert.deepEqual(Array.from(app.quickSwitchFiles), []);
  assert.deepEqual(Array.from(app.recentOpenPaths), []);
  assert.equal(app.drawerOpen, false);
  assert.equal(app.smMode, 'edit');
});

test('switching from an open single-screen navigation keeps the new vault file list open', async () => {
  const { app, calls, state } = createHarness({ topView: 'note', drawerOpen: true });
  await app.switchVault('temporary');

  assert.equal(state.currentId, 'temporary');
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '');
  assert.equal(app.drawerOpen, true);
  assert.deepEqual(calls.slice(-3), ['clear-left:', 'clear-right:', 'save-session:true']);
});

test('a failed pending save keeps the current vault, note paths, and open navigation intact', async () => {
  const { app, calls, state } = createHarness({
    currentFilePath: 'source.md',
    rightFilePath: 'source-right.md',
    drawerOpen: true,
    flushSucceeds: false
  });

  await app.switchVault('temporary');

  assert.deepEqual(calls, ['flush']);
  assert.equal(state.currentId, 'local');
  assert.equal(app.currentVaultId, 'local');
  assert.equal(app.currentFilePath, 'source.md');
  assert.equal(app.rightFilePath, 'source-right.md');
  assert.equal(app.drawerOpen, true);
  assert.equal(app.workspaceSessionSavingEnabled, true);
});

test('a registry switch error keeps the old workspace and resumes session saving', async () => {
  const { app, calls, state } = createHarness({
    currentFilePath: 'source.md',
    rightFilePath: 'source-right.md',
    drawerOpen: true,
    setCurrentFails: true
  });

  await app.switchVault('temporary');

  assert.deepEqual(calls, [
    'flush', 'stop-session', 'set-current:temporary', 'schedule-session', 'toast:切换库失败'
  ]);
  assert.equal(state.currentId, 'local');
  assert.equal(app.currentVaultId, 'local');
  assert.equal(app.currentFilePath, 'source.md');
  assert.equal(app.rightFilePath, 'source-right.md');
  assert.equal(app.drawerOpen, true);
  assert.equal(app.workspaceSessionSavingEnabled, true);
});

test('a workspace clear failure rolls back the library and restores both saved notes', async () => {
  const { app, calls, state } = createHarness({
    currentFilePath: 'source.md',
    rightFilePath: 'source-right.md',
    clearLeftFails: true
  });

  await app.switchVault('temporary');

  assert.equal(state.currentId, 'local');
  assert.equal(app.currentVaultId, 'local');
  assert.equal(app.currentFilePath, 'source.md');
  assert.equal(app.rightFilePath, 'source-right.md');
  assert.equal(app.workspaceSessionSavingEnabled, true);
  assert.ok(calls.includes('clear-left:source.md'));
  assert.ok(calls.includes('clear-right:source-right.md'));
  assert.match(calls.at(-1), /^failure:vault:switch:unknown:not_completed:retry:/);
});

test('a failed workspace rollback leaves session saving disabled and asks the user to reopen notes', async () => {
  const { app, calls, state } = createHarness({
    currentFilePath: 'source.md',
    rightFilePath: 'source-right.md',
    clearLeftFails: true,
    restoreLeftFails: true
  });

  await app.switchVault('temporary');

  assert.equal(state.currentId, 'local');
  assert.equal(app.currentVaultId, 'local');
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '');
  assert.equal(app.workspaceSessionSavingEnabled, false);
  assert.match(calls.at(-1), /^failure:vault:switch:unknown:status_unknown:check_status:/);
  assert.match(calls.at(-1), /从文件树重新打开笔记/);
});

test('a second switch request is ignored while the first is saving', async () => {
  let releaseFlush;
  const flushPending = new Promise(resolve => { releaseFlush = resolve; });
  const { app, calls, state } = createHarness({ flushPending });

  const firstSwitch = app.switchVault('temporary');
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(app.vaultSwitchInProgress, true);

  await app.switchVault('another');
  assert.equal(calls.filter(call => call === 'flush').length, 1);
  releaseFlush(true);
  await firstSwitch;

  assert.equal(state.currentId, 'temporary');
});

test('external vault changes clear both persistent editor buffers', async () => {
  const { app, calls, state } = createHarness({ registryCurrentId: 'external' });
  await app.adoptExternalVaultSwitch();

  assert.deepEqual(calls, [
    'flush', 'stop-session', 'refresh', 'clear-left:', 'clear-right:', 'save-session:true'
  ]);
  assert.equal(state.currentId, 'external');
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, '');
});

test('switching to a vault with a stored session restores its workspace instead of clearing', async () => {
  const { app, calls, state } = createHarness({
    topView: 'vaults',
    session: { vaultId: 'temporary', leftPath: 'left.md', rightPath: 'right.md' }
  });
  await app.switchVault('temporary');

  assert.deepEqual(calls, [
    'stop-session', 'set-current:temporary', 'refresh', 'apply-session:temporary', 'save-session:true'
  ]);
  assert.equal(state.currentId, 'temporary');
  // 恢复路径不得先清空再载入：无 clear-left / clear-right 调用
  assert.ok(!calls.some(call => call.startsWith('clear-left:') || call.startsWith('clear-right:')));
  assert.equal(app.workspaceSessionSavingEnabled, true);
});

test('external vault changes with a stored session restore it as well', async () => {
  const { app, calls, state } = createHarness({
    registryCurrentId: 'external',
    session: { vaultId: 'external', leftPath: 'left.md', rightPath: '' }
  });
  await app.adoptExternalVaultSwitch();

  assert.deepEqual(calls, [
    'flush', 'stop-session', 'refresh', 'apply-session:external', 'save-session:true'
  ]);
  assert.equal(state.currentId, 'external');
  assert.ok(!calls.some(call => call.startsWith('clear-left:') || call.startsWith('clear-right:')));
});
