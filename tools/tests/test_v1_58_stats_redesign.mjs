/*
 * v1.58 写作统计面板重设计 —— 定向测试（58.10 / 58.11）。
 *
 * 1. 新增展示层纯函数：下一个成就唯一、提示文案、本周圆点（口径函数本身不变，
 *    仍由 test_vault_stats.mjs 锁住）。
 * 2. 原型设计稿定向核对：库菜单无入口、连写条 / 单屏菜单打开弹窗、关闭焦点返还、
 *    热力图 7 行 × 12 列、下一个成就唯一、view=stats URL 复现打开弹窗。
 * 3. 原生形态源级断言：弹窗外壳、连写条、7×12 转置、空闲扫描与红线。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const service = readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultStatsService.ets', import.meta.url));
const start = service.indexOf('export interface VaultStatsNoteInput');
assert.ok(start >= 0, '找不到 VaultStatsService 纯计算区起点');
const code = transformSync(service.slice(start) +
  '\nmodule.exports = { badgesOf, heatWeeksOf, countsByDay, nextBadgeIndexOf,' +
  ' nextAchievementHint, currentWeekFlagsOf };',
{ loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({ module: { exports: {} }, console });
vm.runInContext(code, context);
const { badgesOf, heatWeeksOf, countsByDay, nextBadgeIndexOf,
  nextAchievementHint, currentWeekFlagsOf } = context.module.exports;

const html = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const dialog = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsDialog.ets', import.meta.url));
const view = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsView.ets', import.meta.url));
const chip = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsStreakChip.ets', import.meta.url));
const sidebar = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url));
const settings = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const statsStore = readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultStatsPreferenceStore.ets', import.meta.url));

/* --------------------- 58.5 / 58.8 展示层纯函数 --------------------- */

test('58.8 下一个成就：未获得里进度比例最高且唯一', () => {
  const badges = badgesOf(6, 0, 6, 47);
  const next = nextBadgeIndexOf(badges);
  assert.equal(next, 5, '6/7 的「七日连写」进度最高');
  assert.equal(badges[next].name, '七日连写');
  assert.equal(badges.filter((b) => !b.earned && b.value / b.goal === badges[next].value / badges[next].goal).length,
    1, '并列时只取一枚，保证圆环唯一');
  assert.equal(nextBadgeIndexOf(badgesOf(100, 100000, 30, 100)), -1, '全部达成返回 -1');
});

test('58.5 主视觉「下一步」提示与下一个成就一致', () => {
  assert.equal(nextAchievementHint(badgesOf(6, 0, 6, 47), 6), '再写 1 天，解锁「七日连写」');
  assert.equal(nextAchievementHint(badgesOf(100, 100000, 30, 100), 30), '所有成就都已获得');
  assert.match(nextAchievementHint(badgesOf(5, 50000, 0, 0), 0), /下一个成就「十篇」：/);
});

test('58.2 / 58.5 本周圆点：最后一周 7 天、未来日一律 false', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: Math.floor(new Date(2026, 10, 9, 12).getTime() / 1000), charCount: 1 },
    { relPath: 'b.md', mtimeSec: Math.floor(new Date(2026, 10, 10, 12).getTime() / 1000), charCount: 1 }
  ]);
  const flags = currentWeekFlagsOf(heatWeeksOf(counts, new Date(2026, 10, 10, 12)));
  assert.equal(flags.length, 7);
  assert.equal(flags[0], true, '周一有写作');
  assert.equal(flags[1], true, '今天（周二）有写作');
  for (let i = 2; i < 7; i++) {
    assert.equal(flags[i], false, '未到 / 未写的日子为空心');
  }
  // vm 跨 realm 数组不能 strict deepEqual，按值比较。
  assert.equal(JSON.stringify(currentWeekFlagsOf([])),
    JSON.stringify([false, false, false, false, false, false, false]));
});

/* --------------------------- 58.10 原型定向 --------------------------- */

test('58.1 / 58.10 原型：库菜单无统计入口，全屏统计页已删', () => {
  assert.doesNotMatch(html, /id="vaultStatsPage"/);
  assert.doesNotMatch(html, /统计与成就…/);
  assert.match(html, /<button class="streak-chip" id="vaultStatsEntry"/);
  assert.match(html, /id="vaultStatsEntry"[^>]*aria-controls="statsDialog"/);
});

test('58.2 / 58.3 / 58.4 原型：连写条与单屏菜单打开弹窗，关闭返还焦点', () => {
  assert.match(html, /\$\('vaultStatsEntry'\)\.onclick=\(\)=>openVaultStats\(\);/);
  assert.match(html, /\$\('mobileStats'\)\.onclick=\(\)=>mobileAction\(\(\)=>openVaultStats\(\)\);/);
  assert.match(html, /<dialog[^>]*class="utility-dialog import-dialog stats-dialog" id="statsDialog"/);
  assert.match(html, /function openVaultStats\(push=true\)\{[\s\S]{0,300}\$\('statsDialog'\)\.showModal\(\);/);
  assert.match(html, /function closeVaultStats\(updateUrl=true\)\{[\s\S]{0,320}statsReturnFocus\.focus\(\);/);
  assert.match(html, /sheetDialogIds=\[[^\]]*'statsDialog'/);
  assert.match(html, /statsReturnFocus=document\.activeElement/);
});

test('58.7 原型：热力图 7 行 × 12 列小方格，不是 12 行大圆', () => {
  assert.match(html,
    /grid-template-columns:auto repeat\(12,var\(--hc\)\);grid-template-rows:auto repeat\(7,var\(--hc\)\)/);
  assert.match(html, /--hc:clamp\(14px,/);
  const heat = html.slice(html.indexOf('function renderStatsHeat()'),
    html.indexOf('function renderStatsBadges('));
  assert.match(heat, /for\(let w=0;w<12;w\+\+\)/);
  assert.match(heat, /for\(let d=0;d<7;d\+\+\)/);
  assert.match(heat, /grid-column:'\+\(w\+2\)/);
  assert.match(heat, /grid-row:'\+\(d\+2\)/);
  assert.match(heat, /isToday=w===11&&d===dow/);
});

test('58.8 原型：只有一枚「下一个」成就显示圆环进度', () => {
  const badges = html.slice(html.indexOf('function renderStatsBadges('),
    html.indexOf('function statsValues()'));
  assert.match(badges, /const next=list\.filter\(b=>!b\.earned\)\.sort\(\(a,b\)=>b\.value\/b\.goal-a\.value\/a\.goal\)\[0\]/);
  assert.match(badges, /const isNext=b===next/);
  assert.match(badges, /--p:'\+p/);
  assert.equal((badges.match(/isNext\?/g) ?? []).length >= 1, true);
  assert.match(html, /\.stats-medal\.next \.stats-medal-mark\{background:conic-gradient/);
  assert.match(html, /statsBadgeCount'\)\.textContent=list\.filter\(b=>b\.earned\)\.length\+' \/ '\+list\.length\+' 已获得'/);
});

test('58.10 原型：view=stats URL 复现打开弹窗（stateUrl / restoreUrl 成对）', () => {
  assert.match(html, /vaultStatsOpen\?'stats':'notes'/);
  assert.match(html,
    /params\.get\('view'\)==='stats'\)\{closeHistory\(\);openVaultStats\(false\);\}/);
});

/* --------------------------- 58.11 原生形态 --------------------------- */

test('58.4 / 58.11 原生：弹窗外壳与焦点返还，不再有全屏 stats 视图', () => {
  assert.match(dialog, /@CustomDialog/);
  assert.match(dialog, /preferredWidthVp: Size\.statsDialogW/);
  assert.match(dialog, /headerTexts: \(\): void => \{ this\.DialogHeaderTexts\(\); \}/);
  assert.match(index, /cancel: restoreFocus/);
  assert.match(index, /FocusRequest\.safely\(this\.getUIContext\(\), focusReturnId\)/);
  assert.doesNotMatch(index, /if \(this\.topView === 'stats'\)/);
  assert.doesNotMatch(index, /this\.StatsView\(\)/);
});

test('58.2 / 58.3 原生：连写条与单屏菜单入口', () => {
  assert.match(chip, /写作统计：/);
  assert.match(chip, /'今天还没写'/);
  assert.match(chip, /\.id\(this\.chipId\)/);
  assert.match(sidebar, /if \(this\.statsEnabled && !this\.referenceOnly && !this\.asDrawer\) \{/,
    '57.7 起工作区连写条移到覆盖位分支 offset 压底（referenceOnly 留流内、抽屉不挂载语义不变）；v1.58 总开关关闭时连写条不渲染');
  assert.match(sidebar, /showDots: this\.sidebarW <= 0 \|\| this\.sidebarW >= Size\.statsDotsMinSidebarW/);
  assert.match(index, /MobileMoreStatsItem\(\)/);
  assert.match(index, /'连写 '/);
});

test('58.7 / 58.8 原生：热力图按 7 行 × 12 列转置，圆环只在「下一个」', () => {
  assert.match(view, /ForEach\(this\.dayIndexes\(\), \(d: number\) => \{/);
  assert.match(view, /ForEach\(this\.model\.weeks, \(week: VaultStatsWeek, w: number\) => \{/);
  assert.match(view, /isToday: w === this\.model\.weeks\.length - 1 && d === this\.todayIndex\(\)/);
  assert.match(view, /isNext: start \+ col === nextBadgeIndexOf\(this\.model\.badges\)/);
  assert.match(view, /ProgressType\.Ring/);
  assert.equal((view.match(/Progress\(\{ value: this\.percent\(\)/g) ?? []).length, 1);
});

test('58.11 原生：冷启动扫描排到空闲时机，红线不变', () => {
  assert.match(index, /this\.statsIdleTimer = setTimeout\(\(\): void => \{/);
  assert.match(index, /this\.scheduleIdleStatsRefresh\(\);/);
  for (const src of [dialog, view, chip]) {
    assert.ok(!src.includes('hiAppEvent') && !src.includes('hilog') &&
      !src.includes('PerformanceAnalysisKit'), '统计源出现埋点 / 日志 Kit');
  }
});

test('58.12 原生：总开关门控入口 / 连写条 / 后台重算 / 设置项', () => {
  // 关闭时直接拦截弹窗打开，不再进首帧关键路径。
  assert.match(index, /if \(!this\.statsEnabled\) \{\s*return;\s*\}/);
  // 空闲重算整体被开关短路，避免后台扫描。
  assert.match(index, /private scheduleIdleStatsRefresh\(\): void \{\s*if \(!this\.statsEnabled\) \{\s*return;\s*\}/);
  // 单屏「⋯」菜单项仅在开关开启时挂载。
  assert.match(index, /if \(this\.statsEnabled\) \{\s*this\.MobileMoreStatsItem\(\)/);
  // 设置页提供开关（默认关）。
  assert.match(settings, /@Prop statsEnabled: boolean = false;/);
  assert.match(settings, /Toggle\(\{ type: ToggleType\.Switch, isOn: this\.statsEnabled \}\)/);
  assert.match(settings, /onStatsEnabledChange: \(enabled: boolean\) => void = /);
  // 持久化默认值为关闭，未设置 / 读取失败均回退为关。
  assert.match(statsStore, /private static readonly DEFAULT_STATS_ENABLED: boolean = false;/);
  assert.match(statsStore, /return VaultStatsPreferenceStore\.DEFAULT_STATS_ENABLED;/);
  // 开启后立即排一次扫描，避免开启后连写条/弹窗需等冷启动才有数。
  assert.match(index, /private setStatsEnabled\(enabled: boolean\): void \{\s*this\.statsEnabled = enabled;/);
  assert.match(index, /} else \{\s*\/\/.*\n\s*this\.scheduleIdleStatsRefresh\(\);/);
});
