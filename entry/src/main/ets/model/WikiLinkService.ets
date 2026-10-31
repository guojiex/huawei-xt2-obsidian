import { fileIo } from '@kit.CoreFileKit';
import { FileTree } from './FileTree';
import { VaultRegistry } from './VaultRegistry';
import { WikiLinkParser, WikiLinkReference, WikiLinkResolution } from './WikiLinkParser';

interface WikiLinkIndex {
  files: string[];
  outgoing: Map<string, string[]>;
  incoming: Map<string, string[]>;
}

export interface WikiLinkUpdate {
  path: string;
  content: string;
}

interface WikiLinkReplacement {
  start: number;
  end: number;
  text: string;
}

export interface WikiLinkUpdateReport {
  updatedPaths: string[];
  failedPaths: string[];
  scanFailed: boolean;
}

type AtomicWriter = (path: string, content: string) => Promise<void>;

/** Derived current-vault link graph. Markdown files remain the source of truth. */
export class WikiLinkService {
  private static activeVaultId: string = '';
  private static activeIndex: WikiLinkIndex | null = null;
  private static buildPromise: Promise<WikiLinkIndex> | null = null;
  private static buildVaultId: string = '';
  private static buildGeneration: number = 0;
  private static pendingSaves: Map<string, string> = new Map<string, string>();

  static files(registry: VaultRegistry, vaultId: string): string[] {
    if (WikiLinkService.activeVaultId === vaultId && WikiLinkService.activeIndex !== null) {
      return WikiLinkService.activeIndex.files.slice();
    }
    return FileTree.allNotesOf(registry.accessFor(vaultId));
  }

  static resolve(target: string, sourcePath: string, files: string[]): WikiLinkResolution {
    return WikiLinkParser.resolve(target, sourcePath, files);
  }

  static backlinks(registry: VaultRegistry, vaultId: string, targetPath: string): Promise<string[]> {
    if (WikiLinkService.activeVaultId !== vaultId) {
      WikiLinkService.activate(vaultId);
    }
    return WikiLinkService.ensureIndex(registry, vaultId).then((index: WikiLinkIndex): string[] => {
      const sources: string[] | undefined = index.incoming.get(targetPath);
      return sources === undefined ? [] : sources.slice();
    });
  }

  /** Update the active graph after an existing note has been saved. */
  static noteSaved(vaultId: string, path: string, content: string): void {
    if (WikiLinkService.activeVaultId !== vaultId) {
      return;
    }
    if (WikiLinkService.activeIndex !== null) {
      if (WikiLinkService.activeIndex.files.indexOf(path) < 0) {
        WikiLinkService.invalidate(vaultId);
        return;
      }
      WikiLinkService.replaceOutgoing(WikiLinkService.activeIndex, path, content);
      return;
    }
    if (WikiLinkService.buildPromise !== null && WikiLinkService.buildVaultId === vaultId) {
      WikiLinkService.pendingSaves.set(path, content);
    }
  }

  static pathAdded(vaultId: string): void {
    WikiLinkService.invalidate(vaultId);
  }

  static pathRemoved(vaultId: string): void {
    WikiLinkService.invalidate(vaultId);
  }

  static pathRetargeted(vaultId: string): void {
    WikiLinkService.invalidate(vaultId);
  }

  static discardVault(vaultId: string): void {
    if (WikiLinkService.activeVaultId === vaultId) {
      WikiLinkService.activate('');
    }
  }

  /**
   * Find links whose old target path disappeared after a rename/move, rewrite them to the new
   * root-relative path, and save each changed source through the caller's AtomicFile writer.
   */
  static async rewriteReferences(registry: VaultRegistry, vaultId: string, oldPath: string,
    newPath: string, isDirectory: boolean, writer: AtomicWriter): Promise<WikiLinkUpdateReport> {
    let files: string[];
    try {
      files = FileTree.allNotesOf(registry.accessFor(vaultId));
    } catch (error) {
      WikiLinkService.invalidate(vaultId);
      return { updatedPaths: [], failedPaths: [], scanFailed: true };
    }
    const previousFiles: string[] = files.map((path: string): string => {
      return WikiLinkService.isRetargetedPath(path, newPath, isDirectory)
        ? oldPath + path.substring(newPath.length) : path;
    });
    const updates: WikiLinkUpdate[] = [];
    const updatedPaths: string[] = [];
    const failedPaths: string[] = [];
    let cursor: number = 0;
    while (cursor < files.length) {
      const end: number = Math.min(files.length, cursor + 24);
      while (cursor < end) {
        const sourcePath: string = files[cursor];
        cursor++;
        let content: string;
        try {
          content = WikiLinkService.readMarkdown(registry, vaultId, sourcePath);
        } catch (error) {
          failedPaths.push(sourcePath);
          continue;
        }
        const references: WikiLinkReference[] = WikiLinkParser.parse(content);
        const replacements: WikiLinkReplacement[] = [];
        for (let i = 0; i < references.length; i++) {
          const reference: WikiLinkReference = references[i];
          const previousSourcePath: string = WikiLinkService.isRetargetedPath(sourcePath, newPath, isDirectory)
            ? oldPath + sourcePath.substring(newPath.length) : sourcePath;
          const resolution: WikiLinkResolution = WikiLinkParser.resolve(reference.target,
            previousSourcePath, previousFiles);
          if (resolution.path.length === 0 || !WikiLinkService.isRetargetedPath(
            resolution.path, oldPath, isDirectory)) {
            continue;
          }
          const suffix: string = resolution.path.substring(oldPath.length);
          const replacementPath: string = newPath + suffix;
          const currentResolution: WikiLinkResolution = WikiLinkParser.resolve(reference.target, sourcePath, files);
          if (currentResolution.status === 'resolved' && currentResolution.path === replacementPath) {
            continue;
          }
          const replacementTarget: string = WikiLinkParser.pathToTarget(replacementPath);
          if (replacementTarget !== reference.target) {
            const replacement: WikiLinkReplacement = {
              start: reference.targetStart,
              end: reference.targetEnd,
              text: replacementTarget
            };
            replacements.push(replacement);
          }
        }
        if (replacements.length === 0) {
          continue;
        }
        let updated: string = content;
        for (let i = replacements.length - 1; i >= 0; i--) {
          const replacement = replacements[i];
          updated = updated.substring(0, replacement.start) + replacement.text + updated.substring(replacement.end);
        }
        updates.push({ path: sourcePath, content: updated });
      }
      if (cursor < files.length) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout((): void => resolve(), 0);
        });
      }
    }

    for (let i = 0; i < updates.length; i++) {
      try {
        await writer(updates[i].path, updates[i].content);
        updatedPaths.push(updates[i].path);
      } catch (error) {
        failedPaths.push(updates[i].path);
      }
    }
    WikiLinkService.invalidate(vaultId);
    return {
      updatedPaths: WikiLinkService.uniquePaths(updatedPaths),
      failedPaths: WikiLinkService.uniquePaths(failedPaths),
      scanFailed: false
    };
  }

  private static activate(vaultId: string): void {
    WikiLinkService.buildGeneration++;
    WikiLinkService.activeVaultId = vaultId;
    WikiLinkService.activeIndex = null;
    WikiLinkService.buildPromise = null;
    WikiLinkService.buildVaultId = '';
    WikiLinkService.pendingSaves.clear();
  }

  private static invalidate(vaultId: string): void {
    if (WikiLinkService.activeVaultId !== vaultId) {
      return;
    }
    WikiLinkService.buildGeneration++;
    WikiLinkService.activeIndex = null;
    WikiLinkService.buildPromise = null;
    WikiLinkService.buildVaultId = '';
    WikiLinkService.pendingSaves.clear();
  }

  private static ensureIndex(registry: VaultRegistry, vaultId: string): Promise<WikiLinkIndex> {
    if (WikiLinkService.activeIndex !== null && WikiLinkService.activeVaultId === vaultId) {
      return Promise.resolve(WikiLinkService.activeIndex);
    }
    if (WikiLinkService.buildPromise !== null && WikiLinkService.buildVaultId === vaultId) {
      return WikiLinkService.buildPromise;
    }

    const generation: number = WikiLinkService.buildGeneration;
    const files: string[] = FileTree.allNotesOf(registry.accessFor(vaultId));
    const index: WikiLinkIndex = {
      files: files,
      outgoing: new Map<string, string[]>(),
      incoming: new Map<string, string[]>()
    };
    WikiLinkService.buildVaultId = vaultId;
    WikiLinkService.pendingSaves.clear();
    WikiLinkService.buildPromise = new Promise<WikiLinkIndex>((resolve, reject): void => {
      let cursor: number = 0;
      const step = (): void => {
        if (generation !== WikiLinkService.buildGeneration || WikiLinkService.activeVaultId !== vaultId) {
          reject(new Error('双链索引初始化已取消'));
          return;
        }
        try {
          const end: number = Math.min(files.length, cursor + 24);
          while (cursor < end) {
            const path: string = files[cursor];
            WikiLinkService.replaceOutgoing(index, path, WikiLinkService.readMarkdown(registry, vaultId, path));
            cursor++;
          }
          if (cursor < files.length) {
            setTimeout(step, 0);
            return;
          }
          WikiLinkService.pendingSaves.forEach((content: string, path: string): void => {
            if (index.files.indexOf(path) >= 0) {
              WikiLinkService.replaceOutgoing(index, path, content);
            }
          });
          WikiLinkService.activeIndex = index;
          WikiLinkService.buildPromise = null;
          WikiLinkService.buildVaultId = '';
          WikiLinkService.pendingSaves.clear();
          resolve(index);
        } catch (error) {
          WikiLinkService.buildPromise = null;
          WikiLinkService.buildVaultId = '';
          WikiLinkService.pendingSaves.clear();
          reject(new Error('读取 Markdown 失败，未能完成双链索引'));
        }
      };
      step();
    });
    return WikiLinkService.buildPromise;
  }

  private static replaceOutgoing(index: WikiLinkIndex, sourcePath: string, content: string): void {
    const previous: string[] | undefined = index.outgoing.get(sourcePath);
    if (previous !== undefined) {
      for (let i = 0; i < previous.length; i++) {
        const sources: string[] | undefined = index.incoming.get(previous[i]);
        if (sources === undefined) {
          continue;
        }
        const kept: string[] = sources.filter((path: string): boolean => path !== sourcePath);
        if (kept.length === 0) {
          index.incoming.delete(previous[i]);
        } else {
          index.incoming.set(previous[i], kept);
        }
      }
    }
    const targets: string[] = [];
    const seen: Set<string> = new Set<string>();
    const references: WikiLinkReference[] = WikiLinkParser.parse(content);
    for (let i = 0; i < references.length; i++) {
      const resolution: WikiLinkResolution = WikiLinkParser.resolve(references[i].target, sourcePath, index.files);
      if (resolution.status === 'resolved' && !seen.has(resolution.path)) {
        seen.add(resolution.path);
        targets.push(resolution.path);
      }
    }
    index.outgoing.set(sourcePath, targets);
    for (let i = 0; i < targets.length; i++) {
      const existing: string[] | undefined = index.incoming.get(targets[i]);
      if (existing === undefined) {
        index.incoming.set(targets[i], [sourcePath]);
      } else if (existing.indexOf(sourcePath) < 0) {
        existing.push(sourcePath);
      }
    }
  }

  private static readMarkdown(registry: VaultRegistry, vaultId: string, path: string): string {
    return fileIo.readTextSync(registry.absoluteIn(vaultId, path));
  }

  private static isRetargetedPath(path: string, oldPath: string, isDirectory: boolean): boolean {
    return path === oldPath || (isDirectory && path.startsWith(oldPath + '/'));
  }

  private static uniquePaths(paths: string[]): string[] {
    const seen: Set<string> = new Set<string>();
    const result: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      if (!seen.has(paths[i])) {
        seen.add(paths[i]);
        result.push(paths[i]);
      }
    }
    result.sort((left: string, right: string): number => left < right ? -1 : (left > right ? 1 : 0));
    return result;
  }
}
