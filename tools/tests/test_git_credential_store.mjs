import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/git/GitCredentialStore.ets', import.meta.url));
const code = transformSync(source, { loader: 'ts', format: 'cjs' }).code;

function fixture(options = {}) {
  const tags = {
    SECRET: 'secret',
    ALIAS: 'alias',
    CONFLICT_RESOLUTION: 'conflict',
    RETURN_TYPE: 'return-type'
  };
  const records = new Map();
  const calls = [];
  let addError = options.addError;
  const aliasOf = (bytes) => Buffer.from(bytes).toString('utf8');
  const asset = {
    Tag: tags,
    ConflictResolution: { OVERWRITE: 'overwrite' },
    ReturnType: { ALL: 'all' },
    addSync(attributes) {
      calls.push('add:' + aliasOf(attributes.get(tags.ALIAS)));
      if (addError) throw addError;
      const alias = aliasOf(attributes.get(tags.ALIAS));
      records.set(alias, new Map(attributes));
    },
    querySync(query) {
      const alias = aliasOf(query.get(tags.ALIAS));
      calls.push('query:' + alias);
      if (options.queryError) throw options.queryError;
      const record = records.get(alias);
      return record === undefined ? [] : [new Map(record)];
    },
    removeSync(query) {
      const alias = aliasOf(query.get(tags.ALIAS));
      calls.push('remove:' + alias);
      if (options.removeError) throw options.removeError;
      if (!records.delete(alias)) {
        const error = new Error('asset not found');
        error.code = 24000002;
        throw error;
      }
    }
  };
  class TextEncoderFixture {
    encodeInto(value) {
      return new Uint8Array(Buffer.from(value, 'utf8'));
    }
  }
  class TextDecoderFixture {
    decodeToString(value) {
      return Buffer.from(value).toString('utf8');
    }
  }
  const warnings = [];
  const mocks = {
    '@kit.AssetStoreKit': { asset },
    '@kit.ArkTS': { util: { TextEncoder: TextEncoderFixture, TextDecoder: TextDecoderFixture } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn: (...args) => warnings.push(args) } },
    '@kit.BasicServicesKit': { BusinessError: Error }
  };
  const module = { exports: {} };
  vm.runInNewContext(code, {
    module,
    exports: module.exports,
    require: (name) => {
      assert.ok(mocks[name], 'unexpected HarmonyOS import: ' + name);
      return mocks[name];
    },
    Uint8Array,
    Buffer
  });
  return {
    GitCredentialStore: module.exports.GitCredentialStore,
    tags,
    records,
    calls,
    warnings,
    setAddError: (error) => { addError = error; }
  };
}

test('tokens are stored as AssetStoreKit SECRET with a per-vault alias and overwrite policy', () => {
  const f = fixture();
  const token = 'synthetic-test-token-非真实凭据';
  f.GitCredentialStore.saveToken('notes-A', token);

  const record = f.records.get('vault:notes-A:token');
  assert.ok(record);
  assert.equal(Buffer.from(record.get(f.tags.SECRET)).toString('utf8'), token);
  assert.deepEqual([...record.keys()], [f.tags.SECRET, f.tags.ALIAS, f.tags.CONFLICT_RESOLUTION]);
  assert.equal(record.get(f.tags.CONFLICT_RESOLUTION), 'overwrite');
  assert.equal(f.GitCredentialStore.getToken('notes-A'), token);
  assert.equal(f.GitCredentialStore.getToken('notes-B'), null);
});

test('renaming a vault writes the new alias before removing the old credential', () => {
  const f = fixture();
  f.GitCredentialStore.saveToken('old-id', 'synthetic-token');
  f.calls.length = 0;

  f.GitCredentialStore.migrateToken('old-id', 'new-id');

  assert.deepEqual(f.calls, [
    'query:vault:old-id:token',
    'add:vault:new-id:token',
    'remove:vault:old-id:token'
  ]);
  assert.equal(f.GitCredentialStore.getToken('old-id'), null);
  assert.equal(f.GitCredentialStore.getToken('new-id'), 'synthetic-token');
});

test('a failed destination write during credential migration retains the old token', () => {
  const f = fixture();
  f.GitCredentialStore.saveToken('old-id', 'synthetic-token');
  f.calls.length = 0;
  f.setAddError(new Error('destination write failed'));

  assert.throws(() => f.GitCredentialStore.migrateToken('old-id', 'new-id'), /destination write failed/);
  assert.deepEqual(f.calls, ['query:vault:old-id:token', 'add:vault:new-id:token']);
  assert.equal(f.GitCredentialStore.getToken('old-id'), 'synthetic-token');
  assert.equal(f.records.has('vault:new-id:token'), false);
});

test('missing credentials are idempotent while unexpected AssetStoreKit errors remain visible', () => {
  const f = fixture();
  assert.equal(f.GitCredentialStore.getToken('missing'), null);
  assert.doesNotThrow(() => f.GitCredentialStore.removeToken('missing'));

  const errorFixture = fixture({ queryError: Object.assign(new Error('temporary asset failure'), { code: 17 }) });
  assert.throws(() => errorFixture.GitCredentialStore.getToken('vault-A'), /asset querySync 失败: 17/);
});

test('credential deletion failures warn without logging the stored secret', () => {
  const token = 'synthetic-secret';
  const f = fixture({ removeError: Object.assign(new Error('remove failed'), { code: 23 }) });
  f.GitCredentialStore.saveToken('vault-A', token);
  f.GitCredentialStore.removeToken('vault-A');
  assert.equal(f.warnings.length, 1);
  assert.ok(!JSON.stringify(f.warnings).includes(token));
});
