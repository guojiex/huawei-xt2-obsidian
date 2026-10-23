/**
 * RecentOpenStore.ets —— 按库保存最近成功打开的笔记路径（v0.4）。
 * 只存库内相对路径，不存正文；读取时用当前库的有效 Markdown 候选清理失效项。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const RECENT_DOMAIN: number = 0x0004;
const RECENT_TAG: string = 'RecentOpenStore';

export class RecentOpenStore {
  static readonly LIMIT: number = 10;
  private static readonly PREF_NAME: string = 'recent_open_state';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: RecentOpenStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(RECENT_DOMAIN, RECENT_TAG, '最近打开存储初始化失败: %{public}s', JSON.stringify(err));
    }
  }

  /** 过滤已删除或移动的路径；存储 key 按 vaultId 隔离。 */
  load(vaultId: string, validPaths: string[]): string[] {
    const stored: string[] = this.read(vaultId);
    const valid: string[] = [];
    for (let i = 0; i < stored.length; i++) {
      if (validPaths.indexOf(stored[i]) >= 0 && valid.indexOf(stored[i]) < 0) {
        valid.push(stored[i]);
      }
    }
    if (!this.samePaths(stored, valid)) {
      this.write(vaultId, valid);
    }
    return valid;
  }

  /** 仅在文件成功读取并载入编辑器后调用。 */
  record(vaultId: string, relPath: string): void {
    if (vaultId.length === 0 || relPath.length === 0) {
      return;
    }
    const next: string[] = [relPath];
    const stored: string[] = this.read(vaultId);
    for (let i = 0; i < stored.length && next.length < RecentOpenStore.LIMIT; i++) {
      if (stored[i] !== relPath && next.indexOf(stored[i]) < 0) {
        next.push(stored[i]);
      }
    }
    this.write(vaultId, next);
  }

  /** 改名或移动成功后同步更新对应历史路径，避免留下旧入口。 */
  retarget(vaultId: string, oldPath: string, newPath: string, isDir: boolean): void {
    if (vaultId.length === 0 || oldPath === newPath) {
      return;
    }
    const stored: string[] = this.read(vaultId);
    const next: string[] = [];
    for (let i = 0; i < stored.length; i++) {
      const path: string = stored[i];
      let updated: string = path;
      if (path === oldPath || (isDir && path.startsWith(oldPath + '/'))) {
        updated = newPath + path.substring(oldPath.length);
      }
      if (next.indexOf(updated) < 0 && next.length < RecentOpenStore.LIMIT) {
        next.push(updated);
      }
    }
    this.write(vaultId, next);
  }

  private read(vaultId: string): string[] {
    if (this.store === null || vaultId.length === 0) {
      return [];
    }
    try {
      const raw: string = this.store.getSync('recent_' + vaultId, '[]') as string;
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const values: Object[] = parsed as Object[];
      const paths: string[] = [];
      for (let i = 0; i < values.length && paths.length < RecentOpenStore.LIMIT; i++) {
        if (typeof values[i] === 'string' && paths.indexOf(values[i] as string) < 0) {
          paths.push(values[i] as string);
        }
      }
      return paths;
    } catch (error) {
      return [];
    }
  }

  private write(vaultId: string, paths: string[]): void {
    if (this.store === null || vaultId.length === 0) {
      return;
    }
    try {
      this.store.putSync('recent_' + vaultId, JSON.stringify(paths));
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(RECENT_DOMAIN, RECENT_TAG, '最近打开写入失败: %{public}s', JSON.stringify(err));
    }
  }

  private samePaths(left: string[], right: string[]): boolean {
    if (left.length !== right.length) {
      return false;
    }
    for (let i = 0; i < left.length; i++) {
      if (left[i] !== right[i]) {
        return false;
      }
    }
    return true;
  }
}
