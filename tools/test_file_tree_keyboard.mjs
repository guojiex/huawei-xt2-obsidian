import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/FileTreeView.ets', import.meta.url), 'utf8');
function method(name, signature) {
  const start = source.indexOf(`  private ${name}(${signature}`);
  const nextPrivate = source.indexOf('\n  private ', start + 1);
  const nextDoc = source.indexOf('\n  /**', start + 1);
  const end = [nextPrivate, nextDoc].filter((index) => index >= 0).sort((a, b) => a - b)[0];
  assert.ok(start >= 0 && end > start, `could not find FileTreeView.${name}`);
  return source.slice(start, end).trim();
}

const methods = [
  method('isExpanded', 'relPath: string): boolean'),
  method('onDirectoryKey', 'node: TreeNode, event: KeyEvent): boolean'),
  method('toggleDir', 'relPath: string): void'),
  method('treeRowFocusId', 'node: TreeNode): string'),
  method('pathMenuFocusId', 'node: TreeNode, action: string): string'),
  method('openPathMenu', 'node: TreeNode): void'),
  method('closePathMenu', 'restoreFocus: boolean): void'),
  method('onPathMenuDismiss', 'action: DismissPopupAction): void'),
  method('onTreeRowKey', 'node: TreeNode, event: KeyEvent): boolean'),
  method('runPathMenuAction', 'node: TreeNode, action: string): void')
].join('\n');
const code = transformSync(`class FileTreeHarness { ${methods} }; module.exports = FileTreeHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

const KeyCode = {
  KEYCODE_DPAD_LEFT: 5,
  KEYCODE_DPAD_RIGHT: 6,
  KEYCODE_MENU: 7,
  KEYCODE_F10: 8
};
const KeyType = { Down: 1, Up: 2 };
const DismissReason = { PRESS_BACK: 0, TOUCH_OUTSIDE: 1 };

function createHarness(expanded = []) {
  const calls = [];
  const context = vm.createContext({ module: { exports: {} }, KeyCode, KeyType, DismissReason });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    expanded,
    vaultId: 'local',
    pathMenuPath: '',
    pathMenuReturnFocusId: '',
    referenceOnly: false,
    store: { save(vaultId, next) { calls.push(['save', vaultId, [...next]]); } },
    rescan() { calls.push(['rescan']); },
    getUIContext() {
      return { getFocusController() { return { requestFocus(id) { calls.push(['focus', id]); return true; } }; } };
    },
    onSharePath(...args) { calls.push(['share', ...args]); },
    onRenamePath(...args) { calls.push(['rename', ...args]); },
    onMovePath(...args) { calls.push(['move', ...args]); },
    onDeletePath(...args) { calls.push(['delete', ...args]); }
  });
  return { app, calls };
}

function directory(relPath = 'folder') {
  return { isDir: true, relPath };
}

function key(keyCode, type = KeyType.Down, shiftPressed = false, withModifier = true) {
  const event = { keyCode, type };
  if (withModifier) {
    event.getModifierKeyState = (keys) => keys.includes('Shift') && shiftPressed;
  }
  return event;
}

test('Right expands a collapsed directory and persists the existing tree state', () => {
  const { app, calls } = createHarness();

  assert.equal(app.onDirectoryKey(directory(), key(KeyCode.KEYCODE_DPAD_RIGHT)), true);
  assert.deepEqual(Array.from(app.expanded), ['folder']);
  assert.deepEqual(calls, [['save', 'local', ['folder']], ['rescan']]);
});

test('Left collapses an expanded directory through the same toggle path', () => {
  const { app, calls } = createHarness(['folder']);

  assert.equal(app.onDirectoryKey(directory(), key(KeyCode.KEYCODE_DPAD_LEFT)), true);
  assert.deepEqual(Array.from(app.expanded), []);
  assert.deepEqual(calls, [['save', 'local', []], ['rescan']]);
});

test('opposite direction, key-up, and non-directory rows are left unconsumed', () => {
  const { app, calls } = createHarness(['folder']);

  assert.equal(app.onDirectoryKey(directory(), key(KeyCode.KEYCODE_DPAD_RIGHT)), false);
  assert.equal(app.onDirectoryKey(directory(), key(KeyCode.KEYCODE_DPAD_LEFT, KeyType.Up)), false);
  assert.equal(app.onDirectoryKey({ isDir: false, relPath: 'note.md' }, key(KeyCode.KEYCODE_DPAD_RIGHT)), false);
  assert.equal(app.onDirectoryKey(directory(), key(999)), false);
  assert.deepEqual(Array.from(app.expanded), ['folder']);
  assert.deepEqual(calls, []);
});

test('Menu and Shift+F10 open the focused row menu; plain F10 does not', () => {
  const { app } = createHarness();
  const file = { isDir: false, relPath: 'notes/one.md' };

  assert.equal(app.onTreeRowKey(file, key(KeyCode.KEYCODE_MENU)), true);
  assert.equal(app.pathMenuPath, 'notes/one.md');
  assert.equal(app.pathMenuReturnFocusId, 'file-tree-row-local:notes/one.md');

  app.closePathMenu(false);
  assert.equal(app.onTreeRowKey(file, key(KeyCode.KEYCODE_F10)), false);
  assert.equal(app.onTreeRowKey(file, key(KeyCode.KEYCODE_F10, KeyType.Down, true)), true);
  assert.equal(app.pathMenuPath, 'notes/one.md');
});

test('key-up, unmodified F10, and reference-only rows do not open the menu', () => {
  const { app } = createHarness();
  const folder = directory('folder');

  assert.equal(app.onTreeRowKey(folder, key(KeyCode.KEYCODE_MENU, KeyType.Up)), false);
  assert.equal(app.onTreeRowKey(folder, key(KeyCode.KEYCODE_F10, KeyType.Down, false, false)), false);
  app.referenceOnly = true;
  assert.equal(app.onTreeRowKey(folder, key(KeyCode.KEYCODE_MENU)), false);
  assert.equal(app.pathMenuPath, '');
});

test('Escape or system Back dismisses and restores focus to the original row', () => {
  const { app, calls } = createHarness();
  const folder = directory('folder');
  app.openPathMenu(folder);
  let dismissCount = 0;

  app.onPathMenuDismiss({ reason: DismissReason.PRESS_BACK, dismiss() { dismissCount += 1; } });

  assert.equal(dismissCount, 1);
  assert.equal(app.pathMenuPath, '');
  assert.equal(app.pathMenuReturnFocusId, '');
  assert.deepEqual(calls, [['focus', 'file-tree-row-local:folder']]);
});

test('outside dismissal closes the menu without restoring focus over the new target', () => {
  const { app, calls } = createHarness();
  app.openPathMenu(directory('folder'));

  app.onPathMenuDismiss({ reason: DismissReason.TOUCH_OUTSIDE, dismiss() {} });

  assert.equal(app.pathMenuPath, '');
  assert.deepEqual(calls, []);
});

test('path menu actions close first and call existing callbacks with the selected path', () => {
  const { app, calls } = createHarness();
  const folder = directory('folder');
  const file = { isDir: false, relPath: 'folder/note.md' };
  app.openPathMenu(folder);
  app.runPathMenuAction(folder, 'share');
  app.openPathMenu(folder);
  app.runPathMenuAction(folder, 'rename');
  app.openPathMenu(file);
  app.runPathMenuAction(file, 'rename');
  app.openPathMenu(folder);
  app.runPathMenuAction(folder, 'move');
  app.openPathMenu(file);
  app.runPathMenuAction(file, 'delete');

  assert.equal(app.pathMenuPath, '');
  assert.deepEqual(calls, [
    ['share', 'folder', true],
    ['rename', 'folder', true],
    ['rename', 'folder/note.md', false],
    ['move', 'folder', true],
    ['delete', 'folder/note.md', false]
  ]);
});
