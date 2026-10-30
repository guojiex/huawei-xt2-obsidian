import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

function loadModule(source, globals = {}) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} }, ...globals });
  vm.runInContext(code, context);
  return context.module.exports;
}

const vaultModule = loadModule(fs.readFileSync(
  new URL('../entry/src/main/ets/model/Vault.ets', import.meta.url), 'utf8'));
const registrySource = fs.readFileSync(
  new URL('../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url), 'utf8');

function createRegistry(vaultIds = [], existingPaths = []) {
  const paths = new Set(existingPaths);
  const fileOps = [];
  const fileIo = {
    accessSync(path) { return paths.has(path); },
    mkdirSync(path) { fileOps.push(['mkdir', path]); paths.add(path); },
    renameSync(source, target) { fileOps.push(['rename', source, target]); }
  };
  const { VaultRegistry } = loadModule(registrySource, {
    DEFAULT_VAULT_ID: vaultModule.DEFAULT_VAULT_ID,
    sanitizeVaultName: vaultModule.sanitizeVaultName,
    fileIo
  });
  const registry = Object.create(VaultRegistry.prototype);
  registry.state = {
    vaults: vaultIds.map((id, index) => ({
      id,
      vaultKey: `key-${index}`,
      type: 'local',
      createdAt: index
    })),
    currentVaultId: vaultIds[0] ?? ''
  };
  registry.resolver = {
    vaultsRoot: () => '/sandbox/vaults',
    vaultDir: (id) => `/sandbox/vaults/${id}`,
    gitImportMarkerDir: (id) => `/sandbox/vaults/.git-imports/${id}`
  };
  registry.ensureVaultsRoot = () => {};
  registry.newVaultKey = () => 'new-key';
  registry.persist = () => { fileOps.push(['persist']); };
  return { registry, paths, fileOps };
}

test('vault names trim surrounding whitespace before removing every leading dot', () => {
  assert.equal(vaultModule.sanitizeVaultName(' .. '), '');
  assert.equal(vaultModule.sanitizeVaultName(' .folder '), 'folder');
  assert.equal(vaultModule.sanitizeVaultName('  ...notes  '), 'notes');
  assert.equal(vaultModule.sanitizeVaultName(' ../计划/草稿:\\?*"<>|\u0001 '), '计划草稿');
});

test('native create rejects a whitespace-wrapped dot-only name before filesystem access', () => {
  const { registry, fileOps } = createRegistry();

  assert.throws(() => registry.createLocal(' .. '), /库名不能为空/);
  assert.deepEqual(fileOps, []);
  assert.equal(registry.state.vaults.length, 0);
});

test('native ID selection checks registered IDs and orphan directories, and rename preview excludes itself', () => {
  const { registry } = createRegistry(
    ['阅读笔记', '阅读笔记-3'],
    ['/sandbox/vaults/阅读笔记-2']
  );

  assert.equal(registry.uniqueVaultId('阅读笔记', ''), '阅读笔记-4');
  assert.equal(registry.previewRenameId('阅读笔记', '阅读笔记'), '阅读笔记');
  assert.equal(registry.previewRenameId('阅读笔记', '阅读笔记-3'), '阅读笔记-3-2');
  assert.throws(() => registry.previewRenameId('阅读笔记', ' .. '), /库名不能为空/);
});
