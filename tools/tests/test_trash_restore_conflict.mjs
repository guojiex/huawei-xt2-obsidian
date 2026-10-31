import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url), 'utf8');

function extractMethod(signature, endMarker) {
  const start = source.indexOf(`  ${signature}`);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find TrashService method ${signature}`);
  return source.slice(start, end).trim();
}

const restoreMethod = extractMethod(
  'static restore(registry: VaultRegistry, vaultId: string, trashRel: string): string {',
  '\n  private static existsInTrash('
);
const existsAtOriginMethod = extractMethod(
  'private static existsAtOrigin(registry: VaultRegistry, vaultId: string, relPath: string): boolean {',
  '\n  /** 补建 `.trash` 内 target'
);
const code = transformSync(`class TrashService { ${restoreMethod}\n${existsAtOriginMethod} }; module.exports = TrashService;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

test('restore rejects an occupied original path before creating directories or renaming', () => {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    fileIo: {
      accessSync(path) { calls.push(`exists:${path}`); return path === '/vault/notes.md'; },
      mkdirSync(path) { calls.push(`mkdir:${path}`); },
      renameSync(sourcePath, targetPath) { calls.push(`rename:${sourcePath}:${targetPath}`); }
    },
    FullTextSearchService: { noteRestored() { calls.push('search-restored'); } },
    WikiLinkService: { pathAdded() { calls.push('wiki-path-added'); } },
    hilog: { info() { calls.push('log-restored'); } },
    TRASH_DOMAIN: 0,
    TRASH_TAG: 'TrashService'
  });
  vm.runInContext(code, context);
  const TrashService = context.module.exports;
  const registry = {
    absoluteIn(_vaultId, relPath) { return `/vault/${relPath}`; },
    absoluteInTrash(_vaultId, relPath) { return `/vault/.trash/${relPath}`; }
  };

  assert.throws(
    () => TrashService.restore(registry, 'local', 'notes.md'),
    { message: '原位置已有同名文件，请先处理重名' }
  );
  assert.deepEqual(calls, ['exists:/vault/notes.md']);
});
