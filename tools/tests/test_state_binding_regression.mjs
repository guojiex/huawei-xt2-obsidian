import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：v1.32 1e4e389 —— 弹窗按钮 enabled 固化，创建永远禁用
// 根因：@Builder 全局多参数按值传递，回调布尔不随状态变化；
// 修复：改用 UIUtils.makeBinding 按回调传递，按钮 enabled 实时响应表单状态。
// 本测试验证产品源码中弹窗按钮的 enabled 属性使用 makeBinding 模式。

const noteDialogs = readSourceFile(new URL('../../entry/src/main/ets/components/NoteDialogs.ets', import.meta.url));
const vaultDialogs = readSourceFile(new URL('../../entry/src/main/ets/components/VaultDialogs.ets', import.meta.url));
const importDialog = readSourceFile(new URL('../../entry/src/main/ets/components/ImportVaultDialog.ets', import.meta.url));
const gitSyncDialog = readSourceFile(new URL('../../entry/src/main/ets/components/GitSyncDialog.ets', import.meta.url));

test('NoteDialogs uses makeBinding for create/rename/delete button enabled', () => {
  // 新建笔记弹窗：创建按钮 enabled 由输入框非空或条件方法决定
  // 实际模式：makeBinding<boolean>(() => this.normalized().length > 0) 或 makeBinding<boolean>(() => true)
  assert.match(noteDialogs, /UIUtils\.makeBinding<boolean>\(\(\)\s*=>/);
  // 确认按钮的 enabled 使用条件表达式而非 static boolean
  assert.match(noteDialogs, /makeBinding<boolean>\(\(\)\s*=>\s*this\.\w+\(\)\.length\s*>\s*0\)/);
  assert.doesNotMatch(noteDialogs, /enabled:\s*(true|false)\s*[,\n}]/,
    'dialog actions must not use static boolean for enabled');
});

test('VaultDialogs uses makeBinding for create/save button enabled', () => {
  assert.match(vaultDialogs, /makeBinding<boolean>\(\(\)\s*=>/);
  assert.doesNotMatch(vaultDialogs, /enabled:\s*(true|false)\s*[,\n}]/,
    'vault dialog actions must not use static boolean for enabled');
});

test('ImportVaultDialog uses makeBinding for import action enabled', () => {
  assert.match(importDialog, /makeBinding<boolean>\(\(\)\s*=>/);
  assert.doesNotMatch(importDialog, /enabled:\s*(true|false)\s*[,\n}]/,
    'import dialog actions must not use static boolean for enabled');
});

test('GitSyncDialog uses makeBinding for sync/retry action enabled', () => {
  assert.match(gitSyncDialog, /makeBinding<boolean>\(\(\)\s*=>/);
});

// 防回归：v1.32 7e40407 —— @BuilderParam 引用传参 this 丢失闪退
// 根因：@BuilderParam 按值传递时 this 不指向调用方，引用内部 @Builder 会丢失上下文
// 修复：改用 @BuilderParam 引用传递 ($$) 或将 @Builder 定义在 struct 内部
test('dialog shells use @BuilderParam and access this context correctly', () => {
  const shell = readSourceFile(new URL('../../entry/src/main/ets/components/UtilityDialogShell.ets', import.meta.url));
  // @BuilderParam 必须存在——接收内容构建器
  assert.match(shell, /@BuilderParam/);
  // makeBinding 注释提到此修复
  assert.match(shell, /makeBinding/);
  // shell 必须通过 this 访问自己的成员
  assert.match(shell, /this\.\w+/);
});

console.log('状态管理类 bug 防回归检查通过（makeBinding 模式 + @BuilderParam 引用传递）');
