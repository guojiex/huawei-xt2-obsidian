/**
 * StartupMask.ets —— 冷启动品牌遮罩（设计稿 §4 1:1 还原）
 *
 * 设计真源：docs/prototype/v2/index.html `.startup-*`（914–969）+ 启动页设计.md。
 * 冷启动期间盖住工作区：底色 + 氛围层（StartupAmbience）+ 品牌层（图标 / 品牌名 / 随机名言 / 页脚）。
 * 衬线字体由 rawfile 静态子集注册（系统只有 HarmonyOS Sans，通用 serif 族名会回退黑体）。
 * 入场按设计稿 §4 编排：极光淡入 → 图标上浮去模糊 → 光晕淡入 → 品牌名逐字去模糊 →
 * 眉题 / 发丝线展开 → 名言逐字去模糊 → 出处 / 页脚淡入；图标轻浮、光晕呼吸、高光斜扫为持续循环。
 * 就绪且编排播完才 240ms 淡出并隐藏，入场不被提前打断。
 * reduceMotion：直接呈现终态、退出直接切换；系统偏好读取仍未核实（api_notes U1），由宿主传入。
 * v1.65：screenSaver=true 时同一套视觉常驻为屏保 / 台历——不自动淡出、按配置间隔轮换名言、
 * 点击任意处淡出后回调 onExit；默认 false 保持冷启动路径零改动。
 * 装饰层不参与读屏（accessibilityLevel('no')），无埋点、无网络。
 */
import { FontSize, Motion, Radius, Shadow, ScreenSaver, Space, Startup, Weight } from '../common/Tokens';
import { StartupAmbience } from './StartupAmbience';

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

/** 自定义字体全局只注册一次；$rawfile 路径是编译期字面量，不能由 token 传入。 */
let startupSerifRegistered: boolean = false;

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
  /** 工作区恢复就绪（Index 的 workspaceInitialRenderReady）：true 后等编排播完再淡出。 */
  @Prop @Watch('onReadyChange') ready: boolean = false;
  /** 减少动态效果：不播放入场 / 循环、不显示浮尘，直接终态；系统偏好读取仍未核实（api_notes U1）。 */
  @Prop reduceMotion: boolean = false;
  /** v1.65 65.2：屏保 / 台历模式；默认 false 保持冷启动路径零改动。 */
  @Prop screenSaver: boolean = false;
  /** 名言轮换间隔（ms），0 = 不轮换；仅屏保模式生效，档位真源 ScreenSaver.intervalOptions。 */
  @Prop quoteIntervalMs: number = ScreenSaver.defaultIntervalMs;
  /** 屏保点击退出：组件内淡出完成后回调，由宿主卸载覆盖层。 */
  onExit: () => void = (): void => {};
  @State private maskOpacity: number = 1;
  @State private maskGone: boolean = false;
  @State private ambienceOn: boolean = true;
  @State private stageScale: number = 1;
  @State private iconOpacity: number = 0;
  @State private iconTranslateY: number = Startup.iconEnterFromY;
  @State private iconScale: number = Startup.iconEnterFromScale;
  @State private iconBlur: number = Startup.iconEnterFromBlur;
  @State private iconFloatY: number = 0;
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
  @State private haloEnterOpacity: number = 0;
  @State private haloBreathOpacity: number = Startup.haloBreathMinOpacity;
  @State private haloBreathScale: number = Startup.haloBreathMinScale;
  @State private sheenX: number = -Startup.iconSize * Startup.sheenTravelRatio;
  @State private nameCharOpacity: number[] = [];
  @State private eyebrowOpacity: number = 0;
  @State private ruleOpacity: number = 0;
  @State private ruleScaleX: number = Startup.ruleScaleFrom;
  @State private quoteCharOpacity: number[] = [];
  @State private sourceOpacity: number = 0;
  @State private footOpacity: number = 0;
  /** v1.65 65.3：换句时整组淡出 / 淡入，不改动逐字 opacity 数组。 */
  @State private quoteGroupOpacity: number = 1;
  private quote: QuoteEntry = QUOTES[Math.floor(Math.random() * QUOTES.length)];
  private quoteLines: string[] = [];
  private nameChars: string[] = [];
  private quoteLineChars: string[][] = [];
  private quoteLineOffsets: number[] = [];
  private quoteCharCount: number = 0;
  private footDate: string = '';
  private enterTimers: number[] = [];
  private exiting: boolean = false;
  private startAt: number = 0;
  /** 本句名言的实际编排完成时刻（ms）：出处淡入完成与末字浮现完成取较晚，再与 minHold 取较晚。 */
  private holdMs: number = Startup.minHold;
  private sourceAt: number = Startup.enterQuoteDelay;
  private exitTimer: number = -1;
  /** 当前名言下标：每次进入屏保随机起点；轮换按序取下一句。 */
  private quoteIndex: number = Math.floor(Math.random() * QUOTES.length);
  private rotateTimer: number = -1;
  private rotateTimers: number[] = [];
  private saverExiting: boolean = false;

  aboutToAppear(): void {
    this.registerStartupSerif();
    this.quote = QUOTES[this.quoteIndex];
    this.startAt = Date.now();
    this.footDate = formatCnDate(new Date());
    this.nameChars = '曜石笔记'.split('');
    this.quoteLines = splitQuoteLines(this.quote.text);
    let total: number = 0;
    for (let i = 0; i < this.quoteLines.length; i++) {
      this.quoteLineOffsets.push(total);
      const chars: string[] = this.quoteLines[i].split('');
      this.quoteLineChars.push(chars);
      total += chars.length;
    }
    this.quoteCharCount = total;
    this.nameCharOpacity = this.zeros(this.nameChars.length);
    this.quoteCharOpacity = this.zeros(total);
    this.sourceAt = Startup.enterQuoteDelay + total * Startup.quoteCharInterval +
      Startup.sourceAfterLastChar;
    this.holdMs = Math.max(Startup.minHold, this.sourceAt + Startup.enterDur,
      Startup.enterQuoteDelay + (total - 1) * Startup.quoteCharInterval + Startup.charEnterDur);
    if (this.reduceMotion) {
      this.showFinalState();
      this.scheduleRotate(ScreenSaver.firstRotateDelay);
      return;
    }
    this.scheduleEnter(Startup.enterIconDelay, (): void => {
      this.enterIcon();
    });
    this.scheduleEnter(Startup.enterHaloDelay, (): void => {
      this.enterHalo();
    });
    for (let i = 0; i < this.nameChars.length; i++) {
      this.scheduleEnter(Startup.nameCharStart + i * Startup.nameCharInterval, (): void => {
        this.revealNameChar(i);
      });
    }
    this.scheduleEnter(Startup.enterEyebrowDelay, (): void => {
      this.enterEyebrow();
    });
    this.scheduleEnter(Startup.enterRuleDelay, (): void => {
      this.enterRule();
    });
    for (let i = 0; i < total; i++) {
      this.scheduleEnter(Startup.enterQuoteDelay + i * Startup.quoteCharInterval, (): void => {
        this.revealQuoteChar(i);
      });
    }
    this.scheduleEnter(this.sourceAt, (): void => {
      this.enterSource();
    });
    this.scheduleEnter(Startup.enterFootDelay, (): void => {
      this.enterFoot();
    });
    this.scheduleEnter(Startup.loopSheenDelay, (): void => {
      this.playSheen();
    });
    this.scheduleEnter(Startup.loopIconDelay, (): void => {
      this.playIconFloat();
    });
    this.scheduleEnter(Startup.loopHaloDelay, (): void => {
      this.playHaloBreath();
    });
    // 屏保：入场编排播完后再起算第一次轮换，不打断逐字浮现（65.3）。
    this.scheduleRotate(ScreenSaver.firstRotateDelay);
  }

  aboutToDisappear(): void {
    this.clearEnterTimers();
    this.clearRotateTimers();
    if (this.exitTimer >= 0) {
      clearTimeout(this.exitTimer);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 氛围层：极光 / 颗粒 / 浮尘；整层不拦截命中、不参与读屏
      if (this.ambienceOn) {
        StartupAmbience({ reduceMotion: this.reduceMotion })
      }

      Column() {
        // 品牌主体：在剩余空间内居中（原型 .startup-stage）
        Column({ space: Space.s4 }) {
          Stack({ alignContent: Alignment.Center }) {
            // 光晕（原型 .startup-halo）：淡入后按 5s 周期呼吸
            Column()
              .width(Startup.iconSize + Startup.haloPad * 2)
              .height(Startup.iconSize + Startup.haloPad * 2)
              .borderRadius(Radius.full)
              .radialGradient({
                center: [Startup.iconSize / 2 + Startup.haloPad, Startup.iconSize / 2 + Startup.haloPad],
                radius: Startup.iconSize / 2 + Startup.haloPad,
                colors: [[$r('app.color.brand'), 0], [Color.Transparent, 0.72]]
              })
              .opacity(Startup.haloOpacity * this.haloEnterOpacity * this.haloBreathOpacity)
              .scale({ x: this.haloBreathScale, y: this.haloBreathScale })
              .hitTestBehavior(HitTestMode.None)

            // 图标 + 斜扫高光：内层做 6s 周期轻浮，外层做入场，两层属性互不争用
            Stack({ alignContent: Alignment.Center }) {
              Stack({ alignContent: Alignment.Center }) {
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
                Column()
                  .width(Startup.iconSize)
                  .height(Startup.iconSize)
                  .linearGradient({
                    angle: Startup.sheenAngle,
                    colors: [
                      [$r('app.color.bg_card_transparent'), 0],
                      [Startup.sheenColor, 0.5],
                      [$r('app.color.bg_card_transparent'), 1]
                    ]
                  })
                  .translate({ x: this.sheenX })
                  .hitTestBehavior(HitTestMode.None)
              }
              .width(Startup.iconSize)
              .height(Startup.iconSize)
              .borderRadius(Startup.iconRadius)
              .clip(true)
              .blur(this.iconBlur)
            }
            .width(Startup.iconSize)
            .height(Startup.iconSize)
            .translate({ y: this.iconFloatY })
          }
          .width(Startup.iconSize + Startup.haloPad * 2)
          .height(Startup.iconSize + Startup.haloPad * 2)
          .opacity(this.iconOpacity)
          .translate({ y: this.iconTranslateY })
          .scale({ x: this.iconScale, y: this.iconScale })
          .margin({ bottom: Space.s2 })

          // 品牌名（原型 .startup-name）：衬线 600、逐字去模糊浮现，末字空隙用 offset 半宽补偿居中
          Row() {
            ForEach(this.nameChars, (ch: string, index: number) => {
              Text(ch)
                .fontSize(Startup.nameSize)
                .fontWeight(Weight.semibold)
                .fontColor($r('app.color.text_primary'))
                .fontFamily(Startup.serifSemiboldFamily)
                .letterSpacing(Startup.nameSize * Startup.nameTrackingRatio)
                .opacity(this.nameCharOpacity[index])
                .translate({ y: (1 - this.nameCharOpacity[index]) * Startup.charEnterFromY })
                .blur((1 - this.nameCharOpacity[index]) * Startup.nameCharBlur)
            }, (ch: string, index: number): string => 'startup-name-' + index)
          }
          .offset({ x: Startup.nameSize * Startup.nameTrackingRatio / 2 })

          // 眉题（原型 .startup-eyebrow）
          Text('OBSIDIAN NOTES')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .letterSpacing(FontSize.caption * Startup.eyebrowTrackingRatio)
            .offset({ x: FontSize.caption * Startup.eyebrowTrackingRatio / 2 })
            .margin({ top: -Space.s3 })
            .opacity(this.eyebrowOpacity)

          // 发丝线（原型 .startup-rule）：两端渐隐，自中向两侧展开
          Row()
            .width(Startup.ruleW)
            .height(Startup.ruleStroke)
            .linearGradient({
              angle: 90,
              colors: [[Color.Transparent, 0], [$r('app.color.text_secondary'), 0.5], [Color.Transparent, 1]]
            })
            .scale({ x: this.ruleScaleX, y: 1 })
            .opacity(this.ruleOpacity)

          // 名言 + 出处（原型 .startup-quote）：大号引号 + 按分句断行逐字去模糊浮现
          Stack({ alignContent: Alignment.TopStart }) {
            Text('“')
              .fontSize(FontSize.heading * Startup.quoteMarkSizeRatio)
              .fontFamily(Startup.serifFamily)
              .fontColor($r('app.color.brand'))
              .opacity(Startup.quoteMarkOpacity)
              .position({
                x: -FontSize.heading * Startup.quoteMarkSizeRatio * Startup.quoteMarkLeftRatio,
                y: -FontSize.heading * Startup.quoteMarkSizeRatio * Startup.quoteMarkTopRatio
              })
              .hitTestBehavior(HitTestMode.None)

            Column() {
              Column({ space: Space.s1 }) {
                ForEach(this.quoteLineChars, (line: string[], lineIndex: number) => {
                  // 行尾中文标点悬挂在正文之外，按正文居中。
                  Row() {
                    ForEach(line, (ch: string, charIndex: number) => {
                      Text(ch)
                        .fontSize(this.quoteFontSize())
                        .fontColor($r('app.color.text_primary'))
                        .fontFamily(Startup.serifFamily)
                        .lineHeight(this.quoteFontSize() * Startup.quoteLeading)
                        .letterSpacing(this.quoteFontSize() * Startup.quoteTrackingRatio)
                        .opacity(this.quoteCharOpacity[this.quoteLineOffsets[lineIndex] + charIndex])
                        .translate({ y: (1 - this.quoteCharOpacity[this.quoteLineOffsets[lineIndex] + charIndex]) * Startup.charEnterFromY })
                        .blur((1 - this.quoteCharOpacity[this.quoteLineOffsets[lineIndex] + charIndex]) * Startup.quoteCharBlur)
                    }, (ch: string, index: number): string => 'startup-quote-' + lineIndex + '-' + index)
                  }
                  .offset({ x: this.quoteFontSize() * Startup.quotePunctuationOffsetRatio })
                }, (line: string[], index: number): string => 'startup-quote-line-' + index)
              }
              .alignItems(HorizontalAlign.Center)

              Text('—— ' + this.quote.source)
                .fontSize(Startup.sourceSize)
                .fontColor($r('app.color.text_secondary'))
                .fontFamily(Startup.serifFamily)
                .letterSpacing(Startup.sourceSize * Startup.sourceTrackingRatio)
                .margin({ top: Space.s3 })
                .opacity(this.sourceOpacity)
            }
            .alignItems(HorizontalAlign.Center)
            .constraintSize({ maxWidth: this.quoteFontSize() * Startup.quoteMaxEm })
          }
          .opacity(this.quoteGroupOpacity)
        }
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ left: Space.s6, right: Space.s6 })
        .scale({ x: this.stageScale, y: this.stageScale })

        // 页脚（原型 .startup-foot）：中文数字日期；屏保模式放大为台历日期并补退出提示
        Text(this.footDate)
          .fontSize(this.screenSaver ? ScreenSaver.dateSize : FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .fontFamily(Startup.serifFamily)
          .letterSpacing(FontSize.caption * Startup.footTrackingRatio)
          .margin({ bottom: this.screenSaver ? Space.s2 : Startup.footBottom })
          .opacity(this.footOpacity)
        if (this.screenSaver) {
          Text(ScreenSaver.hintText)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily(Startup.serifFamily)
            .letterSpacing(FontSize.caption * Startup.footTrackingRatio)
            .margin({ bottom: Startup.footBottom })
            .opacity(this.footOpacity * ScreenSaver.hintOpacity)
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .opacity(this.maskOpacity)
    .visibility(this.maskGone ? Visibility.None : Visibility.Visible)
    .accessibilityLevel('no')
    .onClick((): void => {
      // 冷启动仍吞掉点击；屏保点击任意处淡出退出（65.4）。
      if (this.screenSaver) {
        this.exitScreenSaver();
      }
    })
  }

  /** 注册衬线字体子集：系统只有 HarmonyOS Sans，必须用自定义字体才能还原原型 --serif。 */
  private registerStartupSerif(): void {
    if (startupSerifRegistered) {
      return;
    }
    this.getUIContext().getFont().registerFont({
      familyName: Startup.serifFamily,
      familySrc: $rawfile('fonts/StartupSerif-Regular.ttf')
    });
    this.getUIContext().getFont().registerFont({
      familyName: Startup.serifSemiboldFamily,
      familySrc: $rawfile('fonts/StartupSerif-Semibold.ttf')
    });
    startupSerifRegistered = true;
  }

  /** 原型 clamp(17px, 1.2vw + 9px, 23px)：1vw = 窗口宽 1%，无窗口尺寸时回退基准 20。 */
  private quoteFontSize(): number {
    if (this.windowWidthVp <= 0) {
      return Startup.quoteSize;
    }
    const scaled: number = this.windowWidthVp * Startup.quoteSizeVwRatio + Startup.quoteSizeBase;
    return Math.min(Startup.quoteSizeMax, Math.max(Startup.quoteSizeMin, scaled));
  }

  private zeros(count: number): number[] {
    const values: number[] = [];
    for (let i = 0; i < count; i++) {
      values.push(0);
    }
    return values;
  }

  private ones(count: number): number[] {
    const values: number[] = [];
    for (let i = 0; i < count; i++) {
      values.push(1);
    }
    return values;
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

  /** 减少动态效果：所有入场状态直接置终态，不注册定时器、不启动循环。 */
  private showFinalState(): void {
    this.iconOpacity = 1;
    this.iconTranslateY = 0;
    this.iconScale = 1;
    this.iconBlur = 0;
    this.haloEnterOpacity = 1;
    this.haloBreathOpacity = 1;
    this.haloBreathScale = 1;
    this.nameCharOpacity = this.ones(this.nameChars.length);
    this.eyebrowOpacity = 1;
    this.ruleOpacity = 1;
    this.ruleScaleX = 1;
    this.quoteCharOpacity = this.ones(this.quoteCharCount);
    this.sourceOpacity = 1;
    this.footOpacity = 1;
  }

  private enterIcon(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.iconOpacity = 1;
      this.iconTranslateY = 0;
      this.iconScale = 1;
      this.iconBlur = 0;
    });
  }

  private enterHalo(): void {
    this.getUIContext().animateTo({ duration: Startup.enterDur, curve: Motion.navCurve }, (): void => {
      this.haloEnterOpacity = 1;
    });
  }

  /** 逐字浮现：数组整体替换以触发 @State 刷新，animateTo 负责 opacity / translate 插值。 */
  private revealNameChar(index: number): void {
    this.getUIContext().animateTo({ duration: Startup.charEnterDur, curve: Motion.navCurve }, (): void => {
      const next: number[] = this.nameCharOpacity.slice();
      next[index] = 1;
      this.nameCharOpacity = next;
    });
  }

  private revealQuoteChar(index: number): void {
    this.getUIContext().animateTo({ duration: Startup.charEnterDur, curve: Motion.navCurve }, (): void => {
      const next: number[] = this.quoteCharOpacity.slice();
      next[index] = 1;
      this.quoteCharOpacity = next;
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
      this.ruleScaleX = 1;
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

  /** 6s 周期轻浮：0 → -5vp → 0，终态回到起点，循环无跳变。 */
  private playIconFloat(): void {
    const half: number = Startup.floatDur / 2;
    const frames: KeyframeState[] = [
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          this.iconFloatY = -Startup.floatAmplitude;
        }
      },
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          this.iconFloatY = 0;
        }
      }
    ];
    this.getUIContext().keyframeAnimateTo({ iterations: -1 }, frames);
  }

  /** 5s 周期呼吸：0.65 / 0.92 → 1 / 1.08 → 回到最小态。 */
  private playHaloBreath(): void {
    const half: number = Startup.haloBreathDur / 2;
    const frames: KeyframeState[] = [
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          this.haloBreathOpacity = 1;
          this.haloBreathScale = Startup.haloBreathMaxScale;
        }
      },
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          this.haloBreathOpacity = Startup.haloBreathMinOpacity;
          this.haloBreathScale = Startup.haloBreathMinScale;
        }
      }
    ];
    this.getUIContext().keyframeAnimateTo({ iterations: -1 }, frames);
  }

  /** 6s 周期斜扫：前 26% 从 -130% 扫到 +130%，其余停留；循环回到起点时高光在裁剪区外，不可见。 */
  private playSheen(): void {
    const to: number = Startup.iconSize * Startup.sheenTravelRatio;
    const frames: KeyframeState[] = [
      {
        duration: Startup.sheenDur * Startup.sheenSweepRatio, curve: Curve.EaseInOut,
        event: (): void => {
          this.sheenX = to;
        }
      },
      {
        duration: Startup.sheenDur * (1 - Startup.sheenSweepRatio), curve: Curve.Linear,
        event: (): void => {
          this.sheenX = to;
        }
      }
    ];
    this.getUIContext().keyframeAnimateTo({ iterations: -1 }, frames);
  }

  /** duration 0 的属性变更停止该属性的无限循环（SDK AnimateParam 注释）；氛围层靠组件销毁停止。 */
  private stopBrandLoops(): void {
    this.getUIContext().animateTo({ duration: 0 }, (): void => {
      this.iconFloatY = 0;
      this.haloBreathOpacity = 1;
      this.haloBreathScale = 1;
      this.sheenX = -Startup.iconSize * Startup.sheenTravelRatio;
    });
  }

  /** v1.65 65.3：换句时重算逐字数组，并清掉上一轮未播完的逐字定时器。 */
  private applyQuote(index: number): void {
    this.clearRotateTimers();
    this.quoteIndex = index;
    this.quote = QUOTES[index];
    this.quoteLines = splitQuoteLines(this.quote.text);
    this.quoteLineChars = [];
    this.quoteLineOffsets = [];
    let total: number = 0;
    for (let i = 0; i < this.quoteLines.length; i++) {
      this.quoteLineOffsets.push(total);
      const chars: string[] = this.quoteLines[i].split('');
      this.quoteLineChars.push(chars);
      total += chars.length;
    }
    this.quoteCharCount = total;
    this.quoteCharOpacity = this.zeros(total);
    this.sourceOpacity = 0;
  }

  /** 递归 setTimeout 排程：间隔 0 / 退出中 / 非屏保都不排；不启用周期轮询计时器。 */
  private scheduleRotate(delay: number): void {
    if (!this.screenSaver || this.saverExiting || this.quoteIntervalMs <= 0) {
      return;
    }
    this.clearRotateTimer();
    this.rotateTimer = setTimeout((): void => {
      this.rotateQuote();
    }, delay);
  }

  private rotateQuote(): void {
    if (!this.screenSaver || this.saverExiting) {
      return;
    }
    const next: number = (this.quoteIndex + 1) % QUOTES.length;
    if (this.reduceMotion) {
      this.applyQuote(next);
      this.quoteCharOpacity = this.ones(this.quoteCharCount);
      this.sourceOpacity = 1;
      this.scheduleRotate(this.quoteIntervalMs);
      return;
    }
    this.getUIContext().animateTo({
      duration: ScreenSaver.rotateFadeDur,
      curve: Motion.navCurve,
      onFinish: (): void => {
        this.applyQuote(next);
        // 淡入与逐字浮现挪到下一轮事件循环，避免在 onFinish 内嵌套动画。
        this.rotateTimers.push(setTimeout((): void => {
          this.getUIContext().animateTo({
            duration: ScreenSaver.rotateFadeDur,
            curve: Motion.navCurve
          }, (): void => {
            this.quoteGroupOpacity = 1;
          });
          this.revealRotatedQuote();
          this.scheduleRotate(this.quoteIntervalMs);
        }, 0));
      }
    }, (): void => {
      this.quoteGroupOpacity = 0;
    });
  }

  /** 换句后的逐字浮现 + 出处淡入；定时器集中登记，退出时一次性清理。 */
  private revealRotatedQuote(): void {
    const total: number = this.quoteCharCount;
    for (let i = 0; i < total; i++) {
      this.rotateTimers.push(setTimeout((): void => {
        this.revealQuoteChar(i);
      }, i * Startup.quoteCharInterval));
    }
    this.rotateTimers.push(setTimeout((): void => {
      this.enterSource();
    }, total * Startup.quoteCharInterval + Startup.sourceAfterLastChar));
  }

  private clearRotateTimer(): void {
    if (this.rotateTimer >= 0) {
      clearTimeout(this.rotateTimer);
      this.rotateTimer = -1;
    }
  }

  private clearRotateTimers(): void {
    this.clearRotateTimer();
    for (let i = 0; i < this.rotateTimers.length; i++) {
      clearTimeout(this.rotateTimers[i]);
    }
    this.rotateTimers = [];
  }

  /** v1.65 65.4：点击任意处淡出退出；回调宿主卸载覆盖层并回到笔记工作区。 */
  private exitScreenSaver(): void {
    if (!this.screenSaver || this.saverExiting) {
      return;
    }
    this.saverExiting = true;
    this.clearEnterTimers();
    this.clearRotateTimers();
    if (this.reduceMotion) {
      this.onExit();
      return;
    }
    this.stopBrandLoops();
    this.getUIContext().animateTo({
      duration: Startup.exitDur,
      curve: Motion.navCurve,
      onFinish: (): void => {
        this.onExit();
      }
    }, (): void => {
      this.maskOpacity = 0;
      this.stageScale = Startup.exitScaleTo;
    });
  }

  /** 就绪后仍等编排播完（holdMs）才淡出，避免逐字动画被提前打断。 */
  private onReadyChange(): void {
    if (!this.ready || this.exiting || this.screenSaver) {
      return;
    }
    const elapsed: number = Date.now() - this.startAt;
    const wait: number = Math.max(this.holdMs - elapsed, 0);
    this.exitTimer = setTimeout((): void => {
      this.startExit();
    }, wait);
  }

  private startExit(): void {
    if (this.exiting) {
      return;
    }
    this.exiting = true;
    this.clearEnterTimers();
    if (this.reduceMotion) {
      this.maskGone = true;
      this.ambienceOn = false;
      return;
    }
    this.stopBrandLoops();
    this.getUIContext().animateTo({
      duration: Startup.exitDur,
      curve: Motion.navCurve,
      onFinish: (): void => {
        this.maskGone = true;
        this.ambienceOn = false;
      }
    }, (): void => {
      this.maskOpacity = 0;
      this.stageScale = Startup.exitScaleTo;
    });
  }
}
