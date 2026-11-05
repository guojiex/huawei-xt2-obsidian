import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

function loadModule(source, globals = {}) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} }, ...globals });
  vm.runInContext(code, context);
  return context.module.exports;
}

const vaultModule = loadModule(readSourceFile(
  new URL('../../entry/src/main/ets/model/Vault.ets', import.meta.url)));
const registrySource = readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));

function createRegistry(vaultIds = [], existingPaths = [], ioOverrides = {}, externalAccessFactory = () => ({
  snapshot: () => [
    { name: 'note.md', isDir: false },
    { name: 'attachments', isDir: true }
  ]
})) {
  const paths = new Set(existingPaths);
  const fileOps = [];
  const fileIo = {
    accessSync(path) { return paths.has(path); },
    mkdirSync(path) { fileOps.push(['mkdir', path]); paths.add(path); },
    renameSync(source, target) { fileOps.push(['rename', source, target]); },
    statSync(path) { fileOps.push(['stat', path]); return { isDirectory: () => true }; },
    listFileSync(path) { fileOps.push(['list', path]); return []; },
    unlinkSync(path) { fileOps.push(['unlink', path]); paths.delete(path); },
    rmdirSync(path) { fileOps.push(['rmdir', path]); paths.delete(path); },
    ...ioOverrides
  };
  const { VaultRegistry } = loadModule(registrySource, {
    DEFAULT_VAULT_ID: vaultModule.DEFAULT_VAULT_ID,
    SAMPLE_VAULT_ID: vaultModule.SAMPLE_VAULT_ID,
    sanitizeVaultName: vaultModule.sanitizeVaultName,
    createExternalVaultAccess: externalAccessFactory,
    fileIo,
    hilog: { warn() {}, info() {}, error() {}, debug() {} }
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
    gitImportMarkerDir: (id) => `/sandbox/vaults/.git-imports/${id}`,
    // v1.5 15.6：删库要顺带清掉 App 私有数据（回收站 / 草稿），两者都在沙箱里按 vaultKey 分目录。
    trashDir: (key) => `/sandbox/trash/${key}`,
    draftsVaultDir: (key) => `/sandbox/drafts/${key}`
  };
  registry.ensureVaultsRoot = () => {};
  // v1.5：真机构造才会走到类字段初始化，这里用原型手工搭的对象得自己补上缓存 Map。
  registry.accessCache = new Map();
  registry.newVaultKey = () => 'new-key';
  registry.isSafeVaultKey = (key) => key.length > 0;
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

test('external registration stores the picker URI without copying or resolving it as a sandbox path', () => {
  const snapshots = [];
  const { registry, fileOps } = createRegistry([], [], {}, (uri) => ({
    snapshot() {
      snapshots.push(uri);
      return [
        { name: '嵌套/笔记.MARKDOWN', isDir: false },
        { name: '附件', isDir: true }
      ];
    }
  }));

  const entry = registry.registerExternal('My Notes', 'file://docs/picked/My%20Notes', 12345);

  assert.deepEqual(snapshots, ['file://docs/picked/My%20Notes']);
  assert.equal(entry.id, 'My Notes');
  assert.equal(entry.type, 'local');
  assert.equal(entry.rootKind, 'external');
  assert.equal(entry.rootUri, 'file://docs/picked/My%20Notes');
  assert.equal(entry.grantedAt, 12345);
  assert.equal(registry.accessCache.get(entry.id) !== undefined, true);
  assert.deepEqual(fileOps, [['persist']]);
});

test('external registration rejects a folder with no visible Markdown before changing registry state', () => {
  const { registry, fileOps } = createRegistry([], [], {}, () => ({ snapshot: () => [
    { name: 'attachments', isDir: true }
  ] }));

  assert.throws(() => registry.registerExternal('Empty', 'file://docs/empty', 12345), /没有可见的 Markdown/);
  assert.equal(registry.state.vaults.length, 0);
  assert.deepEqual(fileOps, []);
});

test('external registration rejects duplicate URIs and invalid URI or grant time', () => {
  const { registry } = createRegistry();
  registry.state.vaults.push({
    id: 'Existing', vaultKey: 'existing-key', type: 'local', createdAt: 1,
    rootKind: 'external', rootUri: 'file://docs/existing', grantedAt: 1
  });

  assert.throws(() => registry.registerExternal('Again', 'file://docs/existing', 2), /已经关联/);
  assert.throws(() => registry.registerExternal('Bad', '/ordinary/path', 2), /URI 无效/);
  assert.throws(() => registry.registerExternal('Bad', 'file://docs/bad', 0), /授权时间无效/);
  assert.equal(registry.state.vaults.length, 1);
});

test('external registration persistence failure rolls back the entry and accessor cache', () => {
  const { registry } = createRegistry();
  registry.persist = (mustSucceed = false) => {
    if (mustSucceed) throw new Error('preferences flush failed');
  };

  assert.throws(() => registry.registerExternal('Failure', 'file://docs/failure', 12345), /preferences flush failed/);
  assert.equal(registry.state.vaults.length, 0);
  assert.equal(registry.accessCache.size, 0);
});

test('Git push branch defaults to xt2 and stays with its vault through rename', () => {
  const { registry } = createRegistry([], ['/sandbox/vaults/repo']);
  const entry = registry.registerGit('repo', 'https://example.invalid/repo.git', 'main', '');

  assert.equal(entry.pushBranch, 'xt2');
  registry.updateGitPushBranch('repo', 'phone/notes');
  assert.equal(registry.list()[0].pushBranch, 'phone/notes');

  const renamed = registry.rename('repo', 'renamed');
  assert.equal(renamed.pushBranch, 'phone/notes');
  assert.equal(registry.list()[0].pushBranch, 'phone/notes');
});

test('Git push branches are isolated by vault', () => {
  const { registry } = createRegistry([], ['/sandbox/vaults/first', '/sandbox/vaults/second']);
  registry.registerGit('first', 'https://example.invalid/first.git', 'main', '');
  registry.registerGit('second', 'https://example.invalid/second.git', 'master', '');

  registry.updateGitPushBranch('first', 'phone/notes');
  registry.updateGitPushBranch('second', 'tablet/notes');

  assert.deepEqual(Array.from(registry.list(), (entry) => entry.pushBranch),
    ['phone/notes', 'tablet/notes']);
});

test('legacy Git registry entries without a push branch default to xt2', () => {
  const { registry } = createRegistry();

  const loaded = registry.parseState(JSON.stringify({
    vaults: [{ id: 'repo', type: 'git', createdAt: 1, branch: 'main' }],
    currentVaultId: 'repo'
  }));

  assert.equal(loaded.vaults[0].branch, 'main');
  assert.equal(loaded.vaults[0].pushBranch, 'xt2');
});

test('Git push branch persistence failure restores the previous per-vault value', () => {
  const { registry } = createRegistry();
  const entry = {
    id: 'repo', vaultKey: 'repo-key', type: 'git', createdAt: 1, pushBranch: 'xt2'
  };
  registry.state.vaults.push(entry);
  registry.persist = (mustSucceed = false) => {
    if (mustSucceed) throw new Error('preferences flush failed');
  };

  assert.throws(() => registry.updateGitPushBranch('repo', 'phone/notes'), /preferences flush failed/);
  assert.equal(entry.pushBranch, 'xt2');
});

test('rename to an occupied name takes the next suffix and leaves the other vault untouched', () => {
  const { registry, fileOps } = createRegistry(['A', 'A-2'], ['/sandbox/vaults/A', '/sandbox/vaults/A-2']);

  const renamed = registry.rename('A', 'A-2');

  assert.equal(renamed.id, 'A-2-2');
  assert.equal(registry.state.currentVaultId, 'A-2-2');
  assert.deepEqual(registry.state.vaults.map((vault) => vault.id), ['A-2-2', 'A-2']);
  assert.deepEqual(fileOps.filter((op) => op[0] === 'rename'),
    [['rename', '/sandbox/vaults/A', '/sandbox/vaults/A-2-2']]);
});

test('rename rejects an illegal name without touching the registry or the filesystem', () => {
  const { registry, fileOps } = createRegistry(['A'], ['/sandbox/vaults/A']);

  assert.throws(() => registry.rename('A', ' . '), /库名不能为空/);
  assert.deepEqual(fileOps, []);
  assert.deepEqual(registry.state.vaults.map((vault) => vault.id), ['A']);
  assert.equal(registry.state.currentVaultId, 'A');
});

test('removing the last vault empties the registry and the same name can be created again', () => {
  const { registry, fileOps } = createRegistry(['A'], ['/sandbox/vaults/A']);

  registry.remove('A');
  assert.equal(registry.state.vaults.length, 0);
  assert.equal(registry.state.currentVaultId, '');

  const recreated = registry.createLocal('A');
  assert.equal(recreated.id, 'A');
  assert.equal(recreated.type, 'local');
  assert.equal(registry.state.vaults.length, 1);
  assert.ok(fileOps.some((op) => op[0] === 'rmdir' && op[1] === '/sandbox/vaults/A'));
  assert.ok(fileOps.some((op) => op[0] === 'mkdir' && op[1] === '/sandbox/vaults/A'));
});

test('removing a vault also clears its trash and drafts directories', () => {
  const { registry, fileOps } = createRegistry(
    ['A'],
    ['/sandbox/vaults/A', '/sandbox/trash/key-0', '/sandbox/drafts/key-0']
  );

  registry.remove('A');

  // 按 vaultKey（不是 id）定位 —— 库改名之后私有数据仍找得到，这是 15.6 的要点。
  assert.ok(fileOps.some((op) => op[0] === 'rmdir' && op[1] === '/sandbox/trash/key-0'),
    '删库必须清掉该库的回收站');
  assert.ok(fileOps.some((op) => op[0] === 'rmdir' && op[1] === '/sandbox/drafts/key-0'),
    '删库必须清掉该库的草稿');
});

test('external vault removal persists detachment before clearing sandbox-private data', () => {
  const { registry, paths, fileOps } = createRegistry([], [
    '/sandbox/trash/external-key',
    '/sandbox/drafts/external-key'
  ]);
  registry.state.vaults.push({
    id: 'External', vaultKey: 'external-key', type: 'local', createdAt: 1,
    rootKind: 'external', rootUri: 'file://docs/external', grantedAt: 1
  });
  registry.state.currentVaultId = 'External';
  registry.persist = (mustSucceed = false) => {
    assert.equal(mustSucceed, true);
    fileOps.push(['persist-external-detach']);
    return true;
  };

  registry.remove('External');

  assert.equal(registry.state.vaults.length, 0);
  assert.ok(fileOps.findIndex((op) => op[0] === 'persist-external-detach') <
    fileOps.findIndex((op) => op[0] === 'rmdir' && op[1] === '/sandbox/trash/external-key'));
  assert.equal(paths.has('/sandbox/trash/external-key'), false);
  assert.equal(paths.has('/sandbox/drafts/external-key'), false);
  assert.equal(fileOps.some((op) => op[1] === '/sandbox/vaults/External'), false,
    '解除外部关联不得递归删除授权目录');
});

test('external vault removal persistence failure preserves private data and restores registry state', () => {
  const { registry, paths, fileOps } = createRegistry([], [
    '/sandbox/trash/external-key',
    '/sandbox/drafts/external-key'
  ]);
  const entry = {
    id: 'External', vaultKey: 'external-key', type: 'local', createdAt: 1,
    rootKind: 'external', rootUri: 'file://docs/external', grantedAt: 1
  };
  registry.state.vaults.push(entry);
  registry.state.currentVaultId = 'External';
  registry.accessCache.set('External', {});
  registry.persist = () => {
    fileOps.push(['persist-external-detach-failed']);
    throw new Error('preferences flush failed');
  };

  assert.throws(() => registry.remove('External'), /preferences flush failed/);

  assert.deepEqual(registry.state.vaults, [entry]);
  assert.equal(registry.state.currentVaultId, 'External');
  assert.equal(registry.accessCache.has('External'), false,
    '调用方已释放系统授权，失败时应忘记旧访问器');
  assert.equal(paths.has('/sandbox/trash/external-key'), true);
  assert.equal(paths.has('/sandbox/drafts/external-key'), true);
  assert.equal(fileOps.some((op) => op[0] === 'rmdir'), false,
    'Preferences 落盘失败时不得清除可恢复私有数据');
});

test('a failing private data cleanup does not resurrect a half-removed registry', () => {
  const { registry } = createRegistry(
    ['A'],
    ['/sandbox/vaults/A', '/sandbox/trash/key-0'],
    {
      statSync(path) {
        if (path === '/sandbox/trash/key-0') {
          throw new Error('回收站占用中');
        }
        return { isDirectory: () => true };
      }
    }
  );

  // 库目录已经删掉了，这里必须留一个「注册表已净」而不是抛回去变成半状态。
  registry.remove('A');
  assert.equal(registry.state.vaults.length, 0);
});

test('a failing vault tree removal keeps the entry and the current vault in the registry', () => {
  const { registry } = createRegistry(['A', 'B'], ['/sandbox/vaults/A', '/sandbox/vaults/B'], {
    statSync(path) {
      if (path === '/sandbox/vaults/A') {
        throw new Error('读取目录失败');
      }
      return { isDirectory: () => true };
    }
  });

  assert.throws(() => registry.remove('A'), /读取目录失败/);
  assert.deepEqual(registry.state.vaults.map((vault) => vault.id), ['A', 'B']);
  assert.equal(registry.state.currentVaultId, 'A');
});

test('first install creates a personal vault and tutorial vault with the tutorial note pending', () => {
  const { registry } = createRegistry();
  registry.sampleInstallPending = true;

  registry.createInitialVaults();

  assert.deepEqual(registry.state.vaults.map((vault) => vault.id), [
    vaultModule.DEFAULT_VAULT_ID,
    vaultModule.SAMPLE_VAULT_ID
  ]);
  assert.equal(registry.state.currentVaultId, vaultModule.SAMPLE_VAULT_ID);
  assert.equal(registry.firstInstallNotePath(), '00_开始/快速上手.md');
});

test('existing registries retain a valid first-install marker and ignore malformed values', () => {
  const { registry } = createRegistry();
  const vault = { id: 'local', vaultKey: 'key-0', type: 'local', createdAt: 0 };

  assert.equal(registry.parseState(JSON.stringify({ vaults: [vault], currentVaultId: 'local' }))?.initialNotePath,
    undefined);
  assert.equal(registry.parseState(JSON.stringify({
    vaults: [vault], currentVaultId: 'local', initialNotePath: '00_开始/快速上手.md'
  }))?.initialNotePath, '00_开始/快速上手.md');
  assert.equal(registry.parseState(JSON.stringify({
    vaults: [vault], currentVaultId: 'local', initialNotePath: 42
  }))?.initialNotePath, undefined);
});

test('first-install marker remains pending if the registry cannot persist its removal', () => {
  const { registry } = createRegistry();
  registry.state.initialNotePath = '00_开始/快速上手.md';
  registry.persist = () => false;

  assert.equal(registry.markFirstInstallNoteOpened(), false);
  assert.equal(registry.firstInstallNotePath(), '00_开始/快速上手.md');

  registry.persist = () => true;
  assert.equal(registry.markFirstInstallNoteOpened(), true);
  assert.equal(registry.firstInstallNotePath(), '');
});
