/*
 * Git 同步「逐行差异」设计稿契约测试。
 *
 * 锁三件事：
 * 1. 原型结构 —— 改动清单每个文件都是可展开按钮；就地 unified diff 容器、色板 token、演示入口俱在；
 * 2. 纯逻辑 —— gitSyncUnifiedDiff 对「修改 / 新增 / 删除 / 无改动」的输出行、增删计数、行号正确；
 * 3. 视觉边界 —— diff 只复用既有 diff-* token，不散写颜色；改动清单窄栏可滚动、读屏有增删前缀。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));
const plain = (value) => JSON.parse(JSON.stringify(value));

function extractFn(name) {
  const m = html.match(new RegExp('^function ' + name + '\\([^\\n]*$', 'm'));
  assert.ok(m, `prototype must define ${name}`);
  return m[0];
}
function extractArrow(name) {
  const m = html.match(new RegExp('^const ' + name + '=[^\\n]*$', 'm'));
  assert.ok(m, `prototype must define ${name}`);
  return m[0];
}

test('v2 git sync hosts expandable per-file rows with inline unified diff', () => {
  assert.ok(html.includes('<span class="vh">'), 'visually-hidden helper exists for screen readers');
  assert.match(html, /\.vh\{position:absolute!important/);
  assert.match(html, /class="sync-file-toggle" data-sync-file="'\+esc\(path\)\+'" aria-expanded="'\+open\+'" aria-controls="'\+ctrl\+'"/);
  assert.match(html, /class="sync-file-diff'\+\(open\?'':' hidden'\)\+'" id="'\+ctrl\+'" role="region"/);
  assert.match(html, /<div class="sync-diff-head">/);
  assert.match(html, /<div class="sync-diff-lines">/);
  assert.match(html, /class="sync-diff-line '\+r\.kind\+'"/);
  assert.match(html, /data-sync-demo="diff"/, 'demo entry to open a diff example');
});

test('diff rows reuse diff-* color tokens, no scattered hex colors in new CSS', () => {
  const block = html.slice(html.indexOf('/* Git sync note diff'), html.indexOf('/* Git sync note diff') + 2200);
  assert.match(block, /\.sync-diff-line\.del\{background:var\(--diff-del-bg\)\}/);
  assert.match(block, /\.sync-diff-line\.add\{background:var\(--diff-add-bg\)\}/);
  assert.match(block, /\.del \.dl-mark,\.sync-diff-line\.del \.dl-text\{color:var\(--danger\)\}/);
  assert.match(block, /\.add \.dl-mark,\.sync-diff-line\.add \.dl-text\{color:var\(--green\)\}/);
  assert.ok(!/#[0-9a-fA-F]{3,8}/.test(block), 'no hardcoded hex colors');
});

test('toggle handler swaps open file in state and toggles hidden without full re-render', () => {
  assert.match(html, /s\.openFile=s\.openFile===p\?'':p;/);
  assert.match(html, /x\.setAttribute\('aria-expanded',String\(on\)\)/);
  assert.match(html, /d\.classList\.toggle\('hidden',!on\)/);
  assert.match(html, /openFile:''\},?|\.openFile=''/);
});

// ---- pure logic: run the extracted algorithm in a VM realm ----
const ctx = {
  mismatchDiffRows: null,
  out: []
};
vm.createContext(ctx);
vm.runInContext(extractFn('mismatchDiffRows'), ctx);
vm.runInContext(extractFn('gitSyncUnifiedDiff'), ctx);

const diff = (before, after) => plain(vm.runInContext('gitSyncUnifiedDiff(__b, __a)', Object.assign(ctx, { __b: before, __a: after })));

test('unified diff: modified file yields paired delete/add plus unchanged context', () => {
  const before = ['A', 'old line', 'B'].join('\n');
  const after = ['A', 'new line', 'B'].join('\n');
  const rows = diff(before, after);
  const kinds = rows.map(r => r.kind);
  assert.ok(kinds.includes('ctx') && kinds.includes('del') && kinds.includes('add'));
  const del = rows.find(r => r.kind === 'del'), add = rows.find(r => r.kind === 'add');
  assert.equal(del.text, 'old line');
  assert.equal(add.text, 'new line');
  assert.equal(del.ol, 2);
  assert.equal(add.nl, 2);
  assert.equal(del.nl, '');
  assert.equal(add.ol, '');
});

test('unified diff: new file (empty before) produces all add rows with correct new line numbers', () => {
  const rows = diff('', ['L1', 'L2', 'L3'].join('\n'));
  assert.deepEqual(rows.map(r => r.kind), ['add', 'add', 'add']);
  assert.deepEqual(rows.map(r => r.nl), [1, 2, 3]);
  assert.ok(rows.every(r => r.ol === ''));
});

test('unified diff: deleted file (empty after) produces all del rows with correct old line numbers', () => {
  const rows = diff(['L1', 'L2'].join('\n'), '');
  assert.deepEqual(rows.map(r => r.kind), ['del', 'del']);
  assert.deepEqual(rows.map(r => r.ol), [1, 2]);
  assert.ok(rows.every(r => r.nl === ''));
});

test('unified diff: identical text yields only context, no del/add', () => {
  const rows = diff(['A', 'B'].join('\n'), ['A', 'B'].join('\n'));
  assert.ok(rows.every(r => r.kind === 'ctx'));
  assert.equal(rows.length, 2);
});

test('demo data covers all three change kinds and yields non-empty stats', () => {
  const dataSrc = html.slice(html.indexOf('const gitSyncFileDiff='), html.indexOf('function gitSyncUnifiedDiff'));
  assert.match(dataSrc, /'00_开始\/快速上手\.md'/);
  assert.match(dataSrc, /'10_写作\/会议记录\/周会 11-03\.md'/);
  assert.match(dataSrc, /'购物清单\.md'/);
  // 修改文件：有增有删；新增文件 before 为空；删除文件 after 为空。
  assert.match(dataSrc, /before:\['# 快速上手'/);
  assert.match(dataSrc, /after:\['# 周会 11-03'/);
  assert.match(dataSrc, /after:''\}/);
});
