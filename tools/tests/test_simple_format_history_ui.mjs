import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const index = fs.readFileSync(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
// Aa 面板（FormatMenu / FormatHistoryButton）视图已从 Index 拆到 FormatDockPanel（Phase 3 重构），
// 面板本体的断言改读子组件；formatMenuMaxHeight 表达式与路由方法仍在 Index。
const dock = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/FormatDockPanel.ets', import.meta.url), 'utf8');
const previewBridge = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url), 'utf8');
const previewSource = fs.readFileSync(
  new URL('../../web/mdpreview/src/index.ts', import.meta.url), 'utf8');
const previewBundle = fs.readFileSync(
  new URL('../../entry/src/main/resources/rawfile/mdpreview/index.html', import.meta.url), 'utf8');
const icons = fs.readFileSync(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url), 'utf8');

test('Aa menu places undo and redo in a separated two-button footer', () => {
  const formatMenu = dock.slice(dock.indexOf('  FormatMenu() {'), dock.indexOf('\n  @Builder', dock.indexOf('  FormatMenu() {')));
  assert.match(formatMenu, /this\.FormatHistoryButton\('undo', '撤销'\)/);
  assert.match(formatMenu, /this\.FormatHistoryButton\('redo', '重做'\)/);
  assert.match(formatMenu, /Row\(\{ space: Space\.s2 \}\) \{[\s\S]*?FormatHistoryButton\('undo'[\s\S]*?FormatHistoryButton\('redo'[\s\S]*?\.border\(\{ width: \{ top: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  assert.match(dock, /FormatHistoryButton\(action: PreviewEditHistoryAction, label: string\)/);
  assert.match(dock, /Icon\(action, Space\.s4, \$r\('app\.color\.text_secondary'\)\)/);
  assert.match(dock, /\.accessibilityText\(label\)/);
  assert.equal((index.match(/Size\.touch \* 6 \+ Space\.s2 \* 6 \+ Size\.touch \+ Space\.s6 \* 2 \+ Size\.touch \+ Space\.s2/g) ?? []).length, 3);
});

test('history buttons route to the selected editable preview and preserve target guards', () => {
  assert.match(index, /private applyFormatHistoryAction\(action: PreviewEditHistoryAction\): void/);
  assert.match(index, /this\.currentVaultId !== this\.formatMenuSourceVaultId/);
  assert.match(index, /this\.paneFilePath\(pane\) !== this\.formatMenuSourcePath/);
  assert.match(index, /this\.previewBridgeForPane\(pane\)\.editHistory\(action\)/);
  assert.match(previewBridge, /export type PreviewEditHistoryAction = 'undo' \| 'redo'/);
  assert.match(previewBridge, /editHistory\(action: PreviewEditHistoryAction\): void/);
});

test('editable preview applies history to the selected block and synchronizes changed source', () => {
  assert.match(previewSource, /editHistory\(action: 'undo' \| 'redo'\): void/);
  assert.match(previewSource, /if \(!editable \|\| editableComposing\) return[\s\S]*?document\.execCommand\(action\)/);
  assert.match(previewSource, /if \(sourceText === previousSource\) replaceSourceBlock\(block\)/);
  assert.match(previewBundle, /editHistory\([^)]*\)\{/);
  assert.match(previewBundle, /document\.execCommand\(/);
  assert.match(icons, /P_UNDO:[\s\S]*P_REDO:/);
  assert.match(icons, /name === 'undo'[\s\S]*return P_UNDO/);
  assert.match(icons, /name === 'redo'[\s\S]*return P_REDO/);
});
