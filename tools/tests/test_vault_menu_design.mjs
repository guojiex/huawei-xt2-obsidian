import assert from 'node:assert/strict';
import fs from 'node:fs';

const sidebar = fs.readFileSync(new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url), 'utf8');
const icons = fs.readFileSync(new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url), 'utf8');
const tokens = fs.readFileSync(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url), 'utf8');
const prototype = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

const start = sidebar.indexOf('  VaultMenu() {');
const end = sidebar.indexOf('\n  private vaultTypeLabel', start);
assert.ok(start >= 0 && end > start, 'could not find VaultSidebar.VaultMenu');
const menu = sidebar.slice(start, end);

assert.ok(!menu.includes('分享知识库'), 'vault switching menu must not contain a share action');
assert.ok(!sidebar.includes('onShareVault'), 'vault switching component must not expose the removed share callback');

// 设计真源：原型 .vault-menu 的容器、标签、选项与动作区样式
assert.match(prototype, /\.vault-menu\{[^}]*max-height:var\(--window-min\);overflow:auto/,
  'prototype .vault-menu must cap its height and scroll');
assert.match(prototype, /\.vault-menu-label\{padding:var\(--s2\);color:var\(--muted\);font-size:var\(--caption\)\}/);
assert.match(prototype, /\.vault-menu-actions\{border-top:var\(--stroke\) solid var\(--line\);margin-top:var\(--s2\);padding-top:var\(--s2\)\}/);
assert.match(prototype, /\.vault-menu-actions button\{width:100%;text-align:left;color:var\(--blue\)\}/);
assert.match(prototype, /\.vault-option\{display:flex;align-items:center;gap:var\(--s2\);width:100%;text-align:left;padding:var\(--s2\);min-width:0\}/);
assert.match(prototype, /\.vault-option\[aria-current=true\]\{background:var\(--blue-soft\);color:var\(--blue\)\}/);

// 原生实现逐条对齐
assert.match(menu, /Text\('切换知识库'\)[\s\S]{0,200}FontSize\.caption/, 'menu must open with the caption label');
assert.match(menu, /Icon\('folder', 18,/, 'each vault option must show the folder glyph');
assert.match(menu, /Icon\('check', 18,/, 'the current vault must show the trailing check glyph');
assert.match(menu, /\.padding\(Space\.s2\)/, 'rows must use the --s2 padding of .vault-option');
assert.match(menu, /FontSize\.body2/, 'rows must inherit the --small body size of the prototype');
assert.match(menu, /app\.color\.brand_bg/, 'the current vault keeps the blue-soft row background');
assert.match(menu, /Divider\(\)[\s\S]{0,120}margin\(\{ top: Space\.s2 \}\)/,
  'the actions divider spans the full width with only an --s2 top gap');
const blueText = (menu.match(/fontColor\(\$r\('app\.color\.brand'\)\)/g) ?? []).length;
// v1.58 58.1 撤销 v1.52 52.3：动作区恢复两行——管理库… / ＋ 导入库…，统计入口移到侧栏连写条。
assert.equal(blueText, 2,
  `the two action rows must use the blue text of .vault-menu-actions button (found ${blueText})`);
assert.ok(!menu.includes('统计与成就'), 'the vault menu must not contain the stats action');
assert.match(menu, /\? \$r\('app\.color\.brand'\) : \$r\('app\.color\.text_primary'\)/,
  'the selected vault row keeps the blue text of .vault-option[aria-current=true]');
assert.match(menu, /Scroll\(\)/, 'a long vault list must scroll instead of overflowing');
assert.match(menu, /constraintSize\(\{ maxHeight: Size\.menuMaxH - Space\.s2 \* 2 \}\)/);
assert.ok(!menu.includes('VaultBadge'), 'the prototype vault menu has no per-row type badge');

// 配套 token 与图标
assert.match(icons, /const P_CHECK: string = 'M5 12L9 16L19 6'/);
assert.match(icons, /\} else if \(name === 'check'\) \{\r?\n    return P_CHECK;/);
assert.match(tokens, /static readonly menuMaxH: number = 620;/);

console.log('vault-menu 与 v2 原型样式对齐检查通过（源码级，不代表设备目视验收）');
