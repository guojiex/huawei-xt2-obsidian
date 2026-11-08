import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

export class ShareImagePreferenceStore {
  private static readonly PREF_NAME: string = 'share_image_preferences';
  private static readonly THEME_KEY: string = 'theme';
  private static readonly WIDTH_KEY: string = 'width';
  private static readonly VALID_WIDTHS: string[] = ['phone', 'wide', 'pane'];
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: ShareImagePreferenceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化长图设置失败 code=' + err.code);
    }
  }

  loadTheme(): string {
    if (this.store === null) {
      return 'light';
    }
    try {
      return (this.store.getSync(ShareImagePreferenceStore.THEME_KEY, 'light') as string) === 'dark'
        ? 'dark' : 'light';
    } catch (error) {
      return 'light';
    }
  }

  saveTheme(theme: string): boolean {
    if (this.store === null || (theme !== 'light' && theme !== 'dark')) {
      return false;
    }
    try {
      this.store.putSync(ShareImagePreferenceStore.THEME_KEY, theme);
      this.store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存长图设置失败 code=' + err.code);
      return false;
    }
  }

  loadWidth(): string {
    if (this.store === null) {
      return 'phone';
    }
    try {
      const raw: string = this.store.getSync(ShareImagePreferenceStore.WIDTH_KEY, 'phone') as string;
      for (const valid of ShareImagePreferenceStore.VALID_WIDTHS) {
        if (raw === valid) {
          return raw;
        }
      }
      return 'phone';
    } catch (error) {
      return 'phone';
    }
  }

  saveWidth(widthId: string): boolean {
    if (this.store === null) {
      return false;
    }
    let valid: boolean = false;
    for (const v of ShareImagePreferenceStore.VALID_WIDTHS) {
      if (widthId === v) {
        valid = true;
        break;
      }
    }
    if (!valid) {
      return false;
    }
    try {
      this.store.putSync(ShareImagePreferenceStore.WIDTH_KEY, widthId);
      this.store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存长图宽度偏好失败 code=' + err.code);
      return false;
    }
  }
}
