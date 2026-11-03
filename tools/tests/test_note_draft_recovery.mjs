import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteDraftService.ets', import.meta.url), 'utf8');

function loadDraftService(files = new Map(), directories = new Set()) {
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout,
    clearTimeout,
    fileIo: {
      accessSync(path) { return files.has(path) || directories.has(path); },
      readTextSync(path) {
        if (!files.has(path)) throw new Error('not found');
        return files.get(path);
      },
      unlinkSync(path) { files.delete(path); },
      mkdirSync(path) { directories.add(path); },
      AtomicFile: class {
        constructor(path) { this.path = path; }
        startWrite() {
          return { write: (content, encoding, callback) => { files.set(this.path, content); callback(); } };
        }
        finishWrite() {}
        failWrite() { files.delete(this.path); }
      }
    },
    hilog: { info() {}, error() {} }
  });
  const compiled = transformSync(
    source.replace(/^import .*;\n/gm, '') + '\nmodule.exports = NoteDraftService;',
    { loader: 'ts', format: 'cjs' }
  ).code;
  vm.runInContext(compiled, context);
  const NoteDraftService = context.module.exports;
  const registry = {
    draftsRoot: () => '/private/drafts',
    draftsVaultDirOf: (vaultId) => '/private/drafts/' + vaultId,
    draftDirectory: (vaultId, relative) => '/private/drafts/' + vaultId +
      (relative.length > 0 ? '/' + relative : ''),
    absoluteDraftIn: (vaultId, path) => '/private/drafts/' + vaultId + '/' + path + '.draft'
  };
  return { NoteDraftService, files, directories, registry };
}

test('a matching formal baseline restores the pending content without changing the vault note', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  files.set(path, JSON.stringify({ version: 1, baseText: 'formal', content: 'pending edit' }));

  const result = await NoteDraftService.recover(registry, 'vault-key', 'notes/a.md', 'formal');

  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    recovered: true, conflict: false, content: 'pending edit'
  });
  assert.equal(files.get(path).includes('pending edit'), true);
});

test('a stale baseline keeps the recovery draft and returns the current formal text', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  const record = JSON.stringify({ version: 1, baseText: 'older formal', content: 'pending edit' });
  files.set(path, record);

  const result = await NoteDraftService.recover(registry, 'vault-key', 'notes/a.md', 'new formal');

  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    recovered: false, conflict: true, content: 'new formal'
  });
  assert.equal(files.get(path), record, 'conflicting user content must not be discarded');
});

test('an unreadable draft is reported as a conflict and remains untouched', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  files.set(path, '{invalid json');

  const result = await NoteDraftService.recover(registry, 'vault-key', 'notes/a.md', 'formal');

  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    recovered: false, conflict: true, content: 'formal'
  });
  assert.equal(files.get(path), '{invalid json');
});

test('a matching draft is cleared only after the formal content matches it', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  files.set(path, JSON.stringify({ version: 1, baseText: 'before', content: 'after' }));

  await NoteDraftService.clearIfMatches(registry, 'vault-key', 'notes/a.md', 'after');
  assert.equal(files.has(path), false);

  files.set(path, JSON.stringify({ version: 1, baseText: 'before', content: 'other' }));
  await NoteDraftService.clearIfMatches(registry, 'vault-key', 'notes/a.md', 'after');
  assert.equal(files.has(path), true, 'a newer draft must be kept');
});

test('an unknown existing draft blocks replacement by a new snapshot', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  files.set(path, '{invalid json');

  const persisted = await NoteDraftService.persist(registry, 'vault-key', 'notes/a.md', 'formal', 'new edit');

  assert.equal(persisted, false);
  assert.equal(files.get(path), '{invalid json');
});

test('draft persistence uses its app-private vault-key path and matching drafts clear safely', async () => {
  const { NoteDraftService, files, registry } = loadDraftService();

  assert.equal(await NoteDraftService.persist(registry, 'vault-key', 'notes/a.md', 'formal', 'pending'), true);
  const path = '/private/drafts/vault-key/notes/a.md.draft';
  assert.deepEqual(JSON.parse(files.get(path)), {
    version: 1, baseText: 'formal', content: 'pending'
  });

  await NoteDraftService.clearIfMatches(registry, 'vault-key', 'notes/a.md', 'pending');
  assert.equal(files.has(path), false);
});

test('a persisted draft recovers after recreating the service context', async () => {
  const first = loadDraftService();
  assert.equal(await first.NoteDraftService.persist(
    first.registry, 'vault-key', 'notes/a.md', 'formal', 'pending edit'), true);

  const restarted = loadDraftService(first.files, first.directories);
  const result = await restarted.NoteDraftService.recover(
    restarted.registry, 'vault-key', 'notes/a.md', 'formal');

  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    recovered: true, conflict: false, content: 'pending edit'
  });
});
