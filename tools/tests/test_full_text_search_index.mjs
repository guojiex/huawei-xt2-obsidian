// v1.40 持久搜索索引（Markdown 真源 + RDB 双写）的 Node 侧回归。
//
// 覆盖：SearchStore 纯工具、FullTextSearchService 编排（建库 / 对账 / pending 消化 /
// 删库清理）、SearchStoreDevice 结构约束（加密、FTS5 短语、代次守卫、无 LIKE、隐私）、
// EntryAbility / Index 接线，以及「生产源码不得再引用已删除的 SearchIndex」。
// 范式与 test_cross_vault_search.mjs 相同：readSourceFile 归一 CRLF，esbuild transformSync
// 抽成 vm 里可跑的类；设备侧 RDB 无法在 Node 里裸跑，行为由 Hypium 假存储补充。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

const searchStoreSource = readSourceFile(new URL('../../entry/src/main/ets/model/SearchStore.ets', import.meta.url));
const vaultAccessSource = readSourceFile(new URL('../../entry/src/main/ets/model/VaultAccess.ets', import.meta.url));
const ftsSource = readSourceFile(new URL('../../entry/src/main/ets/model/FullTextSearchService.ets', import.meta.url));
const deviceSource = readSourceFile(new URL('../../entry/src/main/ets/model/SearchStoreDevice.ets', import.meta.url));
const entryAbilitySource = readSourceFile(new URL('../../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url));
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

// vm 里创建的数组/对象与断言侧分属两个 realm，deepStrictEqual 会因原型不同而失败；
// 统一 JSON 往返归一成本地对象再比较（同 test_cross_vault_search.mjs）。
const plain = (value) => JSON.parse(JSON.stringify(value));

function loadModule(source) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), { loader: 'ts', format: 'cjs' }).code;
  const context = vm.createContext({ module: { exports: {} }, setTimeout, clearTimeout });
  vm.runInContext(code, context);
  return context.module.exports;
}

const searchStore = loadModule(searchStoreSource);
const vaultAccess = loadModule(vaultAccessSource);

const serviceCode = transformSync(
  `${ftsSource.slice(ftsSource.indexOf('export class FullTextSearchService')).trim().replace('export class', 'class')}\nmodule.exports = FullTextSearchService;`,
  { loader: 'ts', format: 'cjs' }).code;

// 每个用例都重新 run 一份类：静态状态（reconciledKeys / failureCounts 等）不跨用例泄漏。
function loadService() {
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout,
    clearTimeout,
    isVaultNoteName: vaultAccess.isVaultNoteName,
    contentHashOf: searchStore.contentHashOf,
    excerptOf: searchStore.excerptOf,
    searchTitleOf: searchStore.searchTitleOf
  });
  vm.runInContext(serviceCode, context);
  return context.module.exports;
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

// ---------------------------- 内存假存储（镜像 SearchStoreDevice 语义） ----------------------------
//
// 代次守卫与 pending 生命周期必须与设备侧一致，否则服务层测试测的是假行为：
// setPending 推进 scan_generation；takePending 只读不删（至少一次语义）；
// 行由 upsertDocument / removeDocuments / dropPending 在 generation ≤ taskGeneration 时删除；
// upsertDocument 拒绝「现有行 generation > taskGeneration」的旧任务写入。

function createMemoryStore(options = {}) {
  const state = {
    vaults: new Map(),
    docs: new Map(),
    pending: new Map(),
    clearedKeys: []
  };
  const vaultRow = (key) => {
    if (!state.vaults.has(key)) {
      state.vaults.set(key, { initialized: false, lastReconciledAt: 0, scanGeneration: 0 });
    }
    return state.vaults.get(key);
  };
  const store = {
    async init() {
      if (options.initRejects) {
        throw new Error('store init failed');
      }
    },
    supportsTokenizer() { return options.tokenizer !== false; },
    async getVaultState(key) {
      const row = state.vaults.get(key);
      return row ? { ...row } : null;
    },
    async listDocuments(key) {
      return [...(state.docs.get(key) ?? new Map()).values()]
        .map((d) => ({ path: d.path, size: d.size, mtimeSec: d.mtimeSec, contentHash: d.contentHash, generation: d.generation }))
        .sort((a, b) => (a.path < b.path ? -1 : 1));
    },
    async queryContent(key, query, limit) {
      if (!store.supportsTokenizer()) {
        throw new Error('SEARCH_STORE_UNAVAILABLE');
      }
      const docs = state.docs.get(key) ?? new Map();
      const lower = query.toLowerCase();
      const out = [];
      for (const doc of [...docs.values()].sort((a, b) => (a.path < b.path ? -1 : 1))) {
        if (out.length >= limit) {
          break;
        }
        if (doc.content.toLowerCase().includes(lower)) {
          out.push({ path: doc.path, contentHash: doc.contentHash });
        }
      }
      return out;
    },
    async setPending(key, paths) {
      const row = vaultRow(key);
      row.scanGeneration += 1;
      if (!state.pending.has(key)) {
        state.pending.set(key, new Map());
      }
      const pending = state.pending.get(key);
      for (const p of paths) {
        pending.set(p, row.scanGeneration);
      }
    },
    async takePending(key) {
      const pending = state.pending.get(key) ?? new Map();
      return [...pending.entries()]
        .map(([p, generation]) => ({ path: p, generation }))
        .sort((a, b) => a.generation - b.generation || (a.path < b.path ? -1 : 1));
    },
    async dropPending(key, target, taskGeneration) {
      const pending = state.pending.get(key);
      if (!pending) {
        return;
      }
      const current = pending.get(target);
      if (current !== undefined && current <= taskGeneration) {
        pending.delete(target);
      }
    },
    async upsertDocument(key, doc, taskGeneration) {
      vaultRow(key);
      if (!state.docs.has(key)) {
        state.docs.set(key, new Map());
      }
      const docs = state.docs.get(key);
      const existing = docs.get(doc.path);
      if (existing && existing.generation > taskGeneration) {
        return;
      }
      docs.set(doc.path, { ...doc, generation: taskGeneration });
      const pending = state.pending.get(key);
      if (pending) {
        const current = pending.get(doc.path);
        if (current !== undefined && current <= taskGeneration) {
          pending.delete(doc.path);
        }
      }
    },
    async removeDocuments(key, target, isDirectory, taskGeneration) {
      const docs = state.docs.get(key);
      if (docs) {
        for (const p of [...docs.keys()]) {
          const matches = p === target || (isDirectory && p.startsWith(target + '/'));
          if (matches && docs.get(p).generation <= taskGeneration) {
            docs.delete(p);
          }
        }
      }
      const pending = state.pending.get(key);
      if (pending) {
        for (const p of [...pending.keys()]) {
          const matches = p === target || (isDirectory && p.startsWith(target + '/'));
          if (matches && pending.get(p) <= taskGeneration) {
            pending.delete(p);
          }
        }
      }
    },
    async markVaultInitialized(key) { vaultRow(key).initialized = true; },
    async markVaultReconciled(key) { vaultRow(key).lastReconciledAt = 777; },
    async clearVault(key) {
      state.clearedKeys.push(key);
      state.docs.delete(key);
      state.pending.delete(key);
      state.vaults.delete(key);
    },
    async listVaultKeys() { return [...state.vaults.keys()]; }
  };
  return { store, state };
}

function createRegistry(vaultDefs) {
  const vaults = vaultDefs.map((def) => ({
    id: def.id,
    vaultKey: def.vaultKey,
    files: new Map(Object.entries(def.files ?? {})),
    unreadable: new Set(def.unreadable ?? []),
    snapshotOverride: def.snapshotOverride ?? null
  }));
  const accessOf = (vault) => ({
    stat(p) {
      const content = vault.files.get(p);
      if (content === undefined) {
        return null;
      }
      return { size: content.length, mtimeSec: 42, isDir: false, isSymbolicLink: false };
    },
    readText(p) {
      const content = vault.files.get(p);
      if (content === undefined || vault.unreadable.has(p)) {
        throw new Error('读不到 ' + p);
      }
      return content;
    },
    snapshotReport() {
      if (vault.snapshotOverride) {
        return vault.snapshotOverride;
      }
      const entries = [...vault.files.keys()].sort().map((name) => ({ name, isDir: false }));
      return { entries, truncated: false, failed: false };
    }
  });
  return {
    vaults,
    vaultKeyOf(id) {
      const found = vaults.find((entry) => entry.id === id);
      if (!found) {
        throw new Error('未注册 ' + id);
      }
      return found.vaultKey;
    },
    accessFor(id) {
      const found = vaults.find((entry) => entry.id === id);
      if (!found) {
        throw new Error('未注册 ' + id);
      }
      return accessOf(found);
    },
    list() { return vaults.map((v) => ({ id: v.id, vaultKey: v.vaultKey })); }
  };
}

function setup(vaultDefs, options = {}) {
  const Service = loadService();
  const { store, state } = createMemoryStore(options);
  const registry = createRegistry(vaultDefs);
  Service.configure(store, registry);
  return { Service, store, state, registry, vaults: registry.vaults };
}

// ---------------------------- SearchStore 纯工具 ----------------------------

test('v1.40 40.1 contentHashOf is stable and sensitive to content changes', () => {
  assert.equal(searchStore.contentHashOf('abc'), searchStore.contentHashOf('abc'));
  assert.notEqual(searchStore.contentHashOf('abc'), searchStore.contentHashOf('abd'));
  assert.equal(searchStore.contentHashOf(''), '0:0');
});

test('v1.40 40.1 excerptOf keeps the window, folds whitespace and marks cuts', () => {
  const long = 'x'.repeat(100) + '  needle  ' + 'y'.repeat(200);
  const excerpt = searchStore.excerptOf(long, 102, 6);
  assert.ok(excerpt.startsWith('…'));
  assert.ok(excerpt.endsWith('…'));
  assert.ok(excerpt.includes('needle'));
  assert.equal(excerpt.includes('  '), false, '空白必须折叠');
});

test('v1.40 40.1 searchTitleOf prefers the first level-1 heading within 20 lines', () => {
  assert.equal(searchStore.searchTitleOf('dir/file.md', '\n'.repeat(10) + '# 我的标题\n正文'), '我的标题');
  assert.equal(searchStore.searchTitleOf('dir/file.md', '\n'.repeat(25) + '# 太深了\n'), 'file');
  assert.equal(searchStore.searchTitleOf('notes/readme.markdown', 'no title'), 'readme');
  assert.equal(searchStore.searchTitleOf('plain.txt', 'x'), 'plain.txt');
});

// ---------------------------- FullTextSearchService 编排 ----------------------------

test('v1.40 40.1 first search builds the persistent index and returns verified results', async () => {
  const { Service, state, registry } = setup([{
    id: 'v1', vaultKey: 'key-alpha',
    files: { 'alpha.md': '# Alpha\n独角兽在雾里出没', 'beta.md': '无关内容', 'sub/note.md': '独角兽二次出现' }
  }]);
  const progress = [];
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', (c, t) => progress.push([c, t]));
  assert.equal(outcome.indexState, 'ready');
  assert.equal(outcome.indexComplete, true);
  assert.deepEqual(plain(outcome.results.map((r) => r.path)), ['alpha.md', 'sub/note.md']);
  assert.ok(outcome.results[0].excerpt.includes('独角兽'));
  assert.deepEqual([...state.docs.get('key-alpha').keys()].sort(), ['alpha.md', 'beta.md', 'sub/note.md']);
  assert.deepEqual(progress.at(-1), [3, 3]);
  assert.ok(progress.some((p) => p[0] === 0 && p[1] === 3), '建库开始就要上报 0/total');
});

test('v1.40 40.2 legacy search() still returns results for 小艺 when the index is available', async () => {
  const { Service, registry } = setup([{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽 内容' } }]);
  const results = await Service.search(registry, 'v1', '独角兽', () => {});
  assert.deepEqual(plain(results.map((r) => r.path)), ['a.md']);
});

test('v1.40 40.4 a single unreadable note does not abort the initial build', async () => {
  const { Service, state, registry } = setup([{
    id: 'v1', vaultKey: 'key-a',
    files: { 'good.md': '独角兽 好', 'bad.md': '独角兽 坏' },
    unreadable: ['bad.md']
  }]);
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'ready');
  assert.deepEqual(plain(outcome.results.map((r) => r.path)), ['good.md']);
  assert.deepEqual([...state.docs.get('key-a').keys()], ['good.md']);
});

test('v1.40 40.4 noteSaved re-reads the current file instead of trusting the saved content', async () => {
  const { Service, state, registry, vaults } = setup([{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '旧内容 独角兽' } }]);
  await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  vaults[0].files.set('a.md', '新内容 独角兽 在此');
  Service.noteSaved('v1', 'a.md', '过期草稿 独角兽');
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'ready');
  assert.equal(outcome.results.length, 1);
  assert.ok(outcome.results[0].excerpt.includes('新内容'));
  assert.equal(state.docs.get('key-a').get('a.md').contentHash, searchStore.contentHashOf('新内容 独角兽 在此'));
});

test('v1.40 40.3 rename clears the old path from the index and indexes the new one', async () => {
  const { Service, state, registry, vaults } = setup([{ id: 'v1', vaultKey: 'key-a', files: { 'old.md': '独角兽 内容' } }]);
  await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  vaults[0].files.delete('old.md');
  vaults[0].files.set('new.md', '独角兽 内容');
  Service.pathRetargeted('v1', 'old.md', 'new.md', false);
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.deepEqual(plain(outcome.results.map((r) => r.path)), ['new.md']);
  assert.deepEqual([...state.docs.get('key-a').keys()], ['new.md']);
});

test('v1.40 40.3 delete removes the doc from the index and restore brings it back', async () => {
  const { Service, state, registry, vaults } = setup([{
    id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽 一', 'b.md': '独角兽 二' }
  }]);
  await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  vaults[0].files.delete('a.md');
  Service.noteRemoved('v1', 'a.md', false);
  let outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.deepEqual(plain(outcome.results.map((r) => r.path)), ['b.md']);
  vaults[0].files.set('a.md', '独角兽 归来');
  Service.noteRestored('v1', 'a.md');
  outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.deepEqual(plain(outcome.results.map((r) => r.path)).sort(), ['a.md', 'b.md']);
  assert.equal(state.docs.get('key-a').has('a.md'), true);
});

test('v1.40 40.1 identical paths in different vaults stay isolated', async () => {
  const { Service, state, registry } = setup([
    { id: 'v1', vaultKey: 'key-one', files: { 'a.md': '独角兽 甲库内容' } },
    { id: 'v2', vaultKey: 'key-two', files: { 'a.md': '独角兽 乙库内容' } }
  ]);
  const first = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  const second = await Service.searchDetailed(registry, 'v2', '独角兽', () => {});
  assert.ok(first.results[0].excerpt.includes('甲库'));
  assert.ok(second.results[0].excerpt.includes('乙库'));
  assert.notEqual(state.docs.get('key-one').get('a.md').contentHash, state.docs.get('key-two').get('a.md').contentHash);
});

test('v1.40 40.8 first use per process reconciles: re-index drift, drop vanished, add external', async () => {
  const { Service, store, state, registry } = setup([{
    id: 'v1', vaultKey: 'key-a',
    files: { 'keep.md': '独角兽 新版内容', 'added.md': '独角兽 外部新增' }
  }]);
  // 模拟上个进程留下的索引：keep.md 内容过期、gone.md 已从文件系统消失。
  await store.markVaultInitialized('key-a');
  state.docs.set('key-a', new Map([
    ['gone.md', { path: 'gone.md', size: 1, mtimeSec: 1, contentHash: 'stale', generation: 0, title: 't', content: '独角兽 已删除' }],
    ['keep.md', { path: 'keep.md', size: 1, mtimeSec: 1, contentHash: 'WRONG', generation: 0, title: 't', content: '独角兽 旧版内容' }]
  ]));
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'ready');
  assert.deepEqual(plain(outcome.results.map((r) => r.path)).sort(), ['added.md', 'keep.md']);
  assert.deepEqual([...state.docs.get('key-a').keys()].sort(), ['added.md', 'keep.md']);
  assert.equal(state.docs.get('key-a').get('keep.md').contentHash, searchStore.contentHashOf('独角兽 新版内容'));
  const again = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.ok(again.reconciledAt > 0, '对账完成后 reconciledAt 要上报给调用方');
  assert.equal(again.indexComplete, true);
});

test('v1.40 40.8 a truncated snapshot must not count missing files as deleted', async () => {
  const { Service, store, state, registry } = setup([{
    id: 'v1', vaultKey: 'key-a', files: {},
    snapshotOverride: { entries: [], truncated: true, failed: false }
  }]);
  await store.markVaultInitialized('key-a');
  state.docs.set('key-a', new Map([
    ['gone.md', { path: 'gone.md', size: 1, mtimeSec: 1, contentHash: 'stale', generation: 0, title: 't', content: '独角兽 已删除' }]
  ]));
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'ready');
  assert.deepEqual(plain(outcome.results), [], '读不到的候选不给出假命中');
  assert.equal(state.docs.get('key-a').has('gone.md'), true, '40.8：截断快照不得把未列出的路径当已删除');
});

test('v1.40 40.8 a failed scan reports error instead of fabricating an empty index', async () => {
  const { Service, state, registry } = setup([{
    id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽 内容' },
    snapshotOverride: { entries: [], truncated: false, failed: true }
  }]);
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'error');
  assert.deepEqual(plain(outcome.results), []);
  assert.equal(state.vaults.has('key-a'), false, '建库失败不能留下半初始化状态');
  assert.equal(state.docs.has('key-a'), false);
});

test('v1.40 40.4 missing tokenizer reports error and never fabricates zero-hit results', async () => {
  const { Service, registry } = setup(
    [{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽 内容' } }],
    { tokenizer: false });
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'error');
  assert.deepEqual(plain(outcome.results), []);
  await assert.rejects(() => Service.search(registry, 'v1', '独角兽', () => {}), /INDEX_UNAVAILABLE/);
});

test('v1.40 40.4 a failed store init keeps failing for the whole process instead of guessing', async () => {
  const { Service, registry } = setup(
    [{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽' } }],
    { initRejects: true });
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'error');
  assert.deepEqual(plain(outcome.results), []);
});

test('v1.40 40.4 a poison pending task is dropped after three failed drains without touching the row', async () => {
  const { Service, state, registry, vaults } = setup([{
    id: 'v1', vaultKey: 'key-a', files: { 'poison.md': '独角兽 毒丸', 'ok.md': '独角兽 正常' }
  }]);
  await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  vaults[0].unreadable.add('poison.md');
  Service.noteSaved('v1', 'poison.md', '任意');
  for (let i = 0; i < 3; i++) {
    const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
    assert.equal(outcome.indexState, 'ready');
    assert.deepEqual(plain(outcome.results.map((r) => r.path)), ['ok.md'], '读不到的候选不能出现在结果里');
  }
  const pending = state.pending.get('key-a');
  assert.equal(pending === undefined || pending.size === 0, true, '连续失败的任务必须被放弃，不能无限重试');
  assert.equal(state.docs.get('key-a').has('poison.md'), true, '放弃任务只清任务，不误删索引行');
});

test('v1.40 40.9 discardVaultKey wipes the vault index and fails later searches', async () => {
  const { Service, state, registry } = setup([{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽 内容' } }]);
  await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  Service.discardVaultKey('key-a');
  await flush();
  assert.deepEqual(state.clearedKeys, ['key-a']);
  assert.equal(state.docs.has('key-a'), false);
  const outcome = await Service.searchDetailed(registry, 'v1', '独角兽', () => {});
  assert.equal(outcome.indexState, 'error');
});

test('v1.40 40.9 startup cleanup clears index rows of vaults missing from the registry', async () => {
  const { Service, state } = setup([{ id: 'v1', vaultKey: 'key-a', files: { 'a.md': '独角兽' } }]);
  state.vaults.set('ghost-key', { initialized: true, lastReconciledAt: 1, scanGeneration: 5 });
  state.docs.set('ghost-key', new Map());
  state.pending.set('ghost-key', new Map());
  await Service.cleanupOrphans();
  assert.deepEqual(state.clearedKeys, ['ghost-key']);
  assert.equal(state.docs.has('ghost-key'), false);
});

// ---------------------------- SearchStoreDevice 结构约束 ----------------------------

test('v1.40 40.1 device store keeps search.db encrypted with the custom tokenizer and rebuilds on drift', () => {
  assert.match(deviceSource, /const DB_NAME: string = 'search\.db'/);
  assert.match(deviceSource, /encrypt: true/);
  assert.match(deviceSource, /relationalStore\.Tokenizer\.CUSTOM_TOKENIZER/);
  assert.match(deviceSource, /relationalStore\.SecurityLevel\.S1/);
  assert.match(deviceSource, /isTokenizerSupported/);
  assert.match(deviceSource, /tokenize='customtokenizer cut_mode short_words'/);
  assert.match(deviceSource, /DROP TABLE IF EXISTS search_fts/);
  assert.match(deviceSource, /UNIQUE \(vault_key, path\)/);
  assert.match(deviceSource, /PRIMARY KEY \(vault_key, path\)/);
});

test('v1.40 40.4 device store enforces generation guards and never deletes by LIKE', () => {
  const noComments = deviceSource
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
  assert.equal(/\bLIKE\b/.test(noComments), false, 'SQLite LIKE 会误删仅大小写不同的路径');
  assert.match(deviceSource, /existingGeneration > taskGeneration/);
  assert.match(deviceSource, /AND generation <= \?/);
  assert.match(deviceSource, /getLong\(2\) <= taskGeneration/);
  assert.match(deviceSource, /getLong\(1\) <= taskGeneration/);
  assert.match(deviceSource, /beginTransaction\(\)/);
  assert.match(deviceSource, /rollBack\(\)/);
});

test('v1.40 40.2 queryContent quotes the whole query as a single FTS5 phrase', () => {
  assert.match(deviceSource, /query\.split\('"\'\)\.join\(' '\)/);
  assert.match(deviceSource, /'"' \+ sanitized \+ '"'/);
});

test('v1.40 privacy: device store logs only codes and table events, never query or content', () => {
  const logLines = deviceSource.split('\n').filter((line) => /hilog\.(info|error)/.test(line));
  assert.equal(logLines.length, 2);
  for (const line of logLines) {
    assert.equal(/query|doc\.|\.path|title|content/.test(line), false);
  }
});

// ---------------------------- 接线与残留检查 ----------------------------

test('v1.40 EntryAbility wires the persistent store into FullTextSearchService at startup', () => {
  assert.match(entryAbilitySource,
    /FullTextSearchService\.configure\(createSearchStore\(this\.context\), registry\)/);
  assert.match(entryAbilitySource, /void FullTextSearchService\.cleanupOrphans\(\)/);
});

test('v1.40 Index wires searchDetailed into the switcher and discards index rows on vault delete', () => {
  assert.match(indexSource, /import \{ SearchOutcome \} from '\.\.\/model\/SearchStore'/);
  assert.match(indexSource, /FullTextSearchService\.searchDetailed\(/);
  assert.match(indexSource, /FullTextSearchService\.discardVaultKey\(vaultKey\)/);
});

test('v1.40 no production source imports the deleted SearchIndex module', () => {
  const mainDir = fileURLToPath(new URL('../../entry/src/main/ets', import.meta.url));
  assert.equal(fs.existsSync(path.join(mainDir, 'model/SearchIndex.ets')), false);
  const offenders = [];
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      if (fs.statSync(full).isDirectory()) {
        walk(full);
      } else if (name.endsWith('.ets') &&
        /from ['"][^'"]*SearchIndex['"]/.test(fs.readFileSync(full, 'utf8'))) {
        offenders.push(path.relative(mainDir, full));
      }
    }
  };
  walk(mainDir);
  assert.deepEqual(offenders, []);
});
