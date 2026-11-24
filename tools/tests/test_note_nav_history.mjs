import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const breakpointSource = readSourceFile(new URL('../../entry/src/main/ets/model/Breakpoint.ets', import.meta.url));
const breakpointCode = transformSync(breakpointSource, { loader: 'ts', format: 'cjs' }).code;
const breakpointModule = { exports: {} };
vm.runInContext(breakpointCode, vm.createContext({ module: breakpointModule, exports: breakpointModule.exports }));
const { Breakpoint } = breakpointModule.exports;

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${startMarker}`);
  return source.slice(start, end).trim();
}

// NOTE_NAV_LIMIT 以源码为准注入 harness，常量值本身有独立断言。
const limitMatch = source.match(/const NOTE_NAV_LIMIT = (\d+);\n/);
assert.ok(limitMatch, 'NOTE_NAV_LIMIT module constant is declared in Index.ets');
const NOTE_NAV_LIMIT = Number(limitMatch[1]);

const code = transformSync(`
class NoteNavHarness {
  ${method('  private pushNoteNav(pane: string, path: string): void {', '\n  /** v2.9：系统返回消费链末端回上一笔记')}
  ${method('  private goBackNoteNav(): boolean {', '\n  private async openVaultManager(')}
  ${method('  onBackPress(): boolean {', '\n  /** 页面隐藏（应用退到后台）')}

  loadFile(relPath) { this.loadFileCalls.push(relPath); }
  loadRightFile(relPath) { this.loadRightFileCalls.push(relPath); }
  setDrawerOpen(open) { this.drawerOpen = open; }
  setSidebarCollapsed(collapsed) { this.sidebarCollapsed = collapsed; }
  scheduleWorkspaceSessionSave() {}
  leaveSecondaryView() { this.topView = 'note'; }
}
module.exports = NoteNavHarness;
`, { loader: 'ts', format: 'cjs' }).code;

let vaultFiles = [];

function createHarness(overrides = {}) {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    Breakpoint,
    NOTE_NAV_LIMIT,
    WikiLinkService: { files: () => vaultFiles },
    VaultRegistry: { get: () => ({}) }
  }));
  const app = new module.exports();
  Object.assign(app, {
    topView: 'note',
    breakpoint: Breakpoint.LG,
    moreMenuOpen: false,
    quickSwitchOpen: false,
    drawerOpen: false,
    focused: false,
    focusNavigationOpen: false,
    sidebarCollapsed: true,
    activePane: 'left',
    experienceMode: 'simple',
    smMode: 'edit',
    currentVaultId: 'vault-a',
    noteNavStack: [],
    loadFileCalls: [],
    loadRightFileCalls: [],
    previewBridge: { closeImageViewer: () => false },
    rightPreviewBridge: { closeImageViewer: () => false }
  }, overrides);
  return app;
}

test('NOTE_NAV_LIMIT source constant is 50 and entries carry pane + path', () => {
  assert.equal(NOTE_NAV_LIMIT, 50);
  assert.match(source, /interface NoteNavEntry \{\s*pane: string;\s*path: string;\s*\}/);
  assert.match(source, /private noteNavStack: NoteNavEntry\[\] = \[\];/);
});

test('link jump records the source note and back reopens it in the same pane', () => {
  vaultFiles = ['notes/a.md', 'notes/b.md'];
  const app = createHarness();

  app.pushNoteNav('left', 'notes/a.md');
  assert.equal(app.goBackNoteNav(), true);
  assert.deepEqual(app.loadFileCalls, ['notes/a.md']);
  assert.deepEqual(app.loadRightFileCalls, []);
  assert.equal(app.noteNavStack.length, 0);

  assert.equal(app.goBackNoteNav(), false);
  assert.deepEqual(app.loadFileCalls, ['notes/a.md']);
});

test('right pane entries reopen through loadRightFile', () => {
  vaultFiles = ['notes/r.md'];
  const app = createHarness();

  app.pushNoteNav('right', 'notes/r.md');
  assert.equal(app.goBackNoteNav(), true);
  assert.deepEqual(app.loadRightFileCalls, ['notes/r.md']);
  assert.deepEqual(app.loadFileCalls, []);
});

test('consecutive identical entries are deduped and empty paths ignored', () => {
  vaultFiles = ['notes/a.md'];
  const app = createHarness();

  app.pushNoteNav('left', 'notes/a.md');
  app.pushNoteNav('left', 'notes/a.md');
  app.pushNoteNav('left', '');
  assert.equal(app.noteNavStack.length, 1);

  app.pushNoteNav('right', 'notes/a.md');
  assert.equal(app.noteNavStack.length, 2);
});

test('stack is capped at NOTE_NAV_LIMIT dropping the oldest entry', () => {
  vaultFiles = [];
  const app = createHarness();

  for (let i = 0; i < NOTE_NAV_LIMIT + 5; i += 1) {
    app.pushNoteNav('left', `notes/n${i}.md`);
  }
  assert.equal(app.noteNavStack.length, NOTE_NAV_LIMIT);
  assert.equal(app.noteNavStack[0].path, 'notes/n5.md');
  assert.equal(app.noteNavStack[NOTE_NAV_LIMIT - 1].path, `notes/n${NOTE_NAV_LIMIT + 4}.md`);
});

test('back skips deleted or renamed targets and keeps popping', () => {
  vaultFiles = ['notes/kept.md'];
  const app = createHarness();

  app.pushNoteNav('left', 'notes/gone.md');
  app.pushNoteNav('right', 'notes/kept.md');
  assert.equal(app.goBackNoteNav(), true);
  assert.deepEqual(app.loadRightFileCalls, ['notes/kept.md']);
  assert.equal(app.noteNavStack.length, 1, 'invalid entry stays until back consumes it');

  app.pushNoteNav('left', 'notes/gone.md');
  assert.equal(app.goBackNoteNav(), false);
  assert.deepEqual(app.loadFileCalls, []);
});

test('onBackPress consumes the note nav history before falling through to the system default', () => {
  vaultFiles = ['notes/a.md'];
  const app = createHarness();

  app.pushNoteNav('left', 'notes/a.md');
  assert.equal(app.onBackPress(), true);
  assert.deepEqual(app.loadFileCalls, ['notes/a.md']);

  assert.equal(app.onBackPress(), false);
  assert.deepEqual(app.loadFileCalls, ['notes/a.md']);
});

test('onBackPress keeps existing consumers ahead of the note nav history', () => {
  vaultFiles = ['notes/a.md'];
  const drawerFirst = createHarness({ drawerOpen: true });
  drawerFirst.pushNoteNav('left', 'notes/a.md');
  assert.equal(drawerFirst.onBackPress(), true);
  assert.equal(drawerFirst.drawerOpen, false);
  assert.deepEqual(drawerFirst.loadFileCalls, []);

  const secondaryFirst = createHarness({ topView: 'settings' });
  secondaryFirst.pushNoteNav('left', 'notes/a.md');
  assert.equal(secondaryFirst.onBackPress(), true);
  assert.equal(secondaryFirst.topView, 'note');
  assert.deepEqual(secondaryFirst.loadFileCalls, []);
  assert.equal(secondaryFirst.noteNavStack.length, 1, 'history survives leaving a secondary view');
});

test('wiki link and vault link jump sites record history before loading', () => {
  const wikiBody = method('  private async handleWikiLinkClick(target: string, pane: string = \'left\'): Promise<void> {',
    '\n  /** 预览里点击库内普通 Markdown 链接');
  assert.equal((wikiBody.match(/this\.pushNoteNav\(pane, sourcePath\);/g) || []).length, 3,
    'resolved / create / re-resolved jump sites each record the source note');
  const vaultBody = method('  private handleVaultLinkClick(href: string, pane: string = \'left\'): void {',
    '\n  /** 编辑器有改动：防抖 500ms');
  assert.equal((vaultBody.match(/this\.pushNoteNav\(pane, sourcePath\);/g) || []).length, 1);
});

test('switching vaults clears the note nav history', () => {
  const switchBody = method('  private async switchVault(id: string): Promise<void> {',
    '\n  private doCreateVault(name: string): void {');
  assert.match(switchBody, /this\.noteNavStack = \[\];/);
  assert.ok(switchBody.indexOf('this.noteNavStack = [];') > switchBody.indexOf('VaultRegistry.get().setCurrent(id)'),
    'history clears after the registry switch commits');
});
