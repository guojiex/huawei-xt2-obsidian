import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const managerSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/VaultManagerView.ets', import.meta.url));
const sidebarSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url));
const dialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/ShareNoteDialog.ets', import.meta.url));
const indexSource = readSourceFile(new URL(
  '../../entry/src/main/ets/pages/Index.ets', import.meta.url));

const helperStart = managerSource.indexOf('  private vaultHasNoNotes(');
const helperEnd = managerSource.indexOf('\n  @Builder', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find vaultHasNoNotes');
const harnessCode = transformSync(`
class VaultManagerHarness {
  ${managerSource.slice(helperStart, helperEnd)}
}
module.exports = VaultManagerHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const harnessModule = { exports: {} };
vm.runInNewContext(harnessCode, { module: harnessModule, exports: harnessModule.exports });

function sourceMethod(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return source.slice(start, end);
}

test('only a known empty vault disables its share action', () => {
  const manager = new harnessModule.exports();
  manager.shareSummaries = [
    { vaultId: 'empty', noteCount: 0 },
    { vaultId: 'with-notes', noteCount: 2 },
    { vaultId: 'unreadable', noteCount: -1 }
  ];

  assert.equal(manager.vaultHasNoNotes('empty'), true);
  assert.equal(manager.vaultHasNoNotes('with-notes'), false);
  assert.equal(manager.vaultHasNoNotes('unreadable'), false);
  assert.equal(manager.vaultHasNoNotes('missing-summary'), false);
});

test('manager share action is accessible and returns to its own trigger', () => {
  const shareRow = sourceMethod(managerSource, "Text('分享')", "Text('改名')");
  assert.match(shareRow, /\.enabled\(!this\.vaultHasNoNotes\(v\.id\)\)/);
  assert.match(shareRow, /\.focusable\(!this\.vaultHasNoNotes\(v\.id\)\)/);
  assert.match(shareRow, /\.id\('vault-manager-share-' \+ v\.id\)/);
  assert.match(shareRow, /这个库还没有笔记/);
  assert.match(shareRow, /this\.onShare\(v\.id, 'vault-manager-share-' \+ v\.id\)/);
  assert.match(indexSource, /shareSummaries: this\.vaultManagerShareSummaries/);
  assert.match(indexSource, /onShare: \(id: string, focusId: string\)[\s\S]{0,120}openShareVaultFromManager\(id, focusId\)/);
  // 2026-11-08 DFX 收口后焦点返回走 FocusRequest.safely
  assert.match(indexSource, /FocusRequest\.safely\(this\.getUIContext\(\), focusReturnId\)/);
});

test('manager share stays on the selected vault, exposes ZIP only, and preserves detail back navigation', () => {
  const openFromManager = sourceMethod(indexSource, '  private openShareVaultFromManager(',
    '\n  private sharePathForScope(');
  // openShareDialog 已移到各 @Builder 之前、紧邻 UndoBar
  const openDialog = sourceMethod(indexSource, '  private openShareDialog(',
    '\n  @Builder\n  UndoBar()');
  const prepareShare = sourceMethod(indexSource, '  private async prepareShare(',
    '\n  private async shareFile(');
  const preview = sourceMethod(indexSource, '  private openShareFilePreview(',
    '\n  private async shareLink(');

  assert.match(openFromManager, /countScope\(registry, vaultId, ''\)/);
  assert.match(openFromManager, /openShareDialog\('vault', '', vaultId, noteCount, focusId\)/);
  assert.match(openDialog, /entries\[i\]\.id === targetVaultId/);
  assert.match(openDialog, /folderScopeDistinct: boolean = folderPath\.length > 0/);
  assert.match(openDialog, /focusReturnId\.length > 0\s*\? \[vaultOption\]\s*: folderScopeDistinct \? \[noteOption, folderOption, vaultOption\] : \[noteOption, vaultOption\]/);
  assert.match(openDialog, /vault\.type === 'git' && focusReturnId\.length === 0/);
  assert.match(prepareShare, /prepareZip\(registry, vault\.id,\s*path, snapshot\)/);
  assert.match(prepareShare, /vault\.id === this\.currentVaultId && activeBridge\.ready/);
  assert.match(preview, /openShareDialog\(scope, path, targetVaultId, vaultNoteCount, focusReturnId\)/);
  assert.match(dialogSource, /if \(this\.scopeOptions\.length > 1\)/);
});

test('normal note share retains the vault range and Git remote-link path', () => {
  // openShareDialog 已移到各 @Builder 之前、紧邻 UndoBar
  const openDialog = sourceMethod(indexSource, '  private openShareDialog(',
    '\n  @Builder\n  UndoBar()');
  assert.match(openDialog, /folderScopeDistinct \? \[noteOption, folderOption, vaultOption\] : \[noteOption, vaultOption\]/);
  assert.match(openDialog, /if \(vault\.type === 'git' && focusReturnId\.length === 0\)/);
  assert.match(sidebarSource, /onManageVaults: \(\) => void/);
  assert.ok(!sidebarSource.includes('onShareVault'));
});
