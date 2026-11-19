/**
 * MarkdownViewAbility.ets —— v1.89：系统「用曜石笔记打开 .md」的独立入口 UIAbility。
 *
 * 与 EntryAbility 完全隔离：不初始化 VaultRegistry / Agent / 搜索索引 / 恢复检查，
 * 因此「不需要笔记库」——用户直接点开一个 .md 就有只读预览，工作区与库零参与（89.4）。
 * 冷 / 热启动两路径都把载荷写进 AppStorage['markdownFileOpen']，由只读页 @Watch 消费；
 * 时间戳 nonce 保证同一文件重复打开也触发刷新（同 v1.56 机制）。
 *
 * 文件读取在 MarkdownOpenDevice 动态 import —— 只有本 ability 被拉起才加载 fileIo。
 */
import { AbilityConstant, UIAbility, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appThemeForColorMode } from '../common/AppTheme';
import { breakpointFromWidthVp } from '../model/Breakpoint';
import { MarkdownOpenService, MarkdownOpenPayload } from '../model/MarkdownOpenService';

const DOMAIN = 0x0000;
const TAG = 'MarkdownViewAbility';

export default class MarkdownViewAbility extends UIAbility {
  /** 缓存拉起 want（冷启动 onCreate 早于 onWindowStageCreate）。 */
  private openWant: Want | null = null;
  /** 主窗口：用于断点监听，使只读页顶栏高度 / gutter 与主应用同款（观感一致，仍免库）。 */
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    this.openWant = want;
    // 只读页观感与主应用同款：主题 / 字号 / 断点发布到 AppStorage（同 EntryAbility 的键）。
    // 只写纯计算结果（appThemeForColorMode / fontSizeScale），不初始化任何库服务，保持免库。
    this.publishTheme();
    AppStorage.setOrCreate('fontSizeScale', this.context.config?.fontSizeScale ?? 1);
  }

  /** 主题跟随系统（appThemeForColorMode 为无副作用的纯函数）。 */
  private publishTheme(): void {
    try {
      AppStorage.setOrCreate('appTheme', appThemeForColorMode(this.context.config?.colorMode));
    } catch (_error) {
      AppStorage.setOrCreate('appTheme', 'light');
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onNewWant');
    // 热启动：App 已在只读页，重新解析并写 nonce 载荷触发 @Watch 刷新。
    this.openWant = want;
    void this.publishPayload(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    // 断点 / 窗口尺寸发布：顶栏高度与 gutter 与 Index 同款（readOnly 页消费同名的 AppStorage 键）。
    // 纯 px2vp + breakpointFromWidthVp 计算，无任何库依赖。
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      const props: window.WindowProperties = this.mainWindow.getWindowProperties();
      this.applyWindowSize(props.windowRect.width, props.windowRect.height);
      this.mainWindow.on('windowSizeChange', (size: window.Size): void => {
        this.applyWindowSize(size.width, size.height);
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, '断点监听注册失败 code=%{public}d', (error as BusinessError).code);
    }
    const want: Want | null = this.openWant;
    // 先写载荷（异步读文件），完成后再 loadContent；页面 aboutToAppear 兜早到、@Watch 兜晚到。
    void this.publishPayload(want).finally((): void => {
      windowStage.loadContent('pages/MarkdownFileOpenPage', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'loadContent 失败 code=%{public}d', err.code);
          return;
        }
        hilog.info(DOMAIN, TAG, 'loadContent 成功');
      });
    });
  }

  /** 窗口尺寸 px → vp → 断点，发布到 AppStorage（与 EntryAbility.applyWindowSize 同键同算法）。 */
  private applyWindowSize(widthPx: number, heightPx: number): void {
    const widthVp: number = px2vp(widthPx);
    const heightVp: number = px2vp(heightPx);
    AppStorage.setOrCreate('windowWidthVp', widthVp);
    AppStorage.setOrCreate('windowHeightVp', heightVp);
    AppStorage.setOrCreate('breakpoint', breakpointFromWidthVp(widthVp));
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== null) {
      try {
        this.mainWindow.off('windowSizeChange');
      } catch (_error) {
        // 注销失败不影响销毁。
      }
      this.mainWindow = null;
    }
  }

  /** 解析 want → 读文件 → 写 AppStorage 载荷；任何异常都落成可读错误载荷，不崩溃。 */
  private async publishPayload(want: Want | null): Promise<void> {
    const now: number = Date.now();
    if (want === null || !MarkdownOpenService.isViewDataAction(want.action)) {
      this.writePayload(MarkdownOpenService.errorPayload('', '无法读取该文件内容', now));
      return;
    }
    const uri: string = typeof want.uri === 'string' ? want.uri : '';
    if (uri.length === 0) {
      this.writePayload(MarkdownOpenService.errorPayload('', '无法读取该文件内容', now));
      return;
    }
    const fileName: string = MarkdownOpenService.fileNameFromUri(uri);
    try {
      const device: ESObject = await import('../model/MarkdownOpenDevice');
      const readUri: (uri: string, fileName: string, at: number) => MarkdownOpenPayload =
        device.readMarkdownUri;
      this.writePayload(readUri(uri, fileName, now));
    } catch (_error) {
      // 动态 import 失败等兜底：只发错误载荷，错误 detail 不进日志。
      hilog.error(DOMAIN, TAG, '加载文件读取模块失败');
      this.writePayload(MarkdownOpenService.errorPayload(fileName, '无法读取该文件内容', now));
    }
  }

  private writePayload(payload: MarkdownOpenPayload): void {
    AppStorage.setOrCreate(MarkdownOpenService.STORAGE_KEY, MarkdownOpenService.serialize(payload));
  }

  onForeground(): void {
    // 前台重算主题 / 字号（系统主题可能在后台切换），与主应用行为一致。
    this.publishTheme();
    AppStorage.setOrCreate('fontSizeScale', this.context.config?.fontSizeScale ?? 1);
  }
}
