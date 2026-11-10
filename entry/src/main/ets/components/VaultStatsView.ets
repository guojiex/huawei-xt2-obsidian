/**
 * VaultStatsView.ets —— 统计与成就面板（原型 vaultStatsPage，v1.52 原生落码）
 *
 * 口径真源：docs/releases/v1.51/需求文档.md §2；实现范围见 v1.52 需求文档 §52.2。
 * 形态与 VaultManagerView 一致：整体替换 Index 内容区（topView 'stats'），
 * 返回走顶栏 ‹ / onBackPress（2.7c 同级），内容页限宽 760 居中，无自带返回。
 *
 * 自上而下：范围行 → 四张数字卡（2×2）→ 近 12 周热力图 → 成就徽章网格 → 口径说明。
 * 状态由 Index 持有（model / scanning / scanFailed）；扫描中数字卡显示「…」占位，
 * 失败显示安全失败文案、不给部分值（52.2）。
 *
 * 红线（51.6 / 52.4）：统计值只本地展示；本文件不埋点、不写日志、不上报。
 */
import { VaultStatsModel, VaultStatsWeek, VaultStatsHeatCell, VaultStatsBadge,
  emptyStatsModel } from '../model/VaultStatsService';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

/** 数字卡：值 + 标签（原型 .stats-card）。子组件而非 @Builder——扫描完成后按 @Prop 回填。 */
@Component
struct VaultStatsCardTile {
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column() {
      Text(this.value)
        .fontSize(FontSize.heading)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .width('100%')
      Text(this.label)
        .fontSize(FontSize.caption)
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
}

/** 成就徽章行：圆形图标 + 名称 + 进度（原型 .stats-badge；达成态彩色，进度态置灰）。 */
@Component
struct VaultStatsBadgeCard {
  @Prop badge: VaultStatsBadge = { name: '', desc: '', progressLabel: '', earned: false };

  build() {
    Row({ space: Space.s3 }) {
      Column() {
        // 图标颜色按达成态分两支字面调用：达成 brand / 未达成置灰（Icon 实参不含 this.）
        if (this.badge.earned) {
          Icon('medal', Space.s5, $r('app.color.brand'))
        } else {
          Icon('medal', Space.s5, $r('app.color.text_tertiary'))
        }
      }
      .width(Space.s10)
      .height(Space.s10)
      .borderRadius(Radius.full)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.badge.earned
        ? $r('app.color.brand_bg') : $r('app.color.bg_navigation'))

      Column({ space: Space.s1 }) {
        Text(this.badge.name)
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .width('100%')
        Text(this.badge.progressLabel)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(Space.s3)
    .borderRadius(Radius.control)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }
}

@Component
export struct VaultStatsView {
  /** 当前库名（范围行展示，Index 传入 currentVaultName()）。 */
  @Prop vaultName: string = '';
  /** 统计结果（Index 持有；进入页 / 重新扫描时先置空模型）。 */
  @Prop model: VaultStatsModel = emptyStatsModel();
  /** 扫描失败：只显示安全失败文案，不显示部分值（52.2）。 */
  @Prop scanFailed: boolean = false;
  /** 扫描中：数字卡显示「…」占位，热力图 / 徽章区待完成后渲染。 */
  @Prop scanning: boolean = false;

  /* ---- 数字卡取值（扫描中占位；总字数 ≥ 10000 按原型折「万」） ---- */

  private noteCountText(): string {
    return this.scanning ? '…' : this.model.noteCount.toString();
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

  private streakText(): string {
    return this.scanning ? '…' : this.model.streakDays.toString() + ' 天';
  }

  private totalDaysText(): string {
    return this.scanning ? '…' : this.model.totalDays.toString() + ' 天';
  }

  /* ---- 热力图档位：0 空格用导航底色，1/2/3 档品牌色加深（原型 color-mix 25/55/85） ---- */

  private heatCellBg(level: number): ResourceColor {
    if (level >= 1) {
      return $r('app.color.brand');
    }
    return $r('app.color.bg_navigation');
  }

  private heatCellOpacity(level: number): number {
    if (level >= 3) {
      return 0.85;
    }
    if (level === 2) {
      return 0.55;
    }
    if (level === 1) {
      return 0.25;
    }
    return 1;
  }

  /** 徽章两列网格的行起点（0/2/4/6；徽章 8 枚，列数固定 2）。 */
  private badgePairStarts(): number[] {
    const starts: number[] = [];
    let i: number = 0;
    while (i < this.model.badges.length) {
      starts.push(i);
      i += 2;
    }
    return starts;
  }

  @Builder
  ScopeRow() {
    // 原型 .stats-scope：muted 正文 + 库名 strong（ink / 600）
    Text() {
      Span('当前知识库：')
      Span(this.vaultName)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Medium)
      Span(' · 统计只在本机计算与展示')
    }
    .fontSize(FontSize.body2)
    .fontColor($r('app.color.text_tertiary'))
    .width('100%')
  }

  @Builder
  FailureCard() {
    Column() {
      Text('统计暂不可用')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Medium)
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
    .margin({ top: Space.s4 })
  }

  @Builder
  CardsGrid() {
    // 原型 .stats-cards：2×2 网格，间距 --s3；空库显示 0 / 0 / 0 天 / 0 天
    Column({ space: Space.s3 }) {
      Row({ space: Space.s3 }) {
        VaultStatsCardTile({ value: this.noteCountText(), label: '笔记数' })
        VaultStatsCardTile({ value: this.wordCountText(), label: '总字数' })
      }
      .width('100%')
      Row({ space: Space.s3 }) {
        VaultStatsCardTile({ value: this.streakText(), label: '连续写作天数' })
        VaultStatsCardTile({ value: this.totalDaysText(), label: '累计写作天数' })
      }
      .width('100%')
    }
    .width('100%')
    .margin({ top: Space.s4, bottom: Space.s4 })
  }

  @Builder
  HeatSection() {
    Column() {
      Text('近 12 周写作热力图')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s3 })

      // 原型 .stats-heat：月份刻度列（定宽）+ 7 列等宽方格（aspect-ratio 1，pill 圆角）
      Column({ space: Space.s1 }) {
        Row({ space: Space.s1 }) {
          Text('')
            .width(Space.s8)
          Text('一')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('二')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('三')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('四')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('五')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('六')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('日')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }
        .width('100%')

        ForEach(this.model.weeks, (week: VaultStatsWeek, weekIndex: number) => {
          Row({ space: Space.s1 }) {
            Text(week.monthLabel)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width(Space.s8)
              .textAlign(TextAlign.End)
            ForEach(week.cells, (cell: VaultStatsHeatCell) => {
              Column()
                .layoutWeight(1)
                .aspectRatio(1)
                .borderRadius(Radius.full)
                .backgroundColor(this.heatCellBg(cell.level))
                .opacity(this.heatCellOpacity(cell.level))
                .accessibilityText(cell.dayLabel + (cell.future
                  ? ' · 未到' : ' · ' + cell.count.toString() + ' 篇'))
            }, (cell: VaultStatsHeatCell) => cell.dayLabel)
          }
          .width('100%')
        }, (week: VaultStatsWeek, weekIndex: number) => 'heat-week-' + weekIndex.toString())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .accessibilityText('近 12 周写作热力图，共 84 格')

      Text('颜色越深表示当日修改的笔记越多。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: Space.s2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: Space.s4, bottom: Space.s4 })
  }

  @Builder
  BadgesSection() {
    Column() {
      Text('成就')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s3 })

      // 原型 .stats-badges：auto-fill 自适应网格；原生固定两列（760 限宽下与卡片对齐）
      Column({ space: Space.s3 }) {
        ForEach(this.badgePairStarts(), (start: number) => {
          Row({ space: Space.s3 }) {
            VaultStatsBadgeCard({ badge: this.model.badges[start] })
            if (start + 1 < this.model.badges.length) {
              VaultStatsBadgeCard({ badge: this.model.badges[start + 1] })
            } else {
              // 奇数枚时占位补齐，保持两列对齐
              Column()
                .layoutWeight(1)
            }
          }
          .width('100%')
        }, (start: number) => 'badge-pair-' + start.toString())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: Space.s4, bottom: Space.s4 })
  }

  @Builder
  StatsNote() {
    Column() {
      // 快照被截断时如实提示（VaultAccess.snapshotReport().truncated 透传）
      if (this.model.truncated && !this.scanFailed) {
        Text('当前库文件较多，本次统计基于已扫描的部分，数字可能略有偏差。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ bottom: Space.s1 })
      }
      // 口径说明（51.5）：活跃日定义 + mtime 口径限制 + 全本地不上报
      Text('活跃日 = 当日至少一篇笔记有修改（以文件时间为准）。Git clone / 导入等操作会刷新文件时间，'
        + '此类「非写作修改」也会计入，不做补偿。统计与成就只在本地计算，不用于埋点或上报。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column() {
        this.ScopeRow()
        if (this.scanFailed) {
          // 失败只给安全文案，不出部分值（52.2）
          this.FailureCard()
        } else {
          this.CardsGrid()
          if (this.scanning) {
            Text('正在统计…')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: Space.s4 })
          } else {
            this.HeatSection()
            this.BadgesSection()
          }
          this.StatsNote()
        }
      }
      // 需求 4.9：内容页限宽 760vp 居中
      .width('100%')
      .constraintSize({ maxWidth: Size.contentMaxW })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.bg_page'))
    .scrollBar(BarState.Off)
  }
}
