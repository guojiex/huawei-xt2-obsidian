// v1.5 15.1：生产授权服务的注入式回归，覆盖 Picker、持久化、回滚和重启恢复时序。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

function loadModule(source) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} }, Date, decodeURIComponent });
  vm.runInContext(code, context);
  return context.module.exports;
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

const auth = loadModule(readSourceFile(
  new URL('../../entry/src/main/ets/model/ExternalVaultAuthorization.ets', import.meta.url)));
const URI = 'file://docs/picked/My%20Notes';

function createService(options = {}) {
  const calls = [];
  const picker = {
    async selectFolder() {
      calls.push(['pick']);
      if (options.pickError) throw options.pickError;
      return options.selection ?? [URI];
    }
  };
  const share = {
    async persistPermission(policies) {
      calls.push(['persist', plain(policies)]);
      if (options.persistError) throw options.persistError;
    },
    async activatePermission(policies) {
      calls.push(['activate', plain(policies)]);
      if (options.activateError) throw options.activateError;
    },
    async checkPersistentPermission(policies) {
      calls.push(['check', plain(policies)]);
      if (options.checkError) throw options.checkError;
      return options.flags ?? [true];
    },
    async revokePermission(policies) {
      calls.push(['revoke', plain(policies)]);
      if (options.revokeError) throw options.revokeError;
    }
  };
  const service = new auth.ExternalVaultAuthorizationService(
    picker, share, () => options.supported !== false, () => 12345);
  return { service, calls };
}

test('folder selection cancellation makes no persistent permission changes', async () => {
  const { service, calls } = createService({ selection: [] });
  assert.equal(await service.chooseAndPersist(), null);
  assert.deepEqual(calls, [['pick']]);
});

test('product picker step keeps only the selection until the user confirms association', async () => {
  const { service, calls } = createService();
  const selection = await service.pickDirectory();
  assert.deepEqual(plain(selection), { uri: URI, displayName: 'My Notes' });
  assert.deepEqual(calls, [['pick']]);
});

test('unsupported folder selection fails before opening the picker', async () => {
  const { service, calls } = createService({ supported: false });
  await assert.rejects(service.chooseAndPersist(), /不支持系统目录选择/);
  assert.deepEqual(calls, []);
});

test('selection persists, confirms, and activates only READ|WRITE for the chosen URI', async () => {
  const { service, calls } = createService();
  const grant = await service.chooseAndPersist();
  assert.deepEqual(plain(grant), {
    uri: URI,
    displayName: 'My Notes',
    grantedAt: 12345
  });
  const policy = [{ uri: URI, operationMode: 3 }];
  assert.deepEqual(calls, [
    ['pick'],
    ['persist', policy],
    ['check', policy],
    ['activate', policy]
  ]);
});

test('invalid picker output is rejected without attempting to persist a path', async () => {
  const { service, calls } = createService({ selection: ['/data/storage/not-a-picker-uri'] });
  await assert.rejects(service.chooseAndPersist(), /未返回可用的目录授权 URI/);
  assert.deepEqual(calls, [['pick']]);
});

test('persistent permission that fails confirmation is revoked', async () => {
  const { service, calls } = createService({ flags: [false] });
  await assert.rejects(service.chooseAndPersist(), /未确认目录持久授权/);
  assert.deepEqual(calls.map((call) => call[0]), ['pick', 'persist', 'check', 'revoke']);
});

test('activation failure revokes the newly persisted permission and preserves the error code', async () => {
  const activationError = Object.assign(new Error('activation failed'), { code: 13900001 });
  const { service, calls } = createService({ activateError: activationError });
  await assert.rejects(service.chooseAndPersist(), (error) => {
    assert.equal(error.code, 13900001);
    return true;
  });
  assert.deepEqual(calls.map((call) => call[0]), ['pick', 'persist', 'check', 'activate', 'revoke']);
});

test('restore reactivates only registered external entries and keeps per-entry failures isolated', async () => {
  let checkNumber = 0;
  const calls = [];
  const share = {
    async persistPermission() {},
    async activatePermission(policies) {
      calls.push(['activate', policies[0].uri]);
      if (policies[0].uri === 'file://docs/moved') {
        throw Object.assign(new Error('moved'), { code: 13900002 });
      }
    },
    async checkPersistentPermission(policies) {
      calls.push(['check', policies[0].uri]);
      checkNumber++;
      return checkNumber === 2 ? [false] : [true];
    },
    async revokePermission() {}
  };
  const service = new auth.ExternalVaultAuthorizationService(
    { async selectFolder() { return []; } }, share, () => true);
  const statuses = await service.restoreRegistered([
    { id: 'sandbox', type: 'local' },
    { id: 'active', rootKind: 'external', rootUri: URI },
    { id: 'missing', rootKind: 'external', rootUri: 'file://docs/revoked' },
    { id: 'moved', rootKind: 'external', rootUri: 'file://docs/moved' }
  ]);
  assert.deepEqual(plain(statuses), [
    { id: 'active', state: 'active', code: 0 },
    { id: 'missing', state: 'missing', code: 0 },
    { id: 'moved', state: 'activation-failed', code: 13900002 }
  ]);
  assert.deepEqual(calls, [
    ['check', URI], ['activate', URI],
    ['check', 'file://docs/revoked'],
    ['check', 'file://docs/moved'], ['activate', 'file://docs/moved']
  ]);
});

test('display names decode URI escapes but malformed escapes remain displayable', () => {
  assert.equal(auth.externalDirectoryDisplayName(URI), 'My Notes');
  assert.equal(auth.externalDirectoryDisplayName('file://docs/bad%2'), 'bad%2');
  assert.equal(auth.externalDirectoryDisplayName('/sandbox/path'), '');
});

test('release checks the saved permission before revoking it', async () => {
  const { service, calls } = createService();
  await service.release(URI);
  const policy = [{ uri: URI, operationMode: 3 }];
  assert.deepEqual(calls, [['check', policy], ['revoke', policy]]);
});
