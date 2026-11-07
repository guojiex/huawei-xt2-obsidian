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

// ⚠️ 结束标记一律用**下一个方法的签名**，不要用注释行：注释是给人看的，改文案就会导致
// 这段源码切片静默失败（曾经因为把 `.trash` 注释改成「回收站」整份测试挂掉）。
const restoreMethod = extractMethod(
  'static restore(registry: VaultRegistry, vaultId: string, trashRel: string): Promise<string> {',
  '\n  private static existsInTrash('
);
const existsAtOriginMethod = extractMethod(
  'private static existsAtOrigin(registry: VaultRegistry, vaultId: string, relPath: string): boolean {',
  '\n  private static ensureTrashParents('
);
const parentDirectoryMethod = extractMethod(
  'private static parentDirectory(relPath: string): string {',
  '\n  private static removePrivateCopy('
);
const readBackWithRetry = extractMethod(
  'private static async readBackWithRetry(read: () => string,',
  '\n  private static walk(registry: VaultRegistry, vaultId: string, relDir: string, out: TrashItem[]): void {'
);
const firstMismatchIndex = extractMethod(
  'private static firstMismatchIndex(expected: string, actual: string): number {',
  '\n  /** 校验失败的具体差异描述'
);
const describeTextMismatch = extractMethod(
  'private static describeTextMismatch(expected: string, actual: string): string {',
  '\n  /** 差异位置附近的内容窗口'
);
const enqueueMethod = extractMethod(
  'private static enqueue<T>(action: () => Promise<T>): Promise<T> {',
  '\n  /** Write a private copy'
);
const code = transformSync(`class TrashService {
  static mutationChain = Promise.resolve();
  static READ_BACK_RETRY_DELAYS_MS = [1];
  ${restoreMethod}
  ${existsAtOriginMethod}
  ${parentDirectoryMethod}
  ${readBackWithRetry}
  ${firstMismatchIndex}
  ${describeTextMismatch}
  ${enqueueMethod}
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
  const readSequence = [...(options.readSequence ?? [])];
  const defaultOriginRead = options.trashContent ?? 'trash-note';
  let readCount = 0;
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout,
    fileIo: {
      readTextSync(path) { calls.push(`read-trash:${path}`); return options.trashContent ?? 'trash-note'; },
      unlinkSync(path) { calls.push(`unlink:${path}`); }
    },
    FullTextSearchService: { noteRestored() { calls.push('search-restored'); } },
    WikiLinkService: { pathAdded() { calls.push('wiki-path-added'); } },
    hilog: {
      info() { calls.push('log-restored'); },
      warn() { calls.push('log-restore-mismatch'); }
    },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  const access = {
    exists(relPath) { calls.push(`exists:${relPath}`); return false; },
    ensureDir(dir) { calls.push(`ensure-dir:${dir}`); },
    async writeAtomic(relPath, content) { calls.push(`write-origin:${relPath}`); },
    readText(relPath) {
      readCount++;
      calls.push(`read-origin-${readCount}`);
      const next = readSequence.length > 0 ? readSequence.shift() : defaultOriginRead;
      if (next instanceof Error) {
        throw next;
      }
      return next;
    }
  };
  const registry = {
    accessFor() { return access; },
    absoluteInTrash(_vaultId, relPath) { return `/private/${relPath}`; }
  };
  return { TrashService, registry, calls };
}

test('restore completes with a single read-back when the origin read matches immediately', async () => {
  const { TrashService, registry, calls } = createHarness();

  const restored = await TrashService.restore(registry, 'local', 'notes.md');

  assert.equal(restored, 'notes.md');
  assert.equal(calls.filter((call) => call.startsWith('read-origin-')).length, 1);
  assert.equal(calls.includes('write-origin:notes.md'), true);
  assert.equal(calls.includes('unlink:/private/notes.md'), true);
  assert.equal(calls.includes('search-restored'), true);
  assert.equal(calls.includes('log-restored'), true);
});

test('restore retries a stale origin read-back until it matches and then unlinks the trash copy', async () => {
  const { TrashService, registry, calls } = createHarness({ readSequence: ['stale-once'] });

  const restored = await TrashService.restore(registry, 'local', 'folder/notes.md');

  assert.equal(restored, 'folder/notes.md');
  assert.deepEqual(calls.filter((call) => call.startsWith('read-origin-')), ['read-origin-1', 'read-origin-2'],
    'a mismatched first read must be retried instead of failing the restore');
  assert.equal(calls.includes('unlink:/private/folder/notes.md'), true);
  assert.equal(calls.includes('log-restored'), true);
});

test('restore keeps the trash copy and warns when the read-back never matches', async () => {
  const { TrashService, registry, calls } = createHarness({
    readSequence: ['stale', 'stale']
  });

  await assert.rejects(
    () => TrashService.restore(registry, 'local', 'notes.md'),
    /恢复副本校验失败，回收站原件仍保留/
  );

  assert.equal(calls.some((call) => call.startsWith('unlink:')), false,
    'the trash copy must be retained when verification fails');
  assert.equal(calls.includes('log-restore-mismatch'), true);
  assert.equal(calls.includes('log-restored'), false);
});

test('restore keeps the trash copy when every read-back attempt throws', async () => {
  const readError = new Error('not ready');
  readError.code = 13900002;
  const { TrashService, registry, calls } = createHarness({
    readSequence: [readError, readError]
  });

  await assert.rejects(
    () => TrashService.restore(registry, 'local', 'notes.md'),
    /恢复副本读取失败\(code=13900002\)，回收站原件仍保留：not ready/
  );

  assert.equal(calls.some((call) => call.startsWith('unlink:')), false);
  assert.equal(calls.includes('log-restored'), false);
});
