/**
 * VaultStatsService.ets —— 统计与成就面板的计算与扫描（v1.52）
 *
 * 口径真源：docs/releases/v1.51/需求文档.md §2（本文件不定义口径，只实现）：
 *  - 按当前库统计；只统计未删除笔记（回收站在库外 filesDir/trash，allNotes 天然不计）；
 *  - 总字数 = 各笔记源码文本去掉空白字符后的字符数总和；
 *  - 活跃日 = 当日至少一篇笔记 mtime 落在该日历日（本地时区，VaultFileStat.mtimeSec 单位秒）；
 *  - 连续写作天数 = 截至今天逐日往前数的连续活跃日；今天无修改从昨天起算；
 *  - 累计写作天数 = 有活跃记录的日历日总数（去重）；
 *  - 近 12 周热力图 84 格：行 = 周（最老在上）、列 = 星期一至日，档位 0 / 1 / 2–3 / ≥4；
 *  - 徽章 8 枚里程碑，达成态与进度态按当前值实时计算。
 *
 * 分层：纯计算（本文件「纯计算区」，不依赖 ArkUI / AbilityKit，Node 契约测试直接切片跑）
 * 与扫描（async、分块让出事件循环，见类 VaultStatsService）。
 *
 * 红线（v1.51 §51.6 / v1.52 §52.4）：统计值只本地计算与展示；
 * 本文件不引埋点 / 日志 Kit、不上报，测试锁住（见 tools/tests/test_vault_stats.mjs）。
 */
import { VaultAccess } from './VaultAccess';

/** 单条笔记的统计输入（扫描层产出，纯计算层只认这个形状）。 */
export interface VaultStatsNoteInput {
  relPath: string;
  mtimeSec: number;
  /** 源码文本去掉空白字符后的字符数。 */
  charCount: number;
}

/** 热力图单格。level：0 空 / 1 一篇 / 2 两到三篇 / 3 四篇及以上。 */
export interface VaultStatsHeatCell {
  dayLabel: string;
  count: number;
  level: number;
  future: boolean;
}

/** 热力图一行（一周）：monthLabel 同月不重复（延续上一行的月份留空）。 */
export interface VaultStatsWeek {
  monthLabel: string;
  cells: VaultStatsHeatCell[];
}

export interface VaultStatsBadge {
  name: string;
  desc: string;
  /** 达成态「已达成 · desc」；进度态「min(value,goal) / goal · desc」。 */
  progressLabel: string;
  earned: boolean;
  /** v1.58 58.5 / 58.8：选择「下一个成就」与画圆环只扩展展示字段，口径不变。 */
  value: number;
  goal: number;
  /** 'count' 笔记 / 'words' 字数 / 'streak' 连写 / 'days' 累计活跃日。 */
  kind: string;
}

export interface VaultStatsModel {
  noteCount: number;
  wordCount: number;
  streakDays: number;
  totalDays: number;
  weeks: VaultStatsWeek[];
  badges: VaultStatsBadge[];
  /** 库快照被截断时如实标记，页面据此提示「基于已扫描部分」。 */
  truncated: boolean;
}

export interface VaultStatsScanOutcome {
  model: VaultStatsModel | null;
  failed: boolean;
}

/* ------------------------------------------------------------------------- */
/* 纯计算区（Node 契约测试按本区注释切片；勿引入 ArkUI / AbilityKit 依赖）      */
/* ------------------------------------------------------------------------- */

/** 每批让出事件循环前最多处理的笔记数。 */
const VAULT_STATS_SCAN_CHUNK: number = 24;
/** 热力图周数（12 周 × 7 天 = 84 格）。 */
const VAULT_STATS_HEAT_WEEKS: number = 12;

/** JS \s 字符集的字符码判定（对齐原型 text.replace(/\s+/g, '') 的口径）。 */
function isWhitespaceCode(code: number): boolean {
  if (code === 32 || (code >= 9 && code <= 13)) {
    return true;
  }
  if (code === 0x00a0 || code === 0x1680) {
    return true;
  }
  if (code >= 0x2000 && code <= 0x200a) {
    return true;
  }
  if (code === 0x2028 || code === 0x2029 || code === 0x202f || code === 0x205f) {
    return true;
  }
  if (code === 0x3000 || code === 0xfeff) {
    return true;
  }
  return false;
}

/** 源码文本去掉空白字符后的字符数（v1.51 §51.2「总字数」的单篇口径）。 */
export function countNonWhitespace(text: string): number {
  let total: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    if (!isWhitespaceCode(text.charCodeAt(i))) {
      total++;
    }
  }
  return total;
}

/** 本地时区的日历日键（yyyymmdd），同一天即同键。 */
function dayKeyOf(date: Date): number {
  return date.getFullYear() * 10000 + (date.getMonth() + 1) * 100 + date.getDate();
}

/** 当天的零点 Date（本地时区；用于日期加减不跨时分秒）。 */
function midnightOf(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

/** 从 date 的零点起平移 days 天（正负皆可；Date 加减自带月/年进位）。 */
function shiftDays(date: Date, days: number): Date {
  const shifted: Date = midnightOf(date);
  shifted.setDate(shifted.getDate() + days);
  return shifted;
}

/** mtime → 日历日 → 当日笔记数（活跃日集合的计数形态）。无效 mtime 跳过不计。 */
export function countsByDay(notes: VaultStatsNoteInput[]): Map<number, number> {
  const counts: Map<number, number> = new Map<number, number>();
  for (let i: number = 0; i < notes.length; i++) {
    const date: Date = new Date(notes[i].mtimeSec * 1000);
    if (Number.isNaN(date.getTime())) {
      continue;
    }
    const key: number = dayKeyOf(date);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

/**
 * 连续写作天数（v1.51 §51.2）：截至今天逐日往前数的连续活跃日；
 * 今天无修改从昨天起算；今天和昨天都无修改为 0。
 */
export function streakDaysOf(counts: Map<number, number>, today: Date): number {
  if (counts.size === 0) {
    return 0;
  }
  let cursor: Date = midnightOf(today);
  if (!counts.has(dayKeyOf(cursor))) {
    cursor = shiftDays(today, -1);
    if (!counts.has(dayKeyOf(cursor))) {
      return 0;
    }
  }
  let streak: number = 0;
  while (counts.has(dayKeyOf(cursor))) {
    streak++;
    // 护栏：坏数据（如未来一整年的 mtime 逐日都有）不无限循环。
    if (streak > 3660) {
      break;
    }
    cursor = shiftDays(cursor, -1);
  }
  return streak;
}

/** 热力图档位：0 篇 0 / 1 篇 1 / 2–3 篇 2 / ≥4 篇 3。 */
export function heatLevelOf(count: number): number {
  if (count >= 4) {
    return 3;
  }
  if (count >= 2) {
    return 2;
  }
  if (count >= 1) {
    return 1;
  }
  return 0;
}

/**
 * 近 12 周热力图（v1.51 §51.3）：行 = 周（最老在上、当前周最下），列 = 星期一至日；
 * 未来日期按 0 篇计并标记 future；月份刻度同月不重复、首行必显。
 */
export function heatWeeksOf(counts: Map<number, number>, today: Date): VaultStatsWeek[] {
  const weeks: VaultStatsWeek[] = [];
  const dowMon0: number = (today.getDay() + 6) % 7;
  const monday: Date = shiftDays(today, -dowMon0);
  let lastMonth: number = -1;
  for (let w: number = VAULT_STATS_HEAT_WEEKS - 1; w >= 0; w--) {
    const weekStart: Date = shiftDays(monday, -w * 7);
    const month: number = weekStart.getMonth() + 1;
    const cells: VaultStatsHeatCell[] = [];
    for (let d: number = 0; d < 7; d++) {
      const date: Date = shiftDays(weekStart, d);
      const key: number = dayKeyOf(date);
      const future: boolean = key > dayKeyOf(midnightOf(today));
      const count: number = future ? 0 : (counts.get(key) ?? 0);
      const cell: VaultStatsHeatCell = {
        dayLabel: (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日',
        count: count,
        level: heatLevelOf(count),
        future: future
      };
      cells.push(cell);
    }
    const week: VaultStatsWeek = {
      monthLabel: month !== lastMonth ? month.toString() + '月' : '',
      cells: cells
    };
    weeks.push(week);
    lastMonth = month;
  }
  return weeks;
}

/** 徽章里程碑表（v1.51 §51.4 首发 8 枚；名称与文案照原型，不改口径）。 */
export function badgesOf(noteCount: number, wordCount: number, streakDays: number,
  totalDays: number): VaultStatsBadge[] {
  const out: VaultStatsBadge[] = [];
  const goals: number[] = [1, 10, 100];
  for (let i: number = 0; i < goals.length; i++) {
    const goal: number = goals[i];
    const name: string = goal === 1 ? '初稿' : (goal === 10 ? '十篇' : '百篇');
    const desc: string = goal === 1 ? '写下第一篇笔记'
      : ('累计 ' + goal.toString() + ' 篇笔记');
    out.push(buildBadge(name, desc, noteCount, goal, 'count'));
  }
  const wordGoals: number[] = [10000, 100000];
  const wordNames: string[] = ['万字', '十万字'];
  const wordDescs: string[] = ['累计 10,000 字', '累计 100,000 字'];
  for (let i: number = 0; i < wordGoals.length; i++) {
    out.push(buildBadge(wordNames[i], wordDescs[i], wordCount, wordGoals[i], 'words'));
  }
  const streakGoals: number[] = [7, 30];
  const streakNames: string[] = ['七日连写', '三十日连写'];
  for (let i: number = 0; i < streakGoals.length; i++) {
    const desc: string = '连续 ' + streakGoals[i].toString() + ' 天有修改';
    out.push(buildBadge(streakNames[i], desc, streakDays, streakGoals[i], 'streak'));
  }
  out.push(buildBadge('百日坚持', '累计 100 个活跃日', totalDays, 100, 'days'));
  return out;
}

function buildBadge(name: string, desc: string, value: number, goal: number,
  kind: string): VaultStatsBadge {
  const earned: boolean = value >= goal;
  const progressLabel: string = earned
    ? '已达成 · ' + desc
    : Math.min(value, goal).toString() + ' / ' + goal.toString() + ' · ' + desc;
  const badge: VaultStatsBadge = {
    name: name,
    desc: desc,
    progressLabel: progressLabel,
    earned: earned,
    value: value,
    goal: goal,
    kind: kind
  };
  return badge;
}

/**
 * v1.58 58.8：「下一个成就」= 未获得徽章里进度比例最高的一枚（并列取靠前）。
 * 全部达成返回 -1；只挑选展示位，不改变任何徽章的达成口径。
 */
export function nextBadgeIndexOf(badges: VaultStatsBadge[]): number {
  let best: number = -1;
  let bestRatio: number = -1;
  for (let i: number = 0; i < badges.length; i++) {
    const badge: VaultStatsBadge = badges[i];
    if (badge.earned || badge.goal <= 0) {
      continue;
    }
    const ratio: number = Math.min(1, badge.value / badge.goal);
    if (ratio > bestRatio) {
      bestRatio = ratio;
      best = i;
    }
  }
  return best;
}

/** v1.58 58.5：主视觉「下一步」提示，与 58.8 选出的「下一个」保持同一枚。 */
export function nextAchievementHint(badges: VaultStatsBadge[], streakDays: number): string {
  const index: number = nextBadgeIndexOf(badges);
  if (index < 0) {
    return '所有成就都已获得';
  }
  const badge: VaultStatsBadge = badges[index];
  if (badge.kind === 'streak' && badge.goal - streakDays <= 3) {
    return '再写 ' + (badge.goal - streakDays).toString() + ' 天，解锁「' + badge.name + '」';
  }
  return '下一个成就「' + badge.name + '」：' + badge.desc;
}

/**
 * v1.58 58.2 / 58.5：本周（最末一周）周一至周日是否有写作；未来日一律 false。
 * 热图 weeks 仍是 12 行 × 7 列（口径不变），这里只取最后一行给连写条 / 主视觉圆点。
 */
export function currentWeekFlagsOf(weeks: VaultStatsWeek[]): boolean[] {
  const flags: boolean[] = [];
  const cells: VaultStatsHeatCell[] = weeks.length > 0 ? weeks[weeks.length - 1].cells : [];
  for (let d: number = 0; d < 7; d++) {
    flags.push(d < cells.length && !cells[d].future && cells[d].count > 0);
  }
  return flags;
}

/** 由扫描输入聚合出完整统计模型（纯计算入口；today 传当前时间）。 */
export function computeStatsModel(notes: VaultStatsNoteInput[], today: Date,
  truncated: boolean): VaultStatsModel {
  const counts: Map<number, number> = countsByDay(notes);
  let wordCount: number = 0;
  for (let i: number = 0; i < notes.length; i++) {
    wordCount += notes[i].charCount;
  }
  const streak: number = streakDaysOf(counts, today);
  const model: VaultStatsModel = {
    noteCount: notes.length,
    wordCount: wordCount,
    streakDays: streak,
    totalDays: counts.size,
    weeks: heatWeeksOf(counts, today),
    badges: badgesOf(notes.length, wordCount, streak, counts.size),
    truncated: truncated
  };
  return model;
}

/** 空模型（进入统计页 / 开始新一次扫描时的占位值；非 null，避免视图层判空）。 */
export function emptyStatsModel(): VaultStatsModel {
  const model: VaultStatsModel = {
    noteCount: 0,
    wordCount: 0,
    streakDays: 0,
    totalDays: 0,
    weeks: [],
    badges: [],
    truncated: false
  };
  return model;
}

/* ------------------------------------------------------------------------- */
/* 扫描层（async、分块让出事件循环——v1.51 §51.6「不得阻塞 UI」）               */
/* ------------------------------------------------------------------------- */

/**
 * 统计扫描：快照失败 → failed（页面显示安全失败文案，不给部分值）；
 * 单篇读失败 → 该篇字数记 0、仍计数（不因单文件失败拒绝整个统计）。
 */
export class VaultStatsService {
  static async scanAccess(access: VaultAccess, nowMs: number): Promise<VaultStatsScanOutcome> {
    let truncated: boolean = false;
    try {
      const report = access.snapshotReport();
      truncated = report.truncated;
      if (report.failed) {
        const failedOutcome: VaultStatsScanOutcome = { model: null, failed: true };
        return failedOutcome;
      }
      const notePaths: string[] = access.allNotes();
      const notes: VaultStatsNoteInput[] = [];
      for (let i: number = 0; i < notePaths.length; i++) {
        const relPath: string = notePaths[i];
        const stat = access.stat(relPath);
        if (stat === null) {
          continue;
        }
        let charCount: number = 0;
        try {
          charCount = countNonWhitespace(access.readText(relPath));
        } catch (_error) {
          charCount = 0;
        }
        const input: VaultStatsNoteInput = {
          relPath: relPath,
          mtimeSec: stat.mtimeSec,
          charCount: charCount
        };
        notes.push(input);
        if ((i + 1) % VAULT_STATS_SCAN_CHUNK === 0) {
          await new Promise<void>((resolve: () => void) => {
            setTimeout(resolve, 0);
          });
        }
      }
      const model: VaultStatsModel = computeStatsModel(notes, new Date(nowMs), truncated);
      const outcome: VaultStatsScanOutcome = { model: model, failed: false };
      return outcome;
    } catch (_error) {
      const failedOutcome: VaultStatsScanOutcome = { model: null, failed: true };
      return failedOutcome;
    }
  }
}
