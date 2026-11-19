/**
 * VaultStatsPage.ets —— 写作统计独立页面（v1.81 原生迁移，原型 #statsPage）
 *
 * 口径真源：docs/releases/v1.51/需求文档.md §2（统计）+ v1.81 §2（年度口径与边界）；
 * 扫描层 VaultStatsService 不动，本文件只画页面。
 * 形态（81.7）：独立页面取代 v1.58 半模态 / 弹窗——单屏占满应用、双 / 三屏占满工作区，
 * 无遮罩、无关闭叉号；顶部返回由 Appbar 承担。三个同级视角互斥：
 *   概览（81.1 / 81.2：暖色主卡大数字 + 三项辅助数字 + 近 12 周热力图）
 *   年度回顾（81.5 / 81.6：年份选择 + 活跃天数 / 年内最长连写 / 活跃月份 + 12 个月柱）
 *   成就（81.3：八枚徽章收藏，已获得 / 下一个 / 未解锁三态，状态不只靠颜色）。
 * 切换视角回到内容顶部；失败只给安全文案、不给部分值（52.2）。
 *
 * 红线（51.6 / 52.4）：统计值只本地计算与展示；本文件不埋点、不写日志、不上报。
 */
import { VaultStatsModel, VaultStatsWeek, VaultStatsHeatCell, VaultStatsBadge,
  VaultStatsYearSummary, VaultStatsMonthBar, emptyStatsModel, nextBadgeIndexOf,
  nextAchievementHint, currentWeekFlagsOf, daysInMonthOf } from '../model/VaultStatsService';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';

/** 热力图单格：小方格（未来日空心 / 今天描边），悬停或长按把日期与篇数回传给标题行。 */
@Component
struct StatsHeatCellTile {
  @Prop cell: VaultStatsHeatCell = { dayLabel: '', count: 0, level: 0, future: false };
  @Prop cellSize: number = Size.statsHeatCellMin;
  @Prop isToday: boolean = false;
  onHoverLabel: (label: string) => void = (_label: string) => {};

  private cellText(): string {
    return this.cell.dayLabel + (this.cell.future ? ' · 未到' : ' · ' + this.cell.count.toString() + ' 篇');
  }

  private cellOpacity(): number {
    if (this.cell.level >= 3) {
      return 1;
    }
    if (this.cell.level === 2) {
      return 0.58;
    }
    if (this.cell.level === 1) {
      return 0.28;
    }
    return 1;
  }

  build() {
    Column()
      .width(this.cellSize)
      .height(this.cellSize)
      .borderRadius(Radius.chip)
      .backgroundColor(this.cell.level >= 1 && !this.cell.future
        ? $r('app.color.brand') : $r('app.color.bg_navigation'))
      .opacity(this.cellOpacity())
      .border({
        width: this.cell.future || this.isToday ? Size.statsHeatOutline : 0,
        color: this.isToday ? $r('app.color.text_primary') : $r('app.color.line')
      })
      .accessibilityText(this.cellText())
      .onHover((isHover: boolean): void => {
        if (isHover) {
          this.onHoverLabel(this.cellText());
        }
      })
      .gesture(LongPressGesture().onAction((): void => {
        this.onHoverLabel(this.cellText());
      }))
  }
}

/**
 * 成就徽章收藏卡（81.3）：奖章圆形标记 + 状态 + 名称 + 条件 / 进度。
 * 三态：已获得（暖色轻浮雕） / 下一个（品牌蓝圆环，唯一） / 未解锁（灰色内圈线稿）。
 */
@Component
struct StatsMedalCard {
  @Prop badge: VaultStatsBadge = { name: '', desc: '', progressLabel: '', earned: false,
    value: 0, goal: 1, kind: 'count' };
  @Prop isNext: boolean = false;

  private percent(): number {
    if (this.badge.goal <= 0) {
      return 0;
    }
    return Math.round(Math.min(1, this.badge.value / this.badge.goal) * 100);
  }

  private statusText(): string {
    if (this.badge.earned) {
      return '已获得';
    }
    return this.isNext ? '即将达成' : '未解锁';
  }

  private statusColor(): Resource {
    if (this.badge.earned) {
      return $r('app.color.cb_warn');
    }
    return this.isNext ? $r('app.color.brand') : $r('app.color.text_tertiary');
  }

  private nameColor(): Resource {
    return this.badge.earned || this.isNext
      ? $r('app.color.text_primary') : $r('app.color.text_tertiary');
  }

  private subText(): string {
    if (this.badge.earned) {
      return this.badge.desc;
    }
    if (this.isNext) {
      return Math.min(this.badge.value, this.badge.goal).toString() + ' / '
        + this.badge.goal.toString();
    }
    return this.badge.desc;
  }

  /**
   * 细内圈线（原型 .stats-medal-mark::after：inset 8、1px、currentColor 18%）+ 奖章图标。
   * 三态色由调用分支静态传入：全局 @Builder（Icon）按值实参禁 this.（api_notes Z2/L-7）。
   */
  @Builder
  MedalMark(tint: Resource) {
    Column()
      .width(Size.statsMedalMark - Space.s4)
      .height(Size.statsMedalMark - Space.s4)
      .borderRadius(Radius.full)
      .border({ width: 1, color: tint })
      .opacity(0.18)
    Icon('medal', Space.s6, tint)
  }

  private groupLabel(): string {
    return this.badge.name + '，' + (this.badge.earned ? '已获得'
      : '未获得，' + this.badge.desc + (this.isNext ? '，进度 ' + this.percent().toString() + '%' : ''));
  }

  build() {
    Column({ space: Space.s2 }) {
    Stack() {
      if (this.isNext && !this.badge.earned) {
        Progress({ value: this.percent(), total: 100, type: ProgressType.Ring })
          .width(Size.statsMedalMark)
          .height(Size.statsMedalMark)
          .color($r('app.color.brand'))
          .backgroundColor($r('app.color.bg_navigation'))
        Column()
          .width(Size.statsMedalMark - Space.s1)
          .height(Size.statsMedalMark - Space.s1)
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.bg_card'))
        this.MedalMark($r('app.color.brand'))
      } else if (this.badge.earned) {
        Column()
          .width(Size.statsMedalMark)
          .height(Size.statsMedalMark)
          .borderRadius(Radius.full)
          .radialGradient({
            center: [Size.statsMedalMark * 0.3, Size.statsMedalMark * 0.25],
            radius: Size.statsMedalMark,
            colors: [[$r('app.color.cb_warn_bg'), 0], [$r('app.color.bg_card'), 1]]
          })
        this.MedalMark($r('app.color.cb_warn'))
      } else {
        Column()
          .width(Size.statsMedalMark)
          .height(Size.statsMedalMark)
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.bg_navigation'))
        this.MedalMark($r('app.color.text_tertiary'))
      }
    }
      .width(Size.statsMedalMark)
      .height(Size.statsMedalMark)

      Text(this.statusText())
        .fontSize(FontSize.caption)
        .fontColor(this.statusColor())
        .maxLines(1)
      Text(this.badge.name)
        .fontSize(FontSize.body2)
        .fontWeight(Weight.medium)
        .fontColor(this.nameColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.subText())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: Space.s6, bottom: Space.s6, left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.card)
    .border({
      width: 1,
      color: this.badge.earned ? $r('app.color.cb_warn_bg')
        : (this.isNext && !this.badge.earned ? $r('app.color.brand_bg') : $r('app.color.line'))
    })
    .backgroundColor(this.badge.earned
      ? $r('app.color.cb_warn_bg') : $r('app.color.bg_card'))
    .accessibilityText(this.groupLabel())
  }
}

@Component
export struct VaultStatsPage {
  @Prop vaultName: string = '';
  @Prop model: VaultStatsModel = emptyStatsModel();
  @Prop scanFailed: boolean = false;
  @Prop scanning: boolean = false;
  /** 单屏：概览纵向堆叠、成就两列、年度指标三列；宽屏并排。 */
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  // v1.57 57.2：导航条避让高度 px（EntryAbility avoidAreaChange 发布，页面侧换算）
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 三个同级视角互斥（81.7）；切换后 Scroll 回顶部。 */
  @State private activeTab: string = 'overview';
  /** 0 = 未选择（取年份列表首项，即当前年）；否则为用户选中的年份。 */
  @State private selectedYear: number = 0;
  @State private hoverLabel: string = '';
  private scroller: Scroller = new Scroller();

  private navClearanceVp(): number {
    return px2vp(Math.max(0, this.navIndicatorHeightPx));
  }

  /* ---- 文案取值（扫描中占位；总字数 ≥ 1 万折「万」） ---- */

  private noteCountText(): string {
    return this.scanning ? '…' : this.model.noteCount.toString() + ' 篇';
  }

  private wordCountText(): string {
    if (this.scanning) {
      return '…';
    }
    const words: number = this.model.wordCount;
    if (words >= 10000) {
      const wan: string = (words / 10000).toFixed(1);
      const trimmed: string = wan.endsWith('.0') ? wan.substring(0, wan.length - 2) : wan;
      return trimmed + ' 万';
    }
    return words.toString();
  }

  private totalDaysText(): string {
    return this.scanning ? '…' : this.model.totalDays.toString() + ' 天';
  }

  private streakText(): string {
    return this.scanning ? '…' : this.model.streakDays.toString();
  }

  private nextHint(): string {
    return nextAchievementHint(this.model.badges, this.model.streakDays);
  }

  private scopeText(): string {
    return this.vaultName.length > 0
      ? this.vaultName + ' · 只在本机统计' : '只在本机统计';
  }

  private earnedCount(): number {
    let n: number = 0;
    for (let i: number = 0; i < this.model.badges.length; i++) {
      if (this.model.badges[i].earned) {
        n++;
      }
    }
    return n;
  }

  /* ---- 热力图：service 给 12 行 × 7 列，这里转置为 7 行 × 12 列 ---- */

  private heatCardWidthVp(): number {
    if (this.windowWidthVp <= 0) {
      return Size.statsPageMaxW / 2;
    }
    const pageW: number = Math.min(Size.statsPageMaxW, this.windowWidthVp);
    return this.singleScreen ? pageW : pageW / 2;
  }

  private heatCellSize(): number {
    const inner: number = this.heatCardWidthVp() - Space.s5 * 2 - Space.s4;
    const available: number = inner - Size.statsHeatLabelW - Size.statsHeatGap * 12;
    return Math.max(Space.s3,
      Math.min(Space.s6, available / 12));
  }

  private todayIndex(): number {
    return (new Date().getDay() + 6) % 7;
  }

  private dayIndexes(): number[] {
    return [0, 1, 2, 3, 4, 5, 6];
  }

  private dayLabels(): string[] {
    return ['一', '', '三', '', '五', '', ''];
  }

  private weekDayNames(): string[] {
    return ['一', '二', '三', '四', '五', '六', '日'];
  }

  private weekFlags(): boolean[] {
    return currentWeekFlagsOf(this.model.weeks);
  }

  /* ---- 成就网格行起点：宽屏 4 列、单屏 2 列 ---- */

  private badgeColumnCount(): number {
    return this.singleScreen ? 2 : 4;
  }

  private badgeRowStarts(): number[] {
    const starts: number[] = [];
    let i: number = 0;
    while (i < this.model.badges.length) {
      starts.push(i);
      i += this.badgeColumnCount();
    }
    return starts;
  }

  private badgeColumnIndexes(start: number): number[] {
    const cols: number[] = [];
    for (let c: number = 0; c < this.badgeColumnCount(); c++) {
      cols.push(c);
    }
    return cols;
  }

  /* ---- 年度：当前展示的年份汇总（选中值不在列表时回退首项） ---- */

  private currentYearSummary(): VaultStatsYearSummary | null {
    if (this.model.years.length === 0) {
      return null;
    }
    if (this.selectedYear > 0) {
      for (let i: number = 0; i < this.model.years.length; i++) {
        if (this.model.years[i].year === this.selectedYear) {
          return this.model.years[i];
        }
      }
    }
    return this.model.years[0];
  }

  private yearOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i: number = 0; i < this.model.years.length; i++) {
      const option: SelectOption = {
        value: this.model.years[i].year.toString() + ' 年'
      };
      options.push(option);
    }
    return options;
  }

  private selectedYearIndex(): number {
    const summary: VaultStatsYearSummary | null = this.currentYearSummary();
    if (summary === null) {
      return 0;
    }
    for (let i: number = 0; i < this.model.years.length; i++) {
      if (this.model.years[i].year === summary.year) {
        return i;
      }
    }
    return 0;
  }

  /** 月柱填充高度：当月活跃天数 / 当月日历天数 × 轨道高（闰年由 service 的天数换算保证）。 */
  private monthFillHeight(bar: VaultStatsMonthBar, year: number): number {
    const days: number = daysInMonthOf(year, bar.month);
    if (days <= 0 || bar.activeDays <= 0) {
      return 0;
    }
    return Math.min(Size.statsMonthTrackH,
      Size.statsMonthTrackH * bar.activeDays / days);
  }

  /* ---- 视角切换（81.7：互斥，切完回内容顶部） ---- */

  private switchTab(tab: string): void {
    if (this.activeTab === tab) {
      return;
    }
    this.activeTab = tab;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private tabLabel(tab: string): string {
    if (tab === 'annual') {
      return '年度回顾';
    }
    if (tab === 'achievements') {
      return '成就';
    }
    return '概览';
  }

  @Builder
  TabButton(tab: string) {
    Text(this.tabLabel(tab))
      .fontSize(FontSize.body2)
      .fontWeight(this.activeTab === tab ? Weight.medium : FontWeight.Normal)
      .fontColor(this.activeTab === tab
        ? $r('app.color.brand') : $r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      // 原型 .stats-tabs button min-height --touch；单屏 flex:1 均分整行、水平 padding --s3
      .height(Size.touch)
      .padding({
        left: this.singleScreen ? Space.s3 : Space.s6,
        right: this.singleScreen ? Space.s3 : Space.s6
      })
      .layoutWeight(this.singleScreen ? 1 : 0)
      .borderRadius(Radius.full)
      .backgroundColor(this.activeTab === tab
        ? $r('app.color.brand_bg') : Color.Transparent)
      .focusable(true)
      .id('stats-tab-' + tab)
      .accessibilityText(this.tabLabel(tab) + (this.activeTab === tab ? '，已选中' : ''))
      .onClick((): void => { this.switchTab(tab); })
  }

  @Builder
  TabBar() {
    Column() {
      // 单屏：范围说明置于按钮行上方（原型页头副标题位置），三个按钮均分整行
      if (this.singleScreen) {
        Text(this.scopeText())
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: Space.s1 })
      }
      Row() {
        Row({ space: Space.s1 }) {
          this.TabButton('overview')
          this.TabButton('annual')
          this.TabButton('achievements')
        }
        .padding({ left: Space.s1, right: Space.s1, top: Space.s1, bottom: Space.s1 })
        .borderRadius(Radius.full)
        .layoutWeight(this.singleScreen ? 1 : 0)

        if (!this.singleScreen) {
          Text(this.scopeText())
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: Space.s3 })
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: this.singleScreen ? Space.s4 : Space.s6,
      right: this.singleScreen ? Space.s4 : Space.s6,
      top: Space.s2,
      bottom: Space.s2
    })
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  /* ---- 概览：主卡（81.1） ---- */

  /** 单屏圆点 12（原型 .window.phone .stats-hero-week i --s3），宽屏 20（--s5）。 */
  private heroDotSize(): number {
    return this.singleScreen ? Space.s3 : Space.s5;
  }

  @Builder
  HeroNumber() {
    Row({ space: Space.s2 }) {
      Text(this.streakText())
        .fontSize(Size.statsNumber)
        .fontWeight(Weight.medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Column({ space: Space.s1 }) {
        Text('天')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text('连续写作')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  HeroWeek() {
    Row({ space: this.singleScreen ? Space.s2 : Space.s3 }) {
      ForEach(this.dayIndexes(), (d: number) => {
        Column({ space: Space.s1 }) {
          Text(this.weekDayNames()[d])
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
          Column()
            .width(this.heroDotSize())
            .height(this.heroDotSize())
            .borderRadius(Radius.full)
            .backgroundColor(this.weekFlags()[d]
              ? $r('app.color.cb_warn') : $r('app.color.line'))
            .border({
              width: d === this.todayIndex() ? Size.statsHeatOutline : 0,
              color: $r('app.color.cb_warn')
            })
        }
        .alignItems(HorizontalAlign.Center)
      }, (d: number): string => 'hero-week-' + d.toString())
    }
    .accessibilityText('本周每天是否有写作')
  }

  @Builder
  HeroCard() {
    Column({ space: Space.s3 }) {
      Text('每一天，都算数')
        .fontSize(FontSize.body2)
        .fontWeight(Weight.medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      // 原型网格区 "main week"：各形态均为大数字左、本周圆点右、同一行；
      // 只有 .window.double 才上下分行（原生无双屏专用分支，宽屏分支沿用同排）。
      Row() {
        this.HeroNumber()
        Blank()
        this.HeroWeek()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(this.scanning ? '正在统计…' : this.nextHint())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .width('100%')
        .padding({ top: Space.s3 })
        .border({ width: { top: 1 }, color: $r('app.color.line') })
    }
    .width('100%')
    // 单屏 padding --s5（.window.phone .stats-hero）、宽屏 --s6
    .padding(this.singleScreen ? Space.s5 : Space.s6)
    .borderRadius(Size.statsRadius)
    .linearGradient({
      angle: 135,
      colors: [
        [$r('app.color.cb_warn_bg'), 0],
        [$r('app.color.bg_card'), 0.7]
      ]
    })
    .accessibilityText('连续写作')
  }

  /* ---- 概览：三项辅助数字（81.1 弱化边框） ---- */

  @Builder
  NumberRow() {
    Row() {
      Column({ space: Space.s1 }) {
        Text('笔记')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.noteCountText())
          .fontSize(FontSize.s3)
          .fontWeight(Weight.medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s3 })

      Column({ space: Space.s1 }) {
        Text('总字数')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.wordCountText())
          .fontSize(FontSize.s3)
          .fontWeight(Weight.medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s3 })
      .border({ width: { left: 1 }, color: $r('app.color.line') })

      Column({ space: Space.s1 }) {
        Text('累计写作')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.totalDaysText())
          .fontSize(FontSize.s3)
          .fontWeight(Weight.medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s3 })
      .border({ width: { left: 1 }, color: $r('app.color.line') })
    }
    .width('100%')
    .borderRadius(Size.statsRadius)
    .backgroundColor($r('app.color.bg_card'))
    .clip(true)
  }

  /* ---- 概览：近 12 周热力图卡（81.2：宽屏与主卡并排、单屏下方） ---- */

  @Builder
  HeatCard() {
    Column({ space: Space.s3 }) {
      Row() {
        Text('近 12 周')
          .fontSize(FontSize.body1)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.hoverLabel.length > 0 ? this.hoverLabel : '少 □ ▢ ▣ ■ 多')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: Size.statsHeatGap }) {
        Row({ space: Size.statsHeatGap }) {
          Text('')
            .width(Size.statsHeatLabelW)
          ForEach(this.model.weeks, (week: VaultStatsWeek, w: number) => {
            Text(week.monthLabel)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width(this.heatCellSize())
              .maxLines(1)
          }, (week: VaultStatsWeek, w: number): string => 'heat-month-' + w.toString())
        }
        .width('100%')

        ForEach(this.dayIndexes(), (d: number) => {
          Row({ space: Size.statsHeatGap }) {
            Text(this.dayLabels()[d])
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width(Size.statsHeatLabelW)
            ForEach(this.model.weeks, (week: VaultStatsWeek, w: number) => {
              if (d < week.cells.length) {
                StatsHeatCellTile({
                  cell: week.cells[d],
                  cellSize: this.heatCellSize(),
                  isToday: w === this.model.weeks.length - 1 && d === this.todayIndex(),
                  onHoverLabel: (label: string): void => { this.hoverLabel = label; }
                })
              }
            }, (week: VaultStatsWeek, w: number): string => 'heat-cell-' + d.toString() + '-' + w.toString())
          }
          .width('100%')
        }, (d: number): string => 'heat-day-' + d.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .accessibilityText('近 12 周写作热力图，7 行 12 列共 84 格')
    }
    .width('100%')
    .padding(Space.s5)
    .borderRadius(Size.statsRadius)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  OverviewSection() {
    if (this.singleScreen) {
      Column({ space: Space.s4 }) {
        this.HeroCard()
        this.NumberRow()
        if (this.scanning) {
          Text('正在统计…')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        } else {
          this.HeatCard()
        }
      }
      .width('100%')
    } else {
      Row({ space: Space.s4 }) {
        Column({ space: Space.s4 }) {
          this.HeroCard()
          this.NumberRow()
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.scanning) {
          Column() {
            Text('正在统计…')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Column() {
            this.HeatCard()
          }
          .layoutWeight(1)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  /* ---- 年度回顾（81.5 / 81.6） ---- */

  @Builder
  AnnualMetricRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
      Blank()
      Text(value)
        .fontSize(FontSize.heading)
        .fontWeight(Weight.medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width('100%')
    .padding({ top: Space.s3, bottom: Space.s3 })
  }

  @Builder
  AnnualMetricsCard(summary: VaultStatsYearSummary, rowWeight: number) {
    Column() {
      Row() {
        Text('这一年的积累')
          .fontSize(FontSize.body1)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('按文件修改时间')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: Space.s3 })

      if (this.singleScreen) {
        Row() {
          Column({ space: Space.s1 }) {
            Text('活跃天数')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
            Text(summary.activeDays.toString() + ' 天')
              .fontSize(FontSize.s3)
              .fontWeight(Weight.medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: Space.s3, bottom: Space.s3 })

          Column({ space: Space.s1 }) {
            Text('最长连写')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
            Text(summary.longestStreakDays.toString() + ' 天')
              .fontSize(FontSize.s3)
              .fontWeight(Weight.medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: Space.s3, bottom: Space.s3 })
          .border({ width: { left: 1 }, color: $r('app.color.line') })

          Column({ space: Space.s1 }) {
            Text('活跃月份')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
            Text(summary.activeMonths.toString() + ' 个月')
              .fontSize(FontSize.s3)
              .fontWeight(Weight.medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: Space.s3, bottom: Space.s3 })
          .border({ width: { left: 1 }, color: $r('app.color.line') })
        }
        .width('100%')
      } else {
        Column() {
          this.AnnualMetricRow('活跃天数', summary.activeDays.toString() + ' 天')
          Divider()
            .color($r('app.color.line'))
          this.AnnualMetricRow('最长连写', summary.longestStreakDays.toString() + ' 天')
          Divider()
            .color($r('app.color.line'))
          this.AnnualMetricRow('活跃月份', summary.activeMonths.toString() + ' 个月')
        }
        .width('100%')
        .clip(true)
      }
    }
    .width('100%')
    .layoutWeight(rowWeight)
    .constraintSize({ minHeight: rowWeight > 0 ? '100%' : 0 })
    // 单屏年度卡 padding --s4（.window.phone .stats-annual-card）、宽屏 --s6
    .padding(this.singleScreen ? Space.s4 : Space.s6)
    .borderRadius(Size.statsRadius)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MonthBar(bar: VaultStatsMonthBar, year: number) {
    Column({ space: Space.s2 }) {
      Text(bar.future ? '—' : bar.activeDays.toString())
        .fontSize(FontSize.caption)
        .fontColor(bar.current ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        .maxLines(1)
      Column() {
        if (bar.future) {
          Column()
            .width('100%')
            .height('100%')
        } else if (bar.activeDays > 0) {
          Column()
            .width('100%')
            .height(this.monthFillHeight(bar, year))
            .backgroundColor($r('app.color.brand'))
            .opacity(bar.current ? 1 : 0.65)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: Space.s8 })
      .height(Size.statsMonthTrackH)
      .borderRadius(Radius.full)
      .backgroundColor(bar.future ? Color.Transparent : $r('app.color.bg_navigation'))
      .border({
        width: bar.future ? 1 : 0,
        color: $r('app.color.line'),
        style: bar.future ? BorderStyle.Dashed : BorderStyle.Solid
      })
      .justifyContent(FlexAlign.End)
      .clip(true)

      Text(bar.month.toString() + '月')
        .fontSize(FontSize.caption)
        .fontColor(bar.current ? $r('app.color.brand') : $r('app.color.text_tertiary'))
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .accessibilityText(bar.month.toString() + '月：'
      + (bar.future ? '未到' : bar.activeDays.toString() + ' 个活跃日'))
  }

  @Builder
  AnnualMonthsCard(summary: VaultStatsYearSummary, rowWeight: number) {
    Column({ space: Space.s4 }) {
      Row() {
        Text('每月写作足迹')
          .fontSize(FontSize.body1)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('活跃天数')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: this.singleScreen ? Space.s1 : Space.s2 }) {
        ForEach(summary.months, (bar: VaultStatsMonthBar, index: number) => {
          this.MonthBar(bar, summary.year)
        }, (bar: VaultStatsMonthBar, index: number): string => 'month-bar-' + bar.month.toString())
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text('柱高按当月活跃天数占日历天数的比例显示；未来月份留空。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .layoutWeight(rowWeight)
    .constraintSize({ minHeight: rowWeight > 0 ? '100%' : 0 })
    // 单屏年度卡 padding --s4（.window.phone .stats-annual-card）、宽屏 --s6
    .padding(this.singleScreen ? Space.s4 : Space.s6)
    .borderRadius(Size.statsRadius)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AnnualSection() {
    if (this.scanning) {
      Text('正在统计…')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    } else {
      this.AnnualContent(this.currentYearSummary())
    }
  }

  /** 年度内容（summary 为 null 时给空态文案，不给部分值）。 */
  @Builder
  AnnualContent(summary: VaultStatsYearSummary | null) {
    if (summary === null) {
      Text('暂无年度数据。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    } else {
      Column({ space: Space.s5 }) {
        // 单屏年份头间距 --s2、年度标题 --large；宽屏 --s4 / --heading（.stats-year-head）
        Row({ space: this.singleScreen ? Space.s2 : Space.s4 }) {
          Column({ space: Space.s1 }) {
            Text(summary.year.toString() + ' · 写作回顾')
              .fontSize(this.singleScreen ? FontSize.s3 : FontSize.heading)
              .fontWeight(Weight.medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
            Text('把日常落笔，连成一年的轨迹')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Select(this.yearOptions())
            .selected(this.selectedYearIndex())
            .value(summary.year.toString() + ' 年')
            .fontColor($r('app.color.text_primary'))
            .font({ size: FontSize.body2, weight: Weight.medium })
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Radius.full)
            .border({ width: 1, color: $r('app.color.line') })
            .height(Size.touch)
            .id('stats-year-select')
            .onSelect((index: number, text: string): void => {
              if (index >= 0 && index < this.model.years.length) {
                this.selectedYear = this.model.years[index].year;
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.singleScreen) {
          Column({ space: Space.s5 }) {
            this.AnnualMetricsCard(summary, 0)
            this.AnnualMonthsCard(summary, 0)
          }
          .width('100%')
        } else {
          Row({ space: Space.s5 }) {
            this.AnnualMetricsCard(summary, 1)
            this.AnnualMonthsCard(summary, 2)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }

        Text('年度按文件修改时间归日，导入与同步也可能改变分布；'
          + '不代表当年新增字数或完整写作历史。成就仍按当前库累计口径展示。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding(Space.s4)
          .borderRadius(Radius.card)
          .backgroundColor($r('app.color.bg_card'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /* ---- 成就收藏（81.3） ---- */

  @Builder
  AchievementsSection() {
    if (this.scanning) {
      Text('正在统计…')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    } else {
      Column({ space: Space.s4 }) {
        Row() {
          Text('成就收藏')
            .fontSize(FontSize.body1)
            .fontWeight(Weight.semibold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(this.earnedCount().toString() + ' / '
            + this.model.badges.length.toString() + ' 已获得')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('从第一次落笔，到让写作成为习惯')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')

        Column({ space: Space.s3 }) {
          ForEach(this.badgeRowStarts(), (start: number) => {
            Row({ space: Space.s3 }) {
              ForEach(this.badgeColumnIndexes(start), (col: number) => {
                if (start + col < this.model.badges.length) {
                  StatsMedalCard({
                    badge: this.model.badges[start + col],
                    isNext: start + col === nextBadgeIndexOf(this.model.badges)
                  })
                    .layoutWeight(1)
                } else {
                  Column()
                    .layoutWeight(1)
                }
              }, (col: number): string => 'medal-col-' + start.toString() + '-' + col.toString())
            }
            .width('100%')
          }, (start: number): string => 'medal-row-' + start.toString())
        }
        .width('100%')
      }
      .width('100%')
      .padding(Space.s6)
      .borderRadius(Size.statsRadius)
      .backgroundColor($r('app.color.bg_card'))
      .alignItems(HorizontalAlign.Start)
    }
  }

  /* ---- 失败与口径说明 ---- */

  @Builder
  FailureCard() {
    Column() {
      Text('统计暂不可用')
        .fontSize(FontSize.body1)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('读取当前知识库失败，请稍后重试。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: Space.s1 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Space.s6)
    .borderRadius(Size.statsRadius)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  StatsFoot() {
    Column() {
      if (this.model.truncated && !this.scanFailed) {
        Text('当前库文件较多，本次统计基于已扫描的部分，数字可能略有偏差。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ bottom: Space.s1 })
      }
      Text('活跃日 = 当日至少一篇笔记有修改（以文件时间为准，导入与同步也会计入）。'
        + '统计只按当前知识库、只在本机计算，不用于埋点或上报。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.TabBar()
      Scroll(this.scroller) {
        Column() {
          Column({ space: Space.s5 }) {
            if (this.scanFailed) {
              // 失败只给安全文案，不出部分值（52.2）
              this.FailureCard()
            } else {
              if (this.activeTab === 'overview') {
                this.OverviewSection()
              } else if (this.activeTab === 'annual') {
                this.AnnualSection()
              } else {
                this.AchievementsSection()
              }
            }
            this.StatsFoot()
          }
          .width('100%')
          .constraintSize({ maxWidth: Size.statsPageMaxW })
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: this.singleScreen ? Space.s4 : Space.s10,
            right: this.singleScreen ? Space.s4 : Space.s10,
            // 单屏上边距 --s5（.window.phone .stats-body），宽屏 --s8
            top: this.singleScreen ? Space.s5 : Space.s8,
            bottom: Space.s8 + this.navClearanceVp()
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .backgroundColor($r('app.color.bg_page'))
      // v1.57 57.4：滚动表面延伸到导航条下方，末条让位由内容 padding bottom 保证
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .id('stats-page')
  }
}
