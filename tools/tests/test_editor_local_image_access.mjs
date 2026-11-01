import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

function loadNoteAssetReader() {
  const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url), 'utf8');
  const start = source.indexOf('  static readAssetDataUri(');
  const end = source.indexOf('\n  // =====', start);
  assert.ok(start >= 0 && end > start, 'could not find NoteService.readAssetDataUri');
  const code = transformSync(`class NoteService { ${source.slice(start, end).trim()} }; module.exports = NoteService;`, {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const logs = [];
  const context = vm.createContext({
    module: { exports: {} },
    Buffer,
    util: {
      Base64Helper: class {
        encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      }
    },
    hilog: { warn: (...args) => logs.push(args) },
    NOTE_DOMAIN: 1,
    NOTE_TAG: 'NoteService'
  });
  vm.runInContext(code, context);
  return { NoteService: context.module.exports, logs };
}

function loadIndexAssetReader() {
  const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const start = source.indexOf('  private readVaultAssetFor(');
  const end = source.indexOf('\n  /** Select one Gallery image', start);
  assert.ok(start >= 0 && end > start, 'could not find Index.readVaultAssetFor');
  const code = transformSync(`class IndexHarness { ${source.slice(start, end).trim()} }; module.exports = IndexHarness;`, {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const reads = [];
  const context = vm.createContext({
    module: { exports: {} },
    NoteService: { readAssetDataUri: (_registry, vaultId, relPath) => {
      reads.push([vaultId, relPath]);
      return 'data:image/png;base64,AQID';
    } },
    VaultRegistry: { get: () => ({}) }
  });
  vm.runInContext(code, context);
  const index = new context.module.exports();
  index.currentVaultId = 'vault-current';
  return { index, reads };
}

test('editor image reads stay in the active vault and use the shared asset reader', () => {
  const { index, reads } = loadIndexAssetReader();
  assert.equal(index.readVaultAssetFor('vault-other', 'notes/private.png'), '');
  assert.deepEqual(reads, []);

  assert.equal(index.readVaultAssetFor('vault-current', 'notes/image.png'), 'data:image/png;base64,AQID');
  assert.deepEqual(reads, [['vault-current', 'notes/image.png']]);
});

test('asset data URI reads use VaultAccess and only expose supported image types', () => {
  const { NoteService } = loadNoteAssetReader();
  const reads = [];
  const registry = {
    accessFor(vaultId) {
      return { readBytes(relPath) {
        reads.push([vaultId, relPath]);
        return new Uint8Array([1, 2, 3]);
      } };
    }
  };

  assert.equal(NoteService.readAssetDataUri(registry, 'vault-a', 'notes/image.png'),
    'data:image/png;base64,AQID');
  assert.deepEqual(reads, [['vault-a', 'notes/image.png']]);
  assert.equal(NoteService.readAssetDataUri(registry, 'vault-a', 'notes/private.md'), '');
  assert.deepEqual(reads, [['vault-a', 'notes/image.png']]);
});

test('failed asset reads return an empty placeholder without logging library paths or errors', () => {
  const { NoteService, logs } = loadNoteAssetReader();
  const secretPath = 'notes/private-name.png';
  const registry = {
    accessFor() {
      return { readBytes() { throw new Error(`cannot read ${secretPath}`); } };
    }
  };

  assert.equal(NoteService.readAssetDataUri(registry, 'vault-a', secretPath), '');
  assert.equal(logs.length, 1);
  assert.equal(logs[0].join(' ').includes(secretPath), false);
  assert.equal(logs[0].join(' ').includes('cannot read'), false);
});
