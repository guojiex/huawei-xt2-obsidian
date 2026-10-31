import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url));

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find NoteService method ${signature}`);
  return source.slice(start, end).trim();
}

const existsMethod = extractMethod(
  'static exists(registry: VaultRegistry, vaultId: string, relPath: string): boolean {',
  '\n  /**\n   * 重名处理'
);
const uniqueFileMethod = extractMethod(
  'static uniqueRelPath(registry: VaultRegistry, vaultId: string, relPath: string): string {',
  '\n  /** 预计算一个尚未占用的笔记路径'
);
const uniqueDirMethod = extractMethod(
  'static uniqueDirPath(registry: VaultRegistry, vaultId: string, relPath: string): string {',
  '\n  /**\n   * 新建空文件夹'
);
const code = transformSync(
  `class NoteService { ${existsMethod}\n${uniqueFileMethod}\n${uniqueDirMethod} }; module.exports = NoteService;`,
  { loader: 'ts', format: 'cjs' }
).code;

function createHarness(existingPaths) {
  const paths = new Set(existingPaths);
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: { accessSync: (path) => paths.has(path) }
  });
  vm.runInContext(code, context);
  const NoteService = context.module.exports;
  const registry = { absoluteIn: (vaultId, relPath) => `/vault/${vaultId}/${relPath}` };
  return { NoteService, registry };
}

test('duplicate Markdown paths add the next suffix before the extension without replacing existing paths', () => {
  const { NoteService, registry } = createHarness([
    '/vault/local/notes.md',
    '/vault/local/notes-2.md'
  ]);

  assert.equal(NoteService.uniqueRelPath(registry, 'local', 'notes.md'), 'notes-3.md');
});

test('duplicate folder paths add a suffix to the folder name', () => {
  const { NoteService, registry } = createHarness([
    '/vault/local/drafts',
    '/vault/local/drafts-2'
  ]);

  assert.equal(NoteService.uniqueDirPath(registry, 'local', 'drafts'), 'drafts-3');
});

test('the same relative path is checked inside its own vault', () => {
  const { NoteService, registry } = createHarness(['/vault/local/notes.md']);

  assert.equal(NoteService.uniqueRelPath(registry, 'local', 'notes.md'), 'notes-2.md');
  assert.equal(NoteService.uniqueRelPath(registry, 'temporary', 'notes.md'), 'notes.md');
});
