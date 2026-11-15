import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
// v1.70 70.1（2026-11-15）：双栏 diff 行构建器的纯函数测试。
// 模型文件 model/EditorMismatchDiff.ets 是自包含纯文本变换，整文件加载。
const source = readSourceFile(new URL('../../entry/src/main/ets/model/EditorMismatchDiff.ets', import.meta.url));
const code = transformSync(`${source}
module.exports.buildEditorMismatchDiffRows = buildEditorMismatchDiffRows;
module.exports.EditorMismatchDiffRow = EditorMismatchDiffRow;
module.exports.KIND = {
  SAME: EDITOR_MISMATCH_KIND_SAME,
  REMOVED: EDITOR_MISMATCH_KIND_REMOVED,
  ADDED: EDITOR_MISMATCH_KIND_ADDED,
  COLLAPSED: EDITOR_MISMATCH_KIND_COLLAPSED
};`, { loader: 'ts', format: 'cjs' }).code;

const context = vm.createContext({ module: { exports: {} } });
vm.runInContext(code, context);
const build = context.module.exports.buildEditorMismatchDiffRows;
const KIND = context.module.exports.KIND;

test('identical texts produce a run of same rows', () => {
  const rows = build('一\n二\n三', '一\n二\n三');
  assert.equal(rows.length, 3);
  for (const row of rows) {
    assert.equal(row.leftKind, KIND.SAME);
    assert.equal(row.rightKind, KIND.SAME);
    assert.equal(row.leftText, row.rightText);
  }
});

test('pure-added tail marks only the new lines as added', () => {
  const rows = build('一\n二', '一\n二\n三');
  assert.equal(rows.length, 3);
  assert.equal(rows[2].leftKind, KIND.SAME);
  assert.equal(rows[2].leftText, '');
  assert.equal(rows[2].rightKind, KIND.ADDED);
  assert.equal(rows[2].rightText, '三');
});

test('BOM-only difference pairs the signed line against the plain line', () => {
  // 2026-11-15 误报场景的展示口径：带 BOM 基线行（删）vs 无 BOM 编辑器行（增）。
  const rows = build('\uFEFF# 标题', '# 标题');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].leftKind, KIND.REMOVED);
  assert.equal(rows[0].leftText, '\uFEFF# 标题');
  assert.equal(rows[0].rightKind, KIND.ADDED);
  assert.equal(rows[0].rightText, '# 标题');
});

test('multi-line edit pairs adjacent removals and additions like git side-by-side', () => {
  const rows = build('x\n旧1\n旧2\ny', 'x\n新1\ny');
  assert.equal(rows.length, 4);
  assert.deepEqual([rows[0].leftKind, rows[0].rightKind], [KIND.SAME, KIND.SAME]);
  assert.deepEqual([rows[1].leftText, rows[1].rightText], ['旧1', '新1']);
  assert.deepEqual([rows[1].leftKind, rows[1].rightKind], [KIND.REMOVED, KIND.ADDED]);
  assert.equal(rows[2].leftKind, KIND.REMOVED);
  assert.equal(rows[2].leftText, '旧2');
  assert.equal(rows[2].rightKind, KIND.SAME);
  assert.deepEqual([rows[3].leftText, rows[3].rightText], ['y', 'y']);
});

test('long identical runs collapse into one note row keeping head and tail context', () => {
  const head = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  const left = [...head, '差异', ...head].join('\n');
  const right = [...head, '不同', ...head].join('\n');
  const rows = build(left, right);
  const collapsed = rows.filter(row => row.leftKind === KIND.COLLAPSED);
  assert.equal(collapsed.length, 2);
  assert.match(collapsed[0].leftText, /行一致/);
  // 首部保留 3 行上下文：一、二、三之后即折叠提示（vm 跨 realm 数组需展开回宿主再比较）。
  assert.deepEqual([...rows.slice(0, 3).map(row => row.leftText)], ['一', '二', '三']);
  assert.equal(rows[3].leftKind, KIND.COLLAPSED);
  // 差异行与配对行仍在。
  const pair = rows.find(row => row.leftText === '差异');
  assert.equal(pair.rightText, '不同');
});

test('oversized inputs fall back to prefix/suffix alignment and cap total rows', () => {
  // 1100×1100 行 > LCS 单元格上限 → 回退路径；行数 > 400 → 截断折叠。
  const left = Array.from({ length: 1100 }, (_, i) => `左${i}`).join('\n');
  const right = Array.from({ length: 1100 }, (_, i) => `右${i}`).join('\n');
  const rows = build(left, right);
  assert.ok(rows.length <= 401, `rows should be capped, got ${rows.length}`);
  const truncation = rows.filter(row => row.leftKind === KIND.COLLAPSED &&
    row.leftText.indexOf('未展示') >= 0);
  assert.equal(truncation.length, 1);
});

test('single oversized cell text is truncated with an ellipsis', () => {
  const long = '字'.repeat(3000);
  const rows = build(long, '短');
  const leftCell = rows[0].leftText;
  assert.equal(leftCell.length, 2001);
  assert.equal(leftCell.endsWith('…'), true);
});
