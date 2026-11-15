/**
 * GitImportDraftStore.ets —— Git 导入输入 / 结果模型及旧页面的进程内交接。
 * 新导入流程经弹窗回调直接调用 GitImportService；地址、分支、用户名和令牌不进路由或 preferences。
 */
export interface GitImportDraft {
  remote: string;
  branch: string;
  username: string;
  token: string;
}

/** Git 导入流程结果；底层 detail 已脱敏，可直接显示在导入弹窗。 */
export interface GitImportOutcome {
  status: string;
  vaultId: string;
  category: string;
  detail: string;
  guidance: string;
  focusTarget: string;
  warning: string;
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
