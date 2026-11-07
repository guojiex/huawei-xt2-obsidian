/**
 * StartupMask.ets —— v1.41 启动页品牌遮罩
 *
 * 设计真源：docs/prototype/v2/启动页设计.md（v2 原型 `.startup-*`）。
 * 冷启动期间盖住工作区，内容为品牌层（图标 + 品牌名 + 随机名言）；
 * `ready` 置位后 240ms 淡出并隐藏，不为动画延长启动。
 * 装饰层：不参与读屏（整体 accessibilityLevel('no')），无埋点、无网络。
 */
import { FontSize, Motion, Radius, Shadow, Space, Startup } from '../common/Tokens';

interface QuoteEntry {
  text: string;
  source: string;
}

/** 名言库 12 句（v1.41 41.2）：公版古籍或广为流传的译句，与 v2 原型 STARTUP_QUOTES 一致。 */
const QUOTES: QuoteEntry[] = [
  { text: '博观而约取，厚积而薄发。', source: '苏轼《稼说送张琥》' },
  { text: '纸上得来终觉浅，绝知此事要躬行。', source: '陆游《冬夜读书示子聿》' },
  { text: '问渠那得清如许？为有源头活水来。', source: '朱熹《观书有感》' },
  { text: '人生到处知何似，应似飞鸿踏雪泥。', source: '苏轼《和子由渑池怀旧》' },
  { text: '他山之石，可以攻玉。', source: '《诗经·小雅·鹤鸣》' },
  { text: '行到水穷处，坐看云起时。', source: '王维《终南别业》' },
  { text: '不积跬步，无以至千里。', source: '荀子《劝学》' },
  { text: '文章本天成，妙手偶得之。', source: '陆游《文章》' },
  { text: '学而不思则罔，思而不学则殆。', source: '《论语·为政》' },
  { text: '世事洞明皆学问，人情练达即文章。', source: '曹雪芹《红楼梦》' },
  { text: '我思故我在。', source: '笛卡尔《谈谈方法》' },
  { text: '未经审视的人生不值得过。', source: '苏格拉底 · 柏拉图《申辩篇》' }
];

const CN_NUM: string[] = ['〇', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const CN_WEEK: string[] = ['日', '一', '二', '三', '四', '五', '六'];

/** 中文数字：10–19 转「十X」，20+ 转「X十Y」（页脚日期够用，不覆盖百位）。 */
function cnNum(value: number): string {
  if (value < 10) {
    return CN_NUM[value];
  }
  const tens: number = Math.floor(value / 10);
  const ones: number = value % 10;
  const tensText: string = tens >= 2 ? CN_NUM[tens] : '';
  const onesText: string = ones > 0 ? CN_NUM[ones] : '';
  return tensText + '十' + onesText;
}

/** 页脚中文数字日期：「二〇二六年十一月七日 · 星期六」。 */
function formatCnDate(now: Date): string {
  const yearStr: string = String(now.getFullYear());
  let yearCn: string = '';
  for (let i = 0; i < yearStr.length; i++) {
    yearCn += CN_NUM[Number(yearStr.charAt(i))];
  }
  return yearCn + '年' + cnNum(now.getMonth() + 1) + '月' + cnNum(now.getDate()) +
    '日 · 星期' + CN_WEEK[now.getDay()];
}

/** 名言按分句断行（标点留行尾），与原型 renderQuote 的切分一致。 */
function splitQuoteLines(text: string): string[] {
  const lines: string[] = text.match(/[^，。；？！]+[，。；？！]?/g) ?? [text];
  return lines;
}

@Component
export struct StartupMask {
  /** 工作区恢复就绪（Index 的 workspaceInitialRenderReady）：true 即中断入场并淡出。 */
  @Prop @Watch('onReadyChange') ready: boolean = false;
  @State private maskOpacity: number = 1;
  @State private maskGone: boolean = false;
  @State private stageScale: number = 1;
  @State private iconOpacity: number = 0;
  @State private iconTranslateY: number = Startup.iconEnterFromY;
  @State private iconScale: number = Startup.iconEnterFromScale;
  @State private nameOpacity: number = 0;
  @State private nameTranslateY: number = Startup.nameEnterFromY;
  @State private eyebrowOpacity: number = 0;
  @State private ruleOpacity: number = 0;
  @State private quoteOpacity: number = 0;
  @State private quoteTranslateY: number = Startup.quoteEnterFromY;
  @State private sourceOpacity: number = 0;
  @State private footOpacity: number = 0;
  private quote: QuoteEntry = QUOTES[Math.floor(Math.random() * QUOTES.length)];
  private quoteLines: string[] = [];
  private footDate: string = '';
  private enterTimers: number[] = [];
  private exiting: boolean = false;

  aboutToAppear(): void {
    this.quoteLines = splitQuoteLines(this.quote.text);
    this.footDate = formatCnDate(new Date());
    this.scheduleEnter(Startup.enterIconDelay, (): void => {
      this.enterIcon();
    });
    this.scheduleEnter(Startup.enterNameDelay, (): void => {
      this.enterName();
    });
    this.scheduleEnter(Startup.enterEyebrowDelay, (): void => {
      this.enterEyebrow();
    });
    this.scheduleEnter(Startup.enterRuleDelay, (): void => {
      this.enterRule();
    });
    this.scheduleEnter(Startup.enterQuoteDelay, (): void => {
      this.enterQuote();
    });
    this.scheduleEnter(Startup.enterSourceDelay, (): void => {
      this.enterSource();
    });
    this.scheduleEnter(Startup.enterFootDelay, (): void => {
      this.enterFoot();
    });
  }

  aboutToDisappear(): void {
    this.clearEnterTimers();
  }

  build() {
    Column() {
      // 品牌主体：在剩余空间内居中（原型 .startup-stage）
      Column({ space: Space.s4 }) {
        Stack({ alignContent: Alignment.Center }) {
          // 光晕（原型 .startup-halo）：brand 径向渐变圆，透明度走 Startup.haloOpacity
          Column()
            .width(Startup.iconSize + Startup.haloPad * 2)
            .height(Startup.iconSize + Startup.haloPad * 2)
            .borderRadius(Radius.full)
            .radialGradient({
              center: [Startup.iconSize / 2 + Startup.haloPad, Startup.iconSize / 2 + Startup.haloPad],
              radius: Startup.iconSize / 2 + Startup.haloPad,
              colors: [[$r('app.color.brand'), 0], [Color.Transparent, 0.72]]
            })
            .opacity(Startup.haloOpacity)
          Image($r('app.media.app_icon_1024'))
            .width(Startup.iconSize)
            .height(Startup.iconSize)
            .objectFit(ImageFit.Cover)
            .borderRadius(Startup.iconRadius)
            .shadow({
              radius: Shadow.floatBlur,
              color: $r('app.color.float_shadow'),
              offsetX: 0,
              offsetY: 8
            })
        }
        .width(Startup.iconSize + Startup.haloPad * 2)
        .height(Startup.iconSize + Startup.haloPad * 2)
        .opacity(this.iconOpacity)
        .translate({ y: this.iconTranslateY })
        .scale({ x: this.iconScale, y: this.iconScale })
        .margin({ bottom: Space.s2 })

        // 品牌名（原型 .startup-name）：末字空隙用 offset 半宽补偿居中
        Text('曜石笔记')
          .fontSize(Startup.nameSize)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('serif')
          .letterSpacing(Startup.nameSize * Startup.nameTrackingRatio)
          .offset({ x: Startup.nameSize * Startup.nameTrackingRatio / 2 })
          .opacity(this.nameOpacity)
          .translate({ y: this.nameTranslateY })

        // 眉题（原型 .startup-eyebrow）
        Text('OBSIDIAN NOTES')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .letterSpacing(FontSize.caption * Startup.eyebrowTrackingRatio)
          .offset({ x: FontSize.caption * Startup.eyebrowTrackingRatio / 2 })
          .margin({ top: -Space.s3 })
          .opacity(this.eyebrowOpacity)

        // 发丝线（原型 .startup-rule）：两端渐隐
        Row()
          .width(Startup.ruleW)
          .height(Startup.ruleStroke)
          .linearGradient({
            angle: 90,
            colors: [[Color.Transparent, 0], [$r('app.color.text_secondary'), 0.5], [Color.Transparent, 1]]
          })
          .opacity(this.ruleOpacity)

        // 名言 + 出处（原型 .startup-quote）：正文与出处分组错峰
        Column() {
          Column({ space: Space.s1 }) {
            ForEach(this.quoteLines, (line: string) => {
              Text(line)
                .fontSize(Startup.quoteSize)
                .fontColor($r('app.color.text_primary'))
                .fontFamily('serif')
                .lineHeight(Startup.quoteSize * Startup.quoteLeading)
                .letterSpacing(Startup.quoteSize * Startup.quoteTrackingRatio)
            })
          }
          .alignItems(HorizontalAlign.Center)
          .opacity(this.quoteOpacity)
          .translate({ y: this.quoteTranslateY })

          Text('—— ' + this.quote.source)
            .fontSize(Startup.sourceSize)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('serif')
            .letterSpacing(Startup.sourceSize * Startup.quoteTrackingRatio)
            .margin({ top: Space.s3 })
            .opacity(this.sourceOpacity)
        }
        .alignItems(HorizontalAlign.Center)
        .constraintSize({ maxWidth: Startup.quoteMaxW })
      }
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .padding({ left: Space.s6, right: Space.s6 })
      .scale({ x: this.stageScale, y: this.stageScale })

      // 页脚（原型 .startup-foot）：中文数字日期；「轻触进入」仅原型演示用，原生不做
      Text(this.footDate)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .fontFamily('serif')
        .letterSpacing(FontSize.caption * Startup.footTrackingRatio)
        .margin({ bottom: Startup.footBottom })
        .opacity(this.footOpacity)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .opacity(this.maskOpacity)
    .visibility(this.maskGone ? Visibility.None : Visibility.Visible)
    .accessibilityLevel('no')
    .onClick((): void => {
    })
  }

  private scheduleEnter(delay: number, enter: () => void): void {
    this.enterTimers.push(setTimeout((): void => {
      enter();
    }, delay));
  }

  private clearEnterTimers(): void {
    for (let i = 0; i < this.enterTimers.length; i++) {
      clearTimeout(this.enterTimers[i]);
    }
    this.enterTimers = [];
  }

  private enterIcon(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.iconOpacity = 1;
      this.iconTranslateY = 0;
      this.iconScale = 1;
    });
  }

  private enterName(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.nameOpacity = 1;
      this.nameTranslateY = 0;
    });
  }

  private enterEyebrow(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.eyebrowOpacity = 1;
    });
  }

  private enterRule(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.ruleOpacity = 1;
    });
  }

  private enterQuote(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.quoteOpacity = 1;
      this.quoteTranslateY = 0;
    });
  }

  private enterSource(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.sourceOpacity = 1;
    });
  }

  private enterFoot(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.footOpacity = 1;
    });
  }

  /** 就绪即中断入场，240ms 淡出后隐藏；不为动画延长启动。 */
  private onReadyChange(): void {
    if (this.ready && !this.exiting) {
      this.exiting = true;
      this.clearEnterTimers();
      this.getUIContext().animateTo({
        duration: Startup.exitDur,
        curve: Motion.navCurve,
        onFinish: (): void => {
          this.maskGone = true;
        }
      }, (): void => {
        this.maskOpacity = 0;
        this.stageScale = Startup.exitScaleTo;
      });
    }
  }
}
