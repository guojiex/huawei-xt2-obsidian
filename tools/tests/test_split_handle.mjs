import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const root = new URL('../../', import.meta.url);
const splitHandle = fs.readFileSync(new URL('entry/src/main/ets/components/SplitHandle.ets', root), 'utf8');
const index = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8');
const agent = fs.readFileSync(new URL('entry/src/main/ets/components/AgentWorkspace.ets', root), 'utf8');
const tokens = fs.readFileSync(new URL('entry/src/main/ets/common/Tokens.ets', root), 'utf8');

test('note split handles show a grip and stateful full-height rail', () => {
  assert.match(splitHandle, /@Prop enhanced: boolean = false/);
  assert.match(splitHandle, /this\.enhanced && \(this\.hovered \|\| this\.focused \|\| this\.dragging\)/);
  assert.match(splitHandle, /backgroundColor\(\$r\('app\.color\.brand'\)\)/);
  assert.match(splitHandle, /Size\.splitGripW/);
  assert.equal((splitHandle.match(/Size\.splitGripDot/g) ?? []).length, 6);
});

test('expanded touch and mouse regions do not change note or Agent layout widths', () => {
  assert.match(splitHandle, /responseRegion\(this\.enhanced/);
  assert.match(splitHandle, /mouseResponseRegion\(this\.enhanced/);
  assert.match(tokens, /splitTouchHitW: number = 36/);
  assert.match(tokens, /splitMouseHitW: number = 24/);
  assert.match(index, /\.width\(Space\.s4 \* this\.noteNavigationProgress\(\)\)/);
  assert.match(index, /\.width\(this\.contentHandleVisible\(\) \? Space\.s4 : 0\)/);

  const agentCalls = agent.match(/SplitHandle\(\{[\s\S]*?\}\)/g) ?? [];
  assert.equal(agentCalls.length, 2);
  for (const call of agentCalls) assert.doesNotMatch(call, /enhanced:\s*true/);
});

test('split drag shows no visual readout or feedback bubble (2026-11-07 user decision)', () => {
  assert.doesNotMatch(splitHandle, /feedbackVisible/);
  assert.doesNotMatch(splitHandle, /showFeedback/);
  assert.doesNotMatch(splitHandle, /栏宽已保存|调整中|已取消调整/);
  assert.doesNotMatch(tokens, /splitTipH/);
  assert.match(splitHandle, /readoutPrimary/);
  assert.match(splitHandle, /readoutWidths/);
  assert.match(splitHandle, /readoutStatus/);
});

test('zero-width handles clip their grip so a collapsed sidebar hides the nav handle (2026-11-07)', () => {
  assert.match(splitHandle, /\.clip\(true\)/);
  // 外部 .width(0) 只作用于包装节点，内部根 Stack 固定 16vp 会溢出绘制，
  // clip 裁不到——显隐必须走 visibility（递归隐藏子树，2026-11-07 双屏实测）。
  assert.match(index, /\.visibility\(this\.noteNavigationProgress\(\) > 0 \? Visibility\.Visible : Visibility\.Hidden\)/);
  assert.match(index, /\.visibility\(this\.contentHandleVisible\(\) \? Visibility\.Visible : Visibility\.Hidden\)/);
  assert.match(index, /\.width\(Space\.s4 \* this\.noteNavigationProgress\(\)\)/);
});

test('split readout reports ratios, pane widths, and boundary causes', () => {
  assert.match(index, /private splitHandlePrimary\(kind: string\)/);
  assert.match(index, /private splitHandleWidths\(kind: string\)/);
  assert.match(index, /private splitHandleStatus\(kind: string\)/);
  assert.match(index, /默认比例/);
  assert.match(index, /每个内容栏至少/);
  assert.match(index, /每栏至少/);
  assert.match(index, /MIN_NAV_RATIO/);
  assert.match(index, /MAX_NAV_RATIO/);
});

test('note split dragging snaps near defaults, honors Alt, and restores cancelled widths', () => {
  assert.match(splitHandle, /getModifierKeyState\(\['Alt'\]\)/);
  assert.match(index, /Math\.abs\(candidate - defaultWidth\) <= 10/);
  assert.match(index, /Math\.abs\(candidateWidth - defaultWidth\) <= 10/);
  assert.match(index, /navigationRatioAtDragStart/);
  assert.match(index, /contentRatioAtDragStart/);
  assert.match(index, /dragCancelled: \(\): void => \{ this\.cancelNavigationDrag\(\); \}/);
  assert.match(index, /dragCancelled: \(\): void => \{ this\.cancelContentDrag\(\); \}/);
});

test('Escape cancels a live drag and touch reset uses two short clicks', () => {
  assert.match(splitHandle, /event\.keyCode === KeyCode\.KEYCODE_ESCAPE && this\.dragging/);
  assert.match(splitHandle, /this\.dragCancelled\(\)/);
  assert.match(splitHandle, /now - this\.lastTapAt <= 320/);
  assert.doesNotMatch(splitHandle, /onDoubleClick/);
});

test('split handles support keyboard adjustment, limits, reset, and current accessible values', () => {
  assert.match(splitHandle, /SPLIT_KEY_STEP: number = 16/);
  assert.match(splitHandle, /SPLIT_KEY_SHIFT_STEP: number = 64/);
  assert.match(splitHandle, /KEYCODE_DPAD_LEFT/);
  assert.match(splitHandle, /KEYCODE_DPAD_RIGHT/);
  assert.match(splitHandle, /getModifierKeyState\(\['Shift'\]\)/);
  assert.match(splitHandle, /KEYCODE_MOVE_HOME[\s\S]*?keyboardToLimit\(false\)/);
  assert.match(splitHandle, /KEYCODE_MOVE_END[\s\S]*?keyboardToLimit\(true\)/);
  assert.match(splitHandle, /KEYCODE_ENTER[\s\S]*?resetRequested\(\)/);
  assert.match(splitHandle, /'分隔条，当前比例：' \+ this\.readoutPrimary/);
  assert.match(splitHandle, /this\.readoutWidths/);
  assert.match(splitHandle, /this\.readoutStatus/);

  assert.match(index, /adjustSplitByKeyboard\('nav', deltaVp\)/);
  assert.match(index, /adjustSplitByKeyboard\('content', deltaVp\)/);
  assert.match(index, /setSplitKeyboardLimit\('nav', maximum\)/);
  assert.match(index, /setSplitKeyboardLimit\('content', maximum\)/);
});
