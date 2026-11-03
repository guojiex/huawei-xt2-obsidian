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

test('split feedback is shown during drag and retained briefly afterward', () => {
  assert.match(splitHandle, /this\.dragging \|\| this\.feedbackVisible/);
  assert.match(splitHandle, /this\.showFeedback\('/);
  assert.match(splitHandle, /setTimeout\([\s\S]*?1100/);
  assert.match(splitHandle, /readoutPrimary/);
  assert.match(splitHandle, /readoutWidths/);
  assert.match(splitHandle, /readoutStatus/);
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
  assert.match(splitHandle, /event\.keyCode !== KeyCode\.KEYCODE_ESCAPE/);
  assert.match(splitHandle, /this\.dragCancelled\(\)/);
  assert.match(splitHandle, /now - this\.lastTapAt <= 320/);
  assert.doesNotMatch(splitHandle, /onDoubleClick/);
});
