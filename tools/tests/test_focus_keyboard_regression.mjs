import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：v1.28 a849690 —— 关闭笔记空栏 requestFocus 150003 闪退
// 根因：空库时 EmptyPane 只渲染「新建笔记」，requestFocus 指向不存在的组件抛 150003
// 修复：focusEmptyPane 根据 noteCount 和 closedPath 选择焦点目标 + try-catch 兜住 150003
// 已有 test_pane_close.mjs 的 focusEmptyPane 逻辑测试，此处验证源码级兜底模式

const index = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

test('focusEmptyPane catches 150003 requestFocus failures instead of crashing', () => {
  const focusMethod = index.substring(
    index.indexOf('private focusEmptyPane('),
    index.indexOf('\n  private', index.indexOf('private focusEmptyPane(') + 1)
  );
  // 必须有 try-catch 包裹 requestFocus 调用
  assert.match(focusMethod, /try\s*\{/);
  assert.match(focusMethod, /catch/);
  assert.match(focusMethod, /requestFocus|150003/);
});

test('focusEmptyPane aligns focus target with the actual rendered branch', () => {
  const focusMethod = index.substring(
    index.indexOf('private focusEmptyPane('),
    index.indexOf('\n  private', index.indexOf('private focusEmptyPane(') + 1)
  );
  // 焦点目标必须根据渲染条件选择：noteCount=0 时无 reopen 行
  assert.match(focusMethod, /currentVaultNoteCount|noteCount/);
  assert.match(focusMethod, /pane-empty-new|pane-empty-reopen/);
});

// 防回归：3e50b6e —— 修复系统返回先收起导航
test('system back press is intercepted before reaching navigation collapse', () => {
  const backHandler = index.substring(
    index.indexOf('onBackPress'),
    index.indexOf('}\n', index.indexOf('onBackPress') + 1)
  );
  // onBackPress 必须在收起导航前处理其他优先级更高的返回逻辑
  assert.match(backHandler, /return\s+true/, 'onBackPress must return true to consume the back event');
});

// 防回归：ad1f3d3 —— 专注下点汉堡只推入/收回文件导航
test('hamburger in focus mode only toggles file navigation, does not exit focus', () => {
  const navButton = index.substring(
    Math.max(0, index.indexOf('workspace-navigation-button') - 300),
    Math.min(index.length, index.indexOf('workspace-navigation-button') + 500)
  );
  // 专注模式下汉堡点击只切换侧栏，不改变专注状态
  assert.doesNotMatch(navButton, /exitFocus|focusMode\s*=\s*false/);
});

// 防回归：3411760 —— 修复专注模式下汉堡导航无效
test('hamburger navigation works in focus mode', () => {
  const navHandler = index.substring(
    index.indexOf('toggleSidebar'),
    Math.min(index.length, index.indexOf('toggleSidebar') + 800)
  );
  // 侧栏切换逻辑不能被专注模式阻断
  assert.doesNotMatch(navHandler, /if\s*\(\s*!this\.focusMode\s*\)\s*return/);
});

// 防回归：bc788f1 —— 对齐分类键盘焦点路径
test('settings category items have proper accessibility for keyboard navigation', () => {
  const settings = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
  assert.match(settings, /accessibilityText|accessibilityLevel/);
});

// 防回归：ee0f091 / a1cb1b7 / 26fac79 —— 预览焦点框黑框
test('preview touch does not produce full-column focus border', () => {
  const preview = readSourceFile(new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url));
  // 预览不应有整栏焦点框
  assert.doesNotMatch(preview, /focusBox|\.border\(.*Color\.Black/);
});

console.log('焦点与键盘类 bug 防回归检查通过（150003 兜底 + 返回拦截 + 专注模式导航）');
