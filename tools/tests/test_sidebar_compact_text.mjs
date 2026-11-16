import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const vaultSidebar = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url), 'utf8');
const fileTree = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url), 'utf8');
const prototype = fs.readFileSync(
  new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

test('file tab count shows only the compact note count; vault switcher reads it aloud', () => {
  // v1.67 精简信息层级：数量只在当前库标题下出现一次，悬停弹层（NoteCountHint）已随
  // 「文件目录 · N 篇笔记」提示一并移除；读屏完整文案落在库切换触发器上。
  assert.match(vaultSidebar, /Text\(this\.noteCount\.toString\(\) \+ ' 篇笔记'\)/);
  assert.match(vaultSidebar, /Text\(this\.noteCount\.toString\(\) \+ ' 篇笔记'\)[\s\S]*?\.maxLines\(1\)/);
  assert.doesNotMatch(vaultSidebar, /noteCountHintOpen|NoteCountHint/);
  assert.match(vaultSidebar,
    /\.accessibilityText\('切换知识库，当前 ' \+[\s\S]*?'，' \+ this\.noteCount\.toString\(\) \+ ' 篇笔记'\)/);
});

test('tree help shows one compact line with the complete hover and screen-reader hint', () => {
  assert.match(fileTree, /Text\('左滑操作 · 拖动移动或打开'\)/);
  assert.match(fileTree, /Text\('左滑操作 · 拖动移动或打开'\)[\s\S]*?\.maxLines\(1\)[\s\S]*?\.textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/);
  assert.match(fileTree, /\.onHover\(\(isHover: boolean\): void => \{\s*this\.helpHintOpen = isHover;/);
  assert.match(fileTree, /\.accessibilityText\('左滑文件可操作；长按拖动笔记或文件夹移动，拖笔记到任一栏打开'\)/);
  assert.match(fileTree, /\.bindPopup\(this\.helpHintOpen,[\s\S]*?builder: this\.HelpHint\(\)/);
  assert.match(fileTree, /HelpHint\(\) \{[\s\S]*Text\('左滑文件可操作；长按拖动笔记或文件夹移动，拖笔记到任一栏打开'\)/);
  assert.match(prototype, /<div class="tree-help" title="左滑文件可操作；长按拖动笔记或文件夹移动，拖笔记到任一栏打开">左滑操作 · 拖动移动或打开<\/div>/);
});

test('sidebar toolbar centers tab labels and sizes nav icons per the v2 prototype', () => {
  // 文件 / 章节 tab：标签在 48vp（--touch）行内垂直居中，20x2 指示条钉在行底（v2 .sidebar-tabs button + ::after）。
  for (const label of ['文件', '章节']) {
    assert.match(vaultSidebar, new RegExp(
      `Text\\('${label}'\\)[\\s\\S]*?\\.maxLines\\(1\\)\\s*\\}\\s*\\.layoutWeight\\(1\\)\\s*\\.justifyContent\\(FlexAlign\\.Center\\)`));
  }
  assert.doesNotMatch(vaultSidebar, /justifyContent\(FlexAlign\.End\)/);
  assert.match(vaultSidebar, /\.width\(Space\.s5\)\s*\.height\(Space\.s1 \/ 2\)\s*\.borderRadius\(Radius\.full\)/);
  // 排序 / 新建按钮：与 .nav-icon svg 的 --tree-icon(18) 同档同色（--muted → text_secondary），不再一个 16 一个 18。
  assert.match(vaultSidebar, /Icon\('sort', Size\.treeIcon, \$r\('app\.color\.text_secondary'\)\)/);
  assert.match(vaultSidebar, /Icon\('plus', Size\.treeIcon, \$r\('app\.color\.text_secondary'\)\)/);
  assert.doesNotMatch(vaultSidebar, /Icon\('plus', 16,/);
  // 设计真源：.nav-icon svg 尺寸取 --tree-icon；tab 指示条 20x2 钉底居中。
  assert.match(prototype, /\.nav-icon svg\{width:var\(--tree-icon\);height:var\(--tree-icon\)/);
  assert.match(prototype, /\.sidebar-tabs button::after\{[^}]*bottom:calc\(-1 \* var\(--stroke\)\);left:50%;width:var\(--s5\);height:var\(--focus\)/);
});
