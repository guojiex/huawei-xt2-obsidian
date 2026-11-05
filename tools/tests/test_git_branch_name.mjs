import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/git/GitBranchName.ets', import.meta.url));
const code = transformSync(source, { loader: 'ts', format: 'cjs' }).code;
const module = { exports: {} };
vm.runInNewContext(code, { module, exports: module.exports });
const { validateGitBranchName } = module.exports;

test('Git branch validation accepts nested and Unicode branch names', () => {
  for (const branch of [
    'xt2', 'phone/notes', '设备-一', 'release/2026.11', '😀'.repeat(100)
  ]) {
    assert.deepEqual({ ...validateGitBranchName(branch) }, { valid: true, reason: '' });
  }
});

test('Git branch validation rejects forbidden ref syntax and path segments', () => {
  for (const branch of [
    '', 'HEAD', '@', 'bad name', 'a~b', 'a^b', 'a:b', 'a?b', 'a*b', 'a[b', 'a\\b',
    'a..b', 'a@{b', 'a//b', '/start', '.hidden', '-option', 'end/', 'end.',
    'path/.hidden', 'path/segment.lock', 'x'.repeat(101), '😀'.repeat(101)
  ]) {
    assert.equal(validateGitBranchName(branch).valid, false, branch);
  }
});
