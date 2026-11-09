import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/WorkspaceSessionStore.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('export interface WorkspaceSession {');
const end = source.indexOf('\nexport class WorkspaceSessionStore', start);
assert.ok(start >= 0 && end > start, 'could not find pure workspace session model');
const code = transformSync(source.slice(start, end).replace(/^export /gm, ''), {
  loader: 'ts',
  format: 'cjs'
}).code + '\nmodule.exports = { parseWorkspaceSession, workspaceSessionPaths, restoreWorkspacePane };';
const module = { exports: {} };
vm.runInContext(code, vm.createContext({ module, exports: module.exports, JSON, Number }));
const { parseWorkspaceSession, workspaceSessionPaths, restoreWorkspacePane } = module.exports;

// v1.47 47.4：每库会话键。切片覆盖整个类，用内存 Preferences 模拟鸿蒙 preferences。
const classStart = source.indexOf('export class WorkspaceSessionStore');
assert.ok(classStart >= 0, 'could not find WorkspaceSessionStore class');
const classCode = transformSync(source.slice(classStart).replace(/^export /gm, ''), {
  loader: 'ts',
  format: 'cjs'
}).code + '\nmodule.exports = WorkspaceSessionStore;';
const classModule = { exports: {} };

function createMemoryPreferences() {
  const values = new Map();
  return {
    getSync: (key, defaultValue) => (values.has(key) ? values.get(key) : defaultValue),
    putSync: (key, value) => values.set(key, value),
    deleteSync: (key) => values.delete(key),
    flushSync: () => true,
    snapshot: () => new Map(values)
  };
}

function createStoreHarness(initial = {}) {
  const preferencesMock = createMemoryPreferences();
  for (const [key, value] of Object.entries(initial)) {
    preferencesMock.putSync(key, value);
  }
  const context = vm.createContext({
    module: classModule,
    exports: classModule.exports,
    JSON,
    Number,
    console: { warn() {} },
    preferences: { getPreferencesSync: () => preferencesMock }
  });
  // 先跑纯模型切片：类里的 parseWorkspaceSession 依赖它在同上下文声明
  vm.runInContext(code, context);
  vm.runInContext(classCode, context);
  const StoreClass = classModule.exports;
  return { store: new StoreClass({}), preferencesMock };
}

function session(overrides = {}) {
  return {
    schemaVersion: 1,
    vaultId: 'local',
    leftPath: '10_写作/a.md',
    rightPath: '20_样式/b.md',
    leftMode: 'edit',
    rightEditing: false,
    activePane: 'left',
    rightPaneIntentionallyEmpty: false,
    referenceVisible: true,
    sidebarCollapsed: true,
    drawerOpen: false,
    focused: false,
    sidebarTab: 'files',
    selectedChapterOffset: -1,
    leftEditorScrollTop: 120,
    leftPreviewScrollTop: 0,
    rightEditorScrollTop: 0,
    rightPreviewScrollTop: 860,
    ...overrides
  };
}

test('workspace session parses the supported UI-only snapshot', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(parseWorkspaceSession(JSON.stringify(session())))), session());
});

test('workspace session writer serializes only the approved UI state', () => {
  const match = /const session: WorkspaceSession = \{([\s\S]*?)\n    \};/.exec(indexSource);
  assert.ok(match, 'could not find the workspace session writer');
  const serializedFields = Array.from(match[1].matchAll(/^\s{6}([A-Za-z][A-Za-z0-9]*):/gm),
    (field) => field[1]);
  assert.deepEqual(serializedFields.sort(), Object.keys(session()).sort());
});

test('workspace session rejects unknown versions and invalid enum or scroll state', () => {
  assert.equal(parseWorkspaceSession(JSON.stringify(session({ schemaVersion: 2 }))), null);
  assert.equal(parseWorkspaceSession(JSON.stringify(session({ leftMode: 'share' }))), null);
  assert.equal(parseWorkspaceSession(JSON.stringify(session({ rightPreviewScrollTop: -1 }))), null);
  assert.equal(parseWorkspaceSession('{broken'), null);
});

test('older workspace sessions default the intentional-empty marker to false', () => {
  const older = session();
  delete older.rightPaneIntentionallyEmpty;
  assert.equal(parseWorkspaceSession(JSON.stringify(older)).rightPaneIntentionallyEmpty, false);
  assert.equal(parseWorkspaceSession(JSON.stringify(session({
    rightPaneIntentionallyEmpty: true,
    rightPath: ''
  }))).rightPaneIntentionallyEmpty, true);
  assert.equal(parseWorkspaceSession(JSON.stringify(session({
    rightPaneIntentionallyEmpty: 'true'
  }))), null);
});

test('single-screen recovery keeps only the previously visible pane', () => {
  const paths = ['10_写作/a.md', '20_样式/b.md'];
  assert.deepEqual(JSON.parse(JSON.stringify(workspaceSessionPaths(session(), true, paths))), {
    leftPath: '10_写作/a.md', rightPath: ''
  });
  assert.deepEqual(JSON.parse(JSON.stringify(workspaceSessionPaths(session({ activePane: 'right' }), true, paths))), {
    leftPath: '', rightPath: '20_样式/b.md'
  });
  assert.deepEqual(JSON.parse(JSON.stringify(workspaceSessionPaths(session({ activePane: 'right' }), true,
    ['10_写作/a.md']))), { leftPath: '', rightPath: '' });
});

test('wide recovery restores both panes and drops paths no longer in the current library', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(workspaceSessionPaths(session(), false, ['10_写作/a.md', '20_样式/b.md']))), {
    leftPath: '10_写作/a.md', rightPath: '20_样式/b.md'
  });
  assert.deepEqual(JSON.parse(JSON.stringify(workspaceSessionPaths(session(), false, ['10_写作/a.md']))), {
    leftPath: '10_写作/a.md', rightPath: ''
  });
});

test('moved or deleted session paths clear their panes without guessing by filename', async () => {
  const movedOrDeleted = session({ leftPath: '10_写作/old.md', rightPath: '20_样式/deleted.md' });
  const resolved = workspaceSessionPaths(movedOrDeleted, false, ['10_写作/renamed.md', '99_其他/old.md']);
  assert.deepEqual(JSON.parse(JSON.stringify(resolved)), { leftPath: '', rightPath: '' });

  const events = [];
  assert.equal(await restoreWorkspacePane(resolved.leftPath, async (path) => {
    events.push('open-left:' + path);
    return true;
  }, async () => events.push('clear-left')), false);
  assert.equal(await restoreWorkspacePane(resolved.rightPath, async (path) => {
    events.push('open-right:' + path);
    return true;
  }, async () => events.push('clear-right')), false);
  assert.deepEqual(events, ['clear-left', 'clear-right']);

  const vaultGuard = indexSource.indexOf('const hasVault: boolean = registry.list().some');
  const pathEnumeration = indexSource.indexOf('const validPaths: string[] = FileTree.allNotesOf');
  assert.ok(vaultGuard >= 0 && pathEnumeration > vaultGuard,
    'the saved vault must exist before its paths can be considered for recovery');
});

test('pane restore falls back independently after unreadable or throwing targets', async () => {
  const events = [];
  const leftOpened = await restoreWorkspacePane('10_写作/a.md', async () => {
    throw new Error('left read failed');
  }, async () => events.push('clear-left'));
  const rightOpened = await restoreWorkspacePane('20_样式/b.md', async () => true,
    async () => events.push('clear-right'));
  assert.equal(leftOpened, false);
  assert.equal(rightOpened, true);
  assert.deepEqual(events, ['clear-left']);
});

test('pane restore clears empty or unreadable targets without propagating fallback failures', async () => {
  let clearCount = 0;
  assert.equal(await restoreWorkspacePane('', async () => true, async () => { clearCount++; }), false);
  assert.equal(await restoreWorkspacePane('10_写作/a.md', async () => false, async () => {
    clearCount++;
    throw new Error('empty state bridge failed');
  }), false);
  assert.equal(clearCount, 2);
});

test('native initialization uses separate left and right restore guards', () => {
  assert.match(indexSource, /restoreWorkspacePane\(leftPath,/);
  assert.match(indexSource, /restoreWorkspacePane\(rightPath,/);
  const scrollMethod = indexSource.slice(indexSource.indexOf('private restoreWorkspaceScrollPositions(): void {'),
    indexSource.indexOf('\n  private applyRestoredChapterSelection(): void {'));
  assert.match(scrollMethod, /try\s*\{[\s\S]*this\.previewBridge\.restoreScrollTop[\s\S]*catch/);
  assert.match(scrollMethod, /try\s*\{[\s\S]*this\.rightPreviewBridge\.restoreScrollTop[\s\S]*catch/);
});

// ===== v1.47 47.4：每库会话键（vault_<id>）与 latest 冷启动键的读写、迁移与清理 =====

test('save writes both the latest key and the per-vault key, and loadFor returns the vault session', () => {
  const { store, preferencesMock } = createStoreHarness();
  const a = session();
  const b = session({ vaultId: 'other', leftPath: '30_项目/c.md' });
  assert.equal(store.save(a), true);
  assert.equal(store.save(b), true);

  assert.equal(preferencesMock.getSync('vault_local', ''), JSON.stringify(a));
  assert.equal(preferencesMock.getSync('vault_other', ''), JSON.stringify(b));
  // latest 始终指向最后一次保存的会话（冷启动用）
  assert.equal(preferencesMock.getSync('latest', ''), JSON.stringify(b));

  assert.equal(store.loadFor('local').leftPath, '10_写作/a.md');
  assert.equal(store.loadFor('other').leftPath, '30_项目/c.md');
  assert.equal(store.loadFor('missing'), null);
});

test('load seeds the per-vault key from latest so the first switch after upgrade keeps the session', () => {
  const a = session();
  const { store, preferencesMock } = createStoreHarness({ latest: JSON.stringify(a) });
  assert.equal(preferencesMock.getSync('vault_local', ''), '');
  assert.equal(store.load().leftPath, '10_写作/a.md');
  // 冷启动 load 时补种每库键：此后切库再回来不丢
  assert.equal(preferencesMock.getSync('vault_local', ''), JSON.stringify(a));
});

test('loadFor falls back to latest only when its vaultId matches the request', () => {
  const a = session();
  const { store } = createStoreHarness({ latest: JSON.stringify(a) });
  assert.equal(store.loadFor('local').vaultId, 'local');
  assert.equal(store.loadFor('other'), null);
});

test('retargetVault migrates the per-vault key, rewrites its vaultId, and fixes latest when it points at the old id', () => {
  const a = session();
  const { store, preferencesMock } = createStoreHarness({
    latest: JSON.stringify(a),
    vault_local: JSON.stringify(a)
  });
  store.retargetVault('local', 'renamed');

  assert.equal(preferencesMock.getSync('vault_local', ''), '');
  const migrated = parseWorkspaceSession(preferencesMock.getSync('vault_renamed', ''));
  assert.equal(migrated.vaultId, 'renamed');
  assert.equal(migrated.leftPath, '10_写作/a.md');
  const latest = parseWorkspaceSession(preferencesMock.getSync('latest', ''));
  assert.equal(latest.vaultId, 'renamed');
});

test('retargetVault leaves the latest key alone when it belongs to another vault', () => {
  const a = session();
  const b = session({ vaultId: 'other', leftPath: '30_项目/c.md' });
  const { store, preferencesMock } = createStoreHarness({ latest: JSON.stringify(b) });
  preferencesMock.putSync('vault_local', JSON.stringify(a));
  store.retargetVault('local', 'renamed');
  assert.equal(parseWorkspaceSession(preferencesMock.getSync('latest', '')).vaultId, 'other');
  assert.equal(parseWorkspaceSession(preferencesMock.getSync('vault_renamed', '')).vaultId, 'renamed');
});

test('removeFor deletes only the per-vault key of the deleted vault', () => {
  const a = session();
  const { store, preferencesMock } = createStoreHarness({ latest: JSON.stringify(a) });
  store.removeFor('local');
  assert.equal(preferencesMock.getSync('vault_local', ''), '');
  assert.equal(preferencesMock.getSync('latest', ''), JSON.stringify(a));
});
