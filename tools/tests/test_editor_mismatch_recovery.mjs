import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
// v1.70 AC-01：弹窗差异上窗 + 三出口（留在当前页面 / 以笔记文件为准 / 以编辑区为准）。
// 方法切片含 showEditorMismatchRecovery 与 saveEditorMismatchFromEditor；file-scope 差异
// 描述与放行键 helpers 一并打入。
const helperStart = source.indexOf('function firstEditorMismatchIndex(');
const helperEnd = source.indexOf('\n/** PaneHead 的按引用传参载体', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find mismatch helpers');
const mismatchHelpers = source.slice(helperStart, helperEnd).trim();
const start = source.indexOf('  private showEditorMismatchRecovery(');
const end = source.indexOf('\n  private showStaleSaveConflict(', start);
assert.ok(start >= 0 && end > start);
const code = transformSync(`${mismatchHelpers}
class Harness { ${source.slice(start, end)} }; module.exports = Harness;
module.exports.describeEditorMismatchForDialog = describeEditorMismatchForDialog;
module.exports.editorMismatchApprovalKeyOf = editorMismatchApprovalKeyOf;`,
  { loader: 'ts', format: 'cjs' }).code;

function fixture(pane) {
  let resolveDialog;
  const dialogs = [], reloads = [], leftFlushes = [], rightFlushes = [];
  let app;
  const context = vm.createContext({ module: { exports: {} }, $r: value => value,
    DOMAIN: 0, TAG: 'test',
    hilog: { warn() {}, error() {} },
    promptAction: { showToast() {} } });
  vm.runInContext(code, context);
  app = new context.module.exports();
  app.getUIContext = () => ({ getPromptAction: () => ({ showDialog(options) {
    dialogs.push(options);
    return new Promise(resolve => { resolveDialog = resolve; });
  } }) });
  app.reloadStaleVaultNote = async (vault, path) => { reloads.push([vault, path]); };
  app.flushSave = async (path, vaultId) => {
    leftFlushes.push([path, vaultId, app.editorMismatchApprovalKey]);
    return true;
  };
  app.flushRightSave = async (path, vaultId) => {
    rightFlushes.push([path, vaultId, app.editorMismatchApprovalKey]);
    return true;
  };
  app.editorMismatchDialogOpen = false;
  app.editorMismatchApprovalKey = '';
  const open = (vault, path, dialogPane, baseline, editor) =>
    app.showEditorMismatchRecovery(vault, path, dialogPane ?? pane, baseline ?? '笔记基线内容', editor ?? '编辑器当前内容');
  return { app, dialogs, reloads, leftFlushes, rightFlushes,
    open, respond: index => resolveDialog({ index }) };
}

test('mismatch dialog shows the diff on the dialog itself and stays once per trigger', async () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left', 'first\nsecond', 'first\r\nsecond');
  f.open('vault', 'a.md', 'left', 'first\nsecond', 'first\r\nsecond');
  assert.equal(f.dialogs.length, 1);
  assert.equal(f.dialogs[0].title, '编辑内容与笔记不一致');
  assert.match(f.dialogs[0].message, /首个差异在第 5 位（基线 U\+a，编辑器 U\+d）/);
  assert.match(f.dialogs[0].message, /笔记版本：first\\nsecond/);
  assert.match(f.dialogs[0].message, /编辑区版本：first\\r\\nsecond/);
  assert.equal(f.dialogs[0].buttons.length, 3);
  assert.equal(f.dialogs[0].buttons.map(button => button.text).join('|'),
    '留在当前页面|以笔记文件为准|以编辑区为准');
  f.respond(0);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.reloads, []);
  assert.deepEqual(f.leftFlushes, []);
  assert.deepEqual(f.rightFlushes, []);
});

test('describeEditorMismatchForDialog reports structural summary plus readable windows', () => {
  const vmContext = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, vmContext);
  const describe = vmContext.module.exports.describeEditorMismatchForDialog;
  assert.equal(describe('相同内容', '相同内容'), '内容一致');
  // 中文原样保留（弹窗面向用户本人），控制字符转义。
  assert.equal(
    describe('标题\n中文正文', '标题\r\n中文正文'),
    '基线 7 字符，编辑器 8 字符，首个差异在第 2 位（基线 U+a，编辑器 U+d）\n' +
    '笔记版本：标题\\n中文正文\n编辑区版本：标题\\r\\n中文正文');
  // 一方是另一方前缀时窗口落在结尾。
  const prefixCase = describe('abcdef', 'abc');
  assert.match(prefixCase, /一方是另一方的前缀/);
  assert.match(prefixCase, /笔记版本：abcdef/);
  assert.match(prefixCase, /编辑区版本：abc/);
});

test('choosing the note file side reloads and never flushes', async () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.respond(1);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.reloads, [['vault', 'a.md']]);
  assert.deepEqual(f.leftFlushes, []);
  assert.deepEqual(f.rightFlushes, []);
});

test('choosing the editor side flushes the left pane once with a one-shot approval', async () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.respond(2);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.reloads, []);
  assert.deepEqual(f.rightFlushes, []);
  assert.equal(f.leftFlushes.length, 1);
  assert.equal(f.leftFlushes[0][0], 'a.md');
  assert.equal(f.leftFlushes[0][1], 'vault');
  assert.equal(f.leftFlushes[0][2], 'left\u0000vault\u0000a.md');
  assert.equal(f.app.editorMismatchApprovalKey, '');
});

test('choosing the editor side flushes the right pane once with a one-shot approval', async () => {
  const f = fixture();
  f.open('vault', 'b.md', 'right');
  f.respond(2);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.leftFlushes, []);
  assert.equal(f.rightFlushes.length, 1);
  assert.equal(f.rightFlushes[0][0], 'b.md');
  assert.equal(f.rightFlushes[0][1], 'vault');
  assert.equal(f.rightFlushes[0][2], 'right\u0000vault\u0000b.md');
  assert.equal(f.app.editorMismatchApprovalKey, '');
});
