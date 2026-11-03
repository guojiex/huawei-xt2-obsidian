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
