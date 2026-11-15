import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
// 双栏 diff 行构建器来自独立模型文件（v1.70 70.1），整文件加载后注入方法切片的 vm。
const diffModelSource = readSourceFile(new URL('../../entry/src/main/ets/model/EditorMismatchDiff.ets', import.meta.url));
const diffModelCode = transformSync(`${diffModelSource}
module.exports.buildEditorMismatchDiffRows = buildEditorMismatchDiffRows;`,
  { loader: 'ts', format: 'cjs' }).code;
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
// v1.70 70.1（2026-11-15 双栏 diff 升级）：编辑不一致恢复弹窗改为 git diff 式双栏对照
// （components/EditorMismatchDialog + model/EditorMismatchDiff），三出口
// （留在当前页面 / 以笔记文件为准 / 以编辑区为准）改为弹窗回调。
// 方法切片含 showEditorMismatchRecovery / closeEditorMismatchDialog / saveEditorMismatchFromEditor；
// file-scope 差异摘要、BOM+CRLF 等价豁免与放行键 helpers 一并打入。
const helperStart = source.indexOf('function firstEditorMismatchIndex(');
const helperEnd = source.indexOf('\n/** PaneHead 的按引用传参载体', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find mismatch helpers');
const mismatchHelpers = source.slice(helperStart, helperEnd).trim();
const start = source.indexOf('  private showEditorMismatchRecovery(');
const end = source.indexOf('\n  private showStaleSaveConflict(', start);
assert.ok(start >= 0 && end > start);
const code = transformSync(`${mismatchHelpers}
class Harness { ${source.slice(start, end)} }; module.exports = Harness;
module.exports.describeEditorTextMismatch = describeEditorTextMismatch;
module.exports.isEditorTextEquivalent = isEditorTextEquivalent;
module.exports.editorMismatchApprovalKeyOf = editorMismatchApprovalKeyOf;`,
  { loader: 'ts', format: 'cjs' }).code;

function fixture(pane) {
  const dialogParams = [];
  const controllerOptions = [];
  const opens = [];
  const reloads = [], leftFlushes = [], rightFlushes = [];
  const diffModelContext = vm.createContext({ module: { exports: {} } });
  vm.runInContext(diffModelCode, diffModelContext);
  const context = vm.createContext({ module: { exports: {} }, $r: value => value,
    DOMAIN: 0, TAG: 'test',
    hilog: { warn() {}, error() {} },
    promptAction: { showToast() {} },
    DialogAlignment: { Bottom: 'bottom', Center: 'center' },
    EditorMismatchDialog: options => { dialogParams.push(options); return options; },
    CustomDialogController: class {
      constructor(options) { this.closed = false; controllerOptions.push(options); }
      open() { opens.push(this); }
      close() { this.closed = true; }
    },
    buildEditorMismatchDiffRows: diffModelContext.module.exports.buildEditorMismatchDiffRows
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  app.isSingleScreenLayout = () => false;
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
  app.editorMismatchDiffCtl = null;
  const open = (vault, path, dialogPane, baseline, editor) =>
    app.showEditorMismatchRecovery(vault, path, dialogPane ?? pane, baseline ?? '笔记基线内容', editor ?? '编辑器当前内容');
  const click = name => {
    const params = dialogParams[dialogParams.length - 1];
    params[name]();
  };
  return { app, dialogParams, controllerOptions, opens, reloads, leftFlushes, rightFlushes,
    open, click };
}

test('mismatch dialog opens a two-column diff dialog once per trigger', () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left', 'first\nsecond', 'first\nsxcond');
  f.open('vault', 'a.md', 'left', 'first\nsecond', 'first\nsxcond');
  assert.equal(f.dialogParams.length, 1);
  assert.equal(f.opens.length, 1);
  const params = f.dialogParams[0];
  assert.match(params.summary, /首个差异在第 7 位（基线 U\+65，编辑器 U\+78）/);
  assert.equal(params.leftHead, '笔记版本 · 2 行');
  assert.equal(params.rightHead, '编辑区版本 · 2 行');
  // 双栏 diff 行：一致行（0|0）+ 差异配对行（删 1 | 增 2）。
  assert.equal(params.rows.length, 2);
  assert.equal(params.rows[0].leftText, 'first');
  assert.equal(params.rows[0].leftKind, 0);
  assert.equal(params.rows[0].rightText, 'first');
  assert.equal(params.rows[0].rightKind, 0);
  assert.equal(params.rows[1].leftText, 'second');
  assert.equal(params.rows[1].leftKind, 1);
  assert.equal(params.rows[1].rightText, 'sxcond');
  assert.equal(params.rows[1].rightKind, 2);
  assert.equal(params.singleScreen, false);
  assert.equal(typeof params.onKeepPage, 'function');
  assert.equal(typeof params.onUseNote, 'function');
  assert.equal(typeof params.onUseEditor, 'function');
  assert.equal(f.controllerOptions[0].autoCancel, true);
  assert.equal(f.controllerOptions[0].customStyle, true);
  assert.equal(f.app.editorMismatchDialogOpen, true);
});

test('keeping the page closes the dialog and resets the guard without any write', () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.click('onKeepPage');
  assert.deepEqual(f.reloads, []);
  assert.deepEqual(f.leftFlushes, []);
  assert.deepEqual(f.rightFlushes, []);
  assert.equal(f.app.editorMismatchDialogOpen, false);
  assert.equal(f.app.editorMismatchDiffCtl, null);
  // 守卫复位后可再次触发（防重入不卡死后续弹窗）。
  f.open('vault', 'a.md', 'left');
  assert.equal(f.dialogParams.length, 2);
});

test('cancel and onWillDismiss reset the re-entry guard', () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.controllerOptions[0].onWillDismiss({ dismiss() {} });
  assert.equal(f.app.editorMismatchDialogOpen, false);
  f.open('vault', 'a.md', 'left');
  assert.equal(f.dialogParams.length, 2);
  f.controllerOptions[1].cancel();
  assert.equal(f.app.editorMismatchDialogOpen, false);
});

test('choosing the note file side reloads and never flushes', () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.click('onUseNote');
  assert.deepEqual(f.reloads, [['vault', 'a.md']]);
  assert.deepEqual(f.leftFlushes, []);
  assert.deepEqual(f.rightFlushes, []);
  assert.equal(f.app.editorMismatchDialogOpen, false);
});

test('choosing the editor side flushes the left pane once with a one-shot approval', async () => {
  const f = fixture();
  f.open('vault', 'a.md', 'left');
  f.click('onUseEditor');
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
  f.click('onUseEditor');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(f.leftFlushes, []);
  assert.equal(f.rightFlushes.length, 1);
  assert.equal(f.rightFlushes[0][0], 'b.md');
  assert.equal(f.rightFlushes[0][1], 'vault');
  assert.equal(f.rightFlushes[0][2], 'right\u0000vault\u0000b.md');
  assert.equal(f.app.editorMismatchApprovalKey, '');
});

test('isEditorTextEquivalent exempts BOM and CRLF-only deltas but not real edits', () => {
  const vmContext = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, vmContext);
  const equivalent = vmContext.module.exports.isEditorTextEquivalent;
  // 2026-11-15 BOM 误报根因：基线带 U+FEFF、编辑器无，其余一致 → 不再弹窗。
  assert.equal(equivalent('\uFEFF# 标题\n正文', '# 标题\r\n正文'), true);
  assert.equal(equivalent('\uFEFF', ''), true);
  assert.equal(equivalent('a', 'a'), true);
  assert.equal(equivalent('a\nb', 'a\nc'), false);
  assert.equal(equivalent('a', 'a\uFEFF'), false);
  assert.equal(equivalent('', 'x'), false);
});
