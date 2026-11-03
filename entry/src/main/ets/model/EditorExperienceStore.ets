import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EditorExperienceMode, readEditorExperience, writeEditorExperience } from './EditorExperiencePolicy';

const EXPERIENCE_DOMAIN: number = 0x0000;
const EXPERIENCE_TAG: string = 'EditorExperienceStore';

/** App-wide simple / professional mode preference, shared across every vault. */
export class EditorExperienceStore {
  private static readonly PREF_NAME: string = 'editor_preferences';
  private static readonly EXPERIENCE_KEY: string = 'experience_mode';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: EditorExperienceStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(EXPERIENCE_DOMAIN, EXPERIENCE_TAG,
        '编辑模式偏好初始化失败，使用简单模式 code=%{public}d', err.code);
    }
  }

  load(): EditorExperienceMode {
    if (this.store === null) {
      return 'simple';
    }
    return readEditorExperience((): string => {
      return this.store?.getSync(EditorExperienceStore.EXPERIENCE_KEY, 'simple') as string;
    });
  }

  save(mode: EditorExperienceMode): boolean {
    if (this.store === null) {
      return false;
    }
    const saved: boolean = writeEditorExperience(mode, (value: string): void => {
      this.store?.putSync(EditorExperienceStore.EXPERIENCE_KEY, value);
      this.store?.flushSync();
    });
    if (!saved) {
      hilog.error(EXPERIENCE_DOMAIN, EXPERIENCE_TAG, '编辑模式偏好写入失败');
    }
    return saved;
  }
}
