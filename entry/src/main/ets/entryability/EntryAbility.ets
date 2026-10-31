import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { breakpointFromWidthVp } from '../model/Breakpoint';
import { appThemeForColorMode } from '../common/AppTheme';
import { VaultRegistry } from '../model/VaultRegistry';
import { AgentMemoryStore } from '../model/AgentMemoryStore';
import { AgentConfigStore } from '../model/AgentConfigStore';
import { AgentRuntime } from '../model/AgentRuntime';
import { NoteDraftService } from '../model/NoteDraftService';
import { SampleVaultInstaller } from '../model/SampleVaultInstaller';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';
/**
 * 折痕/FoldStatus 校准日志 tag。
 * 三折叠三屏态的 getFoldStatus 返回值官方未记载（api_notes.md A1 ❓），
 * 这些日志只用于真机采集数据点（TODO(真机校准)），不做任何形态映射、不参与布局计算。
 */
const FOLD_TAG = 'FoldCalibration';

interface ColorModeObserver {
  onColorModeUpdated: (colorMode: ConfigurationConstant.ColorMode) => void;
}

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /** onCreate 保留启动 Want —— 调试直达参数在这里面（见 resolveInitialPage）。 */
  private debugLaunchWant: Want | null = null;
  private colorModeObserverRegistered: boolean = false;
  private readonly keyboardAvoidAreaListener = (options: window.AvoidAreaOptions): void => {
    if (options.type !== window.AvoidAreaType.TYPE_KEYBOARD) {
      return;
    }
    this.publishKeyboardInset(options.area);
  };
  private readonly colorModeObserver: ColorModeObserver = {
    onColorModeUpdated: (colorMode: ConfigurationConstant.ColorMode): void => {
      this.publishAppTheme(colorMode);
    }
  };
  /** 上一次断点档位，用于判断档位切换才打校准日志（避免同档位重复刷屏）。 */
  private lastBreakpoint: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    this.debugLaunchWant = want;
  }

  /**
   * v1.5 临时核实直达（2026-10-31，与 ExternalDirProbePage 同生共死，正式实现落地后删除）：
   * `aa start -a EntryAbility -b com.jxg.huaweiobsidian --ps yaoshi_debug_page pages/ExternalDirProbePage`
   * 可以不经 Index 直接落到核实页 —— 设备上只有样例库（非 Git 库）时，
   * SyncPage 的入口根本不出现，人工走不到核实页。白名单只收当前唯一核实页，
   * 其他值一律回落 Index，不构成通用路由能力。
   */
  private resolveInitialPage(): string {
    const parameters = this.debugLaunchWant?.parameters;
    if (parameters !== undefined && parameters !== null) {
      const requested = parameters['yaoshi_debug_page'];
      if (typeof requested === 'string' && requested === 'pages/ExternalDirProbePage') {
        hilog.info(DOMAIN, TAG, '%{public}s', '调试直达 pages/ExternalDirProbePage');
        return requested;
      }
    }
    return 'pages/Index';
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // 库注册表单例初始化：必须先于 loadContent，页面侧才能直接 VaultRegistry.get()
    const registry: VaultRegistry = VaultRegistry.initialize(this.context);
    AgentConfigStore.initialize(this.context);
    AgentMemoryStore.initialize(registry);
    AgentRuntime.initialize(registry);
    NoteDraftService.cleanupOrphans(registry);

    // ===== 断点系统（T007）=====
    // 断点只由窗口宽度（vp）计算：window.on('windowSizeChange') + px2vp() 是官方推荐的
    // 统一断点机制（api_notes.md A3 ✅）。
    // 不用 getFoldDisplayMode() 做形态分支：该接口不返回全部形态值（api_notes.md A3）。
    const appContext = this.context.getApplicationContext();
    try {
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '设置跟随系统主题失败: %{public}s', JSON.stringify(err));
    }
    try {
      appContext.onSystemConfigurationUpdated(this.colorModeObserver);
      this.colorModeObserverRegistered = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '系统主题监听注册失败: %{public}s', JSON.stringify(err));
    }
    this.publishAppTheme(this.context.config?.colorMode);

    try {
      this.mainWindow = windowStage.getMainWindowSync();
      // loadContent 前补算初始断点：windowSizeChange 只在尺寸变化时触发，
      // 首帧等不到事件，不补算会出现「初始 sm、展开后才正确」的一帧错档。
      const props: window.WindowProperties = this.mainWindow.getWindowProperties();
      this.applyWindowSize(props.windowRect.width, props.windowRect.height);
      this.mainWindow.on('windowSizeChange', (size: window.Size) => {
        this.applyWindowSize(size.width, size.height);
      });
      this.mainWindow.on('avoidAreaChange', this.keyboardAvoidAreaListener);
      this.publishKeyboardInset(this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '断点监听注册失败: %{public}s', JSON.stringify(err));
    }

    // ===== 折痕 / FoldStatus 数据采集日志点（T014，TODO(真机校准)）=====
    this.registerFoldCalibrationLogging();

    void SampleVaultInstaller.install(registry).catch((error: Error): void => {
      hilog.error(DOMAIN, TAG, '样例库预置失败，保留已写入内容，不自动重试: %{public}s', error.message);
    }).then((): void => {
      windowStage.loadContent(this.resolveInitialPage(), (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      });
    });

  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    try {
      if (this.mainWindow !== null) {
        this.mainWindow.off('windowSizeChange');
        this.mainWindow.off('avoidAreaChange', this.keyboardAvoidAreaListener);
        this.mainWindow = null;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'windowSizeChange 注销失败: %{public}s', JSON.stringify(err));
    }
    try {
      // off 不传 callback = 注销本事件全部订阅（本类只订阅一处，安全）
      display.off('foldStatusChange');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'foldStatusChange 注销失败: %{public}s', JSON.stringify(err));
    }
    if (this.colorModeObserverRegistered) {
      try {
        this.context.getApplicationContext().offSystemConfigurationUpdated(this.colorModeObserver);
        this.colorModeObserverRegistered = false;
      } catch (error) {
        const err = error as BusinessError;
        hilog.error(DOMAIN, TAG, '系统主题监听注销失败: %{public}s', JSON.stringify(err));
      }
    }
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    void AgentMemoryStore.flushPending().catch((): void => {
      hilog.error(DOMAIN, TAG, 'Agent 草稿后台保存失败；保留原会话文件');
    });
  }

  /**
   * 断点计算与写入：宽度 vp → 半开区间判档 → AppStorage（key：breakpoint / windowWidthVp）。
   * UI 层用 @StorageProp('breakpoint') / @StorageProp('windowWidthVp') 消费。
   */
  private applyBreakpoint(widthVp: number): void {
    AppStorage.setOrCreate('windowWidthVp', widthVp);
    const bp: string = breakpointFromWidthVp(widthVp);
    if (bp !== this.lastBreakpoint) {
      this.lastBreakpoint = bp;
      this.logFoldCalibration(widthVp, bp);
    }
    AppStorage.setOrCreate('breakpoint', bp);
    // 每次尺寸变化都刷新 foldStatus（不受档位是否变化影响），供状态栏调试读数
    AppStorage.setOrCreate('foldStatus', this.collectFoldStatus());
    // 折痕只落 px，换算放到页面侧（UI 上下文）——官方提醒 px2vp 依赖窗口像素密度，
    // 在 UIAbility 早期生命周期换算可能异常
    AppStorage.setOrCreate('creasePx', this.collectCreasePx());
  }

  private publishKeyboardInset(area: window.AvoidArea): void {
    const keyboardHeightPx: number = area.visible ? area.bottomRect.height : 0;
    AppStorage.setOrCreate('keyboardInsetPx', Math.max(0, keyboardHeightPx));
  }

  private publishAppTheme(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    AppStorage.setOrCreate('appTheme', appThemeForColorMode(colorMode));
  }

  /** 同一窗口尺寸事件同时更新宽高，布局依据当前窗口，不假设设备折痕坐标。 */
  private applyWindowSize(widthPx: number, heightPx: number): void {
    this.applyBreakpoint(px2vp(widthPx));
    AppStorage.setOrCreate('windowHeightVp', px2vp(heightPx));
  }

  /**
   * 采集折痕中心 x（**px**，多条逗号分隔），优先实时接口、失败回退旧接口。
   *
   * 两个接口都试一遍是为了横向对比：
   * - `display.getLiveCreaseRegion()`   —— @since 20，官方答复推荐（SDK 实证：同步返回 FoldCreaseRegion）
   * - `display.getCurrentFoldCreaseRegion()` —— 旧接口，实测五种形态恒为 372,372（api_notes A2）
   *
   * ⚠️ 只读数与日志，绝不进布局算式（A3 / A6：栏宽只由窗口宽决定）。取不到返回 '-'，不抛出。
   */
  private collectCreasePx(): string {
    const current: string = this.readCreasePx(false);
    const live: string = this.readCreasePx(true);
    hilog.info(DOMAIN, FOLD_TAG, 'TODO(真机校准) crease current=%{public}s live=%{public}s', current, live);
    return (live !== '-') ? live : current;
  }

  /** 读一个折痕接口，返回各 rect 中心 x（px）逗号串；顺带把 left/宽/高打进日志（判折痕方向要用） */
  private readCreasePx(useLive: boolean): string {
    try {
      // ⚠️ 官方示例代码写的 display.getLiveCreaseRegion() 编译不过 —— SDK 实测它是
      // interface Display 的**实例方法**（@ohos.display.d.ts:1432，@since 20），
      // 而 getCurrentFoldCreaseRegion() 才是模块函数（同文件 425 行）。必须走实例。
      const region: display.FoldCreaseRegion =
        useLive ? display.getDefaultDisplaySync().getLiveCreaseRegion()
          : display.getCurrentFoldCreaseRegion();
      const rects: Array<display.Rect> = region.creaseRects;
      if (rects.length === 0) {
        return '-';
      }
      let out: string = '';
      for (let i = 0; i < rects.length; i++) {
        const center: number = rects[i].left + rects[i].width / 2;
        out += (i === 0 ? '' : ',') + Math.round(center).toString();
        hilog.info(DOMAIN, FOLD_TAG, 'crease %{public}s [%{public}d] left=%{public}d w=%{public}d h=%{public}d',
          useLive ? 'LIVE' : 'CURRENT', i, rects[i].left, rects[i].width, rects[i].height);
      }
      return out;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, FOLD_TAG, '折痕采集失败 %{public}s: %{public}s',
        useLive ? 'LIVE' : 'CURRENT', JSON.stringify(err));
      return '-';
    }
  }

  /**
   * 采集 display.getFoldStatus() 供 UI 调试显示（状态栏右下角 FS: 值）。
   * 三折叠三屏态返回值官方未记载（api_notes A1），这里是唯一的第一手读数通道。
   * 失败返回 -1，不抛出，避免影响启动。
   */
  private collectFoldStatus(): number {
    try {
      const status: display.FoldStatus = display.getFoldStatus();
      return status as number;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, FOLD_TAG, 'foldStatus 采集失败: %{public}s', JSON.stringify(err));
      return -1;
    }
  }

  /**
   * 折痕/FoldStatus 校准日志（T014）。
   * 只打印数据点：getFoldStatus 返回值（含三屏态，官方未记载 api_notes A1 ❓）、
   * getCurrentFoldCreaseRegion 折痕 Rect、窗口 vp 宽。
   * TODO(真机校准)：真机采集后回填 docs/harmonyos/，本版本不做任何形态映射。
   */
  private logFoldCalibration(widthVp: number, bp: string): void {
    try {
      const foldable: boolean = display.isFoldable();
      const status: display.FoldStatus = display.getFoldStatus();
      const crease: display.FoldCreaseRegion = display.getCurrentFoldCreaseRegion();
      hilog.info(DOMAIN, FOLD_TAG,
        'TODO(真机校准) 断点=%{public}s 窗口宽=%{public}dvp 可折叠=%{public}s foldStatus=%{public}s 折痕区域=%{public}s',
        bp, Math.round(widthVp), foldable ? '是' : '否',
        JSON.stringify(status), JSON.stringify(crease));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, FOLD_TAG, '折痕/FoldStatus 采集失败: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 订阅物理折叠状态变化（T014）：仅打印数据点。
   * 注意：display.on/off('foldStatusChange') 是 display 命名空间的模块级函数
   * （SDK @ohos.display.d.ts line246），不是 Display 实例方法，直接命名空间调用。
   * 三折叠三屏态返回值官方未记载（api_notes A1 ❓）——不硬编码映射，留 TODO(真机校准)。
   */
  private registerFoldCalibrationLogging(): void {
    try {
      display.on('foldStatusChange', (foldStatus: display.FoldStatus) => {
        const widthVp: number = AppStorage.get<number>('windowWidthVp') ?? -1;
        // 物理折叠变化时同步刷新状态栏读数
        AppStorage.setOrCreate('foldStatus', foldStatus as number);
        AppStorage.setOrCreate('creasePx', this.collectCreasePx());
        hilog.info(DOMAIN, FOLD_TAG,
          'TODO(真机校准) foldStatusChange → foldStatus=%{public}s 窗口宽=%{public}dvp',
          JSON.stringify(foldStatus), Math.round(widthVp));
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, FOLD_TAG, 'foldStatusChange 订阅失败: %{public}s', JSON.stringify(err));
    }
  }
}
