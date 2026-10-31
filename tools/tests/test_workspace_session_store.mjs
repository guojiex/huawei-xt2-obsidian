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

function session(overrides = {}) {
  return {
    schemaVersion: 1,
    vaultId: 'local',
    leftPath: '10_写作/a.md',
    rightPath: '20_样式/b.md',
    leftMode: 'edit',
    rightEditing: false,
    activePane: 'left',
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
  const pathEnumeration = indexSource.indexOf('const validPaths: string[] = FileTree.allMarkdownFiles');
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
