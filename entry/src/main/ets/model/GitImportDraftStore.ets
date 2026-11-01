/**
 * GitImportDraftStore.ets —— Git 导入对话框到现有安全导入页的进程内交接。
 * 地址、分支、用户名和令牌不进入路由参数或 preferences；令牌仅短暂驻留内存。
 */
export interface GitImportDraft {
  remote: string;
  branch: string;
  username: string;
  token: string;
}

export class GitImportDraftStore {
  private static pending: GitImportDraft | null = null;

  static set(draft: GitImportDraft): void {
    GitImportDraftStore.pending = {
      remote: draft.remote,
      branch: draft.branch,
      username: draft.username,
      token: draft.token
    };
  }

  static consume(): GitImportDraft | null {
    const draft: GitImportDraft | null = GitImportDraftStore.pending;
    GitImportDraftStore.pending = null;
    return draft;
  }

  static clear(): void {
    GitImportDraftStore.pending = null;
  }
}
