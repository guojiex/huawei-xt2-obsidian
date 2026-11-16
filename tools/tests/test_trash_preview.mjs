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

// ⚠️ 结束标记用**下一个方法的签名/文档注释**，不要用注释行（既有回收站测试同款约定）。
// readTrashText 位于 list 与 purge 之间：不被 purge→restore、restore→existsInTrash、
// existsInTrash→原位置注释 的既有切片吞掉，本切片（readTrashText→purge）也稳定。
const readTrashTextMethod = extractMethod(
  'static readTrashText(registry: VaultRegistry, vaultId: string, trashRel: string): string {',
  '\n  static purge('
);
const existsInTrashMethod = extractMethod(
  'private static existsInTrash(registry: VaultRegistry, vaultId: string, relPath: string): boolean {',
  '\n  /** 原位置（库内，不在回收站）是否已有同名文件'
);
const code = transformSync(`class TrashService {
  ${readTrashTextMethod}
  ${existsInTrashMethod}
}; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function makeContext(calls, readBehavior) {
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return true; },
      readTextSync(path) {
        calls.push(`read:${path}`);
        if (readBehavior) {
          return readBehavior();
        }
        return '# 笔记正文\n\n- 只读预览';
      }
    },
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

test('readTrashText returns the trash entry content read-only without mutation chain or logs', () => {
  const calls = [];
  const TrashService = makeContext(calls);
  const text = TrashService.readTrashText(registry, 'v1', '工程/a.md');
  assert.equal(text, '# 笔记正文\n\n- 只读预览');
  assert.deepEqual(calls, [
    'exists:/trash/v1/工程/a.md',
    'read:/trash/v1/工程/a.md'
  ]);
  // 隐私红线（硬约束 16）：切片内不得出现 hilog —— 正文绝不进日志。
  assert.equal(readTrashTextMethod.match(/hilog/g), null);
  // 只读：不进变更串行（mutationChain），不产生写操作。
  assert.equal(readTrashTextMethod.match(/mutationChain|enqueue|unlinkSync|writeAtomic/g), null);
});

test('readTrashText rejects a missing entry before any read attempt', () => {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return false; },
      readTextSync(path) { calls.push(`read:${path}`); }
    },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  assert.throws(
    () => TrashService.readTrashText(registry, 'v1', '工程/a.md'),
    /回收站条目不存在，可能已被处理/
  );
  assert.deepEqual(calls, ['exists:/trash/v1/工程/a.md']);
});

test('readTrashText wraps read failures with a readable message and keeps the entry', () => {
  const calls = [];
  const TrashService = makeContext(calls, () => {
    const error = new Error('文件系统异常');
    error.code = 13900010;
    throw error;
  });
  assert.throws(
    () => TrashService.readTrashText(registry, 'v1', '工程/a.md'),
    /回收站条目读取失败：文件系统异常/
  );
  assert.deepEqual(calls, [
    'exists:/trash/v1/工程/a.md',
    'read:/trash/v1/工程/a.md'
  ]);
});
