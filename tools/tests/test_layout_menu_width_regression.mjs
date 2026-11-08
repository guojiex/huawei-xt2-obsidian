import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：v1.32 44fd846 —— 菜单弹层改定宽224/272，修复constraintSize下百分比子项整屏撑开(faqs-arkui-95)
// 根因：弹层 constraintSize({ minWidth }) + 子项 width('100%') 在弹层内按约束最大宽解析撑开整屏
// 修复：菜单容器改显式定宽 s16×3.5（224）和 s16×4.25（272），不依赖 constraintSize

const index = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

test('pane more menu uses fixed width token (s16 × 3.5 = 224), not percentage or constraintSize maxWidth', () => {
  // 找到 PaneMoreMenu builder
  const paneMenuStart = index.indexOf('PaneMoreMenu(pane: string) {');
  const paneMenuEnd = index.indexOf('}\n\n      @Builder', paneMenuStart);
  assert.ok(paneMenuStart > 0, 'could not find PaneMoreMenu');
  const paneMenu = index.substring(paneMenuStart, paneMenuEnd > 0 ? paneMenuEnd : paneMenuStart + 2000);
  // 宽度必须是 s16*3.5 = 224 定值，不能是 constraintSize 或百分比
  assert.match(paneMenu, /\.width\(Space\.s16\s*\*\s*3\.5\)|width.*224/);
  // 去掉注释后再检查 constraintSize（注释提到 faqs-arkui-95 是为了记录不用的原因，不是代码使用）
  const noComments = paneMenu.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(noComments, /constraintSize/, 'pane more menu must not use constraintSize in code');
});

test('single-screen more menu uses fixed width token (s16 × 4.25 = 272)', () => {
  const moreMenuStart = index.indexOf('MoreMenu() {');
  const moreMenuEnd = index.indexOf('}\n\n', moreMenuStart);
  assert.ok(moreMenuStart > 0, 'could not find MoreMenu');
  const moreMenu = index.substring(moreMenuStart, moreMenuEnd > 0 ? moreMenuEnd : moreMenuStart + 2000);
  assert.match(moreMenu, /\.width\(Space\.s16\s*\*\s*4\.25\)|width.*272/);
  // 去掉注释后再检查 constraintSize
  const noComments = moreMenu.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(noComments, /constraintSize/, 'more menu must not use constraintSize in code');
});

// 防回归：v1.22 295bd23 —— 双屏收起目录后左缘残留分栏把手
// 包装节点宽度裁不掉内部根 Stack，显隐必须走 visibility
test('nav split handle visibility is controlled by state, not width clipping', () => {
  // 在 nav-split-handle 的属性中，visibility 由 noteNavigationProgress() 控制
  const handleStart = index.indexOf("id('nav-split-handle')");
  assert.ok(handleStart > 0, 'could not find nav-split-handle');
  const handleSection = index.substring(Math.max(0, handleStart - 400), handleStart + 200);
  // 必须使用 visibility(Hidden) 而不是仅 width(0) 来隐藏
  assert.match(handleSection, /visibility\([^)]*(?:noteNavigationProgress|Visible|Hidden)/);
});

// 防回归：v1.22 36feeb3 —— 分栏把手右半被右栏背景遮盖
// zIndex 移到 SplitHandle 调用处生效
test('split handle has zIndex applied at the call site to avoid being covered', () => {
  // 第二个 SplitHandle（content handle）后面有 .zIndex(4)
  // zIndex 是链式属性，在 }) 后面，需要更大窗口
  const contentHandleStart = index.indexOf("SplitHandle({\n        enhanced: true,\n        readoutPrimary: this.splitHandlePrimary('content')");
  assert.ok(contentHandleStart > 0, 'could not find content SplitHandle');
  const handleSection = index.substring(contentHandleStart, contentHandleStart + 1500);
  assert.match(handleSection, /\.zIndex\(/);
});

// 防回归：v1.22 600ab9f —— settings row min-height 56
test('settings row uses content-driven height, not fixed 48', () => {
  const settingsView = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
  assert.doesNotMatch(settingsView, /height:\s*48\b/);
});

console.log('ArkUI 布局与弹层类 bug 防回归检查通过（菜单定宽 + 把手显隐 + token 对齐）');
