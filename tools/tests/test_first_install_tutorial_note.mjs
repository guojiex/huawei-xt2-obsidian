import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async initializeWorkspaceSession(): Promise<void> {');
const end = source.indexOf('\n  private restoreWorkspaceScrollPositions(): void {', start);
assert.ok(start >= 0 && end > start, 'could not find workspace initialization method');
const method = source.slice(start, end).replace('  private async initializeWorkspaceSession()',
  '  async initializeWorkspaceSession()');
const durationStart = source.indexOf('  private workspaceTransitionDuration(): number {');
const durationEnd = source.indexOf('\n  private setDrawerOpen(', durationStart);
assert.ok(durationStart >= 0 && durationEnd > durationStart, 'could not find workspace transition duration method');
const durationMethod = source.slice(durationStart, durationEnd).replace('  private workspaceTransitionDuration()',
  '  workspaceTransitionDuration()');
const code = transformSync(`class IndexHarness { ${durationMethod} ${method} }\nmodule.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const switchStart = source.indexOf('  private async switchVault(id: string): Promise<void> {');
const switchEnd = source.indexOf('\n  private doCreateVault(name: string): void {', switchStart);
assert.ok(switchStart >= 0 && switchEnd > switchStart, 'could not find vault switch method');
const switchMethod = source.slice(switchStart, switchEnd).replace('  private async switchVault',
  '  async switchVault');
const switchCode = transformSync(`class VaultSwitchHarness { ${switchMethod} }\nmodule.exports = VaultSwitchHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness({ readable = true, saved = true, onRead = null, onWait = null } = {}) {
  const calls = [];
  const registry = {
    firstInstallNotePath: () => '00_开始/快速上手.md',
    currentId: () => 'tutorial',
    markFirstInstallNoteOpened: () => { calls.push('mark-opened'); return true; }
  };
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => registry },
    SAMPLE_VAULT_ID: 'tutorial',
    Motion: { durNav: 240 }
  });
  vm.runInContext(code, context);
  const IndexHarness = context.module.exports;
  const index = new IndexHarness();
  index.workspaceSessionRestoreStarted = false;
  index.pendingWorkspaceSession = null;
  index.navigationAnimationsEnabled = false;
  index.workspaceInitialRenderReady = false;
  index.splitDragging = false;
  index.currentFilePath = '';
  index.waitForInitialWorkspaceSurfaces = async () => {
    if (typeof onWait === 'function') await onWait();
  };
  index.readAndPush = async (path) => {
    calls.push(`open:${path}`);
    if (typeof onRead === 'function') onRead();
    return path.length === 0 || readable;
  };
  index.flushWorkspaceSessionSave = () => { calls.push('save-session'); return saved; };
  return { index, calls };
}

test('workspace navigation stays unanimated through first-session restore, then enables normal transitions', async () => {
  const observedDurations = [];
  const { index } = createHarness({ onRead: () => observedDurations.push(index.workspaceTransitionDuration()) });

  assert.equal(index.workspaceTransitionDuration(), 0);
  await index.initializeWorkspaceSession();

  assert.deepEqual(observedDurations, [0]);
  assert.equal(index.navigationAnimationsEnabled, true);
  assert.equal(index.workspaceTransitionDuration(), 240);
});

test('first install opens the tutorial note and clears its marker only after a saved workspace snapshot', async () => {
  const { index, calls } = createHarness();

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '00_开始/快速上手.md');
  assert.equal(index.workspaceInitialRenderReady, true);
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'save-session', 'mark-opened']);
});

test('failed workspace snapshot leaves the first-install marker for the next launch', async () => {
  const { index, calls } = createHarness({ saved: false });

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '00_开始/快速上手.md');
  assert.equal(index.workspaceInitialRenderReady, true);
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'save-session']);
});

test('missing tutorial note falls back to an empty workspace without clearing its marker', async () => {
  const { index, calls } = createHarness({ readable: false });

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '');
  assert.equal(index.workspaceInitialRenderReady, true);
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'open:']);
});

test('cold-start workspace stays covered until its visible Web surface is ready', async () => {
  let finishSurfaceWait;
  const { index } = createHarness({ onRead: () => {} });
  index.waitForInitialWorkspaceSurfaces = () => new Promise((resolve) => {
    finishSurfaceWait = resolve;
  });

  const restoration = index.initializeWorkspaceSession();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(index.workspaceInitialRenderReady, false);

  finishSurfaceWait();
  await restoration;
  assert.equal(index.workspaceInitialRenderReady, true);
});

test('switching libraries persists the new empty workspace even when the switch starts in a secondary view', async () => {
  const calls = [];
  let currentVaultId = 'tutorial';
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => ({
      setCurrent(id) { currentVaultId = id; },
      currentId: () => currentVaultId
    }) }
  });
  vm.runInContext(switchCode, context);
  const VaultSwitchHarness = context.module.exports;
  const index = new VaultSwitchHarness();
  index.currentVaultId = 'tutorial';
  index.topView = 'vaults';
  index.workspaceSessionSavingEnabled = false;
  index.flushWorkspaceSaves = async () => true;
  index.refreshSharedEditability = async () => {};
  // v1.47 47.4（进行中）switchVault 先取目标库工作区会话：无历史会话时走原「清空双栏」路径
  index.ensureWorkspaceSessionStore = () => {};
  index.workspaceSessionStore = { loadFor: () => null };
  index.stopWorkspaceSessionSaving = () => { index.workspaceSessionSavingEnabled = false; };
  index.refreshFromRegistry = () => { index.currentVaultId = currentVaultId; };
  index.readAndPush = async () => true;
  index.readRightAndPush = async () => true;
  index.flushWorkspaceSessionSave = (force) => {
    calls.push({ force, enabled: index.workspaceSessionSavingEnabled });
    return true;
  };
  index.toastRegistryError = (title, error) => { throw new Error(`${title}: ${error.message}`); };

  await index.switchVault('local');

  assert.equal(index.currentVaultId, 'local');
  assert.deepEqual(calls, [{ force: true, enabled: true }]);
});
