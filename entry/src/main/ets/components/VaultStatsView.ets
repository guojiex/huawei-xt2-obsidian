/**
 * VaultStatsView.ets —— 写作统计面板内容（v1.58 重设计，原型 #statsDialog）
 *
 * 口径真源仍是 docs/releases/v1.51/需求文档.md §2；扫描层 VaultStatsService 不动。
 * 形态：不再替换内容区，作为 VaultStatsDialog（UtilityDialogShell）的 content 渲染，
 * 宽屏居中弹窗 / 单屏半模态由外壳负责。本文件只画内容：
 *   连写主视觉 → 三格数字行 → 7 行 × 12 列热力图 → 8 枚成就（含「下一个」圆环）→ 口径说明。
 *
 * 状态由 VaultStatsDialog 持有并通过 @Prop 下传（CustomDialog 的 @Prop 不随父组件刷新，
 * 故弹窗自己用 @State 承接扫描结果，见 VaultStatsDialog.ets 注释）。扫描中数字显示「…」，
 * 失败只给安全文案、不给部分值。
 *
 * 视觉 token 以 v2 原型 .stats-* 为准；暖色只用既有 --cb-warn / --cb-warn_bg，不新增颜色 token。
 * 红线（51.6 / 52.4）：统计值只本地展示；本文件不埋点、不写日志、不上报。
 */
import { VaultStatsModel, VaultStatsWeek, VaultStatsHeatCell, VaultStatsBadge,
  emptyStatsModel, nextBadgeIndexOf, nextAchievementHint, currentWeekFlagsOf } from '../model/VaultStatsService';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';

/** 热力图单格：小方格（未来日空心 / 今天描边），悬停或长按把日期与篇数回传给标题行。 */
@Component
struct VaultStatsHeatCellTile {
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

/** 成就徽章：圆形标记 + 名称 + 一行说明；「下一个」叠一枚品牌色圆环进度。 */
@Component
struct VaultStatsMedalTile {
  @Prop badge: VaultStatsBadge = { name: '', desc: '', progressLabel: '', earned: false,
    value: 0, goal: 1, kind: 'count' };
  @Prop isNext: boolean = false;

  private percent(): number {
    if (this.badge.goal <= 0) {
      return 0;
    }
    return Math.round(Math.min(1, this.badge.value / this.badge.goal) * 100);
  }

  private subLabel(): string {
    if (this.badge.earned) {
      return '已获得';
    }
    if (this.isNext) {
      return Math.min(this.badge.value, this.badge.goal).toString() + ' / ' + this.badge.goal.toString();
    }
    return this.badge.desc;
  }

  private groupLabel(): string {
    return this.badge.name + '，' + (this.badge.earned ? '已获得' : '未获得，' + this.badge.desc
      + (this.isNext ? '，进度 ' + this.percent().toString() + '%' : ''));
  }

  build() {
    Column({ space: Space.s2 }) {
      Stack() {
        if (this.isNext && !this.badge.earned) {
          Progress({ value: this.percent(), total: 100, type: ProgressType.Ring })
            .width(Size.statsMedalSize)
            .height(Size.statsMedalSize)
            .color($r('app.color.brand'))
            .backgroundColor($r('app.color.bg_navigation'))
        } else if (this.badge.earned) {
          Column()
            .width(Size.statsMedalSize)
            .height(Size.statsMedalSize)
            .borderRadius(Radius.full)
            .radialGradient({
              center: [Size.statsMedalSize / 2, Size.statsMedalSize / 2],
              radius: Size.statsMedalSize / 2,
              colors: [[$r('app.color.cb_warn_bg'), 0], [$r('app.color.bg_card'), 1]]
            })
        } else {
          Column()
            .width(Size.statsMedalSize)
            .height(Size.statsMedalSize)
            .borderRadius(Radius.full)
            .backgroundColor($r('app.color.bg_navigation'))
        }
        if (this.badge.earned) {
          Icon('medal', Space.s6, $r('app.color.cb_warn'))
        } else if (this.isNext) {
          Icon('medal', Space.s6, $r('app.color.brand'))
        } else {
          Icon('medal', Space.s6, $r('app.color.text_tertiary'))
        }
      }
      .width(Size.statsMedalSize)
      .height(Size.statsMedalSize)

      Text(this.badge.name)
        .fontSize(FontSize.body2)
        .fontColor(this.badge.earned
          ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.subLabel())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: Space.s3, bottom: Space.s3, left: Space.s1, right: Space.s1 })
    .borderRadius(Radius.control)
    .accessibilityText(this.groupLabel())
  }
}

@Component
export struct VaultStatsView {
  @Prop vaultName: string = '';
  @Prop model: VaultStatsModel = emptyStatsModel();
  @Prop scanFailed: boolean = false;
  @Prop scanning: boolean = false;
  /** 单屏半模态：主视觉纵向排布、徽章网格收紧。 */
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  // v1.57 57.2：导航条避让高度 px（EntryAbility avoidAreaChange 发布，页面侧换算）
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 悬停 / 长按的热力图单格说明（原生没有 title tooltip，落在标题行）。 */
  @State hoverLabel: string = '';

  private navClearanceVp(): number {
    return px2vp(Math.max(0, this.navIndicatorHeightPx));
  }

  /* ---- 数字取值（扫描中占位；总字数 ≥ 1 万按原型折「万」） ---- */

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

  private earnedCount(): number {
    let n: number = 0;
    for (let i: number = 0; i < this.model.badges.length; i++) {
      if (this.model.badges[i].earned) {
        n++;
      }
    }
    return n;
  }

  /* ---- 热力图：service 仍给 12 行 × 7 列，这里转置为 7 行 × 12 列 ---- */

  private contentWidthVp(): number {
    const dialogW: number = this.singleScreen
      ? Math.max(0, this.windowWidthVp)
      : (this.windowWidthVp > 0
        ? Math.max(0, Math.min(Size.statsDialogW, this.windowWidthVp - Space.s8 * 2))
        : Size.statsDialogW);
    return Math.max(0, dialogW - Space.s5 * 2);
  }

  private heatCellSize(): number {
    const available: number = this.contentWidthVp() - Size.statsHeatLabelW
      - Size.statsHeatGap * 12;
    return Math.max(Size.statsHeatCellMin,
      Math.min(Size.statsHeatCellMax, available / 12));
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

  private badgeRowStarts(): number[] {
    const starts: number[] = [];
    let i: number = 0;
    while (i < this.model.badges.length) {
      starts.push(i);
      i += 4;
    }
    return starts;
  }

  private badgeColumns(): number[] {
    return [0, 1, 2, 3];
  }

  /* ---- 主视觉：连写大数字 + 本周圆点 + 下一步提示 ---- */

  @Builder
  HeroNumber() {
    Row({ space: Space.s2 }) {
      Text(this.streakText())
        .fontSize(Size.statsHeroNum)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Column({ space: Space.s1 }) {
        Text('天')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_tertiary'))
        Text('连续写作')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  HeroWeek() {
    Row({ space: this.singleScreen ? Space.s2 : Space.s1 }) {
      ForEach(this.dayIndexes(), (d: number) => {
        Column({ space: Space.s1 }) {
          Text(this.weekDayNames()[d])
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
          Column()
            .width(Size.statsHeroDot)
            .height(Size.statsHeroDot)
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
    .justifyContent(FlexAlign.End)
    .accessibilityText('本周每天是否有写作')
  }

  @Builder
  HeroSection() {
    Column({ space: Space.s3 }) {
      if (this.singleScreen) {
        this.HeroNumber()
        this.HeroWeek()
      } else {
        Row() {
          this.HeroNumber()
          this.HeroWeek()
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
      }
      Text(this.scanning ? '正在统计…' : this.nextHint())
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .width('100%')
    }
    .width('100%')
    .padding(Space.s5)
    .borderRadius(Radius.card)
    .border({ width: 1, color: $r('app.color.line') })
    .linearGradient({
      angle: 135,
      colors: [
        [$r('app.color.cb_warn_bg'), 0],
        [$r('app.color.bg_card'), 0.7]
      ]
    })
    .accessibilityText('连续写作')
  }

  /* ---- 三格数字行 ---- */

  @Builder
  NumberRow() {
    Row() {
      Column({ space: Space.s1 }) {
        Text('笔记')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.noteCountText())
          .fontSize(this.singleScreen ? FontSize.body1 : FontSize.s3)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
      .border({ width: { right: 1 }, color: $r('app.color.line') })

      Column({ space: Space.s1 }) {
        Text('总字数')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.wordCountText())
          .fontSize(this.singleScreen ? FontSize.body1 : FontSize.s3)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
      .border({ width: { right: 1 }, color: $r('app.color.line') })

      Column({ space: Space.s1 }) {
        Text('累计写作')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
        Text(this.totalDaysText())
          .fontSize(this.singleScreen ? FontSize.body1 : FontSize.s3)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
    }
    .width('100%')
    .borderRadius(Radius.control)
    .border({ width: 1, color: $r('app.color.line') })
    .clip(true)
  }

  /* ---- 近 12 周热力图（7 行 × 12 列） ---- */

  @Builder
  HeatSection() {
    Column() {
      Row() {
        Text('近 12 周')
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
        Text(this.hoverLabel.length > 0 ? this.hoverLabel : '少 □ ▢ ▣ ■ 多')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: Space.s3 })

      Column({ space: Size.statsHeatGap }) {
        // 顶部月份刻度（同月不重复，沿用 service 的 monthLabel）
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

        // 7 行（周一—周日）× 12 列（周）；左侧只标「一 / 三 / 五」
        ForEach(this.dayIndexes(), (d: number) => {
          Row({ space: Size.statsHeatGap }) {
            Text(this.dayLabels()[d])
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width(Size.statsHeatLabelW)
            ForEach(this.model.weeks, (week: VaultStatsWeek, w: number) => {
              if (d < week.cells.length) {
                VaultStatsHeatCellTile({
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
    .alignItems(HorizontalAlign.Start)
  }

  /* ---- 成就（4 列网格，唯一一枚「下一个」带圆环） ---- */

  @Builder
  BadgesSection() {
    Column() {
      Row() {
        Text('成就')
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
        Text(this.earnedCount().toString() + ' / ' + this.model.badges.length.toString() + ' 已获得')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: Space.s3 })

      Column({ space: Space.s2 }) {
        ForEach(this.badgeRowStarts(), (start: number) => {
          Row({ space: this.singleScreen ? Space.s1 : Space.s3 }) {
            ForEach(this.badgeColumns(), (col: number) => {
              if (start + col < this.model.badges.length) {
                VaultStatsMedalTile({
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
    .alignItems(HorizontalAlign.Start)
  }

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
    .padding(Space.s4)
    .borderRadius(Radius.card)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  StatsNote() {
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
    Column({ space: Space.s5 }) {
      if (this.scanFailed) {
        // 失败只给安全文案，不出部分值（52.2）
        this.FailureCard()
      } else {
        this.HeroSection()
        this.NumberRow()
        if (this.scanning) {
          Text('正在统计…')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        } else {
          this.HeatSection()
          this.BadgesSection()
        }
        this.StatsNote()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: Space.s5 + this.navClearanceVp() })
  }
}
