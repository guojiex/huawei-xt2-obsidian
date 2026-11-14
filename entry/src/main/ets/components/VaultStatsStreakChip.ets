/**
 * VaultStatsStreakChip.ets —— 侧栏底部常驻连写条（v1.58 58.2，原型 .streak-chip）
 *
 * 宽屏 / 双屏侧栏主入口：点按打开写作统计弹窗；单屏侧栏是临时抽屉，不挂载本组件。
 * 只读取父级缓存的连写 / 累计 / 本周数据，不做扫描、不阻塞侧栏渲染；数值来自
 * VaultStatsDialog 打开时的同一次重算（结果由 Index 回写），口径见 v1.51 §2。
 *
 * 红线（51.6 / 52.4）：统计值只本地展示；本文件不埋点、不写日志、不上报。
 */
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';

@Component
export struct VaultStatsStreakChip {
  @Prop streakDays: number = 0;
  @Prop totalDays: number = 0;
  /** 缓存扫描未完成时显示「…」，不显示半套数值。 */
  @Prop scanning: boolean = false;
  /** 本周一到周日是否有写作（VaultStatsService.currentWeekFlagsOf）。 */
  @Prop weekFlags: boolean[] = [];
  @Prop todayIndex: number = -1;
  /** 侧栏宽度不足 280vp 时隐藏圆点，只留文字。 */
  @Prop showDots: boolean = true;
  /** note / agent 两侧栏不同 id，焦点归还时才不会命中隐藏的那一个。 */
  @Prop chipId: string = 'vault-stats-streak-chip';
  onOpenStats: () => void = () => {};

  private titleText(): string {
    if (this.scanning) {
      return '…';
    }
    return this.streakDays > 0
      ? '连续写作 ' + this.streakDays.toString() + ' 天' : '今天还没写';
  }

  private subText(): string {
    if (this.scanning) {
      return '查看写作统计';
    }
    return this.streakDays > 0
      ? '累计 ' + this.totalDays.toString() + ' 天 · 查看写作统计' : '查看写作统计';
  }

  private a11yText(): string {
    if (this.scanning) {
      return '写作统计：正在统计';
    }
    return '写作统计：' + (this.streakDays > 0
      ? '连续写作 ' + this.streakDays.toString() + ' 天' : '今天还没写')
      + '，累计 ' + this.totalDays.toString() + ' 天';
  }

  build() {
    Row({ space: Space.s3 }) {
      Row() {
        Icon('flame', Space.s5, $r('app.color.cb_warn'))
      }
      .width(Space.s8)
      .height(Space.s8)
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.cb_warn_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: Space.s1 }) {
        Text(this.titleText())
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subText())
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showDots) {
        Row({ space: Space.s1 }) {
          ForEach([0, 1, 2, 3, 4, 5, 6], (d: number) => {
            Column()
              .width(Space.s2)
              .height(Space.s2)
              .borderRadius(Radius.full)
              .backgroundColor(d < this.weekFlags.length && this.weekFlags[d]
                ? $r('app.color.cb_warn') : $r('app.color.line'))
              .border({
                width: d === this.todayIndex ? Size.statsHeatOutline : 0,
                color: $r('app.color.cb_warn')
              })
          }, (d: number): string => 'streak-dot-' + d.toString())
        }
      }
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
    .borderRadius(Radius.control)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .id(this.chipId)
    .focusable(true)
    .accessibilityText(this.a11yText())
    .onClick((): void => { this.onOpenStats(); })
  }
}
