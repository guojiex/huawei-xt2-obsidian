/** Tracks unsaved editor buffers by pane, vault and note path for background note tools. */
export class WorkspaceEditGuard {
  private static readonly unsaved: Set<string> = new Set<string>();

  static mark(pane: string, vaultId: string, path: string): void {
    if (vaultId.length === 0 || path.length === 0) {
      return;
    }
    WorkspaceEditGuard.unsaved.add(WorkspaceEditGuard.key(pane, vaultId, path));
  }

  static clear(pane: string, vaultId: string, path: string): void {
    if (vaultId.length === 0 || path.length === 0) {
      return;
    }
    WorkspaceEditGuard.unsaved.delete(WorkspaceEditGuard.key(pane, vaultId, path));
  }

  static isUnsaved(vaultId: string, path: string): boolean {
    return WorkspaceEditGuard.unsaved.has(WorkspaceEditGuard.key('left', vaultId, path)) ||
      WorkspaceEditGuard.unsaved.has(WorkspaceEditGuard.key('right', vaultId, path));
  }

  private static key(pane: string, vaultId: string, path: string): string {
    return JSON.stringify([pane, vaultId, path]);
  }
}
