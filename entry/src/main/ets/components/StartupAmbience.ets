/**
 * StartupAmbience.ets —— 启动页氛围层（v1.63）
 *
 * 设计真源：docs/prototype/v2/启动页设计.md §4；v2 原型 `.startup-aura` / `.startup-dust` / `.startup-mask::before`。
 * 自下而上：① 极光（容器外扩 20%、整层 blur 48，三团径向渐变 22 / 27 / 31s 漂移）
 * ② 纸感颗粒（Canvas ImageData 逐块随机灰度，近似 SVG feTurbulence）③ 浮尘（16 粒上浮）。
 * 三层均为装饰：整层 hitTestBehavior(None)，读屏由父层 accessibilityLevel('no') 覆盖。
 * 所有动效统一在根节点 onAppear 起播：ArkUI 禁止在 aboutToAppear 调用 animateTo / keyframeAnimateTo
 * （build 未执行、动画属性无初值，动画不会生效；见 api_notes U4 / 华为显式动画规范）。
 * reduceMotion 时不播放任何循环动效、不渲染浮尘，直接呈现静态终态（设计稿 §4）。
 * 无网络、无埋点、无日志；颜色 / 尺寸 / 时长只引用 token 或 Startup 常量（硬约束 17）。
 */
import { Motion, Radius, Startup } from '../common/Tokens';

interface DustSpec {
  xPercent: number;
  sizeVp: number;
  durationMs: number;
  delayMs: number;
  swayVp: number;
  peakOpacity: number;
}

/** 浮尘初始参数：位置 / 尺寸 / 周期 / 相位 / 摆幅 / 亮度均在冷启动时本地随机，无网络、无持久化。 */
function makeDustSpecs(count: number): DustSpec[] {
  const specs: DustSpec[] = [];
  for (let i = 0; i < count; i++) {
    const durationMs: number = Startup.dustMinDur +
      Math.random() * (Startup.dustMaxDur - Startup.dustMinDur);
    specs.push({
      xPercent: Math.random() * 100,
      sizeVp: Startup.dustMinSize + Math.random() * (Startup.dustMaxSize - Startup.dustMinSize),
      durationMs: durationMs,
      delayMs: -Math.random() * durationMs,
      swayVp: (Math.random() - 0.5) * Startup.dustSway,
      peakOpacity: Startup.dustMinOpacity +
        Math.random() * (Startup.dustMaxOpacity - Startup.dustMinOpacity)
    });
  }
  return specs;
}

/** 单粒浮尘：关键帧 0 → 淡入 → 中程摆动 → 淡出，整段无限循环；结束态透明，回到起点无可见跳变。 */
@Component
struct StartupDustMote {
  @Prop xPercent: number = 0;
  @Prop sizeVp: number = Startup.dustMinSize;
  @Prop durationMs: number = Startup.dustMinDur;
  @Prop delayMs: number = 0;
  @Prop swayVp: number = 0;
  @Prop peakOpacity: number = Startup.dustMinOpacity;
  @Prop travelVp: number = Startup.dustFallbackHeight * Startup.dustTravelRatio;
  @State private moteX: number = 0;
  @State private moteY: number = Startup.dustBottomOffset;
  @State private moteAlpha: number = 0;
  private moteStarted: boolean = false;

  /** 关键帧起播放在 onAppear：aboutToAppear 中动画属性无初值，keyframeAnimateTo 不会生效。 */
  private startRise(): void {
    if (this.moteStarted) {
      return;
    }
    this.moteStarted = true;
    const total: number = this.durationMs;
    const frames: KeyframeState[] = [
      {
        duration: total * Startup.dustFadeInRatio, curve: Curve.Linear,
        event: (): void => {
          this.moteAlpha = this.peakOpacity;
        }
      },
      {
        duration: total * (Startup.dustMidwayRatio - Startup.dustFadeInRatio), curve: Curve.Linear,
        event: (): void => {
          this.moteX = this.swayVp;
          this.moteY = -this.travelVp * Startup.dustMidTravelRatio;
        }
      },
      {
        duration: total * (Startup.dustFadeOutRatio - Startup.dustMidwayRatio), curve: Curve.Linear,
        event: (): void => {
          this.moteX = this.swayVp * Startup.dustSwayReturnRatio;
          this.moteY = -this.travelVp * Startup.dustFadeOutRatio;
        }
      },
      {
        duration: total * (1 - Startup.dustFadeOutRatio), curve: Curve.Linear,
        event: (): void => {
          this.moteAlpha = 0;
          this.moteX = 0;
          this.moteY = -this.travelVp;
        }
      }
    ];
    this.getUIContext().keyframeAnimateTo({ iterations: -1, delay: this.delayMs }, frames);
  }

  build() {
    Column()
      .width(this.sizeVp)
      .height(this.sizeVp)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.brand'))
      .shadow({
        radius: Startup.dustGlowRadius,
        color: $r('app.color.brand'),
        offsetX: 0,
        offsetY: 0
      })
      .position({ x: `${this.xPercent}%`, y: '100%' })
      .translate({ x: this.moteX, y: this.moteY })
      .opacity(this.moteAlpha)
      .hitTestBehavior(HitTestMode.None)
      .onAppear((): void => {
        this.startRise();
      })
  }
}

@Component
export struct StartupAmbience {
  /** 减少动态效果：不走入场 / 循环，不显示浮尘。系统偏好读取仍未核实（api_notes U1），由宿主传入。 */
  @Prop reduceMotion: boolean = false;
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
  @StorageProp('windowHeightVp') windowHeightVp: number = 0;
  @StorageProp('appTheme') @Watch('onThemeChange') theme: string = 'light';
  @State private auraFade: number = 0;
  @State private driftA: number = 0;
  @State private driftB: number = 0;
  @State private driftC: number = 0;
  private dustSpecs: DustSpec[] = [];
  private ambienceStarted: boolean = false;
  private grainContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  aboutToAppear(): void {
    // 只做数据准备与减动效终态；不在生命周期里调用动画 API（见 api_notes U4）。
    this.dustSpecs = makeDustSpecs(Startup.dustCount);
    if (this.reduceMotion) {
      this.auraFade = 1;
    }
  }

  /** 布局与渲染完成后起播：极光 1.6s 淡入 + 三团无限漂移；守卫避免 onAppear 重复触发叠加循环。 */
  private startAmbience(): void {
    if (this.ambienceStarted || this.reduceMotion) {
      return;
    }
    this.ambienceStarted = true;
    this.getUIContext().animateTo({ duration: Startup.auraFadeDur, curve: Motion.navCurve }, (): void => {
      this.auraFade = 1;
    });
    this.playDrift(Startup.auraDurA, (value: number): void => {
      this.driftA = value;
    });
    this.playDrift(Startup.auraDurB, (value: number): void => {
      this.driftB = value;
    });
    this.playDrift(Startup.auraDurC, (value: number): void => {
      this.driftC = value;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 极光：原型 `.startup-aura{inset:-20%;filter:blur(48px)}` —— 容器外扩 20%，整层只模糊一次
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width(this.auraLargeSize())
          .height(this.auraLargeSize())
          .borderRadius(Radius.full)
          .radialGradient({
            center: [this.auraLargeSize() / 2, this.auraLargeSize() / 2],
            radius: this.auraLargeSize() / 2,
            colors: [[$r('app.color.brand'), 0], [$r('app.color.bg_card_transparent'), 1]]
          })
          .opacity(Startup.auraOpacityBlue * this.auraFade)
          .position({ x: Startup.auraPosAX, y: Startup.auraPosAY })
          .translate({ x: this.driftA * this.auraDriftX(), y: this.driftA * this.auraDriftY() })
          .scale({
            x: 1 + this.driftA * Startup.auraScaleDelta,
            y: 1 + this.driftA * Startup.auraScaleDelta
          })
          .hitTestBehavior(HitTestMode.None)

        Column()
          .width(this.auraLargeSize())
          .height(this.auraLargeSize())
          .borderRadius(Radius.full)
          .radialGradient({
            center: [this.auraLargeSize() / 2, this.auraLargeSize() / 2],
            radius: this.auraLargeSize() / 2,
            colors: [[$r('app.color.startup_aura_purple'), 0], [$r('app.color.bg_card_transparent'), 1]]
          })
          .opacity(Startup.auraOpacityPurple * this.auraFade)
          .position({ x: Startup.auraPosBX, y: Startup.auraPosBY })
          .markAnchor({ x: '100%', y: '100%' })
          .translate({ x: -this.driftB * this.auraDriftX(), y: -this.driftB * this.auraDriftY() })
          .scale({
            x: 1 - this.driftB * Startup.auraScaleDeltaB,
            y: 1 - this.driftB * Startup.auraScaleDeltaB
          })
          .hitTestBehavior(HitTestMode.None)

        Column()
          .width(this.auraSmallSize())
          .height(this.auraSmallSize())
          .borderRadius(Radius.full)
          .radialGradient({
            center: [this.auraSmallSize() / 2, this.auraSmallSize() / 2],
            radius: this.auraSmallSize() / 2,
            colors: [[$r('app.color.success'), 0], [$r('app.color.bg_card_transparent'), 1]]
          })
          .opacity(Startup.auraOpacityGreen * this.auraFade)
          .position({ x: Startup.auraPosCX, y: Startup.auraPosCY })
          .translate({ x: -this.driftC * this.auraDriftX(), y: -this.driftC * this.auraDriftY() })
          .scale({
            x: 1 + this.driftC * Startup.auraScaleDelta,
            y: 1 + this.driftC * Startup.auraScaleDelta
          })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(Startup.auraContainerSize)
      .height(Startup.auraContainerSize)
      .position({ x: Startup.auraContainerInset, y: Startup.auraContainerInset })
      .blur(Startup.auraBlur)
      .hitTestBehavior(HitTestMode.None)

      // ② 纸感颗粒：ImageData 逐块随机灰度；浅色深灰 7% / 深色白 5%
      Canvas(this.grainContext)
        .width('100%')
        .height('100%')
        .onReady((): void => {
          this.drawGrain();
        })
        .hitTestBehavior(HitTestMode.None)

      // ③ 浮尘：自下而上缓升并轻微摆动，减少动态效果时整层不渲染
      if (!this.reduceMotion) {
        ForEach(this.dustSpecs, (spec: DustSpec) => {
          StartupDustMote({
            xPercent: spec.xPercent,
            sizeVp: spec.sizeVp,
            durationMs: spec.durationMs,
            delayMs: spec.delayMs,
            swayVp: spec.swayVp,
            peakOpacity: spec.peakOpacity,
            travelVp: this.dustTravel()
          })
        }, (spec: DustSpec, index: number): string => 'startup-dust-' + index)
      }
    }
    .width('100%')
    .height('100%')
    .onAppear((): void => {
      this.startAmbience();
    })
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }

  /** 往返漂移：0 → 1 → 0 两段关键帧无限循环，终态回到起点（不用 PlayMode.Alternate，避免无限轮次的播放模式限制）。 */
  private playDrift(durationMs: number, apply: (value: number) => void): void {
    const half: number = durationMs / 2;
    const frames: KeyframeState[] = [
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          apply(1);
        }
      },
      {
        duration: half, curve: Curve.EaseInOut,
        event: (): void => {
          apply(0);
        }
      }
    ];
    this.getUIContext().keyframeAnimateTo({ iterations: -1 }, frames);
  }

  private vmax(): number {
    const measured: number = Math.max(this.windowWidthVp, this.windowHeightVp);
    return measured > 0 ? measured : Startup.auraFallbackVmax;
  }

  private auraLargeSize(): number {
    return this.vmax() * Startup.auraLargeSizeRatio;
  }

  private auraSmallSize(): number {
    return this.vmax() * Startup.auraSmallSizeRatio;
  }

  private auraDriftX(): number {
    return this.auraLargeSize() * Startup.auraDriftXRatio;
  }

  private auraDriftY(): number {
    return this.auraLargeSize() * Startup.auraDriftYRatio;
  }

  private dustTravel(): number {
    const height: number = this.windowHeightVp > 0 ? this.windowHeightVp : Startup.dustFallbackHeight;
    return height * Startup.dustTravelRatio;
  }

  private onThemeChange(): void {
    this.drawGrain();
  }

  /** 原型 SVG feTurbulence + multiply / screen：ImageData 逐块随机灰度，低 alpha 半透明叠加近似（不启用离屏混合）。 */
  private drawGrain(): void {
    const ctx: CanvasRenderingContext2D = this.grainContext;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const dark: boolean = this.theme === 'dark';
    const rgb: number[] = dark ? Startup.grainDarkRGB : Startup.grainLightRGB;
    const maxAlpha: number = dark ? Startup.grainDarkAlpha : Startup.grainLightAlpha;
    const step: number = Startup.grainNoiseStep;
    const image: ImageData = ctx.createImageData(w, h);
    const data: Uint8ClampedArray = image.data;
    for (let y = 0; y < h; y += step) {
      for (let x = 0; x < w; x += step) {
        const alpha: number = Math.round(Math.random() * maxAlpha * 255);
        for (let dy = 0; dy < step && y + dy < h; dy++) {
          for (let dx = 0; dx < step && x + dx < w; dx++) {
            const at: number = ((y + dy) * w + x + dx) * 4;
            data[at] = rgb[0];
            data[at + 1] = rgb[1];
            data[at + 2] = rgb[2];
            data[at + 3] = alpha;
          }
        }
      }
    }
    ctx.putImageData(image, 0, 0);
  }
}
