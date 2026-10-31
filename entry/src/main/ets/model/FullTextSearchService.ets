/** Builds a current-library in-memory index from Markdown. The index is derived and never persisted. */
import { fileIo } from '@kit.CoreFileKit';
import { FileTree } from './FileTree';
import { VaultRegistry } from './VaultRegistry';
import { SearchIndex, FullTextSearchResult } from './SearchIndex';

type ProgressListener = (completed: number, total: number) => void;

interface PendingMutation {
  kind: string;
  path: string;
  target: string;
  isDirectory: boolean;
  content: string;
}

export class FullTextSearchService {
  private static activeVaultId: string = '';
  private static activeIndex: SearchIndex | null = null;
  private static buildPromise: Promise<SearchIndex> | null = null;
  private static buildVaultId: string = '';
  private static buildGeneration: number = 0;
  private static listeners: ProgressListener[] = [];
  private static pendingMutations: PendingMutation[] = [];
  private static progressCompleted: number = 0;
  private static progressTotal: number = 0;

  static search(registry: VaultRegistry, vaultId: string, query: string,
    onProgress: ProgressListener): Promise<FullTextSearchResult[]> {
    if (query.trim().length === 0) {
      return Promise.resolve([]);
    }
    if (FullTextSearchService.activeVaultId !== vaultId) {
      FullTextSearchService.activate(vaultId);
    }
    return FullTextSearchService.ensureIndex(registry, vaultId, onProgress).then((index: SearchIndex):
      FullTextSearchResult[] => {
      return index.search(query, (path: string): string | null => {
        try {
          return FullTextSearchService.readMarkdown(registry, vaultId, path);
        } catch (error) {
          return null;
        }
      });
    });
  }

  /** Call after a completed save/create; the Markdown file remains the source of truth. */
  static noteSaved(vaultId: string, path: string, content: string): void {
    FullTextSearchService.mutate(vaultId, {
      kind: 'upsert', path: path, target: '', isDirectory: false, content: content
    });
  }

  /** Remove a file or all indexed descendants after permanent deletion or trashing. */
  static noteRemoved(vaultId: string, path: string, isDirectory: boolean): void {
    FullTextSearchService.mutate(vaultId, {
      kind: 'remove', path: path, target: '', isDirectory: isDirectory, content: ''
    });
  }

  /** Restore a trashed Markdown file into the active index after its file move succeeds. */
  static noteRestored(registry: VaultRegistry, vaultId: string, path: string): void {
    if (FullTextSearchService.activeVaultId !== vaultId ||
      (FullTextSearchService.activeIndex === null && FullTextSearchService.buildPromise === null)) {
      return;
    }
    try {
      FullTextSearchService.noteSaved(vaultId, path,
        FullTextSearchService.readMarkdown(registry, vaultId, path));
    } catch (error) {
    }
  }

  /** Keep relative paths aligned after a successful rename or move. */
  static pathRetargeted(vaultId: string, oldPath: string, newPath: string,
    isDirectory: boolean): void {
    FullTextSearchService.mutate(vaultId, {
      kind: 'retarget', path: oldPath, target: newPath, isDirectory: isDirectory, content: ''
    });
  }

  static discardVault(vaultId: string): void {
    if (FullTextSearchService.activeVaultId === vaultId) {
      FullTextSearchService.activate('');
    }
  }

  private static activate(vaultId: string): void {
    FullTextSearchService.buildGeneration++;
    FullTextSearchService.activeVaultId = vaultId;
    FullTextSearchService.activeIndex = null;
    FullTextSearchService.buildPromise = null;
    FullTextSearchService.buildVaultId = '';
    FullTextSearchService.listeners = [];
    FullTextSearchService.pendingMutations = [];
    FullTextSearchService.progressCompleted = 0;
    FullTextSearchService.progressTotal = 0;
  }

  private static mutate(vaultId: string, mutation: PendingMutation): void {
    if (vaultId !== FullTextSearchService.activeVaultId) {
      return;
    }
    if (FullTextSearchService.activeIndex !== null) {
      FullTextSearchService.applyMutation(FullTextSearchService.activeIndex, mutation);
    } else if (FullTextSearchService.buildPromise !== null && FullTextSearchService.buildVaultId === vaultId) {
      FullTextSearchService.pendingMutations.push(mutation);
    }
  }

  private static applyMutation(index: SearchIndex, mutation: PendingMutation): void {
    if (mutation.kind === 'upsert') {
      index.addOrReplace(mutation.path, mutation.content);
    } else if (mutation.kind === 'remove') {
      index.remove(mutation.path, mutation.isDirectory);
    } else if (mutation.kind === 'retarget') {
      index.retarget(mutation.path, mutation.target, mutation.isDirectory);
    }
  }

  private static readMarkdown(registry: VaultRegistry, vaultId: string, path: string): string {
    return fileIo.readTextSync(registry.absoluteIn(vaultId, path));
  }

  private static ensureIndex(registry: VaultRegistry, vaultId: string,
    onProgress: ProgressListener): Promise<SearchIndex> {
    if (FullTextSearchService.activeIndex !== null && FullTextSearchService.activeVaultId === vaultId) {
      onProgress(0, 0);
      return Promise.resolve(FullTextSearchService.activeIndex);
    }
    if (FullTextSearchService.buildPromise !== null && FullTextSearchService.buildVaultId === vaultId) {
      FullTextSearchService.listeners.push(onProgress);
      onProgress(FullTextSearchService.progressCompleted, FullTextSearchService.progressTotal);
      return FullTextSearchService.buildPromise;
    }

    const generation: number = FullTextSearchService.buildGeneration;
    const files: string[] = FileTree.allNotesOf(registry.accessFor(vaultId));
    const index: SearchIndex = new SearchIndex();
    FullTextSearchService.buildVaultId = vaultId;
    FullTextSearchService.listeners = [onProgress];
    FullTextSearchService.pendingMutations = [];
    FullTextSearchService.progressCompleted = 0;
    FullTextSearchService.progressTotal = files.length;
    FullTextSearchService.buildPromise = new Promise<SearchIndex>((resolve, reject): void => {
      let cursor: number = 0;
      const step = (): void => {
        if (generation !== FullTextSearchService.buildGeneration || FullTextSearchService.activeVaultId !== vaultId) {
          reject(new Error('索引初始化已取消'));
          return;
        }
        try {
          const end: number = Math.min(files.length, cursor + 24);
          while (cursor < end) {
            const path: string = files[cursor];
            const content: string = FullTextSearchService.readMarkdown(registry, vaultId, path);
            index.addOrReplace(path, content);
            cursor++;
          }
          FullTextSearchService.progressCompleted = cursor;
          FullTextSearchService.notifyProgress(cursor, files.length);
          if (cursor < files.length) {
            setTimeout(step, 0);
            return;
          }
          for (let i = 0; i < FullTextSearchService.pendingMutations.length; i++) {
            FullTextSearchService.applyMutation(index, FullTextSearchService.pendingMutations[i]);
          }
          FullTextSearchService.activeIndex = index;
          FullTextSearchService.buildPromise = null;
          FullTextSearchService.buildVaultId = '';
          FullTextSearchService.pendingMutations = [];
          FullTextSearchService.listeners = [];
          resolve(index);
        } catch (error) {
          FullTextSearchService.buildPromise = null;
          FullTextSearchService.buildVaultId = '';
          FullTextSearchService.pendingMutations = [];
          FullTextSearchService.listeners = [];
          reject(new Error('读取 Markdown 失败，未能完成全文索引'));
        }
      };
      step();
    });
    return FullTextSearchService.buildPromise;
  }

  private static notifyProgress(completed: number, total: number): void {
    for (let i = 0; i < FullTextSearchService.listeners.length; i++) {
      FullTextSearchService.listeners[i](completed, total);
    }
  }
}
