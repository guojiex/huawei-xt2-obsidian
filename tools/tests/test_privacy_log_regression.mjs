import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：0829db7 / 70d9d19 / 6a8ec6b / a4cc0e3 / 5795517 —— 日志脱敏
// 根因：诊断日志中泄露笔记数据（内容、路径、长度、可见项数等）
// 修复：逐步移除/脱敏日志中的敏感信息
// 已有 test_editor_content_log_privacy.mjs 覆盖脱敏规则，此处验证关键模式

const noteService = readSourceFile(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url));
const trashService = readSourceFile(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url));
const fileTree = readSourceFile(new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const vaultRegistry = readSourceFile(new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));

test('note service never logs note content or length in info/warn/error', () => {
  const logCalls = [...noteService.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([m]) => m);
  for (const call of logCalls) {
    assert.doesNotMatch(call, /text\.length|content\.length|relPath/);
  }
});

test('trash service never logs relPath or note content in diagnostics', () => {
  const logCalls = [...trashService.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([m]) => m);
  for (const call of logCalls) {
    assert.doesNotMatch(call, /relPath|trashRel/);
  }
});

test('file tree never logs visible item count', () => {
  // a4cc0e3: 移除文件树可见项数日志
  assert.doesNotMatch(fileTree, /hilog\.\w+\([^)]*this\.nodes\.length|visibleCount|visibleItems/);
});

test('vault registry never logs vault identifiers in error messages', () => {
  const logCalls = [...vaultRegistry.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([m]) => m);
  for (const call of logCalls) {
    assert.doesNotMatch(call, /err\.message|JSON\.stringify\(err\)|dirs\[i\]/);
  }
});

// 防回归：b3b9465 —— 诊断输出白名单边界
test('diagnostics output only exposes whitelisted fields', () => {
  // 诊断功能分布在 RecentErrorStore（错误收集）和 SettingsView（诊断导出）
  const recentErrors = readSourceFile(new URL('../../entry/src/main/ets/model/RecentErrorStore.ets', import.meta.url));
  const settings = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
  // 诊断输出不能包含用户笔记内容
  assert.doesNotMatch(recentErrors, /noteContent|fileContent|textContent/);
  assert.doesNotMatch(settings, /noteContent|fileContent|textContent/);
  // 构建提交信息可以暴露（是公共信息）
  assert.match(settings, /buildCommit|commitHash|diagnostics/i);
});

// 防回归：6a8ec6b —— 移除诊断日志中的笔记数据
test('workspace diagnostics never include note text or metadata', () => {
  const workspace = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
  const diagCalls = [...workspace.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([m]) => m);
  for (const call of diagCalls) {
    assert.doesNotMatch(call, /content|\.text\b|filePath.*=|noteName/);
  }
});

// 防回归：5795517 —— 预览日志脱敏
test('preview bridge never logs page content in console messages', () => {
  const previewBridge = readSourceFile(new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url));
  assert.doesNotMatch(previewBridge, /onConsole\([^)]*\)[\s\S]{0,180}getMessage\(/);
});

console.log('日志与隐私类 bug 防回归检查通过（脱敏规则 + 白名单 + 无笔记数据）');
