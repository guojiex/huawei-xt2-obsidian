// v1.5 15.6：App 私有数据（回收站 / 崩溃恢复草稿）必须落沙箱、按 vaultKey 分目录。
//
// 这份测试存在的理由：**路径布局是跨层的隐性契约**。`.trash` 以前长在库目录里，
// 靠「库改名时 renameSync 顺带带走」这种巧合在维持，外部授权库一来就崩：那个目录是
// 用户的，往里面塞 `.trash` 会让用户在 Obsidian / Git / 云盘里看到一个垃圾目录。
// 这类问题「不影响功能、但很脏」，review 容易放过，只能靠断言在 CI 里锁死。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

const source = readSourceFile(new URL('../../entry/src/main/ets/model/VaultPathResolver.ets', import.meta.url));

function loadResolver() {
  // 这个文件唯一的 import 是 `common.UIAbilityContext` 的**类型**，运行时用不到，
  // 剥掉即可在 Node 里跑（这一层的价值正是「不依赖任何 @kit.*」）。
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} }, console, Object, Error, JSON });
  vm.runInContext(code, context);
  return context.module.exports.VaultPathResolver;
}

/** 假 Context：解析器只用到 filesDir / cacheDir 两个属性。 */
function fakeContext() {
  return { filesDir: '/files', cacheDir: '/cache' };
}

test('trash no longer lives inside the vault directory', () => {
  const Resolver = loadResolver();
  const resolver = new Resolver(fakeContext());
  const trashDir = resolver.trashDir('k-abc');
  assert.equal(trashDir, '/files/trash/k-abc');
  assert.equal(trashDir.startsWith(resolver.vaultDir('我的库') + '/'), false,
    '回收站不得再是库目录的子树 —— 外部授权库会把 .trash 写进用户自己的目录');
});

test('private dirs are keyed by vaultKey so a rename keeps them reachable', () => {
  const Resolver = loadResolver();
  const resolver = new Resolver(fakeContext());
  // 改名只换 id，vaultKey 不变 → 两条路径必须逐字不变。
  assert.equal(resolver.trashDir('k-abc'), '/files/trash/k-abc');
  assert.equal(resolver.draftsVaultDir('k-abc'), '/files/drafts/k-abc');
  assert.notEqual(resolver.draftsVaultDir('k-abc'), resolver.draftsVaultDir('k-def'),
    '不同 vaultKey 必须落到不同目录');
});

test('trash mirrors the in-vault relative path under its own root', () => {
  const Resolver = loadResolver();
  const resolver = new Resolver(fakeContext());
  assert.equal(resolver.resolveInTrash('k-abc', '工程/a.md'), '/files/trash/k-abc/工程/a.md');
  assert.throws(() => resolver.resolveInTrash('k-abc', '../逃逸.md'), /不允许包含/);
});

test('drafts keep their own root and still refuse unsafe segments', () => {
  const Resolver = loadResolver();
  const resolver = new Resolver(fakeContext());
  assert.equal(resolver.resolveDraft('k-abc', 'a/b.md'), '/files/drafts/k-abc/a/b.md.draft');
  assert.throws(() => resolver.resolveDraft('k-abc', '/abs.md'), /绝对路径/);
  assert.throws(() => resolver.draftsVaultDir('.hidden'), /以点开头/);
});

test('private paths never contain a dot-prefixed segment', () => {
  const Resolver = loadResolver();
  const resolver = new Resolver(fakeContext());
  const produced = [
    resolver.trashDir('k-abc'),
    resolver.resolveInTrash('k-abc', 'a.md'),
    resolver.draftsVaultDir('k-abc'),
    resolver.resolveDraft('k-abc', 'a.md')
  ];
  for (let i = 0; i < produced.length; i++) {
    const segments = produced[i].split('/');
    for (let j = 0; j < segments.length; j++) {
      assert.equal(segments[j].startsWith('.'), false,
        '私有数据路径里不该再出现隐藏段: ' + produced[i]);
    }
  }
});
