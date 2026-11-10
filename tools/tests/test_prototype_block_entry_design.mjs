import assert from 'node:assert/strict';
import fs from 'node:fs';

const prototype = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

// The v2 prototype is an interaction reference only. These checks protect its
// required design entry points without claiming ArkUI or device verification.
assert.match(prototype, /id="blockBar"/);
assert.match(prototype, /id="blockSheet"/);
assert.match(prototype, /id="blockSheetTable"/);
assert.match(prototype, /id="blockSheetBody"/);
assert.match(prototype, /id="blockSheetSub"/);

const barStart = prototype.indexOf('<div class="block-bar hidden" id="blockBar"');
const barEnd = prototype.indexOf('</div>', prototype.indexOf('data-block-op="more"', barStart));
const bar = prototype.slice(barStart, barEnd);
assert.equal([...bar.matchAll(/data-block-op="/g)].length, 4, 'the table bar has three actions plus more');
assert.match(bar, /aria-label="当前块操作"/);
assert.match(prototype, /function openBlockUi\(/);
assert.match(prototype, /function openComplexFor\(/);
assert.match(prototype, /function annotateComplexBlocks\(/);
assert.match(prototype, /function unknownColonRanges\(/);
assert.match(prototype, /block\.classList\.contains\('md-unknown-colon'\)/);
assert.match(prototype, /\.simple-protected::after\{content:'此内容请在专业模式编辑'/);
assert.match(prototype, /tgt\.closest\('\.md-unknown-colon'\)\|\|tgt\.closest/);
assert.match(prototype, /case 'directive':return \{title:'指令块',html:CBH\.info\('此内容请在专业模式编辑'\)\+CBH\.source\(\)\}/);

// D-1 to D-8: complex blocks each have a distinct entry path in simple mode.
for (const marker of [
  'md-code-bar',
  'data-inline',
  'md-callout',
  'md-math',
  'md-props-entry',
  'data-block-id',
  'copy-block-link',
  'cbOpenSource',
  'cbWrite',
  'commitCodeBlock'
]) {
  assert.ok(prototype.includes(marker), `prototype must retain ${marker}`);
}
assert.match(prototype, /复制块链接/);
assert.match(prototype, /复制指向本段的链接/);
assert.match(prototype, /本操作不会自动生成/);
assert.match(prototype, /navigator\.clipboard\?navigator\.clipboard\.writeText\('\[\[#\^'\+blockId\.id\+'\]\]'\)/);
assert.match(prototype, /正文可以包含 \*\*粗体\*\*、\*斜体\*、~~删除线~~和 `行内代码`。 \^demo-paragraph/);

// D-3: narrow screens use the sheet while wide screens use a bounded popup.
assert.match(prototype, /function setSheetMode\(/);
assert.match(prototype, /function positionBlockPopup\(/);
assert.match(prototype, /block-sheet\.as-popup/);

// v1.22: the controls expose grip, rail, live readout, cancellation and keyboard support.
for (const marker of [
  'split-grip',
  'split-rail',
  'split-tip',
  'SPLIT_SNAP_PX',
  'aria-valuetext',
  "event.key==='Escape'",
  "event.key==='Home'",
  "event.key==='End'"
]) {
  assert.ok(prototype.includes(marker), `split enhancement must retain ${marker}`);
}

// v1.50: the table bar follows the active cell (anchor center) and falls back to the whole block.
assert.match(prototype, /blockTarget\.cell&&blockTarget\.cell\.isConnected\?blockTarget\.cell:null/);
assert.match(prototype, /if\(!rect\|\|rect\.width<=0\|\|rect\.height<=0\|\|rect\.bottom<win\.top\+gap\|\|rect\.top>limit\)rect=block\.getBoundingClientRect\(\)/);
assert.match(prototype, /rect\.left\+rect\.width\/2-width\/2/);

const rootStart = prototype.indexOf(':root{');
const rootEnd = prototype.indexOf('}', rootStart);
const tokens = new Set(
  [...prototype.slice(rootStart, rootEnd).matchAll(/--[a-z0-9-]+/g)].map(match => match[0])
);
for (const token of ['--blue', '--line', '--paper', '--s2', '--s4', '--small-r']) {
  assert.ok(tokens.has(token), `prototype must define ${token}`);
}
