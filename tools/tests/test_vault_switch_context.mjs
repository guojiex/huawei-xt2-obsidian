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
    setCurrent(id) { calls.push(`set-current:${id}`); state.currentId = id; },
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
    quickSwitchOpen: true,
    quickSwitchFiles: ['recent.md'],
    recentOpenPaths: ['recent.md'],
    drawerOpen: true,
    smMode: 'preview',
    async flushWorkspaceSaves() {
      calls.push('flush');
      return options.flushSucceeds ?? true;
    },
    stopWorkspaceSessionSaving() { calls.push('stop-session'); },
    refreshFromRegistry() {
      calls.push('refresh');
      this.currentVaultId = registry.currentId();
    },
    async readAndPush(path) { calls.push(`clear-left:${path}`); },
    async readRightAndPush(path) { calls.push(`clear-right:${path}`); },
    flushWorkspaceSessionSave(force) { calls.push(`save-session:${force}`); return true; },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); }
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
