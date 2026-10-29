import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/SampleVaultInstaller.ets'), 'utf8');
const code = transformSync(source.replace(/^import .*;\n/gm, ''), { loader: 'ts', format: 'cjs' }).code;

async function run({ fresh = true, occupied = false, failAt = -1 } = {}) {
  const dirs = new Set(['/local']);
  const files = new Map(occupied ? [['/local/user.md', 'keep me']] : []);
  const writes = [];
  let grant = fresh;
  const registry = {
    consumeSampleInstall() { const result = grant; grant = false; return result; },
    absoluteIn(vault, rel) { assert.equal(vault, 'local'); assert.ok(!rel.includes('..')); return '/local' + (rel ? '/' + rel : ''); }
  };
  const samples = [{ path: 'start/welcome.md', content: '# 欢迎' }, { path: 'assets/diagram.svg', content: '<svg/>' }];
  const context = {
    module: { exports: {} },
    DEFAULT_VAULT_ID: 'local',
    fileIo: {
      listFileSync() { return [...files.keys()]; },
      accessSync(p) { return dirs.has(p) || files.has(p); },
      mkdirSync(p) { dirs.add(p); }
    },
    NoteService: { async saveNote(_, vault, rel, text) {
      if (writes.length === failAt) throw new Error('injected write failure');
      assert.equal(vault, 'local');
      files.set('/local/' + rel, text); writes.push(rel);
    } },
    SAMPLE_VAULT_FILES: samples
  };
  vm.runInNewContext(code, context);
  const installer = context.module.exports.SampleVaultInstaller;
  let error;
  try { await installer.install(registry); } catch (e) { error = e; }
  return { installer, registry, writes, files, error };
}

test('fresh empty default vault receives both Markdown and local assets', async () => {
  const r = await run(); assert.equal(r.writes.length, 2); assert.equal(r.files.get('/local/start/welcome.md'), '# 欢迎');
});
test('existing installations are untouched, even if their default vault is empty', async () => {
  assert.equal((await run({ fresh: false })).writes.length, 0);
});
test('an existing file prevents all sample insertion', async () => {
  const r = await run({ occupied: true }); assert.equal(r.writes.length, 0); assert.equal(r.files.get('/local/user.md'), 'keep me');
});
test('deleted samples are not resurrected on a later stage creation', async () => {
  const r = await run(); r.files.delete('/local/start/welcome.md'); await r.installer.install(r.registry);
  assert.ok(!r.files.has('/local/start/welcome.md')); assert.equal(r.writes.length, 2);
});
test('write failure stops insertion and does not automatically retry over user edits', async () => {
  const r = await run({ failAt: 1 }); assert.match(r.error.message, /injected/);
  r.files.set('/local/start/welcome.md', 'user edit'); await r.installer.install(r.registry);
  assert.equal(r.files.get('/local/start/welcome.md'), 'user edit'); assert.equal(r.writes.length, 1);
});
