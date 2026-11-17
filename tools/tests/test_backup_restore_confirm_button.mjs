import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const dialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/ApplicationBackupDialog.ets',
  import.meta.url
));

test('confirm-step 替换并恢复 gating 走 if 分支，不依赖 @Builder 按值实参（L-7/Z2）', () => {
  // 2026-11-17 用户报障：勾选「我已了解」后「替换并恢复」按钮仍灰、点击无效。
  // 根因族 = api_notes L-7/Z2：@Builder 按值实参是调用时快照，enabled 传
  // `!this.busy && this.confirmed` 表达式会冻结在首帧（false）。
  // 修复模式（仓库已三度验证）：if (this.confirmed) 分支切换，分支内 enabled 只传常量。
  const confirmBranch = dialogSource.slice(
    dialogSource.indexOf("else if (this.step === 'confirm')")
  );
  assert.ok(confirmBranch.length > 0, 'confirm footer branch not found');
  assert.match(confirmBranch, /if \(this\.confirmed\) \{[\s\S]*?this\.Action\('替换并恢复', true, !this\.busy/);
  assert.match(confirmBranch, /\} else \{[\s\S]*?this\.Action\('替换并恢复', true, false/);
  // 禁止回退成按值表达式实参（快照冻结）。
  assert.doesNotMatch(dialogSource, /Action\('替换并恢复', true, !this\.busy && this\.confirmed/);
});
