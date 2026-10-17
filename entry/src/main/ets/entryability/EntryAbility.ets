import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { breakpointFromWidthVp } from '../model/Breakpoint';
import { VaultRegistry } from '../model/VaultRegistry';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';
/**
 * 折痕/FoldStatus 校准日志 tag。
 * 三折叠三屏态的 getFoldStatus 返回值官方未记载（api_notes.md A1 ❓），
 * 这些日志只用于真机采集数据点（TODO(真机校准)），不做任何形态映射、不参与布局计算。
 */
const FOLD_TAG = 'FoldCalibration';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /** 上一次断点档位，用于判断档位切换才打校准日志（避免同档位重复刷屏）。 */
  private lastBreakpoint: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    // 库注册表单例初始化：必须先于 loadContent，页面侧才能直接 VaultRegistry.get()
    VaultRegistry.initialize(this.context);

    // ===== 断点系统（T007）=====
    // 断点只由窗口宽度（vp）计算：window.on('windowSizeChange') + px2vp() 是官方推荐的
    // 统一断点机制（api_notes.md A3 ✅）。
    // 不用 getFoldDisplayMode() 做形态分支：该接口不返回全部形态值（api_notes.md A3）。
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      // loadContent 前补算初始断点：windowSizeChange 只在尺寸变化时触发，
      // 首帧等不到事件，不补算会出现「初始 sm、展开后才正确」的一帧错档。
      const props: window.WindowProperties = this.mainWindow.getWindowProperties();
      this.applyBreakpoint(px2vp(props.windowRect.width));
      this.mainWindow.on('windowSizeChange', (size: window.Size) => {
        this.applyBreakpoint(px2vp(size.width));
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '断点监听注册失败: %{public}s', JSON.stringify(err));
    }

    // ===== 折痕 / FoldStatus 数据采集日志点（T014，TODO(真机校准)）=====
    this.registerFoldCalibrationLogging();

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    try {
      if (this.mainWindow !== null) {
        this.mainWindow.off('windowSizeChange');
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
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
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
