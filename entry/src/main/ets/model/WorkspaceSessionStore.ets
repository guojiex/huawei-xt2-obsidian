/**
 * WorkspaceSessionStore.ets —— 保存可安全重建的笔记工作区 UI 状态（v0.9 9.12）。
 * 不保存笔记正文、临时搜索词、草稿或弹层状态。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

export interface WorkspaceSession {
  schemaVersion: number;
  vaultId: string;
  leftPath: string;
  rightPath: string;
  leftMode: string;
  rightEditing: boolean;
  activePane: string;
  referenceVisible: boolean;
  sidebarCollapsed: boolean;
  drawerOpen: boolean;
  focused: boolean;
  sidebarTab: string;
  selectedChapterOffset: number;
  leftEditorScrollTop: number;
  leftPreviewScrollTop: number;
  rightEditorScrollTop: number;
  rightPreviewScrollTop: number;
}

export interface WorkspaceSessionPaths {
  leftPath: string;
  rightPath: string;
}

/** 单屏只恢复上次实际可见的栏；路径必须属于当前库的有效 Markdown 列表。 */
export function workspaceSessionPaths(session: WorkspaceSession, singleScreen: boolean,
  validPaths: string[]): WorkspaceSessionPaths {
  const leftPath: string = singleScreen && session.activePane === 'right' ? '' : session.leftPath;
  const rightPath: string = singleScreen && session.activePane === 'left' ? '' : session.rightPath;
  return {
    leftPath: validPaths.indexOf(leftPath) >= 0 ? leftPath : '',
    rightPath: validPaths.indexOf(rightPath) >= 0 ? rightPath : ''
  };
}

/** Each pane recovers independently; an unreadable note must not clear its sibling pane. */
export async function restoreWorkspacePane(path: string, open: (path: string) => Promise<boolean>,
  clear: () => Promise<void>): Promise<boolean> {
  if (path.length > 0) {
    try {
      if (await open(path)) {
        return true;
      }
    } catch (error) {
      // Keep failures local to the pane being restored.
    }
  }
  try {
    await clear();
  } catch (error) {
    // A failed empty-state bridge update must not prevent restoring the sibling pane.
  }
  return false;
}

/** Preferences 中的 JSON 先完整校验，再进入 ArkTS 严格模型。 */
export function parseWorkspaceSession(raw: string): WorkspaceSession | null {
  try {
    const value: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    if (value['schemaVersion'] !== 1 || typeof value['vaultId'] !== 'string' ||
      (value['vaultId'] as string).length === 0 || typeof value['leftPath'] !== 'string' ||
      typeof value['rightPath'] !== 'string' || typeof value['leftMode'] !== 'string' ||
      (value['leftMode'] !== 'edit' && value['leftMode'] !== 'preview') ||
      typeof value['rightEditing'] !== 'boolean' || typeof value['activePane'] !== 'string' ||
      (value['activePane'] !== 'left' && value['activePane'] !== 'right') ||
      typeof value['referenceVisible'] !== 'boolean' || typeof value['sidebarCollapsed'] !== 'boolean' ||
      typeof value['drawerOpen'] !== 'boolean' || typeof value['focused'] !== 'boolean' ||
      typeof value['sidebarTab'] !== 'string' ||
      (value['sidebarTab'] !== 'files' && value['sidebarTab'] !== 'chapters') ||
      typeof value['selectedChapterOffset'] !== 'number' ||
      !Number.isInteger(value['selectedChapterOffset'] as number) ||
      (value['selectedChapterOffset'] as number) < -1) {
      return null;
    }
    const scrollKeys: string[] = ['leftEditorScrollTop', 'leftPreviewScrollTop',
      'rightEditorScrollTop', 'rightPreviewScrollTop'];
    for (let i: number = 0; i < scrollKeys.length; i++) {
      const top: Object = value[scrollKeys[i]];
      if (typeof top !== 'number' || !Number.isFinite(top as number) || (top as number) < 0) {
        return null;
      }
    }
    return {
      schemaVersion: 1,
      vaultId: value['vaultId'] as string,
      leftPath: value['leftPath'] as string,
      rightPath: value['rightPath'] as string,
      leftMode: value['leftMode'] as string,
      rightEditing: value['rightEditing'] as boolean,
      activePane: value['activePane'] as string,
      referenceVisible: value['referenceVisible'] as boolean,
      sidebarCollapsed: value['sidebarCollapsed'] as boolean,
      drawerOpen: value['drawerOpen'] as boolean,
      focused: value['focused'] as boolean,
      sidebarTab: value['sidebarTab'] as string,
      selectedChapterOffset: value['selectedChapterOffset'] as number,
      leftEditorScrollTop: value['leftEditorScrollTop'] as number,
      leftPreviewScrollTop: value['leftPreviewScrollTop'] as number,
      rightEditorScrollTop: value['rightEditorScrollTop'] as number,
      rightPreviewScrollTop: value['rightPreviewScrollTop'] as number
    };
  } catch (error) {
    return null;
  }
}

export class WorkspaceSessionStore {
  private static readonly PREF_NAME: string = 'workspace_session';
  private static readonly PREF_KEY: string = 'latest';
  private store: preferences.Preferences | null = null;

  constructor(context: common.UIAbilityContext) {
    try {
      this.store = preferences.getPreferencesSync(context, { name: WorkspaceSessionStore.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      console.warn('初始化工作区会话失败: ' + JSON.stringify(err));
    }
  }

  load(): WorkspaceSession | null {
    if (this.store === null) {
      return null;
    }
    try {
      return parseWorkspaceSession(this.store.getSync(WorkspaceSessionStore.PREF_KEY, '') as string);
    } catch (error) {
      return null;
    }
  }

  save(session: WorkspaceSession): boolean {
    if (this.store === null) {
      return false;
    }
    try {
      this.store.putSync(WorkspaceSessionStore.PREF_KEY, JSON.stringify(session));
      this.store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      console.warn('保存工作区会话失败: ' + JSON.stringify(err));
      return false;
    }
  }
}
