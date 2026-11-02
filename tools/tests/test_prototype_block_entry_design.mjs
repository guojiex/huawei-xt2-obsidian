import assert from 'node:assert/strict';
import fs from 'node:fs';

const prototype = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

// 设计真源：简单模式复杂块编辑设计 §4（C 上下文浮条 + D 块属性面板，Aa 保持纯净）
const barStart = prototype.indexOf('<div class="block-bar hidden" id="blockBar"');
const barEnd = prototype.indexOf('</div>', prototype.indexOf('data-block-op="more"', barStart));
assert.ok(barStart >= 0 && barEnd > barStart, 'prototype must define the contextual block bar');
const bar = prototype.slice(barStart, barEnd);

const sheetStart = prototype.indexOf('<div class="block-sheet hidden" id="blockSheet"');
const sheetEnd = prototype.indexOf('</div>', prototype.indexOf('class="block-sheet-note"', sheetStart));
assert.ok(sheetStart >= 0 && sheetEnd > sheetStart, 'prototype must define the block sheet');
const sheet = prototype.slice(sheetStart, sheetEnd);

// 浮条：最多 4 项（3 个操作 + 更多），每项都有读屏名称
const barButtons = [...bar.matchAll(/<button[^>]*data-block-op="([a-z-]+)"[^>]*aria-label="([^"]+)"/g)];
assert.equal(barButtons.length, 4, `the bar keeps at most four entries (found ${barButtons.length})`);
// 方向：浮条一击用当前方向，按钮标签直接写出方向；面板可切换四个方向并同步浮条
assert.match(bar, /data-block-op="insert-row" aria-label="在当前行下方插入一行">下加行/);
assert.match(bar, /data-block-op="insert-col" aria-label="在当前列右侧插入一列">右加列/);
assert.match(sheet, /<strong id="blockInsertColLabel" style="color:var\(--blue\)">在右侧插入列<\/strong>/);
assert.match(sheet, /<strong id="blockInsertRowLabel" style="color:var\(--blue\)">在下方插入行<\/strong>/);
assert.match(prototype, /function syncBlockBarLabels\(\)\{[\s\S]{0,400}\(left\?'左':'右'\)\+'加列'[\s\S]{0,400}\(up\?'上':'下'\)\+'加行'/);
assert.match(prototype, /function syncBlockSheetLabels\(\)\{[\s\S]{0,300}blockInsertColLabel'\)\.textContent[\s\S]{0,200}blockInsertRowLabel'\)\.textContent/);
assert.match(prototype, /if\(inGroup\)button\.setAttribute\('aria-pressed',String\(side===value\)\);\}syncBlockBarLabels\(\);syncBlockSheetLabels\(\);\}/,
  'switching a side must relabel both the bar and the sheet');
assert.match(prototype, /function insertTableColumn\(side\)\{[\s\S]{0,400}const index=side==='left'\?pos\.colIndex:pos\.colIndex\+1/);
assert.match(prototype, /function insertTableRow\(side\)\{[\s\S]{0,400}const index=side==='up'\?pos\.rowIndex:pos\.rowIndex\+1/);
assert.ok(/<button type="button" class="more" data-block-op="more"/.test(bar), 'the last entry is the more affordance');
assert.match(bar, /role="group" aria-label="当前块操作"/);

// 浮条：贴在块下沿、空间不足上翻，Escape 与点击外部收起
assert.match(prototype, /\.block-bar\{position:fixed;z-index:6;display:flex/);
assert.match(prototype, /let top=rect\.bottom\+gap;\s*\n?\s*if\(top\+height>limit\)top=rect\.top-height-gap;/);
assert.match(prototype, /function closeBlockUi\(\)\{[\s\S]{0,400}\$\('blockBar'\)\.classList\.add\('hidden'\)/);
assert.match(prototype, /event\.key==='Escape'&&blockTarget/);

// 样式对齐 HarmonyOS 半模态（bindSheet）：遮罩 + 顶部拖拽条 + 右上关闭图标 + 大圆角 + 列表行内放控件
assert.match(sheet, /role="dialog" aria-modal="true" aria-label="块设置：表格"/);
assert.match(sheet, /<div class="block-sheet-drag" aria-hidden="true"><\/div>/, 'the sheet shows the HarmonyOS drag bar');
assert.match(sheet, /<strong id="blockSheetTitle">表格<\/strong><button type="button" class="icon" id="blockSheetClose" aria-label="关闭块设置">/);
assert.match(prototype, /<div class="block-scrim hidden" id="blockScrim"><\/div>/, 'the sheet has its own scrim');
assert.match(prototype, /\.block-scrim\{position:fixed;z-index:6;background:var\(--scrim\)\}/);
assert.match(prototype, /\.block-sheet\{position:fixed;z-index:7;max-height:56%;overflow:auto;padding:0 0 var\(--s6\);border-radius:calc\(var\(--r\) \* 2\) calc\(var\(--r\) \* 2\) 0 0;background:var\(--paper\);box-shadow:var\(--shadow\)\}/);
assert.match(prototype, /\.block-sheet-drag\{width:var\(--s10\);height:var\(--s1\);margin:var\(--s3\) auto var\(--s2\);border-radius:var\(--pill\);background:var\(--line\)\}/);
assert.match(prototype, /\.block-sheet-head strong\{font-size:var\(--large\);font-weight:500\}/);
assert.match(prototype, /\.block-sheet \.hs-row \.seg\{flex:none;margin:0\}/, 'the segmented control sits inside the row');
assert.ok(!sheet.includes('hs-group-title'), 'the sheet groups by spacing, not by captions');
assert.match(prototype, /event\.target===\$\('blockScrim'\)\)\{closeBlockUi\(\);return;\}/, 'tapping the scrim dismisses the sheet');

// 属性面板：标题行 + 设置行 + 方向分段 + 源码兜底，且可滚动
assert.match(sheet, /class="settings-toggle-row"[\s\S]{0,200}首行为表头/);
assert.match(sheet, /aria-label="插入列的方向"[\s\S]{0,200}data-block-side="left"[\s\S]{0,120}data-block-side="right"/);
assert.match(sheet, /aria-label="插入行的方向"[\s\S]{0,200}data-block-side="up"[\s\S]{0,120}data-block-side="down"/);
assert.match(sheet, /id="blockSourceEdit"[\s\S]{0,200}以源码编辑此块/);
assert.match(sheet, /class="block-sheet-note">原型示意：只演示交互，不写入笔记内容。切换方向会同步到浮条按钮。/);

// Aa 浮层保持纯净：结构不变，且不含任何块操作
const menuStart = prototype.indexOf('<div class="simple-format-menu">');
const menuEnd = prototype.indexOf('</div>', prototype.indexOf('id="simpleRedo"', menuStart));
const menu = prototype.slice(menuStart, menuEnd);
assert.ok(!menu.includes('data-block-op'), 'the Aa menu must not carry block operations');
assert.ok(!prototype.includes('当前块：'), 'the rejected Aa context section must not exist');
assert.match(menu, /data-simple-format="paragraph"/, 'the Aa menu keeps its text and paragraph entries');

// 键盘 / 读屏不依赖浮条：表格可聚焦并以 Enter 打开块 UI
assert.match(prototype, /table\.setAttribute\('tabindex','0'\)/);
assert.match(prototype, /table\.addEventListener\('keydown'[\s\S]{0,160}openBlockUi\(table/);
assert.match(prototype, /for\(const id of \['simpleAa','simpleAaRight'\]\)\$\(id\)\.addEventListener\('toggle'[\s\S]{0,80}closeBlockUi\(\)/,
  'the Aa menu and the block bar must be mutually exclusive');

// 块选中态与表格提示文案
assert.match(prototype, /\.simple-block-active\{box-shadow:0 0 0 var\(--stroke\) var\(--blue\)/);
assert.match(prototype, /\.simple-block-active::after\{content:none\}/, 'the protected hint yields to the block entry');
assert.match(prototype, /\.simple-protected\[data-block-type=table\]::after\{content:'表格编辑将在后续版本开放'\}/);
assert.match(prototype, /\.simple-protected::after\{content:'此内容请在专业模式编辑'/,
  'the default hint still covers the blocks that are not scheduled');

// 新增样式只使用已定义的 v2 token
for (const id of ['blockBar', 'blockSheet', 'blockSheetTitle', 'blockSheetClose', 'blockHeaderRow', 'blockSourceEdit']) {
  assert.ok(prototype.includes(`id="${id}"`), `the block entry script references #${id}, which must exist in the prototype`);
}
const rootStart = prototype.indexOf(':root{'), rootEnd = prototype.indexOf('}', rootStart);
const darkStart = prototype.indexOf('[data-theme="dark"]{'), darkEnd = prototype.indexOf('}', darkStart);
const defined = new Set([...prototype.slice(rootStart, rootEnd).matchAll(/--[a-z0-9-]+/g), ...prototype.slice(darkStart, darkEnd).matchAll(/--[a-z0-9-]+/g)].map(match => match[0]));
const cssStart = prototype.indexOf('/* 2026-11-02 complex block entry'), cssEnd = prototype.indexOf('.block-sheet-note{', cssStart);
const added = prototype.slice(cssStart, cssEnd);
assert.ok(cssStart >= 0 && cssEnd > cssStart, 'the entry styles must live in one marked block');
const used = [...added.matchAll(/var\((--[a-z0-9-]+)\)/g)].map(match => match[1]);
assert.ok(used.length > 0, 'the entry styles must reuse the v2 tokens');
for (const token of used) assert.ok(defined.has(token), `the entry styles must not introduce ${token}`);
