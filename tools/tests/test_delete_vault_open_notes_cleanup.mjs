import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

// 工作树为 CRLF，源码切片/正则统一按 LF 处理（见 lib/source.mjs）。
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const runtimeSource = readSourceFile(new URL('../../entry/src/main/ets/model/AgentRuntime.ets', import.meta.url));

function slice(startMarker, endMarker) {
  const start = indexSource.indexOf(startMarker);
  const end = indexSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not locate Index section ${startMarker}`);
  return indexSource.slice(start, end);
}

const deleteMethod = slice('  private async doDeleteVault(id: string): Promise<void> {',
  '\n  /** 摘掉左右栏的防抖写盘定时器');
const resetMethod = slice('  private resetOpenNotesAfterVaultRemoval(): void {',
  '\n  /**\n   * 删库成功、注册表已刷新后重建工作区');
const restoreMethod = slice('  private async restoreWorkspaceAfterVaultRemoval(): Promise<void> {',
  '\n  /**\n   * 新建笔记（顺序不能乱）');

test('removeVault callback is synchronous so removed=true implies the registry is updated', () => {
  // 外部目录授权释放是异步的，必须待在会被 await 的 cleanup 回调；
  // 若在 removeVault 里 await，deleteVaultWithCleanup 不 await 它就会提前返回。
  const cleanupEnd = deleteMethod.indexOf('        (): void => {');
  assert.ok(cleanupEnd > 0, 'removeVault must be a synchronous (): void => callback');
  const cleanupBody = deleteMethod.slice(0, cleanupEnd);
  assert.match(cleanupBody, /await authorization\.release\(target\.rootUri\)/);
  // 只取 removeVault 回调本体，不能把后面主流程的 await 算进来。
  const removeEnd = deleteMethod.indexOf('\n        });', cleanupEnd);
  assert.ok(removeEnd > cleanupEnd);
  const removeBody = deleteMethod.slice(cleanupEnd, removeEnd);
  const removeCode = removeBody.replace(/\/\/[^\n]*/g, '');
  assert.doesNotMatch(removeCode, /await /, 'removeVault callback must not contain await');
  assert.match(removeCode, /reg\.remove\(id\);/);
  // AgentRuntime 的实现也必须保持同步调用，不能悄悄改成 async 回调却不 await。
  assert.match(runtimeSource, /\n      removeVault\(\);\n/);
  assert.match(runtimeSource, /removeVault: \(\) => void\)/);
});

test('open note state is cleared synchronously between reg.remove and refreshFromRegistry', () => {
  const removePos = deleteMethod.indexOf('reg.remove(id);');
  const resetPos = deleteMethod.indexOf('this.resetOpenNotesAfterVaultRemoval();');
  const refreshPos = deleteMethod.indexOf('this.refreshFromRegistry();');
  assert.ok(removePos > 0 && resetPos > 0 && refreshPos > 0);
  assert.ok(removePos < resetPos,
    'state must be cleared immediately after the registry entry is removed');
  assert.ok(resetPos < refreshPos,
    'state must be cleared before refreshFromRegistry triggers a re-render');
  assert.match(deleteMethod, /if \(deletingCurrent\) \{\s*\n\s*this\.resetOpenNotesAfterVaultRemoval\(\);/);
  // 只有删当前库才需要清；删别的库不该动用户正在看的笔记。
  assert.match(deleteMethod, /\} else if \(deletingCurrent\) \{/);
  assert.match(deleteMethod, /await this\.restoreWorkspaceAfterVaultRemoval\(\)/);
});

test('reset clears both panes, sessions, in-flight requests and pending writes', () => {
  assert.match(resetMethod, /this\.leftOpenRequestId\+\+/);
  assert.match(resetMethod, /this\.rightOpenRequestId\+\+/);
  assert.match(resetMethod, /this\.cancelPendingNoteSaves\(\)/);
  assert.match(resetMethod, /this\.stopWorkspaceSessionSaving\(\)/);
  for (const field of ['currentFilePath', 'rightFilePath', 'leftSession', 'rightSession',
    'editorDirty', 'rightEditorDirty', 'recentOpenPaths', 'chapterEntries']) {
    assert.match(resetMethod, new RegExp(`this\\.${field} = `));
  }
  // 不能在这里 flush 旧库编辑：库目录已删，写回无意义且会抛「库不存在」。
  assert.doesNotMatch(resetMethod, /flushSave|flushWorkspaceSaves/);
});

test('rebuild pushes empty content into resident editor/preview when no session to restore', () => {
  assert.match(restoreMethod, /WorkspaceSessionStore\)\.loadFor\(nextVaultId\)/);
  assert.match(restoreMethod, /await this\.applyWorkspaceSession\(targetSession\)/);
  assert.match(restoreMethod, /await this\.readAndPush\('', false\)/);
  assert.match(restoreMethod, /await this\.readRightAndPush\(''\)/);
  assert.match(restoreMethod, /this\.workspaceSessionSavingEnabled = true/);
});

test('failed or skipped deletion restores pending saves instead of dropping edits', () => {
  assert.match(deleteMethod, /if \(!removed\) \{[\s\S]*?this\.reschedulePendingNoteSaves\(\)/);
  assert.match(deleteMethod, /\} catch \(error\) \{[\s\S]*?this\.reschedulePendingNoteSaves\(\)/);
  const cancelMethod = slice('  private cancelPendingNoteSaves(): void {',
    '\n  /** 删除未执行/失败');
  assert.match(cancelMethod, /this\.saveTimer = -1/);
  assert.match(cancelMethod, /this\.rightSaveTimer = -1/);
  const rescheduleMethod = slice('  private reschedulePendingNoteSaves(): void {',
    '\n  /**\n   * 删除当前库后**同步**清空');
  assert.match(rescheduleMethod, /this\.scheduleSave\(\)/);
  assert.match(rescheduleMethod, /this\.scheduleRightSave\(\)/);
});
