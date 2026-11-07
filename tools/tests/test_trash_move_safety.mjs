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
const firstMismatchIndex = extractMethod(
  'private static firstMismatchIndex(expected: string, actual: string): number {',
  '\n  /** 校验失败的具体差异描述'
);
const describeTextMismatch = extractMethod(
  'private static describeTextMismatch(expected: string, actual: string): string {',
  '\n  /** 差异位置附近的内容窗口'
);
const escapeAround = extractMethod(
  'private static escapeAround(text: string, index: number, radius: number): string {',
  '\n  private static enqueue<'
);
const readBackWithRetry = extractMethod(
  'private static async readBackWithRetry(read: () => string,',
  '\n  private static walk(registry: VaultRegistry, vaultId: string, relDir: string, out: TrashItem[]): void {'
);
const code = transformSync(`class TrashService {
  static mutationChain = Promise.resolve();
  static READ_BACK_RETRY_DELAYS_MS = [1];
  ${moveToTrash}
  ${moveText}
  ${firstMismatchIndex}
  ${describeTextMismatch}
  ${escapeAround}
  ${readBackWithRetry}
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
    setTimeout,
    fileIo: {
      accessSync(path) { calls.push(`private-root-exists:${path}`); return false; },
      mkdirSync(path, recursive) {
        calls.push(`mkdir-private-root:${path}`);
        if (recursive === true) { calls.push('mkdir-private-root-recursive'); }
      },
      readTextSync(path) {
        calls.push('verify-private-copy');
        if (options.privateReadThrows) {
          const readError = new Error('No such file or directory');
          readError.code = 13900002;
          throw readError;
        }
        if (options.privateReadSequence && options.privateReadSequence.length > 0) {
          return options.privateReadSequence.shift();
        }
        return options.privateRead ?? privateFiles.get(path.substring('/private/local/'.length));
      }
    },
    FullTextSearchService: { noteRemoved() { calls.push('search-removed'); } },
    WikiLinkService: { pathRemoved() { calls.push('wiki-removed'); } },
    hilog: {
      info() { calls.push('log-trashed'); },
      warn() { calls.push('log-verify-mismatch'); }
    },
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

test('a mismatched private copy reports the exact mismatch and prevents removal of the formal note', async () => {
  const { TrashService, registry, calls, getFormal } = createHarness({ privateRead: 'corrupt' });
  await assert.rejects(() => TrashService.moveToTrash(registry, 'local', 'notes.md'),
    /副本校验失败.*期望 6 字符，读回 7 字符，首个差异在第 0 位（期望 U\+62，读回 U\+63）；副本路径 \/private\/local\/notes\.md/);

  assert.equal(calls.includes('log-verify-mismatch'), true);
  assert.equal(calls.some((call) => call.startsWith('remove-source:')), false);
  assert.equal(getFormal(), 'before');
});

test('an unreadable private copy reports the read error code and keeps the formal note', async () => {
  const { TrashService, registry, calls, getFormal } = createHarness({ privateReadThrows: true });
  await assert.rejects(() => TrashService.moveToTrash(registry, 'local', 'notes.md'),
    /副本读取失败\(code=13900002\)，原笔记未删除：No such file or directory；副本路径 \/private\/local\/notes\.md/);

  assert.equal(calls.some((call) => call.startsWith('remove-source:')), false);
  assert.equal(getFormal(), 'before');
});

test('a formal source change before removal discards only the redundant private copy', async () => {
  const { TrashService, registry, calls, privateFiles, getFormal } = createHarness({ sourceChanges: true });
  await assert.rejects(() => TrashService.moveToTrash(registry, 'local', 'notes.md'),
    /已保留原文件：删除前 6 字符，当前 7 字符/);

  assert.equal(calls.some((call) => call.startsWith('remove-source:')), false);
  assert.equal(calls.includes('remove-private-copy'), true);
  assert.equal(getFormal(), 'changed');
  assert.equal(privateFiles.size, 0);
});

test('a stale private read-back is retried until it matches so deletion still completes', async () => {
  const { TrashService, registry, calls, getFormal } = createHarness({
    privateReadSequence: ['stale-once']
  });
  await TrashService.moveToTrash(registry, 'local', 'notes.md');

  assert.equal(calls.filter((call) => call === 'verify-private-copy').length, 2,
    'a mismatched first read must be retried instead of failing the delete');
  assert.equal(calls.some((call) => call.startsWith('remove-source:')), true);
  assert.equal(getFormal(), '');
  assert.equal(calls.includes('search-removed'), true);
});
