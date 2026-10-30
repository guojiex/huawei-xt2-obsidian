import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

/** App-wide editor display preferences shared by every vault and pane. */
export class EditorPreferenceStore {
  private static readonly PREF_NAME: string = 'editor_preferences';
  private static readonly SHOW_LINE_NUMBERS_KEY: string = 'show_line_numbers';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: EditorPreferenceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化编辑器设置失败: ' + JSON.stringify(err));
    }
  }

  showLineNumbers(): boolean {
    if (this.store === null) {
      return false;
    }
    try {
      return (this.store.getSync(EditorPreferenceStore.SHOW_LINE_NUMBERS_KEY, 'false') as string) === 'true';
    } catch (error) {
      const err = error as BusinessError;
      console.warn('读取编辑器设置失败: ' + JSON.stringify(err));
      return false;
    }
  }

  saveShowLineNumbers(show: boolean): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(EditorPreferenceStore.SHOW_LINE_NUMBERS_KEY, show ? 'true' : 'false');
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存编辑器设置失败: ' + JSON.stringify(err));
    }
  }
}
