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

const moveToTrash = extractMethod(
  'static moveToTrash(registry: VaultRegistry, vaultId: string, relPath: string): Promise<string> {',
  '\n  private static async moveTextToPrivateTrash('
);
const moveText = extractMethod(
  'private static async moveTextToPrivateTrash(registry: VaultRegistry, vaultId: string,',
  '\n  /**\n   * Import legacy in-vault `.trash` notes'
);
const code = transformSync(`class TrashService {
  static mutationChain = Promise.resolve();
  ${moveToTrash}
  ${moveText}
  static enqueue(action) { const job = this.mutationChain.then(action); this.mutationChain = job.then(() => {}, () => {}); return job; }
  static existsInTrash(_registry, _vaultId, relPath) { return this.privateFiles.has(relPath); }
  static ensureTrashParents() {}
  static async writePrivateAtomic(path, content) { this.calls.push('write-private'); this.privateFiles.set(path.substring('/private/local/'.length), content); }
  static removePrivateCopy(path) { this.calls.push('remove-private-copy'); this.privateFiles.delete(path.substring('/private/local/'.length)); }
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
  const privateFiles = new Map();
  let formal = 'before';
  let sourceReads = 0;
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`private-root-exists:${path}`); return false; },
      mkdirSync(path, recursive) {
        calls.push(`mkdir-private-root:${path}`);
        if (recursive === true) { calls.push('mkdir-private-root-recursive'); }
      },
      readTextSync(path) {
        calls.push('verify-private-copy');
        return options.privateRead ?? privateFiles.get(path.substring('/private/local/'.length));
      }
    },
    FullTextSearchService: { noteRemoved() { calls.push('search-removed'); } },
    WikiLinkService: { pathRemoved() { calls.push('wiki-removed'); } },
    hilog: { info() { calls.push('log-trashed'); } },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  TrashService.calls = calls;
  TrashService.privateFiles = privateFiles;
  const access = {
    readText(path) {
      sourceReads++;
      calls.push(`read-source-${sourceReads}`);
      if (options.sourceChanges && sourceReads > 1) formal = 'changed';
      if (options.sourceUnreadable && sourceReads > 1) throw new Error('authorization lost');
      return formal;
    },
    remove(path) {
      calls.push(`remove-source:${path}`);
      if (options.removeFails) throw new Error('controlled removal failure');
      formal = '';
    }
  };
  const registry = {
    accessFor() { return access; },
    trashDirOf(vaultId) { return `/private/${vaultId}`; },
    absoluteInTrash(vaultId, relPath) { return `/private/${vaultId}/${relPath}`; }
  };
  return { TrashService, registry, access, calls, privateFiles, getFormal: () => formal };
}

test('moveToTrash creates the trash root with a recursive mkdir so a missing parent cannot break deletion', async () => {
  const { TrashService, registry, calls } = createHarness();
  await TrashService.moveToTrash(registry, 'local', 'notes.md');

  const mkdirIndex = calls.findIndex((call) => call.startsWith('mkdir-private-root:'));
  assert.ok(mkdirIndex >= 0, 'trash root mkdir was not called');
  assert.equal(calls.includes('mkdir-private-root-recursive'), true,
    'trash root must be created with mkdirSync(path, true); a single-level mkdir throws ENOENT ' +
    'when filesDir/trash does not exist yet (2026-11-07 regression: every delete failed)');
});

test('moveToTrash verifies a private copy and unchanged formal source before removing it', async () => {
  const { TrashService, registry, calls, getFormal } = createHarness();
  await TrashService.moveToTrash(registry, 'local', 'notes.md');

  assert.ok(calls.indexOf('write-private') < calls.indexOf('verify-private-copy'));
  assert.ok(calls.indexOf('verify-private-copy') < calls.indexOf('read-source-2'));
  assert.ok(calls.indexOf('read-source-2') < calls.indexOf('remove-source:notes.md'));
  assert.equal(getFormal(), '');
  assert.equal(calls.includes('search-removed'), true);
});

test('a mismatched private copy prevents removal of the formal note', async () => {
  const { TrashService, registry, calls, getFormal } = createHarness({ privateRead: 'corrupt' });
  await assert.rejects(() => TrashService.moveToTrash(registry, 'local', 'notes.md'), /副本校验失败/);

  assert.equal(calls.some((call) => call.startsWith('remove-source:')), false);
  assert.equal(getFormal(), 'before');
});

test('a formal source change before removal discards only the redundant private copy', async () => {
  const { TrashService, registry, calls, privateFiles, getFormal } = createHarness({ sourceChanges: true });
  await assert.rejects(() => TrashService.moveToTrash(registry, 'local', 'notes.md'), /已保留原文件/);

  assert.equal(calls.some((call) => call.startsWith('remove-source:')), false);
  assert.equal(calls.includes('remove-private-copy'), true);
  assert.equal(getFormal(), 'changed');
  assert.equal(privateFiles.size, 0);
});
