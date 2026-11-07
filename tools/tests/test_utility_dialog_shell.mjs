import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const shellSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/UtilityDialogShell.ets',
  import.meta.url
));
const noteDialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/NoteDialogs.ets',
  import.meta.url
));
const vaultDialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/VaultDialogs.ets',
  import.meta.url
));
const quickSwitcherSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/QuickSwitcher.ets',
  import.meta.url
));
const importDialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/ImportVaultDialog.ets',
  import.meta.url
));
const shareDialogSource = readSourceFile(new URL(
  '../../entry/src/main/ets/components/ShareNoteDialog.ets',
  import.meta.url
));

test('utility shell matches the wide dialog and single-screen sheet geometry', () => {
  assert.match(shellSource, /preferredWidthVp: number = Size\.utilityDialogW/);
  assert.match(shellSource, /Math\.max\(0, Math\.min\(this\.preferredWidthVp, this\.windowWidthVp - Space\.s8\)\)/);
  // v1.32 32.13：宽屏限高 = 窗口高 - 上下各 s8；单屏 0.86 不变
  assert.match(shellSource, /return this\.windowHeightVp \* 0\.86;/);
  assert.match(shellSource, /return Math\.max\(0, this\.windowHeightVp - Space\.s8 \* 2\);/);
  assert.match(shellSource, /Radius\.dialog \* 2/);
  assert.match(shellSource, /height\(Space\.s10\)/);
  assert.match(shellSource, /\.fontWeight\(600\)/);
});

test('native note, vault, quick-switch, import, and share dialogs use the shared shell', () => {
  assert.equal((noteDialogSource.match(/UtilityDialogShell\(\{/g) ?? []).length, 4);
  assert.equal((vaultDialogSource.match(/UtilityDialogShell\(\{/g) ?? []).length, 3);
  assert.equal((quickSwitcherSource.match(/UtilityDialogShell\(\{/g) ?? []).length, 1);
  assert.equal((importDialogSource.match(/UtilityDialogShell\(\{/g) ?? []).length, 1);
  assert.equal((shareDialogSource.match(/UtilityDialogShell\(\{/g) ?? []).length, 1);
  assert.match(importDialogSource, /preferredWidthVp: Size\.importDialogW/);
  assert.match(shareDialogSource, /preferredWidthVp: Size\.shareW/);
});

test('utility actions share primary, secondary, danger, and disabled styling', () => {
  assert.match(shellSource, /\.fontSize\(FontSize\.body1\)/);
  assert.match(shellSource, /tone === 'secondary'[\s\S]*?tone === 'danger'/);
  // v1.32 32.12：主 / 危险禁用态中性化（--line 底、--muted 字、不透明）；次要禁用沿用 45%
  // 2026-11-07 EM-B2 回归修复：enabled 改 Binding<boolean>（按回调传递），读 .value
  assert.match(shellSource, /\.opacity\(!enabled\.value && tone === 'secondary' \? 0\.45 : 1\)/);
  assert.match(shellSource, /\.enabled\(enabled\.value\)/);
  assert.match(shellSource, /\.focusable\(keyboardFocusable && enabled\.value\)/);
  assert.match(shellSource, /import \{ Binding \} from '@kit\.ArkUI';/);
  assert.match(shellSource, /enabled: Binding<boolean>/);
  assert.match(shellSource, /\.layoutWeight\(singleScreen \? 1 : 0\)/);
});

// 2026-11-06 真机 JSCrash 修复（官方 FAQ faqs-arkui-229）：成员 @Builder 以
// `this.xxx` 引用方式传给子组件 @BuilderParam 时，builder 体内 this 指向子组件
// （UtilityDialogShell），弹窗自己的成员（selectedDir / confirm 等）全部读成
// undefined —— 新建笔记在重渲染时崩（:239 selectedDir.length）、删除笔记点
// 确认时崩（:369 this.confirm is not callable）。传递处必须用箭头函数包裹，
// 让 this 词法绑定回弹窗实例。
test('shell consumers wrap content and footer builders in arrows to preserve this', () => {
  const shareFilePreviewSource = readSourceFile(new URL(
    '../../entry/src/main/ets/components/ShareFilePreviewDialog.ets',
    import.meta.url
  ));
  const consumers = [
    { name: 'NoteDialogs', source: noteDialogSource, shells: 4, footers: 4 },
    { name: 'VaultDialogs', source: vaultDialogSource, shells: 3, footers: 3 },
    { name: 'QuickSwitcher', source: quickSwitcherSource, shells: 1, footers: 0 },
    { name: 'ImportVaultDialog', source: importDialogSource, shells: 1, footers: 1 },
    { name: 'ShareNoteDialog', source: shareDialogSource, shells: 1, footers: 0 },
    { name: 'ShareFilePreviewDialog', source: shareFilePreviewSource, shells: 1, footers: 1 }
  ];
  for (const consumer of consumers) {
    const wrappedContent =
      (consumer.source.match(/content: \(\): void => \{ this\.DialogContent\(\); \}/g) ?? []).length;
    const wrappedFooter =
      (consumer.source.match(/footer: \(\): void => \{ this\.DialogFooter\(\); \}/g) ?? []).length;
    assert.equal(wrappedContent, consumer.shells,
      `${consumer.name}: every shell usage must pass content as an arrow-wrapped builder`);
    assert.equal(wrappedFooter, consumer.footers,
      `${consumer.name}: footer must be arrow-wrapped wherever the shell receives one`);
    assert.doesNotMatch(consumer.source, /content: this\.DialogContent\b/,
      `${consumer.name}: passing DialogContent by reference rebinds this to the shell (JSCrash)`);
    assert.doesNotMatch(consumer.source, /footer: this\.DialogFooter\b/,
      `${consumer.name}: passing DialogFooter by reference rebinds this to the shell (JSCrash)`);
  }
});

// 2026-11-07 EM-B2 回归修复：全局 @Builder 多参按值传参不触发动态渲染（官方 arkts-builder
// 限制 3）。7e40407 把 content/footer lambda 化修 JSCrash 后，footer 里 UtilityDialogAction
// 的 enabled 按值固化 —— 新建笔记输入合法名称后创建按钮永远禁用（EM-B2 实证：hint 消失
// = rawName 已提交，但按钮仍灰、点击无效果）。修复：enabled 参数改 Binding<boolean>，
// 调用点全部用 UIUtils.makeBinding 按回调传递（API 20+，官方文档指定的多参全局 @Builder
// 状态刷新方式）。本测试锁住「每个调用的 enabled 都是 makeBinding 包裹」。
test('every utility action passes enabled as a makeBinding callback', () => {
  const gitSyncSource = readSourceFile(new URL(
    '../../entry/src/main/ets/components/GitSyncDialog.ets',
    import.meta.url
  ));
  const shareFilePreviewSource = readSourceFile(new URL(
    '../../entry/src/main/ets/components/ShareFilePreviewDialog.ets',
    import.meta.url
  ));
  const consumers = [
    { name: 'NoteDialogs', source: noteDialogSource },
    { name: 'VaultDialogs', source: vaultDialogSource },
    { name: 'GitSyncDialog', source: gitSyncSource },
    { name: 'ImportVaultDialog', source: importDialogSource },
    { name: 'ShareFilePreviewDialog', source: shareFilePreviewSource }
  ];
  for (const consumer of consumers) {
    const calls = consumer.source.match(/UtilityDialogAction\(/g) ?? [];
    const wrapped =
      consumer.source.match(/this\.singleScreen,\s*UIUtils\.makeBinding<boolean>/gs) ?? [];
    assert.equal(wrapped.length, calls.length,
      `${consumer.name}: every UtilityDialogAction enabled arg must be UIUtils.makeBinding (by-value boolean never refreshes)`);
    assert.match(consumer.source, /import \{ (?:\w+, )?UIUtils(?:, \w+)? \} from '@kit\.ArkUI';/,
      `${consumer.name}: must import UIUtils from @kit.ArkUI`);
  }
});
