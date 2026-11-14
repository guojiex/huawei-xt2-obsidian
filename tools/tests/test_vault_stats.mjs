/*
 * v1.52 统计与成就面板 —— 契约测试。
 *
 * 覆盖两层：
 *  1. 纯逻辑：VaultStatsService 的口径函数（v1.51 §2）——字数去空白、活跃日聚合、
 *     连写三分支（今天有 / 今天无昨天有 / 断档）、累计去重、热力图分档与未来日 /
 *     月份刻度、徽章达成与进度边界（value == goal）、computeStatsModel 聚合、
 *     扫描分块与失败语义（快照失败 / 单篇读失败记 0 不中断）。
 *  2. 源级断言（v1.58 58.11 更新）：Index 弹窗接线 / 扫描回写 / 焦点返还、
 *     侧栏连写条与单屏菜单入口、库菜单无统计入口、弹窗内容形态、Icons flame / medal、
 *     红线（统计源文件无 hiAppEvent / hilog / PerformanceAnalysisKit）。
 *  注：58.11 要求口径用例不变且通过；v1.58 新增纯函数与原型定向测试另见
 *      test_v1_58_stats_redesign.mjs。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultStatsService.ets', import.meta.url));

// 纯计算区 + 扫描层一起切片（切片从首个接口声明到文件尾，import 区天然排除）
const start = source.indexOf('export interface VaultStatsNoteInput');
assert.ok(start >= 0, '找不到 VaultStatsService 纯计算区起点');

const code = transformSync(source.slice(start) +
  '\nmodule.exports = { countNonWhitespace, countsByDay, streakDaysOf, heatLevelOf,' +
  ' heatWeeksOf, badgesOf, computeStatsModel, emptyStatsModel, VaultStatsService };',
{ loader: 'ts', format: 'cjs' }).code;
const context = vm.createContext({
  module: { exports: {} },
  console,
  setTimeout: (fn) => fn()
});
vm.runInContext(code, context);
const {
  countNonWhitespace, countsByDay, streakDaysOf, heatLevelOf,
  heatWeeksOf, badgesOf, computeStatsModel, emptyStatsModel, VaultStatsService
} = context.module.exports;

/** 本地时区某天中午的 Date（避开日界附近的实现细节）。 */
const day = (y, m, d, h = 12) => new Date(y, m, d, h, 0, 0);
/** 本地某天的 mtimeSec（VaultFileStat 单位：秒）。 */
const mtimeAt = (y, m, d, h = 12) => Math.floor(day(y, m, d, h).getTime() / 1000);
/** vm 跨 realm 的数组 / 对象过 JSON 化再 deepEqual（原型不同会被 strictEqual 拒）。 */
const plain = (value) => JSON.parse(JSON.stringify(value));

// 2026-11-10（周二）：本周周一 = 11-09；热力图 12 行起点 = 08-24（周一）
const TODAY = day(2026, 10, 10);

/* ------------------------- 字数（51.2 总字数） ------------------------- */

test('countNonWhitespace: 空白字符集对齐 JS \\s（空格/制表/换行/全角空格/NBSP/BOM）', () => {
  assert.equal(countNonWhitespace('你 好\n\t\r世 界'), 4);
  assert.equal(countNonWhitespace('\u3000\u00a0\ufeff'), 0);
  assert.equal(countNonWhitespace('a\u2028b\u2029c\u2003d'), 4);
  assert.equal(countNonWhitespace('hello world'), 10);
  assert.equal(countNonWhitespace(''), 0);
});

/* --------------------- 活跃日聚合与连写 / 累计（51.2） --------------------- */

test('countsByDay: 同日聚合、跨日分键、无效 mtime 跳过', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 10, 0), charCount: 1 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 10, 23), charCount: 1 },
    { relPath: 'c.md', mtimeSec: mtimeAt(2026, 10, 8), charCount: 1 },
    { relPath: 'bad.md', mtimeSec: Number.NaN, charCount: 1 }
  ]);
  assert.equal(counts.size, 2); // 11-10 去重 + 11-08；NaN 不进集合
  const sum = [...counts.values()].reduce((a, b) => a + b, 0);
  assert.equal(sum, 3);
});

test('streakDaysOf: 今天有修改 → 从今天起算', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 0 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 0 }
  ]);
  assert.equal(streakDaysOf(counts, TODAY), 2);
});

test('streakDaysOf: 今天无修改、昨天有 → 从昨天起算', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 0 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 8), charCount: 0 }
  ]);
  assert.equal(streakDaysOf(counts, TODAY), 2);
});

test('streakDaysOf: 今天和昨天都无修改 → 0（即使更早连续）', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 8), charCount: 0 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 7), charCount: 0 }
  ]);
  assert.equal(streakDaysOf(counts, TODAY), 0);
});

test('streakDaysOf: 昨天断档则连写截断在今天（连续段被缺口打断）', () => {
  const counts = countsByDay([
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 0 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 8), charCount: 0 }
  ]);
  assert.equal(streakDaysOf(counts, TODAY), 1);
});

test('streakDaysOf: 五天连写到今天 = 5；空集合 = 0', () => {
  const notes = [6, 7, 8, 9, 10].map((d) => (
    { relPath: 'n' + d + '.md', mtimeSec: mtimeAt(2026, 10, d), charCount: 0 }));
  assert.equal(streakDaysOf(countsByDay(notes), TODAY), 5);
  assert.equal(streakDaysOf(new Map(), TODAY), 0);
});

/* --------------------- 热力图分档与结构（51.3） --------------------- */

test('heatLevelOf: 档位边界 0/1/2–3/≥4', () => {
  assert.equal(heatLevelOf(0), 0);
  assert.equal(heatLevelOf(1), 1);
  assert.equal(heatLevelOf(2), 2);
  assert.equal(heatLevelOf(3), 2);
  assert.equal(heatLevelOf(4), 3);
  assert.equal(heatLevelOf(7), 3);
});

test('heatWeeksOf: 12 行 × 7 列 = 84 格，最老周在上、行起点为周一', () => {
  const weeks = heatWeeksOf(new Map(), TODAY);
  assert.equal(weeks.length, 12);
  const total = weeks.reduce((a, w) => a + w.cells.length, 0);
  assert.equal(total, 84);
  assert.equal(weeks[0].cells[0].dayLabel, '8月24日'); // 最老一行从周一 08-24 起
  assert.equal(weeks[11].cells[0].dayLabel, '11月9日'); // 当前周从周一 11-09 起
});

test('heatWeeksOf: 月份刻度同月不重复、首月必显', () => {
  const weeks = heatWeeksOf(new Map(), TODAY);
  assert.deepEqual(plain(weeks.map((w) => w.monthLabel)),
    ['8月', '', '9月', '', '', '', '10月', '', '', '', '11月', '']);
});

test('heatWeeksOf: 当日计数入格、今天之后标记未到且计 0', () => {
  const counts = countsByDay([
    ...[1, 2, 3, 4].map((i) => (
      { relPath: 'x' + i + '.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 0 })),
    { relPath: 'y.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 0 }
  ]);
  const weeks = heatWeeksOf(counts, TODAY);
  const last = weeks[11].cells;
  assert.equal(last[0].count, 4); // 11-09（周一）4 篇
  assert.equal(last[0].level, 3);
  assert.equal(last[0].future, false);
  assert.equal(last[1].count, 1); // 11-10（今天）
  assert.equal(last[1].level, 1);
  assert.equal(last[1].future, false);
  for (let i = 2; i < 7; i++) {
    assert.equal(last[i].future, true, 'cell ' + i + ' 应标记未到');
    assert.equal(last[i].count, 0);
    assert.equal(last[i].level, 0);
  }
});

/* --------------------- 徽章达成与进度边界（51.4） --------------------- */

test('badgesOf: 首发 8 枚、名称与顺序照原型', () => {
  const names = badgesOf(0, 0, 0, 0).map((b) => b.name);
  assert.deepEqual(plain(names),
    ['初稿', '十篇', '百篇', '万字', '十万字', '七日连写', '三十日连写', '百日坚持']);
});

test('badgesOf: value == goal 即达成（边界含等号），进度态 min/goal', () => {
  const badges = badgesOf(1, 0, 0, 0);
  assert.equal(badges[0].earned, true); // 初稿 1/1
  assert.equal(badges[0].progressLabel, '已达成 · 写下第一篇笔记');
  assert.equal(badges[1].earned, false);
  assert.equal(badges[1].progressLabel, '1 / 10 · 累计 10 篇笔记');
});

test('badgesOf: 进度不超过 goal（min 截断）、四类口径各管各的', () => {
  const badges = badgesOf(10, 10000, 7, 3);
  assert.equal(badges[1].earned, true); // 十篇 10/10
  assert.equal(badges[2].earned, false); // 百篇按笔记数
  assert.equal(badges[2].progressLabel, '10 / 100 · 累计 100 篇笔记');
  assert.equal(badges[3].earned, true); // 万字 10000/10000（字数口径）
  assert.equal(badges[5].earned, true); // 七日连写 7/7（连写口径）
  assert.equal(badges[6].earned, false);
  assert.equal(badges[6].progressLabel, '7 / 30 · 连续 30 天有修改');
  assert.equal(badges[7].earned, false); // 百日坚持按累计活跃日
  assert.equal(badges[7].progressLabel, '3 / 100 · 累计 100 个活跃日');
});

test('badgesOf: 全达成态（100 篇 / 十万字 / 30 连写 / 100 活跃日）', () => {
  const badges = badgesOf(100, 100000, 30, 100);
  assert.ok(badges.every((b) => b.earned));
  assert.ok(badges.every((b) => b.progressLabel.startsWith('已达成 · ')));
});

/* --------------------- computeStatsModel / 空模型 --------------------- */

test('computeStatsModel: 聚合笔记数与字数、truncated 透传、空库全零', () => {
  const notes = [
    { relPath: 'a.md', mtimeSec: mtimeAt(2026, 10, 10), charCount: 12 },
    { relPath: 'b.md', mtimeSec: mtimeAt(2026, 10, 9), charCount: 34 }
  ];
  const model = computeStatsModel(notes, TODAY, true);
  assert.equal(model.noteCount, 2);
  assert.equal(model.wordCount, 46);
  assert.equal(model.streakDays, 2);
  assert.equal(model.totalDays, 2);
  assert.equal(model.weeks.length, 12);
  assert.equal(model.badges.length, 8);
  assert.equal(model.truncated, true);

  const empty = computeStatsModel([], TODAY, false);
  assert.equal(empty.noteCount, 0);
  assert.equal(empty.wordCount, 0);
  assert.equal(empty.streakDays, 0);
  assert.equal(empty.totalDays, 0);
  assert.equal(empty.truncated, false);
});

test('emptyStatsModel: 零值空集合（非 null，进页占位）', () => {
  const model = emptyStatsModel();
  assert.equal(model.noteCount, 0);
  assert.deepEqual(plain(model.weeks), []);
  assert.deepEqual(plain(model.badges), []);
  assert.equal(model.truncated, false);
});

/* --------------------- 扫描（52.1 分块 + 失败语义） --------------------- */

function accessMock({ paths = [], texts = new Map(), mtimeByPath = new Map(),
  failed = false, truncated = false, readFailPaths = new Set(), statNullPaths = new Set() }) {
  return {
    snapshotReport() {
      return { failed, truncated };
    },
    allNotes() {
      return paths;
    },
    stat(relPath) {
      if (statNullPaths.has(relPath)) {
        return null;
      }
      return { mtimeSec: mtimeByPath.get(relPath) ?? mtimeAt(2026, 10, 10), size: 1 };
    },
    readText(relPath) {
      if (readFailPaths.has(relPath)) {
        throw new Error('read failed');
      }
      return texts.get(relPath) ?? '';
    }
  };
}

test('scanAccess: 快照失败 → failed（model null，不给部分值）', async () => {
  const outcome = await VaultStatsService.scanAccess(
    accessMock({ failed: true, paths: ['a.md'] }), TODAY.getTime());
  assert.equal(outcome.failed, true);
  assert.equal(outcome.model, null);
});

test('scanAccess: 正常路径聚合（字数来自 readText 去空白）', async () => {
  const outcome = await VaultStatsService.scanAccess(accessMock({
    paths: ['a.md', 'b.md'],
    texts: new Map([['a.md', 'hello world'], ['b.md', '你 好']]),
    mtimeByPath: new Map([['a.md', mtimeAt(2026, 10, 10)], ['b.md', mtimeAt(2026, 10, 9)]])
  }), TODAY.getTime());
  assert.equal(outcome.failed, false);
  assert.equal(outcome.model.noteCount, 2);
  assert.equal(outcome.model.wordCount, 12);
  assert.equal(outcome.model.streakDays, 2);
});

test('scanAccess: 单篇读失败字数记 0、不中断；stat 为 null 的跳过不计', async () => {
  const outcome = await VaultStatsService.scanAccess(accessMock({
    paths: ['ok.md', 'bad.md', 'ghost.md'],
    texts: new Map([['ok.md', 'abc'], ['bad.md', '忽略这个']]),
    readFailPaths: new Set(['bad.md']),
    statNullPaths: new Set(['ghost.md'])
  }), TODAY.getTime());
  assert.equal(outcome.failed, false);
  assert.equal(outcome.model.noteCount, 2); // ghost 不计
  assert.equal(outcome.model.wordCount, 3); // bad 记 0
});

test('scanAccess: 超过单块上限（24 篇）分块让出后仍完整统计', async () => {
  const paths = [];
  const texts = new Map();
  for (let i = 0; i < 30; i++) {
    const p = 'note' + i + '.md';
    paths.push(p);
    texts.set(p, 'abcdef'); // 每篇 6 字
  }
  const outcome = await VaultStatsService.scanAccess(
    accessMock({ paths, texts }), TODAY.getTime());
  assert.equal(outcome.model.noteCount, 30);
  assert.equal(outcome.model.wordCount, 180);
});

test('scanAccess: truncated 从快照报告透传到模型', async () => {
  const outcome = await VaultStatsService.scanAccess(accessMock({ truncated: true }),
    TODAY.getTime());
  assert.equal(outcome.model.truncated, true);
});

/* ---------------------------- 源级断言 ---------------------------- */

const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const sidebarSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url));
const agentWorkspaceSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/AgentWorkspace.ets', import.meta.url));
const statsViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsView.ets', import.meta.url));
const statsDialogSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsDialog.ets', import.meta.url));
const streakChipSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultStatsStreakChip.ets', import.meta.url));
const iconsSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));

test('源级：Index 写作统计弹窗接线（58.4 / 58.11：不再是全屏次级页）', () => {
  assert.match(indexSource, /@State vaultStatsModel: VaultStatsModel = emptyStatsModel\(\);/);
  assert.match(indexSource,
    /private async openVaultStats\(fromView: string, focusReturnId: string\): Promise<void>/);
  assert.match(indexSource, /builder: VaultStatsDialog\(\{/);
  assert.match(indexSource, /alignment: sheet \? DialogAlignment\.Bottom : DialogAlignment\.Center/);
  assert.match(indexSource, /private async scanVaultStats\(vaultId: string\): Promise<VaultStatsScanOutcome>/);
  assert.match(indexSource, /private scheduleIdleStatsRefresh\(\): void/);
  assert.match(indexSource, /if \(this\.statsDialogOpen\) \{/);
  assert.doesNotMatch(indexSource, /this\.topView = 'stats';/);
  assert.doesNotMatch(indexSource, /this\.StatsView\(\)/);
  assert.doesNotMatch(indexSource, /return '统计与成就';/);
});

test('源级：过期结果丢弃（回填前校验当前库）', () => {
  assert.match(indexSource, /if \(this\.currentVaultId === vaultId\) \{/);
  assert.match(indexSource, /this\.vaultStatsFailed = outcome\.failed;/);
  assert.match(indexSource, /void this\.scanVaultStats\(this\.currentVaultId\);/);
});

test('源级：双侧栏连写条 + 单屏菜单入口（58.2 / 58.3）', () => {
  assert.match(indexSource,
    /void this\.openVaultStats\('note', 'vault-stats-streak-chip'\);/);
  assert.match(indexSource, /void this\.openVaultStats\('agent', 'agent-stats-streak-chip'\);/);
  assert.match(indexSource, /void this\.openVaultStats\('note', 'workspace-more-button'\);/);
  assert.match(indexSource, /MobileMoreStatsItem\(\)/);
  assert.match(sidebarSource, /VaultStatsStreakChip\(\{/);
  assert.match(sidebarSource, /statsStreakDays: number = 0;/);
  assert.match(sidebarSource, /showDots: this\.sidebarW <= 0 \|\| this\.sidebarW >= Size\.statsDotsMinSidebarW/);
  assert.match(agentWorkspaceSource, /statsChipId: 'agent-stats-streak-chip'/);
  assert.match(agentWorkspaceSource, /onOpenStats: \(\): void => \{ this\.onOpenStats\(\); \},/);
});

test('源级：库菜单无统计入口（58.1，恢复「管理库 / 导入库」两行动作）', () => {
  assert.ok(!sidebarSource.includes('统计与成就…'), '库菜单不得再有统计入口');
  assert.ok(sidebarSource.indexOf('管理库…') >= 0 && sidebarSource.indexOf('＋ 导入库…') >= 0);
  assert.doesNotMatch(sidebarSource, /this\.menuOpen = false;\s*this\.onOpenStats\(\);/);
});

test('源级：Icons 注册 flame / medal（防线：不编造图标名）', () => {
  assert.match(iconsSource, /const P_MEDAL: string =/);
  assert.match(iconsSource, /name === 'medal'/);
  assert.match(iconsSource, /const P_FLAME: string =/);
  assert.match(iconsSource, /name === 'flame'/);
});

test('源级：弹窗外壳与内容形态（58.4–58.9 / 58.11）', () => {
  assert.match(statsDialogSource, /@CustomDialog/);
  assert.match(statsDialogSource, /UtilityDialogShell\(\{/);
  assert.match(statsDialogSource, /preferredWidthVp: Size\.statsDialogW/);
  assert.match(statsDialogSource, /aboutToAppear\(\): void \{\s*void this\.loadStats\(\);/);
  assert.match(statsDialogSource, /onRequestScan/);
  assert.match(statsViewSource, /this\.HeroSection\(\)/);
  assert.match(statsViewSource, /this\.NumberRow\(\)/);
  assert.match(statsViewSource, /7 行 12 列共 84 格/);
  assert.match(statsViewSource, /nextBadgeIndexOf\(this\.model\.badges\)/);
  assert.match(statsViewSource, /ProgressType\.Ring/);
  assert.match(statsViewSource, /'统计暂不可用'/);
  assert.match(statsViewSource, /'读取当前知识库失败，请稍后重试。'/);
  assert.match(statsViewSource, /正在统计…/);
  assert.match(statsViewSource, /本次统计基于已扫描的部分/);
  assert.match(statsViewSource, /统计只按当前知识库、只在本机计算，不用于埋点或上报。/);
  assert.match(streakChipSource, /'vault-stats-streak-chip'/);
  assert.match(streakChipSource, /'今天还没写'/);
});

test('源级：红线——统计源文件不埋点、不打日志（51.6 / 52.4）', () => {
  for (const src of [source, statsViewSource, statsDialogSource, streakChipSource]) {
    assert.ok(!src.includes('hiAppEvent'), '统计源出现 hiAppEvent');
    assert.ok(!src.includes('hilog'), '统计源出现 hilog');
    assert.ok(!src.includes('PerformanceAnalysisKit'), '统计源出现 PerformanceAnalysisKit');
  }
});
