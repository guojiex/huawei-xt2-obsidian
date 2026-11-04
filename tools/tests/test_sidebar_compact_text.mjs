import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const vaultSidebar = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url), 'utf8');
const fileTree = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url), 'utf8');
const prototype = fs.readFileSync(
  new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

test('file tab count shows only the compact note count and exposes its full label', () => {
  assert.match(vaultSidebar, /Text\(this\.noteCount\.toString\(\) \+ ' 篇笔记'\)/);
  assert.match(vaultSidebar, /\.maxLines\(1\)\s*\.textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/);
  assert.match(vaultSidebar, /\.onHover\(\(isHover: boolean\): void => \{\s*this\.noteCountHintOpen = isHover;/);
  assert.match(vaultSidebar, /\.accessibilityText\('文件目录 · ' \+ this\.noteCount\.toString\(\) \+ ' 篇笔记'\)/);
  assert.match(vaultSidebar, /\.bindPopup\(this\.noteCountHintOpen,[\s\S]*?builder: this\.NoteCountHint\(\)/);
  assert.match(vaultSidebar, /NoteCountHint\(\) \{[\s\S]*Text\('文件目录 · ' \+ this\.noteCount\.toString\(\) \+ ' 篇笔记'\)/);
});

test('tree help shows one compact line with the complete hover and screen-reader hint', () => {
  assert.match(fileTree, /Text\('左滑操作 · 拖图标到任一栏'\)/);
  assert.match(fileTree, /Text\('左滑操作 · 拖图标到任一栏'\)[\s\S]*?\.maxLines\(1\)[\s\S]*?\.textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/);
  assert.match(fileTree, /\.onHover\(\(isHover: boolean\): void => \{\s*this\.helpHintOpen = isHover;/);
  assert.match(fileTree, /\.accessibilityText\('左滑文件可操作；拖动行尾图标到任一栏打开'\)/);
  assert.match(fileTree, /\.bindPopup\(this\.helpHintOpen,[\s\S]*?builder: this\.HelpHint\(\)/);
  assert.match(fileTree, /HelpHint\(\) \{[\s\S]*Text\('左滑文件可操作；拖动行尾图标到任一栏打开'\)/);
  assert.match(prototype, /<div class="tree-help" title="左滑文件可操作；拖动行尾图标到任一栏打开">左滑操作 · 拖图标到任一栏<\/div>/);
});
