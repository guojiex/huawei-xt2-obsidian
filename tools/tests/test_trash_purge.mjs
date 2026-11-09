import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url), 'utf8');

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find TrashService method ${signature}`);
  return source.slice(start, end).trim();
}

// ⚠️ 结束标记用**下一个方法的签名**，不要用注释行（既有回收站测试同款约定）。
// purge 位于 list 与 restore 之间：既不被 restore→existsInTrash 的既有切片吞掉，
// 也保证本切片（purge→restore）稳定。
const purgeMethod = extractMethod(
  'static purge(registry: VaultRegistry, vaultId: string, trashRel: string): Promise<void> {',
  '\n  static restore('
);
const existsInTrashMethod = extractMethod(
  'private static existsInTrash(registry: VaultRegistry, vaultId: string, relPath: string): boolean {',
  '\n  /** 原位置（库内，不在回收站）是否已有同名文件'
);
const enqueueMethod = extractMethod(
  'private static enqueue<T>(action: () => Promise<T>): Promise<T> {',
  '\n  /** Write a private copy'
);
const code = transformSync(`class TrashService {
  static mutationChain = Promise.resolve();
  ${purgeMethod}
  ${existsInTrashMethod}
  ${enqueueMethod}
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function makeContext(calls, unlinkBehavior) {
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return true; },
      unlinkSync(path) {
        calls.push(`unlink:${path}`);
        if (unlinkBehavior) {
          unlinkBehavior();
        }
      }
    },
    hilog: { info() { calls.push('log-purged'); } },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  return context.module.exports;
}

const registry = {
  absoluteInTrash(vaultId, relPath) {
    return `/trash/${vaultId}/${relPath}`;
  }
};

test('purge unlinks exactly the confirmed trash entry', async () => {
  const calls = [];
  const TrashService = makeContext(calls);
  await TrashService.purge(registry, 'v1', '工程/a.md');
  assert.deepEqual(calls, [
    'exists:/trash/v1/工程/a.md',
    'unlink:/trash/v1/工程/a.md',
    'log-purged'
  ]);
});

test('purge keeps the entry and reports the reason when unlink fails', async () => {
  const calls = [];
  const TrashService = makeContext(calls, () => {
    const error = new Error('设备空间不足');
    error.code = 13900010;
    throw error;
  });
  await assert.rejects(
    TrashService.purge(registry, 'v1', '工程/a.md'),
    /永久删除失败，条目已保留：设备空间不足/
  );
  assert.deepEqual(calls, ['exists:/trash/v1/工程/a.md', 'unlink:/trash/v1/工程/a.md']);
});

test('purge rejects a missing entry without touching the trash', async () => {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return false; },
      unlinkSync(path) { calls.push(`unlink:${path}`); }
    },
    hilog: { info() { calls.push('log-purged'); } },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  await assert.rejects(
    TrashService.purge(registry, 'v1', '工程/a.md'),
    /回收站条目不存在，可能已被处理/
  );
  assert.deepEqual(calls, ['exists:/trash/v1/工程/a.md']);
});
