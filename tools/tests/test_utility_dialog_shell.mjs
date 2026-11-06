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
  assert.match(shellSource, /\.opacity\(!enabled && tone === 'secondary' \? 0\.45 : 1\)/);
  assert.match(shellSource, /\.layoutWeight\(singleScreen \? 1 : 0\)/);
});
