import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.9：更新日志不超前于当前版本 —— 关于页与完整版本记录只显示
// 版本号 ≤ 已安装版本的条目；没有符合条目时显示占位文案；版本号运行时读包信息。
const filter = readSourceFile(
  new URL('../../entry/src/main/ets/model/ChangelogFilter.ets', import.meta.url));
const settings = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const history = readSourceFile(
  new URL('../../entry/src/main/ets/components/ReleaseHistoryView.ets', import.meta.url));
const changelogData = readSourceFile(
  new URL('../../entry/src/main/ets/model/ChangelogData.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

test('changelog filter mirrors prototype versionNotAfter semantics (32.9)', () => {
  // 分段数值比较：split('.') + 逐段 parse，解析失败按 0（原型 Number() + ||0）
  assert.match(filter, /export function versionNotAfter\(candidate: string, installed: string\): boolean \{/);
  assert.match(filter, /candidate\.split\('\.'\)/);
  assert.match(filter, /installed\.split\('\.'\)/);
  assert.match(filter, /if \(x !== y\) \{\s*\n\s*return x < y;\s*\n\s*\}/);
  assert.match(filter, /return true;/);
  assert.match(filter, /Number\.isNaN\(value\) \? 0 : value/);
  // 只保留 ≤ 已安装版本；安装版本为空（读取失败）不过滤，不清空更新日志
  assert.match(filter, /export function releasedEntries\(entries: ChangelogEntry\[\], installedVersion: string\): ChangelogEntry\[\] \{/);
  assert.match(filter, /if \(installedVersion\.length === 0\) \{\s*\n\s*return entries;\s*\n\s*\}/);
  assert.match(filter, /if \(versionNotAfter\(entries\[i\]\.version, installedVersion\)\) \{/);
  // 原型同源实现
  assert.match(prototype, /function versionNotAfter\(a,b\)\{/);
  assert.match(prototype, /function releasedEntries\(entries\)\{return \(entries\|\|\[\]\)\.filter\(e=>versionNotAfter\(e\.version,settingsData\.version\)\);\}/);
});

test('about tab filters recent changelog by installed version with empty fallback (32.9)', () => {
  // 版本号运行时读自身包信息，不写死（api_notes H-1/H-2）
  assert.match(settings, /bundleManager\.getBundleInfoForSelfSync\(/);
  assert.match(settings, /this\.versionName = info\.versionName;/);
  // 占位值不出现在过滤基准里：读取失败 = 空串 = 不过滤
  assert.match(settings, /private changelogInstalledVersion\(\): string \{/);
  assert.match(settings, /return '';/);
  assert.match(settings, /return releasedEntries\(RECENT_CHANGELOG, this\.changelogInstalledVersion\(\)\);/);
  // 空态占位文案与原型 .release-empty 一致（--small:14px ↔ body2、--muted ↔ text_tertiary）
  assert.match(settings, /Text\('当前版本的更新说明将在发布后显示。'\)/);
  assert.match(settings, /ChangelogList\(\{ entries: this\.releasedRecentEntries\(\) \}\)/);
  // 完整版本记录入口保持
  assert.match(settings, /Text\('查看完整版本记录 ›'\)/);
  assert.match(prototype, /\.release-empty\{margin:0;padding:var\(--s4\);color:var\(--muted\);font-size:var\(--small\)\}/);
});

test('full history view applies the same release filter (32.9)', () => {
  // 运行时读包信息；读不到 = 空串 = 不过滤（不清空历史列表）
  assert.match(history, /import \{ releasedEntries \} from '\.\.\/model\/ChangelogFilter';/);
  assert.match(history, /bundleManager\.getBundleInfoForSelfSync\(/);
  assert.match(history, /this\.installedVersion = info\.versionName;/);
  assert.match(history, /this\.installedVersion = '';/);
  // 同一过滤 + 同一空态文案
  assert.match(history, /releasedEntries\(CHANGELOG_ENTRIES, this\.installedVersion\)\.length === 0/);
  assert.match(history, /ChangelogList\(\{ entries: releasedEntries\(CHANGELOG_ENTRIES, this\.installedVersion\) \}\)/);
  assert.match(history, /Text\('当前版本的更新说明将在发布后显示。'\)/);
  // 原型：#recentChangelog 与 #allChangelog 都走 renderReleaseEntries → releasedEntries
  assert.match(prototype, /\$\('recentChangelog'\)\.innerHTML=renderReleaseEntries\(settingsData\.recent\)/);
  assert.match(prototype, /\$\('allChangelog'\)\.innerHTML=renderReleaseEntries\(/);
});

test('generator contract unchanged: RECENT_CHANGELOG stays a static slice (32.9)', () => {
  // 过滤在运行时做，ChangelogData 生成产物不掺版本判断
  assert.match(changelogData, /export const RECENT_CHANGELOG: ChangelogEntry\[\] = CHANGELOG_ENTRIES\.slice\(0, 3\);/);
});
