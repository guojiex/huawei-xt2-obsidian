import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.37 37.1–37.4：设置页「导出当前知识库」—— 备份分组 / 复用 25.18 库级分享 / 空库禁用 / 重置先导出。
const settings = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const tabStart = settings.indexOf('  DataTab() {');
const tabEnd = settings.indexOf('\n  @Builder\n', tabStart + 1);
assert.ok(tabStart >= 0 && tabEnd > tabStart, 'could not find SettingsView.DataTab');
const dataTab = settings.slice(tabStart, tabEnd);

test('backup group sits above local data with export row and footnote (37.1)', () => {
  // 分组顺序：数据标题 → 备份 → 导出行 → 注脚 → 本地数据
  const heading = dataTab.indexOf("'数据'");
  const backupTitle = dataTab.indexOf("this.GroupTitle('备份')");
  const exportRow = dataTab.indexOf("'导出当前知识库（ZIP）'");
  const footnote = dataTab.indexOf('不包含应用设置、草稿、回收站与访问令牌。其他知识库可在「管理库」中逐个分享。');
  const localTitle = dataTab.indexOf("this.GroupTitle('本地数据')");
  assert.ok(heading >= 0 && backupTitle > heading, 'backup group title after data heading');
  assert.ok(exportRow > backupTitle && footnote > exportRow && localTitle > footnote,
    'backup group precedes local data group');
  // 标题 --blue（brand）+ 说明三段拼接（库名 · N 篇 · ZIP）
  assert.match(dataTab, /Text\('导出当前知识库（ZIP）'\)[\s\S]*?fontColor\(\$r\('app\.color\.brand'\)\)/);
  assert.match(settings, /「' \+ this\.currentVaultId \+ '」· ' \+ this\.currentVaultNoteCount\.toString\(\) \+/);
  assert.match(settings, /' 篇笔记 · 打包为 ZIP，可保存到文件或发给自己'/);
  // 注脚与原型 .hs-note 文案一致
  assert.ok(prototype.includes('不包含应用设置、草稿、回收站与访问令牌。其他知识库可在「管理库」中逐个分享。'),
    'footnote matches prototype hs-note copy');
});

test('export reuses the 25.18 vault share entry with focus return (37.2)', () => {
  // SettingsView 回调 → Index.openShareVaultFromManager(currentVaultId, focusId)
  assert.match(settings, /onExportCurrentVault: \(focusId: string\) => void = \(_focusId: string\) => \{\};/);
  assert.match(dataTab, /this\.onExportCurrentVault\('settings-export-vault-row'\)/);
  assert.match(dataTab, /\.id\('settings-export-vault-row'\)/);
  const paneStart = index.indexOf('  SettingsPane() {');
  const paneEnd = index.indexOf('\n  @Builder\n', paneStart + 1);
  const pane = index.slice(paneStart, paneEnd);
  assert.ok(paneStart >= 0 && paneEnd > paneStart, 'could not find Index.SettingsPane');
  assert.match(pane, /currentVaultNoteCount: this\.currentVaultNoteCount,/);
  assert.match(pane, /onExportCurrentVault: \(focusId: string\): void => \{/);
  assert.match(pane, /this\.openShareVaultFromManager\(this\.currentVaultId, focusId\)/);
  // 25.18 入口保持：按库 id 计数、空库 toast、focusReturnId 透传
  assert.match(index, /private openShareVaultFromManager\(vaultId: string, focusId: string\): void \{/);
  assert.match(index, /this\.openShareDialog\('vault', '', vaultId, noteCount, focusId\)/);
});

test('empty vault disables the row and swaps the hint (37.3)', () => {
  // 禁用条件 = 无库或空库（原型 syncExportBackup 同款）
  assert.match(settings,
    /return this\.currentVaultId\.length === 0 \|\| this\.currentVaultNoteCount === 0;/);
  assert.match(settings, /return '当前没有知识库';/);
  assert.match(settings, /return '当前知识库没有笔记，无需导出';/);
  assert.match(dataTab, /\.enabled\(!this\.exportBackupDisabled\(\)\)/);
  assert.match(dataTab, /\.opacity\(this\.exportBackupDisabled\(\) \? 0\.4 : 1\)/);
  // 读屏播报禁用态（vault-manager share 同款先例）
  assert.match(dataTab, /'导出当前知识库，已禁用，' \+ this\.exportBackupHint\(\)/);
  // 原型三态文案一致
  assert.ok(prototype.includes('当前知识库没有笔记，无需导出'));
  assert.ok(prototype.includes('当前没有知识库'));
});

test('reset confirm suggests exporting first via inline link (37.4)', () => {
  // 建议先「导出当前知识库」作为备份。→ 行内链接收起确认区并打开同一分享入口
  const confirmStart = dataTab.indexOf("'确定重置所有数据？'");
  const detailStart = dataTab.indexOf('本页编辑、插入图片、文件操作和回收站将恢复为初始样例');
  assert.ok(confirmStart >= 0 && detailStart > confirmStart, 'reset confirm block found');
  const confirm = dataTab.slice(confirmStart, detailStart);
  assert.match(confirm, /Span\('建议先'\)/);
  assert.match(confirm, /Span\('导出当前知识库'\)[\s\S]*?fontColor\(\$r\('app\.color\.brand'\)\)/);
  assert.match(confirm, /Span\('作为备份。'\)/);
  // 空库不触发（原型 resetExportFirst 同款守卫）；点按收起确认区再打开分享
  assert.match(confirm, /if \(this\.exportBackupDisabled\(\)\) \{\s*\n\s*return;\s*\n\s*\}/);
  assert.match(confirm, /this\.resetConfirmOpen = false;/);
  assert.match(confirm, /this\.onExportCurrentVault\('settings-export-vault-row'\);/);
  // 原型文案与行为一致：建议先导出当前知识库作为备份
  assert.ok(prototype.includes('建议先') && prototype.includes('导出当前知识库</button>作为备份。'));
  // 不改变重置步骤：确认标题、说明与两个按钮保持
  assert.ok(detailStart > 0, 'reset detail copy unchanged');
  assert.match(dataTab, /'重置并恢复样例'/);
});
