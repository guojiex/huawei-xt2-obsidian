import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url));

function extract(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find source block ${startMarker}`);
  return source.slice(start, end).trim();
}

const saveMethod = extract(
  '  static saveNote(registry: VaultRegistry, vaultId: string, relPath: string, content: string,',
  '\n  /**\n   * 按读取版本条件保存'
);
const enqueueMethod = extract(
  '  private static enqueueSaveNote(registry: VaultRegistry, vaultId: string, relPath: string,',
  '\n  /** 撤销本次创建时'
);
const code = transformSync(`
class NoteServiceHarness {
  static saveChain = Promise.resolve();
  static tryReadNote() { return state.content; }
  static exists() { return false; }
  ${saveMethod}
  ${enqueueMethod}
}
const NoteService = NoteServiceHarness;
module.exports = NoteServiceHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(content) {
  const state = { content, writes: [] };
  const context = vm.createContext({
    module: { exports: {} },
    state,
    FullTextSearchService: { noteSaved() {} },
    WikiLinkService: { noteSaved() {} }
  });
  vm.runInContext(code, context);
  const registry = {
    accessFor() {
      return {
        async writeAtomic(path, text) {
          state.writes.push({ path, text });
          state.content = text;
        }
      };
    }
  };
  return { NoteService: context.module.exports, registry, state };
}

test('editor save refuses to replace a note changed since the editor baseline was read', async () => {
  const { NoteService, registry, state } = createHarness('external version');

  await assert.rejects(
    NoteService.saveNote(registry, 'vault', 'note.md', 'local edit', 'opened version'),
    /STALE_CONTENT/
  );
  assert.equal(state.content, 'external version');
  assert.deepEqual(state.writes, []);
});

test('editor save writes when the expected baseline still matches', async () => {
  const { NoteService, registry, state } = createHarness('opened version');

  await NoteService.saveNote(registry, 'vault', 'note.md', 'local edit', 'opened version');
  assert.equal(state.content, 'local edit');
  assert.deepEqual(state.writes, [{ path: 'note.md', text: 'local edit' }]);
});

test('trusted internal save callers may omit the editor baseline', async () => {
  const { NoteService, registry, state } = createHarness('existing');

  await NoteService.saveNote(registry, 'vault', 'note.md', 'internal update');
  assert.equal(state.content, 'internal update');
});
