import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));
const start = source.indexOf('  cleanupGitImport(finalId: string, importingId: string): void {');
const end = source.indexOf('\n  /** 登记成功后移除恢复标记', start);
assert.ok(start >= 0 && end > start, 'could not find VaultRegistry.cleanupGitImport');
const method = source.slice(start, end);
const code = transformSync(`class Harness { ${method} }; module.exports = Harness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(markedImports, registered = []) {
  const markerDirs = new Set(['/markers/project']);
  const removed = [];
  const context = vm.createContext({
    module: { exports: {} },
    // 2026-11-13 起后缀改为 VaultRegistry.ets 文件级导出常量，方法内是裸标识符引用。
    GIT_IMPORTING_SUFFIX: '__importing',
    VaultRegistry: { GIT_IMPORTING_SUFFIX: '__importing' },
    fileIo: {
      accessSync(path) { return markerDirs.has(path); }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  app.resolver = {
    gitImportMarkerDir(finalId) { return `/markers/${finalId}`; },
    gitImportTempMarkerDir(finalId, importingId) { return `/markers/${finalId}/${importingId}`; },
    vaultDir(id) { return `/vaults/${id}`; }
  };
  app.findEntry = id => registered.includes(id) ? { id } : null;
  app.removePathTreeIfExists = path => removed.push(path);
  app.removeImportMarker = (finalId, importingId) => removed.push(`/markers/${finalId}/${importingId}`);
  for (const importingId of markedImports) {
    markerDirs.add(`/markers/project/${importingId}`);
  }
  return { app, removed };
}

test('a retry cannot clean directories owned by another import recovery marker', () => {
  const { app, removed } = createHarness(['project__importing-old']);

  assert.throws(
    () => app.cleanupGitImport('project', 'project__importing-retry'),
    /恢复标记不属于本次导入/
  );
  assert.deepEqual(removed, []);
});

test('the matching import marker permits cleanup of only its unregistered directories', () => {
  const { app, removed } = createHarness(['project__importing-current']);

  app.cleanupGitImport('project', 'project__importing-current');

  assert.deepEqual(removed, [
    '/vaults/project__importing-current',
    '/vaults/project',
    '/markers/project/project__importing-current'
  ]);
});

test('cleanup preserves a registered final library', () => {
  const { app, removed } = createHarness(['project__importing-current'], ['project']);

  app.cleanupGitImport('project', 'project__importing-current');

  assert.deepEqual(removed, [
    '/vaults/project__importing-current',
    '/markers/project/project__importing-current'
  ]);
});
