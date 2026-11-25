import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/**
 * v2.6 图标整包迁移 HarmonyOS Symbol —— 映射表锁定测试。
 *
 * 1. `Icons.ets` 的 `SYMBOLS` 记录必须与本表逐项一致（45 名 → 45 id）。
 *    id 逐一核自本机 SDK `sysResource.js` symbol 段（api_notes J-2，2026-11-22）；
 *    本文件锁定「已核实」的名单——新增 / 改动 id 必须先过名单核实再同步改这里。
 * 2. `pathOf` 自绘兜底必须覆盖同名集合（Symbol 摘除即可回落，不许出现两边都缺的名字）。
 * 3. XT2 渲染缺失回退的口径：从 `SYMBOLS` 摘除该条目（回落自绘），并同步改这里的期望集合。
 */

const iconsSource = readFileSync(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url), 'utf8');

const EXPECTED = new Map(Object.entries({
  menu: 'sys.symbol.line_3_horizontal',
  close: 'sys.symbol.xmark',
  back: 'sys.symbol.chevron_left',
  chevronDown: 'sys.symbol.chevron_down',
  chevronUp: 'sys.symbol.chevron_up',
  chevronRight: 'sys.symbol.chevron_forward',
  search: 'sys.symbol.magnifyingglass',
  collapse: 'sys.symbol.chevron_left_2',
  folder: 'sys.symbol.folder',
  check: 'sys.symbol.checkmark',
  doc: 'sys.symbol.doc',
  note: 'sys.symbol.doc_text',
  plus: 'sys.symbol.plus',
  rename: 'sys.symbol.square_and_pencil',
  move: 'sys.symbol.move',
  trash: 'sys.symbol.trash',
  restore: 'sys.symbol.restore_all_items',
  archive: 'sys.symbol.archivebox',
  undo: 'sys.symbol.arrow_counterclockwise',
  redo: 'sys.symbol.arrow_clockwise',
  sync: 'sys.symbol.arrow_2_circlepath',
  settings: 'sys.symbol.slider_horizontal_2',
  message: 'sys.symbol.message',
  share: 'sys.symbol.share',
  image: 'sys.symbol.picture',
  task: 'sys.symbol.checkmark_square',
  more: 'sys.symbol.ellipsis_circle',
  sort: 'sys.symbol.sort',
  pin: 'sys.symbol.pin',
  pinOff: 'sys.symbol.pin_slash',
  star: 'sys.symbol.star',
  starFilled: 'sys.symbol.star_fill',
  swap: 'sys.symbol.swap',
  link: 'sys.symbol.link',
  follow: 'sys.symbol.text_arrow_up_and_down',
  columns: 'sys.symbol.rectangle_split_2x1',
  fileReference: 'sys.symbol.rectangle_split_2x1',
  focus: 'sys.symbol.arrow_up_left_and_arrow_down_right',
  exitFocus: 'sys.symbol.fullscreen',
  simpleMode: 'sys.symbol.text_alignleft',
  professionalMode: 'sys.symbol.code',
  keyboardDone: 'sys.symbol.keyboard_chevron_compact_up',
  medal: 'sys.symbol.medal',
  flame: 'sys.symbol.flame',
  screenSaver: 'sys.symbol.display'
}));

function parseSymbolsRecord(source) {
  const start = source.indexOf('const SYMBOLS: Record<string, Resource> = {');
  assert.ok(start >= 0, 'Icons.ets 找不到 SYMBOLS 记录');
  const end = source.indexOf('};', start);
  const body = source.slice(start, end);
  const map = new Map();
  const re = /'(\w+)': \$r\('(sys\.symbol\.\w+)'\),?/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    assert.ok(!map.has(m[1]), `SYMBOLS 里 ${m[1]} 重复注册`);
    map.set(m[1], m[2]);
  }
  return map;
}

test('2.6.1 SYMBOLS 映射表逐项与已核实名单一致（45 名 → 45 id）', () => {
  const actual = parseSymbolsRecord(iconsSource);
  assert.equal(actual.size, EXPECTED.size,
    `SYMBOLS 条目数 ${actual.size} != 期望 ${EXPECTED.size}（新增/摘除须同步改本测试期望集）`);
  for (const [name, id] of EXPECTED) {
    assert.equal(actual.get(name), id,
      `${name} 的 id 应为 ${id}，实际 ${actual.get(name) ?? '(未注册)'}`);
  }
});

test('2.6.2 SYMBOLS 每个 id 都是 sys.symbol 前缀的小写蛇形名（防凭记忆编造）', () => {
  for (const [, id] of parseSymbolsRecord(iconsSource)) {
    assert.match(id, /^sys\.symbol\.[a-z0-9_]+$/, `${id} 命名不符合 sys.symbol 蛇形约定`);
  }
});

test('2.6.3 自绘兜底 pathOf 覆盖全部映射名（Symbol 摘除即可回落，不允许两边都缺）', () => {
  for (const name of parseSymbolsRecord(iconsSource).keys()) {
    const re = new RegExp(`name === '${name}'`);
    assert.match(iconsSource, re, `pathOf 缺 ${name} 分支：SYMBOLS 摘除后将无兜底`);
  }
});

test('2.6.4 Icon() 默认渲染 SymbolGlyph；FILLED_ICONS 兜底与 L-7/Z2 内联通道保留', () => {
  assert.match(iconsSource,
    /if \(symbolMapped\(name\)\) \{\s*SymbolGlyph\(symbolGlyphOf\(name\)\)\s*\.fontSize\(size\)\s*\.fontColor\(\[color\]\)/);
  assert.match(iconsSource, /const FILLED_ICONS: string\[\] = \['sync', 'starFilled'\];/);
  assert.match(iconsSource, /export function symbolGlyphOf\(name: string\): Resource \{/);
});
