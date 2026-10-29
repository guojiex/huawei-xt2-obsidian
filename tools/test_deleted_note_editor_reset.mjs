import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

function extractMethod(signature, nextMarker) {
  const start = source.indexOf(`  private async ${signature}`);
  const end = source.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${signature}`);
  return source.slice(start, end).trim();
}

const deletePathMethod = extractMethod('doDeletePath(relPath: string): Promise<void> {', '\n  /** 注册表操作失败');
const trashFileMethod = extractMethod('doTrashFile(relPath: string): Promise<void> {', '\n  /** 撤销条：弹出');
const classSource = `class IndexHarness { ${deletePathMethod}\n${trashFileMethod} }; module.exports = IndexHarness;`;
const code = transformSync(classSource, { loader: 'ts', format: 'cjs' }).code;

function createHarness(options = {}) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    VaultRegistry: { get: () => ({}) },
    NoteService: {
      async deletePath(_registry, vaultId, path) {
        calls.push(`delete:${vaultId}:${path}`);
      }
    },
    TrashService: {
      moveToTrash(_registry, vaultId, path) {
        calls.push(`trash:${vaultId}:${path}`);
        return `.trash/${path}`;
      }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    currentVaultId: 'local',
    currentFilePath: options.currentFilePath ?? '',
    rightFilePath: options.rightFilePath ?? '',
    trashSeq: 0,
    async flushWorkspaceSaves() {
      calls.push('flush');
      return options.flushSucceeds ?? true;
    },
    resetSaveFeedback() { calls.push('reset-feedback'); },
    async readAndPush(path) { calls.push(`clear-left:${path}`); },
    async readRightAndPush(path) { calls.push(`clear-right:${path}`); },
    refreshFileTree() { calls.push('refresh-tree'); },
    toastRegistryError(prefix) { calls.push(`toast:${prefix}`); },
    showUndo() { calls.push('show-undo'); }
  });
  return { app, calls };
}

test('permanent deletion clears the left editor after deleting its selected subtree', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'folder/current.md', rightFilePath: 'keep.md' });
  await app.doDeletePath('folder');

  assert.deepEqual(calls, ['flush', 'reset-feedback', 'delete:local:folder', 'clear-left:', 'refresh-tree']);
  assert.equal(app.currentFilePath, '');
  assert.equal(app.rightFilePath, 'keep.md');
});

test('moving the selected right note to trash clears its editor while preserving the left note', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'keep.md', rightFilePath: 'folder/current.md' });
  await app.doTrashFile('folder/current.md');

  assert.deepEqual(calls, [
    'flush', 'reset-feedback', 'trash:local:folder/current.md', 'clear-right:', 'refresh-tree', 'show-undo'
  ]);
  assert.equal(app.currentFilePath, 'keep.md');
  assert.equal(app.rightFilePath, '');
});

test('deleting an unrelated path leaves both editor buffers alone', async () => {
  const { app, calls } = createHarness({ currentFilePath: 'keep.md', rightFilePath: 'also-keep.md' });
  await app.doDeletePath('other-folder');

  assert.deepEqual(calls, ['delete:local:other-folder', 'refresh-tree']);
  assert.equal(app.currentFilePath, 'keep.md');
  assert.equal(app.rightFilePath, 'also-keep.md');
});
