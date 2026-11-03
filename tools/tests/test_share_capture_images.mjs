import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../web/mdpreview/src/index.ts', import.meta.url));
const start = source.indexOf('async function waitForLocalImages(');
const end = source.indexOf('\nfunction nextRenderedFrame()', start);
assert.ok(start >= 0 && end > start, 'could not find waitForLocalImages');
const method = source.slice(start, end);
const code = transformSync(`${method}\nmodule.exports = waitForLocalImages;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createWaiter(images, missingImages = []) {
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  const waitForLocalImages = module.exports;
  return waitForLocalImages({
    querySelectorAll(selector) {
      return selector.includes('share-missing') ? missingImages : images;
    }
  });
}

test('a missing local image blocks long-image capture with an actionable error', async () => {
  const missing = { dataset: { shareMissing: 'true' } };
  await assert.rejects(createWaiter([], [missing]), /本地图片缺失或无法读取/);
  assert.match(source, /img\.dataset\.shareMissing = 'true'/);
});

test('a local image decode failure blocks long-image capture without exposing its path', async () => {
  const broken = {
    decode: async () => { throw new Error('/private/vault/secret.png'); },
    naturalWidth: 0,
    naturalHeight: 0
  };
  await assert.rejects(createWaiter([broken]), /本地图片无法解码，请检查附件/);
});

test('successfully decoded local images still allow capture', async () => {
  const valid = {
    decode: async () => {},
    naturalWidth: 32,
    naturalHeight: 24
  };
  await assert.doesNotReject(createWaiter([valid]));
});
