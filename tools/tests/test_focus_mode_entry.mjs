import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';

const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const iconSource = fs.readFileSync(new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url), 'utf8');
const apiNotes = fs.readFileSync(new URL('../../docs/harmonyos/api_notes.md', import.meta.url), 'utf8');
const buttonStart = indexSource.indexOf('  FocusModeButton() {');
const buttonEnd = indexSource.indexOf('\n  @Builder', buttonStart);
assert.ok(buttonStart >= 0 && buttonEnd > buttonStart, 'could not find FocusModeButton');
const focusButton = indexSource.slice(buttonStart, buttonEnd);

test('native focus entry switches its custom icon, accessible name, hint and selected token', () => {
  assert.match(focusButton, /Icon\(this\.focused \? 'exitFocus' : 'focus'/);
  assert.match(focusButton, /this\.focused \? '退出专注模式' : '进入专注模式'/);
  assert.match(focusButton, /this\.focused \? '恢复目录和参考栏' : '隐藏目录和参考栏，聚焦当前笔记'/);
  assert.match(focusButton, /this\.focused \? \$r\('app\.color\.brand_bg'\) : Color\.Transparent/);
  assert.match(focusButton, /this\.toggleFocus\(\)/);
});

test('custom exit-focus path is registered and the control stays out of single-screen layout', () => {
  assert.match(iconSource, /const P_EXIT_FOCUS: string = '[^']+'/);
  assert.match(iconSource, /name === 'exitFocus'[\s\S]*?return P_EXIT_FOCUS/);
  assert.doesNotMatch(focusButton, /sys\.symbol\./);
  assert.match(indexSource, /if \(this\.topView === 'note'\) \{[\s\S]*?if \(!this\.isSingleScreenLayout\(\)\) \{[\s\S]*?this\.FocusModeButton\(\)/);
});

test('focus preference restoration, explicit toggle, and its current API floor remain wired', () => {
  assert.match(indexSource, /this\.focused = session\.focused/);
  assert.match(indexSource, /private toggleFocus\(\): void \{\s*this\.focused = !this\.focused;\s*this\.scheduleWorkspaceSessionSave\(\)/);
  assert.match(indexSource, /if \(this\.focused\) \{\s*this\.toggleFocus\(\)/);
  assert.match(apiNotes, /accessibilityText\(value: string\)` 自 API 11 起、`accessibilityTextHint\(value: string\)` 自 API 12 起/);
});
