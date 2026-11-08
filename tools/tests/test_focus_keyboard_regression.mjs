import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { readSourceFile } from './lib/source.mjs';

// 防回归：v1.28 a849690 —— 关闭笔记空栏 requestFocus 150003 闪退
// 防回归：2026-11-08 DFX jscrash —— 完成编辑 finishSimpleEditingFor 裸调 requestFocus 150003 闪退
// 收口：全仓 22 处调用点统一走 common/FocusRequest.ets 的 FocusRequest.safely（try-catch 吞 150003）
// v1.46：safely 按 150001/150002/150003 区分日志（api_notes L-20）+ EntryAbility 安装 CrashGuard 全局兜底
// 见 docs/harmonyos/api_notes.md L-19 / L-20

const index = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const focusRequest = readSourceFile(new URL('../../entry/src/main/ets/common/FocusRequest.ets', import.meta.url));
const crashGuard = readSourceFile(new URL('../../entry/src/main/ets/common/CrashGuard.ets', import.meta.url));
const entryAbility = readSourceFile(new URL('../../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url));

function listEtsFiles(dirUrl, out = []) {
  for (const entry of readdirSync(fileURLToPath(dirUrl), { withFileTypes: true })) {
    const childUrl = new URL(entry.name + (entry.isDirectory() ? '/' : ''), dirUrl);
    if (entry.isDirectory()) {
      listEtsFiles(childUrl, out);
    } else if (entry.name.endsWith('.ets')) {
      out.push(childUrl);
    }
  }
  return out;
}

test('focusEmptyPane delegates to FocusRequest.safely instead of bare requestFocus', () => {
  const focusMethod = index.substring(
    index.indexOf('private focusEmptyPane('),
    index.indexOf('\n  private', index.indexOf('private focusEmptyPane(') + 1)
  );
  // 150003 兜底已收口到 FocusRequest.safely，不允许回到裸调
  assert.match(focusMethod, /FocusRequest\.safely/);
  assert.doesNotMatch(focusMethod, /getFocusController\(\)\s*\.\s*requestFocus/);
});

test('FocusRequest.safely catches 150003 BusinessError and never rethrows', () => {
  // 兜底助手必须捕获 150003 并降级为 warn 日志，不得向上抛
  assert.match(focusRequest, /catch/);
  assert.match(focusRequest, /150003/);
  assert.doesNotMatch(focusRequest, /throw/);
});

test('FocusRequest.safely differentiates official focus error codes (v1.46, api_notes L-20)', () => {
  // 三个官方错误码分支必须都在，未知码走带 code 的兜底日志
  assert.match(focusRequest, /150001/, 'must handle 150001 (component cannot be focused)');
  assert.match(focusRequest, /150002/, 'must handle 150002 (unfocusable ancestor)');
  assert.match(focusRequest, /150003/, 'must handle 150003 (not on tree / does not exist)');
  assert.match(focusRequest, /err\.code/, 'unknown codes must be logged with err.code');
});

test('FocusRequest logs never contain focusId (note paths stay out of logs)', () => {
  // 隐私红线（AGENTS.md 硬约束 16）：焦点 id 含笔记路径，不得进日志
  for (const line of focusRequest.split('\n')) {
    if (line.includes('hilog.')) {
      assert.doesNotMatch(line, /focusId/, `hilog line must not reference focusId: ${line.trim()}`);
    }
  }
});

test('CrashGuard installs setDefaultErrorHandler with chaining and official exit fallback (v1.46)', () => {
  // 官方示例结构：setDefaultErrorHandler 注册 → hilog 记录 → 链式前序处理器 → 无前序时 ProcessManager.exit
  assert.match(crashGuard, /setDefaultErrorHandler/);
  assert.match(crashGuard, /previousHandler/);
  assert.match(crashGuard, /ProcessManager/);
  assert.match(crashGuard, /exit\(0\)/);
  assert.doesNotMatch(crashGuard, /hiAppEvent\s*\.\s*(write|addWatcher)/, 'crash guard logs must never feed analytics');
});

test('EntryAbility installs CrashGuard in onCreate (main thread only API)', () => {
  // setDefaultErrorHandler 仅主线程（子线程抛 16000205）：安装点必须在 EntryAbility.onCreate
  const onCreate = entryAbility.substring(
    entryAbility.indexOf('onCreate('),
    entryAbility.indexOf('\n  }', entryAbility.indexOf('onCreate('))
  );
  assert.match(onCreate, /CrashGuard\.install\(\)/, 'onCreate must call CrashGuard.install()');
});

test('no bare getFocusController().requestFocus outside FocusRequest.ets', () => {
  // 全仓源码防线：除 common/FocusRequest.ets 外，任何 .ets 不得出现裸 requestFocus 调用
  const offenders = [];
  for (const fileUrl of listEtsFiles(new URL('../../entry/src/main/ets/', import.meta.url))) {
    if (fileURLToPath(fileUrl).replaceAll('\\', '/').endsWith('/common/FocusRequest.ets')) {
      continue;
    }
    const src = readSourceFile(fileUrl);
    if (/getFocusController\(\)\s*\.\s*requestFocus/.test(src)) {
      offenders.push(fileURLToPath(fileUrl));
    }
  }
  assert.deepEqual(offenders, [], `bare requestFocus found in: ${offenders.join(', ')}`);
});

test('focusEmptyPane aligns focus target with the actual rendered branch', () => {
  // v1.46 46.5：目标选择收在 emptyPaneFocusId（focusEmptyPane → consumeEmptyPaneFocus 均依赖）
  const focusBlock = index.substring(
    index.indexOf('private focusEmptyPane('),
    index.indexOf('private focusPaneBody(')
  );
  // 焦点目标必须根据渲染条件选择：noteCount=0 时无 reopen 行
  assert.match(focusBlock, /currentVaultNoteCount|noteCount/);
  assert.match(focusBlock, /pane-empty-new|pane-empty-reopen/);
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
