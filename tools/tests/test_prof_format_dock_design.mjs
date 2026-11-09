import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.2：专业模式格式栏停靠 —— 与 v1.30 简单模式一致；仅编辑状态显示，预览隐藏。
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const dockStart = index.indexOf('  ProfFormatDock(pane: string) {');
const dockEnd = index.indexOf('\n  @Builder\n', dockStart + 1);
assert.ok(dockStart >= 0 && dockEnd > dockStart, 'could not find Index.ProfFormatDock');
const dock = index.slice(dockStart, dockEnd);

test('professional format bar docks as a full row like v1.30 simple mode', () => {
  // 整行停靠：通栏宽 + 顶部细线 + bg_card 底；无阴影、无圆角（不再浮动盖源码）
  assert.match(dock, /\.width\('100%'\)/);
  assert.match(dock, /\.border\(\{ width: \{ top: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  assert.match(dock, /\.backgroundColor\(\$r\('app\.color\.bg_card'\)\)/);
  assert.doesNotMatch(dock, /\.shadow\(/);
  assert.doesNotMatch(dock, /\.borderRadius\(/);
  // 高度 = touch + 上下 s1；v1.46 46.6/46.8：dock 不再叠 keyboardInsetVp margin——
  // 键盘避让收敛到 UIContext 级 OFFSET_WITH_CARET，dock 保留 margin 会双重上抬（XT2 真机实测）
  assert.match(dock, /\.height\(Size\.touch \+ Space\.s1 \* 2\)/);
  assert.doesNotMatch(dock, /keyboardInsetVp/);
  // 按钮集合与简单模式共用（Aa 面板 / 插入图片照常可用）
  assert.match(dock, /this\.FormatActionsRow\(pane, Space\.s1\)/);
  // 无「完成编辑」按钮 —— 专业模式走 PaneHead 编辑 / 预览切换
  assert.doesNotMatch(dock, /SimpleDoneAction/);
});

test('wide screen aligns left, single screen centers (prototype edit-tools rule)', () => {
  assert.match(dock,
    /\.justifyContent\(this\.isSingleScreenLayout\(\) \? FlexAlign\.Center : FlexAlign\.Start\)/);
  assert.match(dock,
    /left: this\.isSingleScreenLayout\(\) \? Space\.s3 : Space\.s5,/);
  // 原型 .window:not(.simple-mode) 停靠规则：宽屏 flex-start + 左内边距 s5；phone 居中 + s3
  assert.match(prototype,
    /window:not\(\.simple-mode\)[^{]*>\.edit-tools:not\(\.hidden\)\{[^}]*justify-content:flex-start/);
  assert.match(prototype,
    /window\.phone:not\(\.simple-mode\)[^{]*>\.edit-tools:not\(\.hidden\)\{[^}]*justify-content:center;padding-left:var\(--s3\)/);
  // 顶部细线 + 无阴影 + paper 底
  assert.match(prototype,
    /window:not\(\.simple-mode\)[^{]*>\.edit-tools:not\(\.hidden\)\{[^}]*border-width:var\(--stroke\) 0 0[^}]*box-shadow:none[^}]*background:var\(--paper\)/);
});

test('dock only shows while source editing; floating toolbar is gone', () => {
  // 右栏：仅专业模式 + 源码编辑（rightEditing）+ 有笔记；预览时隐藏
  const rightPaneStart = index.indexOf('  RightWorkspacePane() {');
  const rightPaneEnd = index.indexOf('\n  @Builder\n', rightPaneStart + 1);
  const rightPane = index.slice(rightPaneStart, rightPaneEnd);
  assert.match(rightPane,
    /if \(this\.experienceMode === 'professional' && this\.rightEditing &&[\s\S]*?this\.rightFilePath\.length > 0\) \{\s*\n\s*this\.ProfFormatDock\('right'\)/);
  // 左栏：仅专业模式 + smMode 'edit' + 有笔记
  const editorPaneStart = index.indexOf('  EditorPane(showHingeWarning: boolean) {');
  const editorPaneEnd = index.indexOf('\n  @Builder\n', editorPaneStart + 1);
  const editorPane = index.slice(editorPaneStart, editorPaneEnd);
  assert.match(editorPane,
    /if \(this\.experienceMode === 'professional' && this\.smMode === 'edit' &&[\s\S]*?this\.currentFilePath\.length > 0\) \{\s*\n\s*this\.ProfFormatDock\('left'\)/);
  // 停靠栏在内容 Stack（layoutWeight 收缩）之后，源码末行不被遮挡
  assert.match(editorPane,
    /\.layoutWeight\(1\)[\s\S]*?this\.ProfFormatDock\('left'\)/);
  assert.match(rightPane,
    /\.layoutWeight\(1\)[\s\S]*?this\.ProfFormatDock\('right'\)/);
  // v1.7 浮动格式条已删除（无引用、无 Blank 胶囊浮层）
  assert.doesNotMatch(index, /FormatToolbar/);
  assert.match(rightPane, /this\.SimpleFormatDock\('right'\)/);
});
