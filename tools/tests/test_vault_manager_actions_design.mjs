import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.10：库管理页底部两键等宽并排——「＋ 新建笔记库」主按钮（brand 底），
// 「＋ 导入库」次按钮（--nav 底、--ink 字），pill 圆角、weight 500（原型 .vault-manager-actions）。
const manager = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultManagerView.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const actionsStart = manager.indexOf("Row({ space: Space.s3 }) {\n            Text('＋ 新建笔记库')");
assert.ok(actionsStart >= 0, 'could not find vault-manager actions Row');
const actionsEnd = manager.indexOf('.width(\'100%\')', manager.indexOf('.onClick(() => { this.onImportVault(); })'));
const actions = manager.slice(actionsStart, actionsEnd);
assert.ok(actionsEnd > actionsStart, 'could not bound vault-manager actions block');

test('two equal-width buttons sit side by side in one row (32.10)', () => {
  // 等宽并排：同一 Row、gap --s3、两键各 layoutWeight(1)
  assert.match(actions, /Row\(\{ space: Space\.s3 \}\)/);
  assert.equal((actions.match(/\.layoutWeight\(1\)/g) ?? []).length, 2,
    '新建与导入两键均分宽度');
  // 文案与原型一致（全角＋）
  assert.match(actions, /Text\('＋ 新建笔记库'\)/);
  assert.match(actions, /Text\('＋ 导入库'\)/);
  // 公共规格：--touch 高、pill 圆角、weight 500、body 字号
  assert.equal((actions.match(/\.height\(Size\.itemH\)/g) ?? []).length, 2);
  assert.equal((actions.match(/\.borderRadius\(Radius\.full\)/g) ?? []).length, 2);
  assert.equal((actions.match(/\.fontWeight\(FontWeight\.Medium\)/g) ?? []).length, 2);
  assert.equal((actions.match(/\.fontSize\(FontSize\.body1\)/g) ?? []).length, 2);
  // 旧虚线幽灵行样式不再出现在操作区
  assert.ok(!actions.includes('BorderStyle.Dashed'), '操作区不再用虚线描边行');
});

test('primary create button uses brand fill and the secondary import uses nav fill (32.10)', () => {
  // 主按钮：--blue 底（brand）+ --paper 字（on_brand）
  const createIdx = actions.indexOf("Text('＋ 新建笔记库')");
  const importIdx = actions.indexOf("Text('＋ 导入库')");
  const createBlock = actions.slice(createIdx, importIdx);
  assert.match(createBlock, /\.fontColor\(\$r\('app\.color\.on_brand'\)\)/);
  assert.match(createBlock, /\.backgroundColor\(\$r\('app\.color\.brand'\)\)/);
  // 次按钮：--nav 底（bg_navigation）+ --ink 字（text_primary）
  const importBlock = actions.slice(importIdx);
  assert.match(importBlock, /\.fontColor\(\$r\('app\.color\.text_primary'\)\)/);
  assert.match(importBlock, /\.backgroundColor\(\$r\('app\.color\.bg_navigation'\)\)/);
  // 导入键保持可聚焦 + 稳定 id（ImportVaultDialog 焦点返回依赖）
  assert.match(importBlock, /\.focusable\(true\)\s*\.id\('vault-manager-import-button'\)/);
  assert.match(manager, /\.onClick\(\(\) => \{ this\.onImportVault\(\); \}\)/);
});

test('prototype vault-manager-actions rules map onto the native row (32.10)', () => {
  // 原型：grid 1fr 1fr 等宽、gap --s3、按钮 --touch 高 + pill 圆角 + weight 500
  assert.match(prototype, /\.vault-manager-actions\{display:grid;grid-template-columns:1fr 1fr;gap:var\(--s3\)\}/);
  assert.match(prototype,
    /\.vault-manager-actions button\{min-height:var\(--touch\);padding:0 var\(--s4\);border-radius:var\(--pill\);font-weight:500\}/);
  // 主按钮 .primary：--blue 底 / --paper 字；actions 内 width:auto（由 grid 等分）
  assert.match(prototype, /\.primary\{background:var\(--blue\);color:var\(--paper\);border-radius:var\(--pill\);width:100%\}/);
  assert.match(prototype, /\.vault-manager-actions \.primary\{width:auto\}/);
  // 次按钮 .vault-secondary：--nav 底 / --ink 字
  assert.match(prototype, /\.vault-manager-actions \.vault-secondary\{background:var\(--nav\);color:var\(--ink\)\}/);
  // 原型按钮文案
  assert.match(prototype, />＋ 新建笔记库</);
  assert.match(prototype, />＋ 导入库</);
});
