/*
 * v1.81 写作统计、年度回顾与成就重设计 —— 原生迁移定向测试（81.5–81.7）。
 *
 * 1. 年度口径纯函数（81.5 / 81.6，真实 mtime，非演示）：
 *    yearsOf 年份列表（数据年份 ∪ 当前年、降序）、annualOfYear 当前年截至今日 /
 *    历史年完整日历 / 跨年连写截断 / 未来月置空、daysInMonthOf 闰年、
 *    computeStatsModel.years 聚合、emptyStatsModel.years 空集合。
 * 2. 源级断言（81.7 独立页形态）：三视角互斥与回顶、年份选择、成就三态、
 *    失败安全文案、导航条沉浸、Index 接线（topView='stats' + 独立页）。
 * 3. token / 原型对齐：--stats-* 五值与 Tokens 一致；原型年度脚注含「演示」前缀，
 *    原生脚注删演示句、保留口径警示（81.6）。
 * 4. 红线（51.6 / 52.4）：统计源不埋点、不打日志、不上报。
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
  '\nmodule.exports = { countsByDay, yearsOf, annualOfYear, daysInMonthOf,' +
  ' computeStatsModel, emptyStatsModel };',
{ loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({ module: { exports: {} }, console });
vm.runInContext(code, context);
const { countsByDay, yearsOf, annualOfYear, daysInMonthOf,
  computeStatsModel, emptyStatsModel } = context.module.exports;

/** 本地时区某天中午的 Date。 */
const day = (y, m, d, h = 12) => new Date(y, m, d, h, 0, 0);
const mtimeAt = (y, m, d, h = 12) => Math.floor(day(y, m, d, h).getTime() / 1000);
/** vm 跨 realm 的数组 / 对象过 JSON 化再 deepEqual。 */
const plain = (value) => JSON.parse(JSON.stringify(value));

// 2026-11-10（周二）：当前年截至今日；2024 为闰年、2025 为完整历史年
const TODAY = day(2026, 10, 10);

/* ------------------------- 81.5 闰年与月份天数 ------------------------- */

test('81.5 daysInMonthOf: 平年 2 月 28 / 闰年 2 月 29 / 大小月', () => {
  assert.equal(daysInMonthOf(2026, 2), 28);
  assert.equal(daysInMonthOf(2024, 2), 29);
  assert.equal(daysInMonthOf(2026, 1), 31);
  assert.equal(daysInMonthOf(2026, 4), 30);
});

/* ------------------------- 81.5 年份列表 ------------------------- */

test('81.5 yearsOf: 数据年份 ∪ 当前年、降序去重；空库只有当前年', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2024, 4, 3), charCount: 1 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2025, 0, 5), charCount: 1 },
    { relPath: 'c.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 1 }
  ]);
  assert.deepEqual(plain(yearsOf(counts, TODAY)), [2026, 2025, 2024]);
  assert.deepEqual(plain(yearsOf(new Map(), TODAY)), [2026]);
  // 未来年份也在数据里时按数据算（mtime 异常超前不丢年份）
  assert.deepEqual(plain(yearsOf(countsByDay([
    { relPath: 'f.md', mtimeSec: mtimeAt(2027, 0, 1), charCount: 1 }]), TODAY)),
  [2027, 2026]);
});

/* ------------------------- 81.5 / 81.6 年度指标 ------------------------- */

test('81.5 annualOfYear: 当前年截至今日，未来月置空不计、当月标 current', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 0, 2), charCount: 1 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 1, 5), charCount: 1 },
    { relPath: 'c.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 1 },
    { relPath: 'd.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 1 },
    // 12 月尚未到：即使 mtime 超前也不计入当前年
    { relPath: 'future.md', mtimeSec: mtimeAt(2026, 11, 5), charCount: 1 }
  ]);
  const s = annualOfYear(counts, 2026, TODAY);
  assert.equal(s.year, 2026);
  assert.equal(s.activeDays, 4); // 1/2、2/5、11/9、11/10
  assert.equal(s.longestStreakDays, 2); // 11/9–11/10
  assert.equal(s.activeMonths, 3); // 1、2、11 月
  assert.equal(s.months.length, 12);
  assert.equal(s.months[10].current, true); // 11 月
  assert.equal(s.months[10].activeDays, 2);
  assert.equal(s.months[11].future, true); // 12 月未到
  assert.equal(s.months[11].activeDays, 0);
  assert.equal(s.months[10].future, false);
});

test('81.5 annualOfYear: 跨年连写在本年内截断（12 月末 → 1 月初不算同段）', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2025, 11, 30), charCount: 1 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2025, 11, 31), charCount: 1 },
    { relPath: 'c.md', mtimeSec: mtimeAt(2026, 0, 1), charCount: 1 }
  ]);
  assert.equal(annualOfYear(counts, 2025, TODAY).longestStreakDays, 2);
  assert.equal(annualOfYear(counts, 2026, TODAY).longestStreakDays, 1);
});

test('81.5 annualOfYear: 历史年为完整日历年（含闰日 2/29），无 current / future 月', () => {
  const counts = countsByDay([
    ...[1, 2, 3, 4, 5, 6, 7].map((d) => (
      { relPath: 'n' + d + '.md', mtimeSec: mtimeAt(2024, 1, 22 + d), charCount: 1 }))
  ]); // 2024-02-23 … 02-29（闰年七天连写，含 2/29）
  const s = annualOfYear(counts, 2024, TODAY);
  assert.equal(s.activeDays, 7);
  assert.equal(s.longestStreakDays, 7);
  assert.equal(s.months[1].activeDays, 7); // 2 月
  assert.ok(s.months.every((m) => m.future === false && m.current === false));
});

test('81.5 computeStatsModel: years 按年份降序聚合、空库含当前年；空模型 years 为空', () => {
  const notes = [
    { relPath: 'a.md', mtimeSec: mtimeAt(2025, 5, 1), charCount: 5 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 5 }
  ];
  const model = computeStatsModel(notes, TODAY, false);
  assert.deepEqual(plain(model.years.map((y) => y.year)), [2026, 2025]);
  assert.equal(model.years[0].months.length, 12);
  assert.equal(model.years[0].months[10].current, true); // 当前年 11 月标 current

  const empty = computeStatsModel([], TODAY, false);
  assert.deepEqual(plain(empty.years.map((y) => y.year)), [2026]); // 当前年即使无写作也在列

  assert.deepEqual(plain(emptyStatsModel().years), []);
});

/* ------------------------- 81.7 源级：独立页形态 ------------------------- */

const page = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsPage.ets', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const tokens = readSourceFile(
  new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const html = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

test('81.7 源级：三视角互斥、切换回内容顶部、页面 id', () => {
  assert.match(page, /\.id\('stats-page'\)/);
  assert.match(page, /this\.TabButton\('overview'\)/);
  assert.match(page, /this\.TabButton\('annual'\)/);
  assert.match(page, /this\.TabButton\('achievements'\)/);
  assert.match(page, /\.id\('stats-tab-' \+ tab\)/);
  // 切视角互斥 + 回顶：同一 Scroller 复位
  assert.match(page, /private switchTab\(tab: string\): void \{/);
  assert.match(page, /this\.scroller\.scrollTo\(\{ xOffset: 0, yOffset: 0 \}\);/);
  // 单屏纵向堆叠 / 宽屏并排两个分支都在
  assert.match(page, /if \(this\.singleScreen\) \{/);
});

test('81.5 源级：年份选择（数据年份∪当前年，选中回退首项）', () => {
  assert.match(page, /\.id\('stats-year-select'\)/);
  assert.match(page, /private currentYearSummary\(\): VaultStatsYearSummary \| null \{/);
  assert.match(page, /private yearOptions\(\): SelectOption\[\] \{/);
  // summary 为空给空态文案，不给部分值
  assert.match(page, /'暂无年度数据。'/);
});

test('81.6 源级：年度脚注删演示句、保留口径警示；月柱按活跃天数比例', () => {
  assert.match(page, /不代表当年新增字数或完整写作历史。成就仍按当前库累计口径展示。/);
  assert.doesNotMatch(page, /演示/);
  assert.match(page, /柱高按当月活跃天数占日历天数的比例显示；未来月份留空。/);
  assert.match(page, /private monthFillHeight\(bar: VaultStatsMonthBar, year: number\): number \{/);
  assert.match(page, /daysInMonthOf\(year, bar\.month\)/);
});

test('81.3 源级：成就三态（已获得 / 即将达成唯一 / 未解锁），状态不只靠颜色', () => {
  assert.match(page, /'已获得'/);
  assert.match(page, /'即将达成'/);
  assert.match(page, /'未解锁'/);
  assert.match(page, /isNext: start \+ col === nextBadgeIndexOf\(this\.model\.badges\)/);
  assert.match(page, /this\.earnedCount\(\)\.toString\(\)/);
});

test('81.7 源级：Index 独立页接线（打开重扫、返回还原视图与焦点、标题）', () => {
  // 打开时若不在扫描中重扫一次，保证数字新鲜
  assert.match(index, /if \(!this\.vaultStatsScanning\) \{\s*this\.vaultStatsScanning = true;/);
  assert.match(index, /scanFailed: this\.vaultStatsFailed,/);
  assert.match(index, /scanning: this\.vaultStatsScanning,/);
  assert.match(index, /singleScreen: this\.isSingleScreenLayout\(\),/);
  assert.match(index, /windowWidthVp: this\.windowWidthVp/);
  // 返回视图 + 焦点返还
  assert.match(index, /this\.statsReturnView = this\.topView === 'note' \? 'note' : this\.topView;/);
  assert.match(index, /} else if \(this\.topView === 'stats'\) \{\s*this\.returnFromVaultStats\(\);/);
  // 顶栏标题与 Agent 入口
  assert.match(index, /return '写作统计';/);
  assert.match(index, /void this\.openVaultStats\('agent', 'agent-stats-streak-chip'\);/);
});

test('81.7 源级：导航条沉浸（滚动容器延伸 + 末条让位）', () => {
  assert.match(page, /@StorageProp\('navIndicatorHeightPx'\) navIndicatorHeightPx: number = 0;/);
  assert.match(page, /px2vp\(Math\.max\(0, this\.navIndicatorHeightPx\)\)/);
  assert.match(page,
    /\.expandSafeArea\(\[SafeAreaType\.SYSTEM\], \[SafeAreaEdge\.BOTTOM\]\)/);
  assert.match(page, /bottom: Space\.s8 \+ this\.navClearanceVp\(\)/);
});

test('81.7 源级：失败只给安全文案、不出部分值（52.2）', () => {
  assert.match(page, /if \(this\.scanFailed\) \{/);
  assert.match(page, /this\.FailureCard\(\)/);
  assert.match(page, /'统计暂不可用'/);
  assert.match(page, /'读取当前知识库失败，请稍后重试。'/);
});

/* ------------------------- token / 原型对齐 ------------------------- */

test('81.1–81.7 token 对齐：--stats-* 五值与 Tokens.ets 一致', () => {
  assert.match(html, /--stats-content-width:1080px/);
  assert.match(tokens, /static readonly statsPageMaxW: number = 1080;/);
  assert.match(html, /--stats-number:76px/);
  assert.match(tokens, /static readonly statsNumber: number = 76;/);
  assert.match(html, /--stats-medal:64px/);
  assert.match(tokens, /static readonly statsMedalMark: number = 64;/);
  assert.match(html, /--stats-chart:144px/);
  assert.match(tokens, /static readonly statsMonthTrackH: number = 144;/);
  assert.match(html, /--stats-radius:24px/);
  assert.match(tokens, /static readonly statsRadius: number = 24;/);
  assert.match(page, /constraintSize\(\{ maxWidth: Size\.statsPageMaxW \}\)/);
  assert.match(page, /\.fontSize\(Size\.statsNumber\)/);
  assert.match(page, /Size\.statsMedalMark/);
  assert.match(page, /Size\.statsMonthTrackH/);
  assert.match(page, /\.borderRadius\(Size\.statsRadius\)/);
});

test('81.5 / 81.6 原型对齐：年度回顾结构与脚注（原型含演示前缀，原生删）', () => {
  assert.match(html, /<select id="statsYear"><\/select>/);
  assert.match(html, /<h3>每月写作足迹<\/h3>/);
  assert.match(html, /柱高按当月活跃天数占日历天数的比例显示；未来月份留空。/);
  // 原型是演示夹具：脚注带「年度回顾为交互演示」前缀；原生为真实口径，删除该句
  assert.match(html, /年度回顾为交互演示。正式统计按文件修改时间归日/);
  assert.match(html, /成就仍按当前库累计口径展示。/);
});

test('81.7 原型对齐：三视角标签与文案一致', () => {
  assert.match(html, /id="statsOverviewTab"[^>]*>概览</);
  assert.match(html, /id="statsAnnualTab"[^>]*>年度回顾</);
  assert.match(html, /id="statsAchievementsTab"[^>]*>成就</);
  assert.match(html, /每一天，都算数/);
  assert.match(html, /<h3 id="statsHeatTitle">近 12 周<\/h3>/);
  assert.match(page, /'每一天，都算数'/);
  assert.match(page, /'把日常落笔，连成一年的轨迹'/);
  assert.match(page, /'从第一次落笔，到让写作成为习惯'/);
});

/* ------------------------- 红线 ------------------------- */

test('81.7 红线：统计源不埋点、不打日志（51.6 / 52.4）', () => {
  for (const src of [service, page]) {
    assert.ok(!src.includes('hiAppEvent'), '统计源出现 hiAppEvent');
    assert.ok(!src.includes('hilog'), '统计源出现 hilog');
    assert.ok(!src.includes('PerformanceAnalysisKit'), '统计源出现 PerformanceAnalysisKit');
  }
});
