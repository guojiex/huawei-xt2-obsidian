/**
 * ScreenSaverPreferenceStore.ets —— 屏保 / 台历的应用级偏好（v1.65 65.5）。
 *
 * 只存「名言轮换间隔」一个值，全局生效、不按库隔离；档位与默认值真源在 Tokens.ScreenSaver。
 * 形态沿用 EditorPreferenceStore：preferences.getPreferencesSync + getSync/putSync/flushSync，
 * 读写失败都回退默认档，不因偏好异常阻断进入屏保。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { ScreenSaver } from '../common/Tokens';

export class ScreenSaverPreferenceStore {
  private static readonly PREF_NAME: string = 'screensaver_preferences';
  private static readonly INTERVAL_KEY: string = 'quote_interval_ms';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: ScreenSaverPreferenceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化屏保设置失败 code=' + err.code);
    }
  }

  /** 读取轮换间隔；缺失 / 解析失败 / 非合法档位一律回退默认 1 分钟。 */
  intervalMs(): number {
    if (this.store === null) {
      return ScreenSaver.defaultIntervalMs;
    }
    try {
      const raw: string = this.store.getSync(ScreenSaverPreferenceStore.INTERVAL_KEY,
        String(ScreenSaver.defaultIntervalMs)) as string;
      const value: number = Number(raw);
      return ScreenSaver.isValidInterval(value) ? value : ScreenSaver.defaultIntervalMs;
    } catch (error) {
      const err = error as BusinessError;
      console.warn('读取屏保设置失败 code=' + err.code);
      return ScreenSaver.defaultIntervalMs;
    }
  }

  saveIntervalMs(ms: number): void {
    if (this.store === null || !ScreenSaver.isValidInterval(ms)) {
      return;
    }
    try {
      this.store.putSync(ScreenSaverPreferenceStore.INTERVAL_KEY, String(ms));
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存屏保设置失败 code=' + err.code);
    }
  }
}
