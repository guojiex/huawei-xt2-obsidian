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
const code = transformSync(`class IndexHarness { ${method} }\nmodule.exports = IndexHarness;`, {
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

function createHarness({ readable = true, saved = true } = {}) {
  const calls = [];
  const registry = {
    firstInstallNotePath: () => '00_开始/快速上手.md',
    currentId: () => 'tutorial',
    markFirstInstallNoteOpened: () => { calls.push('mark-opened'); return true; }
  };
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => registry },
    SAMPLE_VAULT_ID: 'tutorial'
  });
  vm.runInContext(code, context);
  const IndexHarness = context.module.exports;
  const index = new IndexHarness();
  index.workspaceSessionRestoreStarted = false;
  index.pendingWorkspaceSession = null;
  index.currentFilePath = '';
  index.readAndPush = async (path) => { calls.push(`open:${path}`); return path.length === 0 || readable; };
  index.flushWorkspaceSessionSave = () => { calls.push('save-session'); return saved; };
  return { index, calls };
}

test('first install opens the tutorial note and clears its marker only after a saved workspace snapshot', async () => {
  const { index, calls } = createHarness();

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '00_开始/快速上手.md');
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'save-session', 'mark-opened']);
});

test('failed workspace snapshot leaves the first-install marker for the next launch', async () => {
  const { index, calls } = createHarness({ saved: false });

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '00_开始/快速上手.md');
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'save-session']);
});

test('missing tutorial note falls back to an empty workspace without clearing its marker', async () => {
  const { index, calls } = createHarness({ readable: false });

  await index.initializeWorkspaceSession();

  assert.equal(index.currentFilePath, '');
  assert.deepEqual(calls, ['open:00_开始/快速上手.md', 'open:']);
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
