import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const userErrorSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/UserErrorMessages.ets', import.meta.url));
const sourceFiles = {
  index: readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url)),
  sync: readSourceFile(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url)),
  settings: readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url)),
  switcher: readSourceFile(new URL('../../entry/src/main/ets/components/QuickSwitcher.ets', import.meta.url)),
  agent: readSourceFile(new URL('../../entry/src/main/ets/components/AgentWorkspace.ets', import.meta.url)),
  editor: readSourceFile(new URL('../../entry/src/main/ets/components/EditorWebView.ets', import.meta.url)),
  preview: readSourceFile(new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url)),
  imageDialog: readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareImagePreviewDialog.ets', import.meta.url)),
  fileDialog: readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareFilePreviewDialog.ets', import.meta.url)),
  textDialog: readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareTextPreviewDialog.ets', import.meta.url)),
  agentRuntime: readSourceFile(
    new URL('../../entry/src/main/ets/model/AgentRuntime.ets', import.meta.url)),
  trash: readSourceFile(
    new URL('../../entry/src/main/ets/components/TrashView.ets', import.meta.url)),
  intent: readSourceFile(
    new URL('../../entry/src/main/ets/entryability/InsightIntentExecutorImpl.ets', import.meta.url))
};

const userErrorCode = transformSync(`
${userErrorSource.replace(/^export /gm, '')}
module.exports = { shareFailureMessage };
`, { loader: 'ts', format: 'cjs' }).code;
const userErrorModule = { exports: {} };
new Function('module', 'exports', userErrorCode)(userErrorModule, userErrorModule.exports);
const { shareFailureMessage } = userErrorModule.exports;
const feedbackStart = sourceFiles.index.indexOf('  private toastRegistryError(');
const feedbackEnd = sourceFiles.index.indexOf('\n  // ===== 1.7 回收站', feedbackStart);
assert.ok(feedbackStart >= 0 && feedbackEnd > feedbackStart, 'could not find Index.toastRegistryError');
const feedbackMethod = sourceFiles.index.slice(feedbackStart, feedbackEnd).trim();
const feedbackCode = transformSync(`
class IndexFailureFeedbackHarness { ${feedbackMethod} }
module.exports = IndexFailureFeedbackHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const feedbackModule = { exports: {} };
vm.runInContext(feedbackCode, vm.createContext({
  module: feedbackModule, exports: feedbackModule.exports, DOMAIN: 0, TAG: 'test',
  hilog: { warn() {} }
}));

test('unknown share exceptions are replaced with phase-specific actionable feedback', () => {
  const secret = 'path=/private/vault/note.md token=secret-token response=private';
  const phases = ['image_prepare', 'text_prepare', 'file_prepare', 'handoff'];
  for (const phase of phases) {
    const message = shareFailureMessage(new Error(secret), phase);
    assert.ok(!message.includes(secret));
    assert.match(message, /原因未确定/);
  }
  assert.match(shareFailureMessage(
    new Error('文本超过系统分享 200 KB 限制，请删减内容后重试或改用 Markdown / ZIP。'),
    'text_prepare'
  ), /200 KB/);
});

test('known missing-image errors do not expose their path', () => {
  const message = shareFailureMessage(
    new Error('缺少本地图片，未生成分享文件：/private/vault/assets/secret.png'),
    'file_prepare'
  );
  assert.match(message, /图片缺失或不可用/);
  assert.ok(!message.includes('/private/vault/assets/secret.png'));
});

test('registry failures identify the operation and report its completion state and next step', () => {
  const Harness = feedbackModule.exports;
  const app = new Harness();
  const calls = [];
  app.showFailureFeedback = (...args) => calls.push(args);

  app.toastRegistryError('保存失败', new Error('/private/vault/note.md'), 'note', 'save');
  app.toastRegistryError('删除失败', new Error('/private/vault'), 'vault', 'delete');
  app.toastRegistryError('新建笔记失败', new Error('/private/vault/new.md'), 'file', 'create');
  app.toastRegistryError('移动失败', new Error('/private/vault/path'), 'file', 'move');

  assert.deepEqual(calls.map((args) => args.slice(0, 5)), [
    ['note', 'save', 'unknown', 'status_unknown', 'retry'],
    ['vault', 'delete', 'unknown', 'status_unknown', 'check_status'],
    ['file', 'create', 'unknown', 'status_unknown', 'check_status'],
    ['file', 'move', 'unknown', 'status_unknown', 'check_status']
  ]);
  assert.match(calls[0][5], /恢复草稿仍保留/);
  assert.match(calls[1][5], /知识库删除结果未确认/);
  assert.match(calls[2][5], /笔记创建结果未确认/);
  assert.match(calls[3][5], /原位置和目标位置/);
  assert.ok(!calls.flat().some((value) => typeof value === 'string' && value.includes('/private/')));
});

test('critical failure surfaces do not display raw system exception text', () => {
  assert.doesNotMatch(sourceFiles.index, /showToast\(\{\s*message:\s*(?:err|error)\.message/);
  assert.doesNotMatch(sourceFiles.sync, /appendLog\(\s*(?:err|error)\.message/);
  assert.doesNotMatch(sourceFiles.sync, /appendLog\([^;\n]*\+\s*(?:err|error)\.message/);
  assert.match(sourceFiles.sync, /appendLog\(label \+[\s\S]*?explainError\(err\.message/);
  assert.doesNotMatch(sourceFiles.sync, /return message;/);
  assert.doesNotMatch(sourceFiles.settings, /this\.(?:resetError|agentMessage)\s*=\s*err\.message/);
  assert.doesNotMatch(sourceFiles.switcher, /fullTextError\s*=\s*\(error as Error\)\.message/);
  assert.doesNotMatch(sourceFiles.agent, /this\.statusText\s*=\s*err\.message/);
  assert.doesNotMatch(sourceFiles.editor, /getErrorInfo\(\)|error\.message/);
  assert.doesNotMatch(sourceFiles.preview, /getErrorInfo\(\)|err\.message/);
  assert.match(sourceFiles.index, /recordFailure\(operation, phase, category, outcome, nextStep\)/);
  assert.match(sourceFiles.index, /private toastRegistryError\([\s\S]*RecentErrorOperation[\s\S]*RecentErrorPhase/);
  assert.match(sourceFiles.agentRuntime, /event\.result = AgentRuntime\.failureMessage\(event\.errorCode\)/);
  assert.doesNotMatch(sourceFiles.agentRuntime, /event\.result\s*=\s*err\.message/);
  assert.doesNotMatch(sourceFiles.agentRuntime, /setAssistantText\(assistant,\s*'执行未完成：'\s*\+\s*err\.message/);
  assert.match(sourceFiles.agentRuntime, /'AMBIGUOUS_TARGET',\s*'CREATE_CONFLICT'/);
  assert.match(sourceFiles.agentRuntime, /case 'AMBIGUOUS_TARGET':[\s\S]*?case 'CREATE_CONFLICT':/);
  assert.doesNotMatch(sourceFiles.intent, /err\.message|String\(error\)/);
  assert.match(sourceFiles.intent, /操作完成状态未确认/);
  assert.doesNotMatch(sourceFiles.intent, /'不支持的端插件工具：'\s*\+\s*name/);
  assert.match(sourceFiles.trash, /回收站读取失败；内容未从回收站移除/);
  assert.match(sourceFiles.trash, /旧回收站迁移未完成；原目录已保留/);
  for (const file of [sourceFiles.imageDialog, sourceFiles.fileDialog, sourceFiles.textDialog]) {
    assert.match(file, /shareFailureMessage\(error,/);
  }
});
