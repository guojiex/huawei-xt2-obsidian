import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const tokens = readSourceFile(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const start = source.indexOf('  private async closePaneNote(paneName: string): Promise<void> {');
const end = source.indexOf('\n  private focusEmptyPane(', start);
assert.ok(start >= 0 && end > start, 'could not find Index.closePaneNote');

const closeMethod = source.slice(start, end).trim();
const code = transformSync(`class IndexHarness { ${closeMethod} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(options = {}) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    promptAction: { showToast: ({ message }) => calls.push(`toast:${message}`) },
    hilog: { warn: (...args) => calls.push(`warn:${args[1]}`) },
    DOMAIN: 0,
    TAG: 'Index'
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  const bridge = (name) => ({
    beginDocumentTransition() {
      calls.push(`begin:${name}`);
      return name === 'left' ? 11 : 22;
    },
    restoreDocumentTransition(id) {
      calls.push(`restore:${name}:${id}`);
    }
  });
  const store = {
    recordClosed(vaultId, pane, path) {
      calls.push(`closed:${vaultId}:${pane}:${path}`);
    }
  };
  Object.assign(app, {
    calls,
    topView: 'note',
    currentVaultId: 'vault-a',
    currentFilePath: options.leftPath ?? 'left.md',
    rightFilePath: options.rightPath ?? 'right.md',
    activePane: options.activePane ?? 'left',
    experienceMode: options.experienceMode ?? 'professional',
    workspaceOpenRequests: 0,
    leftOpenRequestId: 1,
    rightOpenRequestId: 2,
    paneCloseRequestSequence: 0,
    leftCloseRequestId: 0,
    rightCloseRequestId: 0,
    leftComposing: false,
    rightComposing: false,
    rightPaneIntentionallyEmpty: false,
    formatMenuOpen: false,
    tableGridOpen: false,
    blockPanelPane: '',
    blockToolbarPane: '',
    paneMorePane: '',
    backlinksPane: '',
    recentOpenStore: store,
    editorBridge: bridge('left'),
    rightEditorBridge: bridge('right'),
    paneFilePath(pane) {
      return pane === 'right' ? this.rightFilePath : this.currentFilePath;
    },
    simpleWorkspacePane() {
      return this.activePane;
    },
    sharedNoteEditor() {
      return this.activePane === 'right' ? this.rightEditorBridge : this.editorBridge;
    },
    async flushRightSave(path, vaultId) {
      calls.push(`save-right:${path}:${vaultId}`);
      return options.saveResult ?? true;
    },
    async flushSave(path, vaultId, bridgeArg) {
      calls.push(`save-left:${path}:${vaultId}:${bridgeArg === this.rightEditorBridge ? 'right' : 'left'}`);
      return options.saveResult ?? true;
    },
    setActivePane(pane) {
      this.activePane = pane;
      calls.push(`active:${pane}`);
    },
    closeFormatMenu() {
      calls.push('format-close');
    },
    isBlockPropertyPanelOpen() {
      return false;
    },
    closeBlockPropertyPanel() {},
    closeBlockToolbar() {},
    paneCloseHovered: '',
    async readRightAndPush(path, requestId) {
      calls.push(`clear-right:${path}:${requestId}`);
      if (options.readRightAndPush) {
        return await options.readRightAndPush.call(this, path, requestId);
      }
      return true;
    },
    async readAndPush(path, initializeRight, requestId) {
      calls.push(`clear-left:${path}:${requestId}`);
      if (options.readAndPush) {
        return await options.readAndPush.call(this, path, initializeRight, requestId);
      }
      return true;
    },
    ensureRecentOpenStore() {},
    refreshRecentOpenPaths() {
      if (options.refreshRecentOpenPaths) {
        options.refreshRecentOpenPaths.call(this);
      }
      this.rightLastClosedPath = this.rightFilePath.length === 0 ? 'right.md' : '';
      this.leftLastClosedPath = this.currentFilePath.length === 0 ? 'left.md' : '';
    },
    flushWorkspaceSessionSave() {
      calls.push('session-save');
      return true;
    },
    focusEmptyPane(pane) {
      calls.push(`focus-empty:${pane}`);
    },
    showFailureFeedback(...args) {
      calls.push(`failure:${args[0]}:${args[1]}:${args[5]}`);
    }
  });
  return app;
}

test('closing a pane saves first and leaves the other pane untouched', async () => {
  const app = createHarness();

  await app.closePaneNote('right');

  assert.equal(app.rightFilePath, '');
  assert.equal(app.currentFilePath, 'left.md');
  assert.equal(app.rightPaneIntentionallyEmpty, true);
  assert.equal(app.rightOpenRequestId, 3);
  assert.equal(app.rightCloseRequestId, 0);
  assert.ok(app.calls.indexOf('save-right:right.md:vault-a') < app.calls.indexOf('clear-right::3'));
  assert.ok(app.calls.includes('closed:vault-a:right:right.md'));
  assert.ok(app.calls.includes('session-save'));
  assert.ok(app.calls.includes('focus-empty:right'));
  assert.equal(app.calls.some((call) => call.startsWith('failure:')), false);
});

test('closing one side of a same-note pair saves the active editor and keeps its sibling open', async () => {
  const app = createHarness({ leftPath: 'shared.md', rightPath: 'shared.md', activePane: 'right' });

  await app.closePaneNote('left');

  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, 'shared.md');
  assert.equal(app.calls.includes('save-left:shared.md:vault-a:right'), true);
  assert.equal(app.calls.includes('closed:vault-a:left:shared.md'), true);
});

test('a failed save prevents clearing the pane or recording a closed path', async () => {
  const app = createHarness({ saveResult: false });

  await app.closePaneNote('right');

  assert.equal(app.rightFilePath, 'right.md');
  assert.equal(app.calls.some((call) => call.startsWith('clear-right:')), false);
  assert.equal(app.calls.some((call) => call.startsWith('closed:')), false);
  assert.equal(app.rightCloseRequestId, 0);
});

test('a failed bridge clear restores the saved note path and document transition', async () => {
  const app = createHarness({
    readRightAndPush(path) {
      return Promise.resolve(path.length > 0);
    }
  });

  await app.closePaneNote('right');
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(app.rightFilePath, 'right.md');
  assert.equal(app.rightPaneIntentionallyEmpty, false);
  assert.ok(app.calls.includes('restore:right:22'));
  assert.ok(app.calls.includes('clear-right:right.md:3'));
  assert.ok(app.calls.some((call) => call.startsWith('failure:note:bridge:')));
  assert.equal(app.calls.some((call) => call.startsWith('closed:')), false);
});

test('recent-note refresh failure does not reopen a pane after its bridge was cleared', async () => {
  const app = createHarness({
    refreshRecentOpenPaths() {
      throw new Error('index unavailable');
    }
  });

  await app.closePaneNote('right');

  assert.equal(app.rightFilePath, '');
  assert.equal(app.rightPaneIntentionallyEmpty, true);
  assert.ok(app.calls.includes('session-save'));
  assert.ok(app.calls.includes('focus-empty:right'));
  assert.equal(app.calls.some((call) => call.startsWith('failure:')), false);
});

test('a new pane target arriving during clear is not overwritten or reported as a close failure', async () => {
  let finishClear;
  const app = createHarness({
    readRightAndPush(path) {
      if (path === '') {
        return new Promise((resolve) => {
          finishClear = () => {
            this.rightFilePath = 'new.md';
            this.rightOpenRequestId++;
            resolve(false);
          };
        });
      }
      return Promise.resolve(true);
    }
  });

  const closing = app.closePaneNote('right');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(typeof finishClear, 'function');
  finishClear();
  await closing;

  assert.equal(app.rightFilePath, 'new.md');
  assert.equal(app.calls.some((call) => call.startsWith('failure:')), false);
  assert.equal(app.calls.some((call) => call.startsWith('restore:right:')), false);
});

test('a stale simple-preview response cannot show an error for the newly opened note', async () => {
  const app = createHarness({ experienceMode: 'simple' });
  app.flushSimplePreviewPane = async function () {
    this.currentFilePath = 'new-left.md';
    this.leftOpenRequestId++;
    return '左栏笔记目标已变化';
  };

  await app.closePaneNote('right');

  assert.equal(app.rightFilePath, 'right.md');
  assert.equal(app.calls.some((call) => call.startsWith('failure:')), false);
  assert.equal(app.calls.some((call) => call.startsWith('save-right:')), false);
});

test('the shared path row exposes a labeled 40vp close action and empty panes hide it', () => {
  const start = source.indexOf('  PaneTitle($$: PaneHeadParam) {');
  const end = source.indexOf('\n  @Builder', start);
  const paneTitle = source.slice(start, end);

  assert.match(paneTitle, /if \(this\.paneFilePath\(\$\$\.pane\)\.length > 0\)/);
  assert.match(paneTitle, /\.width\(Size\.paneClose\)\s*\.height\(Size\.paneClose\)/);
  assert.match(paneTitle, /\.accessibilityText\('关闭笔记：' \+/);
  assert.match(tokens, /static readonly paneClose: number = Space\.s10;/);
});

test('the app-bar share entry is hidden while the active pane is empty', () => {
  const start = source.indexOf('      if (this.topView === \'note\') {', source.indexOf('@Builder\n  Appbar'));
  const end = source.indexOf('\n      } else if (this.topView === \'agent\') {', start);
  const noteAppBar = source.slice(start, end);

  assert.match(noteAppBar, /if \(this\.activeFilePath\(\)\.length > 0\) \{\s*this\.IconButton\('share'/);
});

// —— v1.28 崩溃回归（DFX JSCrash 2026-11-06）：点击「关闭笔记」闪退 ——
// 空库时 EmptyPane 只渲染「新建笔记」，不渲染「重新打开」行；且 setTimeout(0)
// 可能先于空栏挂载执行，requestFocus 抛 150003 必须被兜住。
const focusStart = source.indexOf('  private focusEmptyPane(pane: string): void {');
const focusEnd = source.indexOf('\n  private focusPaneBody(', focusStart);
assert.ok(focusStart >= 0 && focusEnd > focusStart, 'could not find Index.focusEmptyPane');
const focusMethod = source.slice(focusStart, focusEnd).trim();
const focusCode = transformSync(`class IndexHarness { ${focusMethod} }; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createFocusHarness(options = {}) {
  const requested = [];
  const warns = [];
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout: (fn) => fn(),
    hilog: { warn: (...args) => warns.push(args[2]) },
    DOMAIN: 0,
    TAG: 'Index'
  });
  vm.runInContext(focusCode, context);
  const app = new context.module.exports();
  Object.assign(app, {
    currentVaultNoteCount: options.noteCount ?? 0,
    leftLastClosedPath: options.leftLastClosedPath ?? '',
    rightLastClosedPath: options.rightLastClosedPath ?? '',
    paneLastClosedPath(pane) {
      return pane === 'right' ? this.rightLastClosedPath : this.leftLastClosedPath;
    },
    getUIContext() {
      return {
        getFocusController() {
          return {
            requestFocus(id) {
              if (options.requestFocusThrows) {
                throw new Error('150003 request focus failed');
              }
              requested.push(id);
            }
          };
        }
      };
    }
  });
  return { app, requested, warns };
}

test('focusEmptyPane aligns its target with the rendered empty pane branch', () => {
  // 空库 + 有最近关闭路径：渲染侧只有「新建笔记」，焦点不得指向必然不存在的 reopen 行
  const emptyVault = createFocusHarness({ noteCount: 0, rightLastClosedPath: 'a.md' });
  emptyVault.app.focusEmptyPane('right');
  assert.deepEqual(emptyVault.requested, ['pane-empty-new-right']);

  // 非空库 + 有最近关闭路径：指向 reopen 行
  const nonEmpty = createFocusHarness({ noteCount: 3, rightLastClosedPath: 'a.md' });
  nonEmpty.app.focusEmptyPane('right');
  assert.deepEqual(nonEmpty.requested, ['pane-empty-reopen-right']);

  // 非空库 + 无最近关闭路径：指向新建
  const noRecent = createFocusHarness({ noteCount: 3 });
  noRecent.app.focusEmptyPane('right');
  assert.deepEqual(noRecent.requested, ['pane-empty-new-right']);
});

test('a requestFocus miss (150003) no longer crashes the close flow', () => {
  const thrown = createFocusHarness({
    noteCount: 3,
    rightLastClosedPath: 'a.md',
    requestFocusThrows: true
  });

  assert.doesNotThrow(() => thrown.app.focusEmptyPane('right'));
  assert.deepEqual(thrown.requested, []);
  assert.ok(thrown.warns.includes('空栏焦点请求未命中目标组件'));
});
