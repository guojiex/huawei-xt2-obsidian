import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

/** 写作统计（v1.58）总开关：关闭时隐藏全部入口与侧栏连写条，并跳过后台重算。 */
export class VaultStatsPreferenceStore {
  /** 默认关闭：新用户开箱即隐藏写作统计，需手动在设置中开启。 */
  private static readonly DEFAULT_STATS_ENABLED: boolean = false;
  private static readonly PREF_NAME: string = 'vault_stats_preferences';
  private static readonly STATS_ENABLED_KEY: string = 'stats_enabled';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: VaultStatsPreferenceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化写作统计设置失败 code=' + err.code);
    }
  }

  /** 默认关闭（DEFAULT_STATS_ENABLED），未设置或读取失败时回退为关闭，避免偷偷回退成开。 */
  statsEnabled(): boolean {
    if (this.store === null) {
      return VaultStatsPreferenceStore.DEFAULT_STATS_ENABLED;
    }
    try {
      return (this.store.getSync(
        VaultStatsPreferenceStore.STATS_ENABLED_KEY,
        VaultStatsPreferenceStore.DEFAULT_STATS_ENABLED ? 'true' : 'false') as string) === 'true';
    } catch (error) {
      const err = error as BusinessError;
      console.warn('读取写作统计开关失败 code=' + err.code);
      return VaultStatsPreferenceStore.DEFAULT_STATS_ENABLED;
    }
  }

  saveStatsEnabled(enabled: boolean): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(VaultStatsPreferenceStore.STATS_ENABLED_KEY, enabled ? 'true' : 'false');
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存写作统计开关失败 code=' + err.code);
    }
  }
}
