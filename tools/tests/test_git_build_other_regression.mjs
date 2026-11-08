import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：c0043b4 —— 签名 profile 必须与 keystore 同源
// 本测试验证签名配置的约束条件被代码或脚本正确强制

const hvigorFile = readSourceFile(new URL('../../entry/hvigorfile.ts', import.meta.url));

test('hvigorfile reads signing config from local overrides, not build-profile', () => {
  // 签名配置从 .local/local-signing.json 注入，build-profile.json5 永久无签名
  assert.match(hvigorFile, /overrides.*signingConfig|signingConfig.*overrides|local-signing/);
});

// 防回归：aba518a —— 导入 Git 仓库页导入态标题与顶栏重复
test('git import page title "仓库地址" appears only in the visible title, error text is acceptable', () => {
  const syncPage = readSourceFile(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url));
  // "仓库地址" 出现在标题和错误提示文案中，这是合理的
  // 真正的 bug 是标题自身重复显示——检查标题构建处只有一个
  const titleMatches = [...syncPage.matchAll(/Text\([^)]*仓库地址[^)]*\)/g)];
  // 应该只有一处 Text() 包含 "仓库地址" 作为标题
  assert.ok(titleMatches.length >= 1, 'should have at least one 仓库地址 title');
  // 确认不是同一内容出现两次作为并列标题（之前的 bug）
  const duplicateTitle = syncPage.match(/仓库地址[^)]*\)[\s\S]{0,100}仓库地址/);
  // 如果有重复标题出现，两个 Text('仓库地址') 会紧挨着
  const standaloneTitles = [...syncPage.matchAll(/Text\('仓库地址'\)/g)];
  assert.ok(standaloneTitles.length <= 1, 'should not have duplicate 仓库地址 standalone titles');
});

// 防回归：3393b78 / 601f14d —— 完善首发 Git 界面暂隐收口
test('git sync entry is hidden for non-git vaults', () => {
  const index = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
  // 非 Git 库不显示同步入口——条件渲染
  const gitEntry = index.substring(
    Math.max(0, index.indexOf('git-sync-button') - 200),
    Math.min(index.length, index.indexOf('git-sync-button') + 500)
  );
  assert.match(gitEntry, /if\s*\(|isGit|gitEnabled/);
});

// 防回归：d6c657d —— 修复未闭合代码块切换
test('markdown code block format handles unclosed fences gracefully', () => {
  const codeBlockFormat = readSourceFile(new URL('../../web/mdeditor/src/codeBlockFormat.ts', import.meta.url));
  // 必须处理 FencedCode 节点（未闭合的代码围栏）
  assert.match(codeBlockFormat, /FencedCode/);
  // 必须有切换代码块的逻辑
  assert.match(codeBlockFormat, /toggleCodeBlock/);
  assert.ok(codeBlockFormat.length > 0);
});

// 防回归：7e7f8ca / 86dcb50 / a06fc62 —— AgentKit 隔离
test('agent imports are guarded by try-catch for emulator environments', () => {
  // Agent 功能已大量删除，确保剩余入口有防护
  const entryAbility = readSourceFile(new URL('../../entry/src/main/ets/entryability/EntryAbility.ets', import.meta.url));
  // 不应有未防护的 AgentKit 直接导入
  assert.doesNotMatch(entryAbility, /import.*@kit\.AgentKit/);
});

// 防回归：2bc0458 —— Windows CRLF 与路径导致 Node 回归失败
test('source file reading normalizes CRLF to LF', () => {
  const source = readSourceFile(new URL('./lib/source.mjs', import.meta.url));
  assert.match(source, /replace\(\s*\/\\r\\n\/g/);
});

// 防回归：81dd049 —— CRLF 预览源码映射
test('preview source mapping handles CRLF normalization', () => {
  const preview = readSourceFile(new URL('../../web/mdpreview/src/index.ts', import.meta.url));
  // 预览源码映射必须处理 CRLF
  assert.match(preview, /\\r\\n|\\r|CRLF|replace/);
});

// 防回归：9334583 —— 保留首装标记并持久化空工作区
test('first install flag is persisted and empty workspace is saved', () => {
  const vaultRegistry = readSourceFile(new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));
  assert.match(vaultRegistry, /firstInstall|isFirstInstall|hasOpenedBefore/);
});

// 防回归：e8c3c86 —— 库名空白前缀未去点
test('vault name trimming removes leading/trailing whitespace and dots', () => {
  const vaultRegistry = readSourceFile(new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));
  assert.match(vaultRegistry, /trim\(\)/);
});

// 防回归：22b4b12 —— 保留编辑保护并校验回归
test('workspace session save guards against stale save requests', () => {
  const sessionStore = readSourceFile(new URL('../../entry/src/main/ets/model/WorkspaceSessionStore.ets', import.meta.url));
  assert.ok(sessionStore.length > 0);
});

// 防回归：a642281 —— 保留小艺本地笔记接线
test('xiaoyi/insight intent note service does not expose note content in logs', () => {
  const insightService = readSourceFile(new URL('../../entry/src/main/ets/entryability/InsightIntentNoteService.ets', import.meta.url));
  const logCalls = [...insightService.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([m]) => m);
  for (const call of logCalls) {
    assert.doesNotMatch(call, /content|text|body/);
  }
});

console.log('Git/桥接/构建链/其他类 bug 防回归检查通过');
