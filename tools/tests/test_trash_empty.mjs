import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
// CRLF 归一（见 lib/source.mjs 说明）：切片与 vm 都按 LF 工作。
const source = readSourceFile(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url));

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find TrashService method ${signature}`);
  return source.slice(start, end).trim();
}

// ⚠️ 结束标记用**下一个方法的签名**，不要用注释行（既有回收站测试同款约定）。
// purge 与 purgeAll 相邻（purge → purgeAll → restore）：一次切 [purge, restore)，
// 两个方法都只出现一次；单独再切 purgeAll 会与组合切片重复实现，esbuild 直接报重定义。
const purgeAndPurgeAll = extractMethod(
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
const code = transformSync(`interface PurgeAllOutcome { succeeded: string[]; failed: string[]; }
class TrashService {
  static mutationChain = Promise.resolve();
  ${purgeAndPurgeAll}
  ${existsInTrashMethod}
  ${enqueueMethod}
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function makeTrashService(calls, unlinkBehavior) {
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return true; },
      unlinkSync(path) {
        calls.push(`unlink:${path}`);
        if (unlinkBehavior && unlinkBehavior(path)) {
          const error = new Error('设备空间不足');
          error.code = 13900010;
          throw error;
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

// vm realm 里 new 出来的数组与宿主 assert.deepEqual 严格比较会因原型不同而失败
//（“same structure but are not reference-equal”），统一展开成宿主数组再断言。
function hostOutcome(outcome) {
  return { succeeded: [...outcome.succeeded], failed: [...outcome.failed] };
}

test('purgeAll deletes every snapshot entry in order (55.3 全部成功)', async () => {
  const calls = [];
  const TrashService = makeTrashService(calls);
  const outcome = await TrashService.purgeAll(registry, 'v1', ['工程/a.md', 'b.md']);
  assert.deepEqual(hostOutcome(outcome), { succeeded: ['工程/a.md', 'b.md'], failed: [] });
  // 末尾多一条 log-purged 是 purgeAll 自己的汇总日志（条目标题 / 路径不进日志，硬约束 16）。
  assert.deepEqual(calls, [
    'exists:/trash/v1/工程/a.md',
    'unlink:/trash/v1/工程/a.md',
    'log-purged',
    'exists:/trash/v1/b.md',
    'unlink:/trash/v1/b.md',
    'log-purged',
    'log-purged'
  ]);
});

test('purgeAll keeps going and counts correctly when one unlink fails (55.4 部分失败不回滚)', async () => {
  const calls = [];
  const TrashService = makeTrashService(calls, (path) => path.endsWith('b.md'));
  const outcome = await TrashService.purgeAll(registry, 'v1', ['a.md', 'b.md', 'c.md']);
  assert.deepEqual([...outcome.succeeded], ['a.md', 'c.md']);
  assert.deepEqual([...outcome.failed], ['b.md']);
  // 失败不中断：b.md 之后 c.md 仍被尝试且成功（顺序在其失败尝试之后）。
  assert.ok(calls.indexOf('unlink:/trash/v1/c.md') > calls.indexOf('unlink:/trash/v1/b.md'));
});

test('purgeAll returns an empty outcome for an empty list without touching the trash', async () => {
  const calls = [];
  const TrashService = makeTrashService(calls);
  const outcome = await TrashService.purgeAll(registry, 'v1', []);
  assert.deepEqual(hostOutcome(outcome), { succeeded: [], failed: [] });
  assert.deepEqual(calls, []);
});

test('purgeAll only touches the snapshot; entries added later stay (55.5 范围固定)', async () => {
  const calls = [];
  const TrashService = makeTrashService(calls);
  const outcome = await TrashService.purgeAll(registry, 'v1', ['a.md']);
  assert.deepEqual(hostOutcome(outcome), { succeeded: ['a.md'], failed: [] });
  // 弹窗打开后才进回收站的 later.md 不在快照里：一次 exists / unlink 都不该有它。
  assert.ok(!calls.some((entry) => entry.includes('later.md')));
});

test('purgeAll counts an already-processed entry as failed instead of throwing', async () => {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      // 第一个条目已被并发处理（不存在），第二个还在。
      accessSync(path) { calls.push(`exists:${path}`); return !path.endsWith('a.md'); },
      unlinkSync(path) { calls.push(`unlink:${path}`); }
    },
    hilog: { info() { calls.push('log-purged'); } },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  const outcome = await TrashService.purgeAll(registry, 'v1', ['a.md', 'b.md']);
  assert.deepEqual([...outcome.succeeded], ['b.md']);
  assert.deepEqual([...outcome.failed], ['a.md']);
  assert.deepEqual(calls, [
    'exists:/trash/v1/a.md',
    'exists:/trash/v1/b.md',
    'unlink:/trash/v1/b.md',
    'log-purged',
    'log-purged'
  ]);
});
