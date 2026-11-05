import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url));

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find TrashService method ${signature}`);
  return source.slice(start, end).trim();
}

const migrate = extractMethod(
  'static migrateLegacyTrash(registry: VaultRegistry, vaultId: string): Promise<void> {',
  '\n  private static findLegacyTrashDestination('
);
const findDestination = extractMethod(
  'private static findLegacyTrashDestination(registry: VaultRegistry, vaultId: string,',
  '\n  /**\n   * 列出回收站全部文件'
);
const code = transformSync(`class TrashService {
  static mutationChain = Promise.resolve();
  static legacyMigrationCompleted = new Set();
  ${migrate}
  ${findDestination}
  static enqueue(action) { const job = this.mutationChain.then(action); this.mutationChain = job.then(() => {}, () => {}); return job; }
  static existsInTrash(registry, vaultId, relPath) { return fileIo.accessSync(registry.absoluteInTrash(vaultId, relPath)); }
  static ensureTrashParents() {}
  static async writePrivateAtomic(path, content) { privateFiles.set(path, corruptCopy ? 'corrupt' : content); calls.push(['write', path]); }
  static removePrivateCopy(path) { privateFiles.delete(path); calls.push(['remove', path]); }
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness({ sourceTree = {}, privateTree = {}, corruptCopy = false } = {}) {
  const calls = [];
  const sourceFiles = new Map(Object.entries({ '.trash': null, ...sourceTree }));
  const privateFiles = new Map(Object.entries(privateTree));
  const context = vm.createContext({
    module: { exports: {} },
    privateFiles,
    corruptCopy,
    calls,
    fileIo: {
      accessSync(path) { return privateFiles.has(path); },
      mkdirSync(path) { privateFiles.set(path, null); },
      readTextSync(path) {
        if (!privateFiles.has(path) || privateFiles.get(path) === null || privateFiles.get(path)?.symbolicLink) {
          throw new Error('not a file');
        }
        return privateFiles.get(path);
      },
      lstatSync(path) {
        if (!privateFiles.has(path)) { const error = new Error('missing path'); error.code = 2; throw error; }
        const value = privateFiles.get(path);
        return { isDirectory: () => value === null, isSymbolicLink: () => value?.symbolicLink === true };
      }
    },
    isVaultNoteName(name) { return name.toLowerCase().endsWith('.md') || name.toLowerCase().endsWith('.markdown'); },
    hilog: { info() {} },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  const access = {
    stat(path) {
      if (!sourceFiles.has(path)) return null;
      const value = sourceFiles.get(path);
      return { isDir: value === null, isSymbolicLink: false };
    },
    listAll(path, includeHidden) {
      const prefix = path + '/';
      const names = new Map();
      for (const [candidate, value] of sourceFiles) {
        if (!candidate.startsWith(prefix)) continue;
        const remainder = candidate.slice(prefix.length);
        const name = remainder.split('/')[0];
        if (!includeHidden && name.startsWith('.')) continue;
        names.set(name, value === null || remainder.includes('/'));
      }
      return Array.from(names, ([name, isDir]) => ({ name, isDir }));
    },
    readText(path) {
      if (!sourceFiles.has(path) || sourceFiles.get(path) === null) throw new Error('missing source');
      return sourceFiles.get(path);
    }
  };
  const registry = {
    accessFor() { return access; },
    trashDirOf(vaultId) { return `/private/${vaultId}`; },
    absoluteInTrash(vaultId, relPath) { return `/private/${vaultId}/${relPath}`; }
  };
  return { TrashService, registry, sourceFiles, privateFiles, calls };
}

test('copies and verifies legacy notes, including hidden descendants, while retaining the original tree', async () => {
  const harness = createHarness({ sourceTree: {
    '.trash/old.md': 'old note',
    '.trash/archive': null,
    '.trash/archive/.hidden.markdown': 'hidden note',
    '.trash/foreign.bin': 'not a legacy note'
  } });
  const before = Array.from(harness.sourceFiles.entries());

  await harness.TrashService.migrateLegacyTrash(harness.registry, 'vault');

  assert.equal(harness.privateFiles.get('/private/vault/old.md'), 'old note');
  assert.equal(harness.privateFiles.get('/private/vault/archive/.hidden.markdown'), 'hidden note');
  assert.equal(harness.privateFiles.has('/private/vault/foreign.bin'), false);
  assert.deepEqual(Array.from(harness.sourceFiles.entries()), before);
  assert.equal(harness.calls.filter(([kind]) => kind === 'write').length, 2);
});

test('preserves a different private item by choosing a numbered path and is idempotent', async () => {
  const harness = createHarness({
    sourceTree: { '.trash/notes.md': 'legacy copy' },
    privateTree: { '/private/vault/notes.md': 'newer private item' }
  });

  await harness.TrashService.migrateLegacyTrash(harness.registry, 'vault');
  await harness.TrashService.migrateLegacyTrash(harness.registry, 'vault');

  assert.equal(harness.privateFiles.get('/private/vault/notes.md'), 'newer private item');
  assert.equal(harness.privateFiles.get('/private/vault/notes-2.md'), 'legacy copy');
  assert.equal(harness.sourceFiles.get('.trash/notes.md'), 'legacy copy');
  assert.equal(harness.calls.filter(([kind]) => kind === 'write').length, 1);
});

test('treats a dangling private symlink as a collision without reading through it', async () => {
  const harness = createHarness({
    sourceTree: { '.trash/notes.md': 'legacy copy' },
    privateTree: { '/private/vault/notes.md': { symbolicLink: true } }
  });

  await harness.TrashService.migrateLegacyTrash(harness.registry, 'vault');

  assert.deepEqual(harness.privateFiles.get('/private/vault/notes.md'), { symbolicLink: true });
  assert.equal(harness.privateFiles.get('/private/vault/notes-2.md'), 'legacy copy');
  assert.equal(harness.sourceFiles.get('.trash/notes.md'), 'legacy copy');
});

test('a failed copy verification removes only the bad private copy and keeps the legacy source', async () => {
  const harness = createHarness({ sourceTree: { '.trash/safe.md': 'source' }, corruptCopy: true });

  await assert.rejects(() => harness.TrashService.migrateLegacyTrash(harness.registry, 'vault'), /副本校验失败/);

  assert.equal(harness.sourceFiles.get('.trash/safe.md'), 'source');
  assert.equal(harness.privateFiles.has('/private/vault/safe.md'), false);
  assert.equal(harness.calls.filter(([kind]) => kind === 'remove').length, 1);
});
