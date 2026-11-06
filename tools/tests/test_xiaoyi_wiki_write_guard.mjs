import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { test } from 'node:test';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL(
  '../../entry/src/main/ets/entryability/InsightIntentNoteService.ets', import.meta.url), 'utf8');

function extractMember(name, isStatic = false) {
  const signature = isStatic ? `private static ${name}(` : `private `;
  let start = source.indexOf(signature);
  if (isStatic) {
    assert.ok(start >= 0, `missing ${name}`);
  } else {
    start = source.indexOf(`private async ${name}(`);
    if (start < 0) {
      start = source.indexOf(`private ${name}(`);
    }
    assert.ok(start >= 0, `missing ${name}`);
  }
  const open = source.indexOf('{', start);
  assert.ok(open > start, `missing ${name} body`);
  let depth = 1;
  let end = open + 1;
  while (depth > 0 && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0, `could not parse ${name}`);
  return source.slice(start, end)
    .replace(/^private static /, 'static ')
    .replace(/^private async /, 'async ')
    .replace(/^private /, '');
}

const members = [
  extractMember('resolveVaultId', true),
  extractMember('parseReadOnlyFolders', true),
  extractMember('isReadOnlyPath', true),
  extractMember('createNote'),
  extractMember('appendNote'),
  extractMember('editNote'),
  extractMember('applyExistingMutation'),
  extractMember('requireAgentWritablePath')
];
const code = transformSync(`
  class InsightIntentNoteService {
    static busyVaults = new Set();
    ${members.join('\n')}
  }
  module.exports = { InsightIntentNoteService };
`, { loader: 'ts', format: 'cjs' }).code;

const noteService = {
  exists(registry, vaultId, relPath) {
    return fs.existsSync(path.join(registry.root, relPath));
  },
  tryReadNote(registry, vaultId, relPath) {
    if (registry.readWikiFails && relPath === '_wiki.md') {
      return null;
    }
    try {
      return fs.readFileSync(path.join(registry.root, relPath), 'utf8');
    } catch (error) {
      return null;
    }
  },
  previewCreatePath(registry, vaultId, relPath) {
    return relPath;
  },
  async createNoteWithContent(registry, vaultId, relPath, content) {
    registry.stats.writes++;
    const target = path.join(registry.root, relPath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
  },
  async saveNoteIfUnchanged(registry, vaultId, relPath, before, after) {
    registry.stats.writes++;
  }
};
const module = { exports: {} };
vm.runInNewContext(code, vm.createContext({
  module,
  NoteService: noteService,
  WorkspaceEditGuard: { isUnsaved: () => false },
  Error
}));
const { InsightIntentNoteService } = module.exports;

function makeService(registry) {
  const service = new InsightIntentNoteService();
  service.registry = registry;
  service.requiredString = (params, key, allowEmpty = false) => {
    const value = params[key];
    if (typeof value !== 'string' || (!allowEmpty && value.trim().length === 0)) {
      throw new Error(`INVALID_PARAMETER:${key}`);
    }
    return value;
  };
  service.requireVault = () => {};
  service.requireSafeNotePath = (vaultId, relPath) => relPath;
  service.requireAllowedParent = () => {};
  service.requireExistingNote = () => {};
  service.enterVault = () => {
    registry.stats.entered++;
  };
  service.beginOperation = async () => {
    registry.stats.operations++;
    return { resultHash: 'hash', operationId: 'operation' };
  };
  service.finishAppliedOperation = async () => {};
  service.finishFailedOperation = async () => {};
  service.readExpectedVersion = () => 'before';
  return service;
}

test('Wiki write protection blocks unsafe service mutations in an isolated vault', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'xiaoyi-wiki-guard-'));
  const registry = {
    root,
    currentId: () => 'vault-test',
    readWikiFails: false,
    stats: { writes: 0, operations: 0, entered: 0 }
  };
  const service = makeService(registry);
  const create = (notePath) => service.createNote({
    vaultId: 'vault-test',
    path: notePath,
    text: 'fixture content'
  });
  const resetStats = () => {
    registry.stats = { writes: 0, operations: 0, entered: 0 };
  };
  const assertNoMutation = () => {
    assert.deepEqual(registry.stats, { writes: 0, operations: 0, entered: 0 });
  };

  try {
    fs.writeFileSync(path.join(root, '_wiki.md'), '---\nreadonly: ["raw/"]\n---\n');
    await assert.rejects(create('raw/source.md'), /PATH_READONLY/);
    assertNoMutation();

    fs.writeFileSync(path.join(root, '_wiki.md'), '---\nreadonly: ["../raw/"]\n---\n');
    await assert.rejects(create('notes/new.md'), /WIKI_RULE_INVALID/);
    assertNoMutation();

    fs.writeFileSync(path.join(root, '_wiki.md'), '---\nreadonly: ["raw/"]\n---\n');
    registry.readWikiFails = true;
    await assert.rejects(create('notes/new.md'), /WIKI_RULE_READ_FAILED/);
    assertNoMutation();
    registry.readWikiFails = false;

    await assert.rejects(create('_wiki.md'), /PATH_READONLY/);
    assertNoMutation();

    fs.writeFileSync(path.join(root, '_wiki.md'), '---\nreadonly: ["raw/"]\n---\n');
    const protectedParams = {
      vaultId: 'vault-test',
      path: 'raw/source.md',
      baseHash: 'hash',
      anchor: 'before',
      text: 'after'
    };
    await assert.rejects(service.appendNote(protectedParams), /PATH_READONLY/);
    assertNoMutation();
    await assert.rejects(service.editNote(protectedParams), /PATH_READONLY/);
    assertNoMutation();
    await assert.rejects(service.applyExistingMutation(
      'vault-test', 'EditNote', 'raw/source.md', 'before', 'after'), /PATH_READONLY/);
    assertNoMutation();

    const result = await create('notes/new.md');
    assert.equal(result.path, 'notes/new.md');
    assert.equal(fs.readFileSync(path.join(root, 'notes/new.md'), 'utf8'), 'fixture content');
    assert.deepEqual(registry.stats, { writes: 1, operations: 1, entered: 1 });

    resetStats();
    fs.rmSync(path.join(root, '_wiki.md'));
    await create('unrestricted/new.md');
    assert.equal(fs.readFileSync(path.join(root, 'unrestricted/new.md'), 'utf8'), 'fixture content');
    assert.deepEqual(registry.stats, { writes: 1, operations: 1, entered: 1 });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
