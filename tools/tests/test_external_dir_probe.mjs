// v1.5 最小样例（ExternalDirProbe）的源方法级回归。
//
// 为什么能直接跑 .ets：model 文件没有 import、没有 UI、IO 全靠构造函数注入，
// 这里是 Node 视角的受控假实现 —— 覆盖「Picker 取消 / 持久化失败 / 重新激活 /
// 递归列出 / 写入后回读 / 原内容还原」这些真实设备上不易稳定复现的分支。
// 它证明的是**样例代码的时序正确**，不证明 Picker / fileshare 在设备上的真实行为
// （那部分由 XT2 真机实测负责，见 v1.5 §6.1）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

/**
 * ⚠️ vm realm 里创建的 `[]` / `{}` 用的是**那个 realm 的** Array/Object 原型，
 * node:assert/strict 的 deepEqual 会判原型不同，报
 * 「Values have same structure but are not reference-equal」。
 * 所以凡是要拿源码产物与宿主期望值做**结构比较**的，先经这里归一化到宿主 realm。
 * （直接比较字符串 / 数字 / 布尔不受影响，不必绕。）
 */
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function loadModule(source) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, context);
  return context.module.exports;
}

const probe = loadModule(readSourceFile(
  new URL('../../entry/src/main/ets/model/ExternalDirProbe.ets', import.meta.url)));

const DIR_URI = 'file://docs/picked/My%20Notes';

function createFs(initial = {}) {
  const files = new Map(Object.entries(initial));
  const writes = [];
  return {
    files,
    writes,
    failWrite: false,
    listCalls: [],
    listFileSync(uri, options) {
      this.listCalls.push({ uri, options });
      return [...files.keys()];
    },
    readText(uri) {
      const key = uri.replace(DIR_URI + '/', '');
      if (!files.has(key)) {
        const err = new Error('ENOENT');
        err.code = 13900002;
        return Promise.reject(err);
      }
      return Promise.resolve(files.get(key));
    },
    async writeAtomic(uri, content) {
      if (this.failWrite) {
        throw new probe.ProbeWriteError(13900001, 'policy denied');
      }
      const key = uri.replace(DIR_URI + '/', '');
      writes.push([key, content]);
      files.set(key, content);
    }
  };
}

function createShare(overrides = {}) {
  const calls = [];
  const base = {
    calls,
    persistResult: Promise.resolve(),
    activateResult: Promise.resolve(),
    persistedFlags: [true],
    async persistPermission(policies) { calls.push(['persist', policies]); return this.persistResult; },
    async activatePermission(policies) { calls.push(['activate', policies]); return this.activateResult; },
    async checkPersistentPermission(policies) { calls.push(['check', policies]); return this.persistedFlags; }
  };
  return Object.assign(base, overrides);
}

function createRunner(options = {}) {
  const fs = options.fs ?? createFs(options.initial);
  const share = options.share ?? createShare(options.shareOverrides);
  const picker = options.picker ?? {
    uris: [DIR_URI],
    async selectFolder() { return this.uris; }
  };
  return { runner: new probe.ExternalDirProbeRunner(picker, share, fs), fs, share, picker };
}

test('only accepts file:// directory URIs and rejects empty or plain paths', () => {
  assert.equal(probe.isProbeDirectoryUri(DIR_URI), true);
  assert.equal(probe.isProbeDirectoryUri(''), false);
  assert.equal(probe.isProbeDirectoryUri('   '), false);
  // 普通绝对路径不是 Picker 的返回形态，拒绝以免绕过解析器
  assert.equal(probe.isProbeDirectoryUri('/data/storage/el2/base/files/vaults/x'), false);
  assert.equal(probe.isProbeDirectoryUri('file://'), false);
});

test('policy carries READ|WRITE only (CREATE/DELETE modes are API 20)', () => {
  assert.equal(probe.PROBE_OPERATION_MODE, 3);
  assert.deepEqual(plain(probe.buildProbePolicy(DIR_URI)), { uri: DIR_URI, operationMode: 3 });
});

test('display name decodes percent-escapes and survives malformed escape', () => {
  assert.equal(probe.displayNameFromUri(DIR_URI), 'My Notes');
  assert.equal(probe.displayNameFromUri('file://docs/中文 目录'), '中文 目录');
  assert.equal(probe.displayNameFromUri('file://docs/bad%2'), 'bad%2');
  assert.equal(probe.displayNameFromUri('not-a-uri'), '');
});

test('markdown selection skips hidden and excluded segments', () => {
  const entries = [
    '笔记.md',
    '子目录/第二篇.MD',
    '.git/config',
    '.hidden/secret.md',
    'node_modules/pkg/readme.md',
    '图片.png',
    'sub/.trash/old.md'
  ];
  assert.deepEqual(plain(probe.selectProbeMarkdown(entries)), ['笔记.md', '子目录/第二篇.MD']);
  assert.equal(probe.isMarkdownEntry('A.MARKDOWN'), true);
  assert.equal(probe.isMarkdownEntry('a.txt'), false);
  assert.equal(probe.hasSkippedSegment('a/.git/b.md'), true);
  assert.equal(probe.hasSkippedSegment('a/b.md'), false);
  assert.equal(probe.shouldSkipSegment('..'), true);
});

test('human-readable error descriptions cover fileshare and fileIo codes', () => {
  assert.match(probe.describeProbeError(13900001), /13900001/);
  assert.match(probe.describeProbeError(201), /FILE_ACCESS_PERSIST/);
  assert.match(probe.describeProbeError(401), /401/);
  assert.match(probe.describeProbeError(13900002), /13900002/);
  // 未知码不能翻译成「成功」
  assert.match(probe.describeProbeError(12345), /code=12345/);
});

test('step summary labels the API under test and keeps the error code', () => {
  const ok = probe.describeProbeStep('persist', true, 0, '');
  assert.equal(ok.label, 'persistPermission 持久化授权');
  assert.equal(ok.detail, '成功');
  const failed = probe.describeProbeStep('persist', false, 13900001, '');
  assert.equal(failed.ok, false);
  assert.match(failed.detail, /13900001/);
  const business = probe.describeProbeStep('atomic', false, 0, '写后回读未见标记');
  assert.equal(business.detail, '写后回读未见标记');
});

test('picking returns empty string when the user cancels or the uri is unusable', async () => {
  const cancelled = createRunner({ picker: { async selectFolder() { return []; } } });
  assert.equal(await cancelled.runner.pickDirectory(), '');

  const badShape = createRunner({ picker: { async selectFolder() { return ['/plain/path']; } } });
  assert.equal(await badShape.runner.pickDirectory(), '');

  const good = createRunner();
  assert.equal(await good.runner.pickDirectory(), DIR_URI);
});

test('persist / activate / check all send the same read+write policy', async () => {
  const { runner, share } = createRunner();
  const policy = { uri: DIR_URI, operationMode: 3 };
  await runner.persist(DIR_URI);
  await runner.activate(DIR_URI);
  assert.equal(await runner.checkPersisted(DIR_URI), true);
  assert.deepEqual(plain(share.calls), [
    ['persist', [policy]],
    ['activate', [policy]],
    ['check', [policy]]
  ]);
});

test('checkPersisted is false when the platform reports an empty or false flag', async () => {
  const empty = createRunner({ shareOverrides: { persistedFlags: [] } });
  assert.equal(await empty.runner.checkPersisted(DIR_URI), false);
  const no = createRunner({ shareOverrides: { persistedFlags: [false] } });
  assert.equal(await no.runner.checkPersisted(DIR_URI), false);
});

test('listEntries asks for recursive listing of the directory uri', () => {
  const { runner, fs } = createRunner({ initial: { 'a.md': '# a', 'sub/b.md': '# b' } });
  assert.deepEqual(runner.listEntries(DIR_URI), ['a.md', 'sub/b.md']);
  assert.deepEqual(plain(fs.listCalls), [{ uri: DIR_URI, options: { recursion: true } }]);
});

test('probeWrite updates an existing note, verifies by reading back, then restores it', async () => {
  const original = '# 原有标题\n\n原有正文\n';
  const { runner, fs } = createRunner({ initial: { 'a.md': original } });
  const step = await runner.probeWrite(DIR_URI, ['a.md']);
  assert.equal(step.ok, true);
  assert.equal(step.id, 'atomic');
  // 写了标记 + 还原，共两次原子写；最终内容与原文一致
  assert.equal(fs.writes.length, 2);
  assert.equal(fs.writes[0][1], original + '\n' + probe.PROBE_MARK + '\n');
  assert.equal(fs.writes[1][1], original);
  assert.equal(fs.files.get('a.md'), original);
});

test('probeWrite falls back to a temp file when the directory has no markdown', async () => {
  const { runner, fs } = createRunner({ initial: {} });
  const step = await runner.probeWrite(DIR_URI, []);
  assert.equal(step.ok, true);
  const keys = [...fs.files.keys()];
  assert.deepEqual(keys, [probe.PROBE_FILE_NAME]);
});

test('probeWrite reports write failure with its error code and leaves content untouched', async () => {
  const original = '# keep me\n';
  const fs = createFs({ 'a.md': original });
  fs.failWrite = true;
  const { runner } = createRunner({ fs, initial: { 'a.md': original } });
  const step = await runner.probeWrite(DIR_URI, ['a.md']);
  assert.equal(step.ok, false);
  assert.equal(step.detail.includes('13900001'), true);
  assert.equal(fs.files.get('a.md'), original);
});

test('probeWrite fails without pretending success when read-back loses the mark', async () => {
  const fs = createFs({ 'a.md': '# a\n' });
  // 写入成功但读回来丢内容 —— 模拟文件系统在这类 URI 上的静默失败
  const originalRead = fs.readText.bind(fs);
  let reads = 0;
  fs.readText = (uri) => {
    reads += 1;
    if (reads === 2) {
      return Promise.resolve('# a\n');
    }
    return originalRead(uri);
  };
  const { runner } = createRunner({ fs });
  const step = await runner.probeWrite(DIR_URI, ['a.md']);
  assert.equal(step.ok, false);
  assert.match(step.detail, /回读未见标记/);
});

test('errorCodeOf reads numeric codes and degrades to -1 for unknown shapes', () => {
  assert.equal(probe.ExternalDirProbeRunner.errorCodeOf({ code: 201 }), 201);
  assert.equal(probe.ExternalDirProbeRunner.errorCodeOf(new Error('boom')), -1);
  assert.equal(probe.ExternalDirProbeRunner.errorCodeOf(null), -1);
  assert.equal(probe.ExternalDirProbeRunner.errorCodeOf('text'), -1);
});
