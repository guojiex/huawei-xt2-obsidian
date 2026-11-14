import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'XiaoyiEntryPreferenceStore';

/** 应用级小艺对话入口显隐偏好；新安装与读失败均默认关闭。 */
export class XiaoyiEntryPreferenceStore {
  private static readonly PREF_NAME: string = 'xiaoyi_entry_preferences';
  private static readonly SHOW_ENTRY_KEY: string = 'show_dialog_entry';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: XiaoyiEntryPreferenceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '小艺入口设置初始化失败 code=%{public}d', err.code);
    }
  }

  load(): boolean {
    if (this.store === null) {
      return false;
    }
    try {
      const value: Object = this.store.getSync(XiaoyiEntryPreferenceStore.SHOW_ENTRY_KEY, false) as Object;
      return typeof value === 'boolean' ? value : false;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '读取小艺入口设置失败 code=%{public}d', err.code);
      return false;
    }
  }

  save(show: boolean): boolean {
    if (this.store === null) {
      return false;
    }
    try {
      this.store.putSync(XiaoyiEntryPreferenceStore.SHOW_ENTRY_KEY, show);
      this.store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, '保存小艺入口设置失败 code=%{public}d', err.code);
      return false;
    }
  }
}
