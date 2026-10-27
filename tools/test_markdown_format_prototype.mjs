import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const source = html.slice(html.indexOf('  function applyMarkdownFormat('), html.indexOf('  function closeFormatPanel('));
function editor(value, start = 0, end = value.length) {
  const ta = { value, selectionStart: start, selectionEnd: end, scrollTop: 24,
    setRangeText(text, from, to) { this.value = this.value.slice(0, from) + text + this.value.slice(to); },
    setSelectionRange(from, to) { this.selectionStart = from; this.selectionEnd = to; },
    focus() {}, dispatchEvent() {} };
  const context = vm.createContext({ ta, current: 'note', Event: class {}, showToast() {} });
  vm.runInContext(source, context);
  return { ta, apply(kind) { context.kind = kind; vm.runInContext('applyMarkdownFormat(kind)', context); } };
}
for (const [kind, formatted] of [['italic', '*同一段文字*'], ['bold', '**同一段文字**'], ['code', '`同一段文字`']]) {
  test(`${kind}: repeated clicks toggle without accumulating markers`, () => {
    const f = editor('同一段文字');
    for (let i = 0; i < 6; i++) {
      f.apply(kind);
      assert.equal(f.ta.value, i % 2 === 0 ? formatted : '同一段文字');
      assert.equal(f.ta.value.slice(f.ta.selectionStart, f.ta.selectionEnd), '同一段文字');
      assert.equal(f.ta.scrollTop, 24);
    }
  });
}
test('italic toggles inside bold without removing bold', () => {
  const f = editor('**文字**', 2, 4);
  f.apply('italic'); assert.equal(f.ta.value, '***文字***');
  f.apply('italic'); assert.equal(f.ta.value, '**文字**');
});
test('bold toggles inside italic without removing italic', () => {
  const f = editor('*文字*', 1, 3);
  f.apply('bold'); assert.equal(f.ta.value, '***文字***');
  f.apply('bold'); assert.equal(f.ta.value, '*文字*');
});
test('reselecting text including its delimiters can remove its format', () => {
  for (const [kind, value, expected] of [['italic','*文字*','文字'],['bold','**文字**','文字'],['italic','***文字***','**文字**'],['bold','***文字***','*文字*']]) {
    const f = editor(value); f.apply(kind); assert.equal(f.ta.value, expected);
  }
});
test('toggle leaves neighboring text untouched and placeholders also toggle off', () => {
  const f = editor('前文 文字 后文', 3, 5);
  f.apply('italic'); f.apply('italic'); assert.equal(f.ta.value, '前文 文字 后文');
  const empty = editor(''); empty.apply('italic'); empty.apply('italic');
  assert.equal(empty.ta.value, '斜体文字');
});
