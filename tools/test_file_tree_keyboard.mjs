import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/FileTreeView.ets', import.meta.url), 'utf8');
const keyStart = source.indexOf('  private onDirectoryKey(node: TreeNode, event: KeyEvent): boolean {');
const keyEnd = source.indexOf('\n  /**', keyStart);
const expandedStart = source.indexOf('  private isExpanded(relPath: string): boolean {');
const expandedEnd = source.indexOf('\n  private displayName(', expandedStart);
const toggleStart = source.indexOf('  private toggleDir(relPath: string): void {');
const toggleEnd = source.indexOf('\n  /**', toggleStart);
assert.ok(keyStart >= 0 && keyEnd > keyStart, 'could not find FileTreeView.onDirectoryKey');
assert.ok(expandedStart >= 0 && expandedEnd > expandedStart, 'could not find FileTreeView.isExpanded');
assert.ok(toggleStart >= 0 && toggleEnd > toggleStart, 'could not find FileTreeView.toggleDir');

const methods = [
  source.slice(expandedStart, expandedEnd),
  source.slice(keyStart, keyEnd),
  source.slice(toggleStart, toggleEnd)
].map((method) => method.trim()).join('\n');
const code = transformSync(`class FileTreeHarness { ${methods} }; module.exports = FileTreeHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

const KeyCode = { KEYCODE_DPAD_LEFT: 5, KEYCODE_DPAD_RIGHT: 6 };
const KeyType = { Down: 1, Up: 2 };

function createHarness(expanded = []) {
  const calls = [];
  const context = vm.createContext({ module: { exports: {} }, KeyCode, KeyType });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    expanded,
    vaultId: 'local',
    store: { save(vaultId, next) { calls.push(['save', vaultId, [...next]]); } },
    rescan() { calls.push(['rescan']); }
  });
  return { app, calls };
}

function directory(relPath = 'folder') {
  return { isDir: true, relPath };
}

function key(keyCode, type = KeyType.Down) {
  return { keyCode, type };
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
