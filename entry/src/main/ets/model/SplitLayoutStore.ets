import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { DEFAULT_CONTENT_RATIO } from './PaneLayout';

export interface SplitLayoutState {
  navigationRatio: number;
  contentRatio: number;
}

export class SplitLayoutStore {
  private static readonly PREF_NAME: string = 'pane_layout';
  private static readonly PREF_KEY: string = 'shared_split';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: SplitLayoutStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化分栏设置失败: ' + JSON.stringify(err));
    }
  }

  load(): SplitLayoutState {
    if (this.store === null) {
      return { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO };
    }
    try {
      const raw: string = this.store.getSync(SplitLayoutStore.PREF_KEY, '') as string;
      if (raw.length === 0) {
        return { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO };
      }
      const value: Record<string, number> = JSON.parse(raw) as Record<string, number>;
      const nav: number = value['navigationRatio'];
      const content: number = value['contentRatio'];
      return {
        navigationRatio: typeof nav === 'number' && nav >= 0.22 && nav <= 0.46 ? nav : -1,
        contentRatio: typeof content === 'number' && content > 0 && content < 1
          ? content : DEFAULT_CONTENT_RATIO
      };
    } catch (error) {
      return { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO };
    }
  }

  save(state: SplitLayoutState): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(SplitLayoutStore.PREF_KEY, JSON.stringify(state));
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存分栏设置失败: ' + JSON.stringify(err));
    }
  }

  reset(): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.deleteSync(SplitLayoutStore.PREF_KEY);
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      console.warn('重置分栏设置失败: ' + JSON.stringify(err));
    }
  }
}
