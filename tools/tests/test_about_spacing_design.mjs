import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.11：关于页卡片间距 ——「检查更新」卡片与相邻卡片之间留 --s4 间距。
// 修复主体在设计真源（原型 update-check 模板）；v1.17 检查更新卡片于 2026-11-06 落入原生关于页，
// 本测试锁定：原型 s4 间距规则 + 原生关于页各卡片（含检查更新卡）间距与 .hs-hero / .hs-group-title 一致。
const settings = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const aboutStart = settings.indexOf('  AboutTab() {');
const aboutEnd = settings.indexOf('\n  @Builder\n', aboutStart + 1);
assert.ok(aboutStart >= 0 && aboutEnd > aboutStart, 'could not find SettingsView.AboutTab');
const about = settings.slice(aboutStart, aboutEnd);

test('prototype keeps s4 gap between update-check card and the info card (32.11)', () => {
  // update-check 模板插在 hero 之后（aboutOverview.firstElementChild = .hs-hero）
  assert.match(prototype,
    /\$\('aboutOverview'\)\.firstElementChild\.insertAdjacentHTML\('afterend',updateCheckTemplate\)/);
  assert.match(prototype, /<div id="updateCheckGroup" class="update-check-group" data-state="idle">/);
  assert.match(prototype, /<span class="hs-title">检查更新<\/span>/);
  // 32.11 修复：卡片组与下方信息卡片之间留 --s4
  assert.match(prototype, /\.update-check-group\{margin-bottom:var\(--s4\)\}/);
});

test('native about hero padding matches .hs-hero (32.11)', () => {
  // .hs-hero{padding:var(--s4) 0 var(--s6)}：图标区上 s4、下 s6
  assert.match(prototype, /\.hs-hero\{display:flex;flex-direction:column;align-items:center;text-align:center;padding:var\(--s4\) 0 var\(--s6\)\}/);
  assert.match(about, /Image\(\$r\('app\.media\.app_icon_1024'\)\)/);
  assert.match(about, /\.padding\(\{ top: Space\.s4, bottom: Space\.s6 \}\)/);
});

test('native about card gaps stay uniform across the tab (32.11)', () => {
  // 卡片之间统一 s4 底距（信息卡片 margin-bottom s4；更新日志卡片为末卡不再加距）
  const infoCard = about.indexOf('Span(\'反馈邮箱 \')');
  assert.ok(infoCard > 0, 'about info card found');
  const infoBlock = about.slice(infoCard, about.indexOf("this.GroupTitle('更新日志')"));
  assert.match(infoBlock, /\.margin\(\{ bottom: Space\.s4 \}\)/);
  // 分组标题与 .hs-group-title 一致：上 s5 下 s2、caption、500、muted
  assert.match(prototype,
    /\.hs-group-title\{margin:var\(--s5\) var\(--s4\) var\(--s2\);font-size:var\(--caption\);font-weight:500;color:var\(--muted\)/);
  assert.match(settings, /\.margin\(\{ top: Space\.s5, bottom: Space\.s2 \}\)/);
  assert.match(about, /this\.GroupTitle\('更新日志'\)/);
  // v1.17 已落地（2026-11-06）：检查更新卡片进入关于页，应用 32.11 的 s4 间距规则 ——
  // 检查更新卡在信息卡与更新日志之间，与信息卡同用 margin-bottom s4（原型 .update-check-group）
  const updateCard = about.indexOf('v1.17：检查更新组');
  assert.ok(updateCard > infoCard, 'v1.17 update-check card sits after the info card');
  assert.ok(updateCard < about.indexOf("this.GroupTitle('更新日志')"),
    'v1.17 update-check card sits before the changelog group');
  const updateBlock = about.slice(updateCard, about.indexOf("this.GroupTitle('更新日志')"));
  assert.match(updateBlock, /\.margin\(\{ bottom: Space\.s4 \}\)/);
});
