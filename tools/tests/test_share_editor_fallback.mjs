import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const shareFlowSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));

// v1.53 53.6：分享不再硬依赖隐藏的源码编辑器 Web 就绪。
// 用户实测：笔记正常显示（预览 Web），点分享却报「编辑器尚未就绪，暂时无法分享」且持续
// 不自愈——守卫检查的是隐藏的 CodeMirror 编辑器桥 ready，与预览显示无关；编辑器 Web
// 加载失败在简单模式下不可见，分享被永久阻断。
// 修复：noteMarkdownForShare 统一取正文——桥就绪走桥（含未保存改动），未就绪读磁盘文件
// （编辑器未就绪即不存在其未保存改动；简单模式预览编辑直接落盘，文件即权威内容）。

test('53.6 守卫不再要求编辑器桥就绪，空路径提示改为打开笔记', () => {
  assert.doesNotMatch(shareFlowSource, /编辑器尚未就绪，暂时无法分享/,
    '旧的「编辑器尚未就绪」阻断分支必须删除');
  const guard = shareFlowSource.match(
    /const notePath: string = vault\.id === this\.currentVaultId \? this\.activeFilePath\(\) : '';\s*\n\s*if \(scope === 'note' && notePath\.length === 0\) \{\s*\n\s*promptAction\.showToast\(\{ message: '请先打开一篇笔记' \}\);/);
  assert.ok(guard, 'openShareDialog 守卫应只拦「没有打开笔记」，不再拦编辑器未就绪');
});

test('53.6 noteMarkdownForShare：桥就绪走桥，未就绪读文件兜底', () => {
  const helper = shareFlowSource.match(
    /private async noteMarkdownForShare\(vaultId: string, path: string\): Promise<string> \{[\s\S]*?\n  \}/);
  assert.ok(helper, '缺少 noteMarkdownForShare helper');
  const body = helper[0];
  assert.match(body, /bridge\.ready[\s\S]*?getContent\(\)/, '桥就绪必须走 getContent（含编辑器内未保存改动）');
  assert.match(body, /NoteService\.tryReadNote\(VaultRegistry\.get\(\), vaultId, path\)/,
    '桥未就绪必须直接读库文件兜底');
  assert.match(body, /text === null[\s\S]*?throw new Error\('未能读取笔记内容，暂时无法分享'\)/,
    '文件读取失败必须显式报错，不得静默分享空内容');
});

test('53.6 四条笔记分享链路全部改走 noteMarkdownForShare，无残留直连编辑器桥', () => {
  const flows = [
    /if \(format === 'text' && scope === 'note'\) \{\s*\n\s*const markdown: string = await this\.noteMarkdownForShare\(vault\.id, path\);/,
    /if \(scope === 'note'\) \{\s*\n\s*const markdown: string = await this\.noteMarkdownForShare\(vault\.id, path\);/,
  ];
  for (const flow of flows) {
    assert.match(shareFlowSource, flow);
  }
  const imageShare = shareFlowSource.match(
    /private async prepareNoteImageShare\(vaultId: string, notePath: string,\s*\n\s*itemName: string\): Promise<ShareImagePreviewImage> \{[\s\S]*?\n\s*const markdown: string = await this\.noteMarkdownForShare\(vaultId, notePath\);/);
  assert.ok(imageShare, '长图链路应去 editor 形参并改走 noteMarkdownForShare');
  assert.doesNotMatch(shareFlowSource, /prepareNoteImageShare\(\s*\n?\s*vaultId, notePath, itemName, this\.editorBridgeForPath\(notePath\)\)/,
    '长图调用点不得再传编辑器桥');
  const pdfShare = shareFlowSource.match(
    /private async prepareNotePdfShare\([\s\S]*?const markdown: string = await this\.noteMarkdownForShare\(vaultId, notePath\);/);
  assert.ok(pdfShare, 'PDF 链路应改走 noteMarkdownForShare');
  assert.doesNotMatch(shareFlowSource, /editorBridgeForPath\((?:path|notePath)\)\.getContent\(\)/,
    '分享链路不得再直连编辑器桥取正文');
});

test('53.6 ZIP 快照（库/目录作用域）保持既有 ready 条件兜底语义不变', () => {
  const snapshot = shareFlowSource.match(
    /const activeBridge: EditorBridge = this\.editorBridgeForPath\(activePath\);\s*\n\s*if \(vault\.id === this\.currentVaultId && activeBridge\.ready && activePath\.length > 0 &&/);
  assert.ok(snapshot, '库/目录 ZIP 快照仅在桥就绪时附带，未就绪由服务端读盘，维持原状');
});
