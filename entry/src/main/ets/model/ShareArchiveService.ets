import { zlib } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { NoteShareService } from './NoteShareService';
import { VaultRegistry } from './VaultRegistry';

export interface ShareSnapshot {
  path: string;
  markdown: string;
}

export interface PreparedArchiveShare {
  filePath: string;
  fileName: string;
  fileCount: number;
  noteCount: number;
  imageCount: number;
}

export interface ShareScopeCount {
  fileCount: number;
  noteCount: number;
}

interface VaultFile {
  path: string;
  isMarkdown: boolean;
}

/** 文件夹 / 知识库分享 ZIP；只遍历用户库内容，所有绝对路径仍经 VaultRegistry 解析。 */
export class ShareArchiveService {
  private static nextId: number = 0;
  private static readonly MAX_DEPTH: number = 64;

  static async prepareZip(registry: VaultRegistry, vaultId: string, folderPath: string,
    snapshot: ShareSnapshot | null): Promise<PreparedArchiveShare> {
    NoteShareService.pruneExpired(registry);
    const files: VaultFile[] = [];
    const directories: string[] = [];
    ShareArchiveService.collectScope(registry, vaultId, folderPath, files, directories);

    const included: string[] = [];
    for (let i = 0; i < files.length; i++) {
      included.push(files[i].path);
    }
    const archiveImages: Map<string, string> = new Map<string, string>();
    const externalImages: string[] = [];
    const rewrittenMarkdown: Map<string, string> = new Map<string, string>();
    let noteCount: number = 0;
    for (let i = 0; i < files.length; i++) {
      const item: VaultFile = files[i];
      if (!item.isMarkdown) {
        continue;
      }
      noteCount++;
      const markdown: string = await ShareArchiveService.readSnapshot(registry, vaultId, item.path, snapshot);
      const references = NoteShareService.scanMarkdownImages(markdown);
      for (let j = 0; j < references.length; j++) {
        const source: string = references[j].source;
        if (NoteShareService.isRemoteImage(source)) {
          continue;
        }
        let imagePath: string = '';
        try {
          imagePath = NoteShareService.resolveImagePath(item.path, source, references[j].rootRelative === true);
        } catch (error) {
          throw new Error('图片路径越界或属于内部目录，未生成分享文件：' + source);
        }
        const imageAbs: string = registry.absoluteIn(vaultId, imagePath);
        let imageStat: fileIo.Stat;
        try {
          imageStat = fileIo.lstatSync(imageAbs);
        } catch (error) {
          throw new Error('缺少本地图片，未生成分享文件：' + source);
        }
        if (!imageStat.isFile() || imageStat.isSymbolicLink()) {
          throw new Error('本地图片不是普通文件，未生成分享文件：' + source);
        }
        if (included.indexOf(imagePath) >= 0) {
          archiveImages.set(imagePath, imagePath);
        } else if (!archiveImages.has(imagePath)) {
          if (NoteShareService.isExcludedVaultPath(imagePath)) {
            throw new Error('图片位于不分享的应用内部目录，未生成分享文件：' + source);
          }
          externalImages.push(imagePath);
          archiveImages.set(imagePath, '');
        }
      }
      // Rewrite after external images have been assigned archive paths below.
      rewrittenMarkdown.set(item.path, markdown);
    }

    const externalRoot: string = ShareArchiveService.uniqueExternalRoot(included, directories);
    for (let i = 0; i < externalImages.length; i++) {
      archiveImages.set(externalImages[i], externalRoot + '/' + externalImages[i]);
    }
    for (let i = 0; i < files.length; i++) {
      if (files[i].isMarkdown) {
        rewrittenMarkdown.set(files[i].path, NoteShareService.rewriteMarkdownImages(
          rewrittenMarkdown.get(files[i].path) ?? '', files[i].path, archiveImages));
      }
    }

    const shareId: string = 'archive-' + Date.now().toString() + '-' + ShareArchiveService.nextId.toString();
    ShareArchiveService.nextId++;
    const payloadRel: string = shareId + '/payload';
    try {
      const payloadAbs: string = registry.sharePath(payloadRel);
      fileIo.mkdirSync(payloadAbs, true);
      const createdDirectories: string[] = [payloadRel];
      for (let i = 0; i < directories.length; i++) {
        ShareArchiveService.ensureDirectory(registry, payloadRel, directories[i], createdDirectories);
      }
      for (let i = 0; i < files.length; i++) {
        const item: VaultFile = files[i];
        ShareArchiveService.ensureParent(registry, payloadRel, item.path, createdDirectories);
        const output: string = registry.sharePath(payloadRel + '/' + item.path);
        if (item.isMarkdown) {
          await NoteShareService.writeAtomic(output, rewrittenMarkdown.get(item.path) ?? '');
        } else {
          fileIo.copyFileSync(registry.absoluteIn(vaultId, item.path), output);
        }
      }
      for (let i = 0; i < externalImages.length; i++) {
        const sourcePath: string = externalImages[i];
        const targetPath: string = archiveImages.get(sourcePath) ?? '';
        ShareArchiveService.ensureParent(registry, payloadRel, targetPath, createdDirectories);
        fileIo.copyFileSync(registry.absoluteIn(vaultId, sourcePath),
          registry.sharePath(payloadRel + '/' + targetPath));
      }
      const name: string = ShareArchiveService.archiveName(vaultId, folderPath);
      const zipName: string = name + '.zip';
      const zipPath: string = registry.sharePath(shareId + '/' + zipName);
      await zlib.compressFile(payloadAbs, zipPath, {});
      NoteShareService.removeTree(registry, payloadRel);
      return {
        filePath: zipPath,
        fileName: zipName,
        fileCount: files.length + externalImages.length,
        noteCount: noteCount,
        imageCount: archiveImages.size
      };
    } catch (error) {
      try {
        NoteShareService.removeTree(registry, shareId);
      } catch (cleanupError) {
        // The temporary directory is private to this failed preparation and will be pruned later.
      }
      const err = error as Error;
      throw new Error('生成分享文件失败，请检查本地空间后重试：' + err.message);
    }
  }

  static countScope(registry: VaultRegistry, vaultId: string, folderPath: string): ShareScopeCount {
    const files: VaultFile[] = [];
    const directories: string[] = [];
    ShareArchiveService.collectScope(registry, vaultId, folderPath, files, directories);
    let noteCount: number = 0;
    for (let i = 0; i < files.length; i++) {
      if (files[i].isMarkdown) {
        noteCount++;
      }
    }
    return { fileCount: files.length, noteCount: noteCount };
  }

  static uniqueExternalRoot(included: string[], directories: string[]): string {
    let candidate: string = '__share_assets';
    let suffix: number = 2;
    while (ShareArchiveService.pathOccupied(candidate, included, directories)) {
      candidate = '__share_assets_' + suffix.toString();
      suffix++;
    }
    return candidate;
  }

  private static pathOccupied(path: string, included: string[], directories: string[]): boolean {
    if (included.indexOf(path) >= 0) {
      return true;
    }
    const descendants: string = path + '/';
    for (let i = 0; i < included.length; i++) {
      if (included[i].startsWith(descendants)) {
        return true;
      }
    }
    for (let i = 0; i < directories.length; i++) {
      if (directories[i] === path || directories[i].startsWith(descendants)) {
        return true;
      }
    }
    return false;
  }

  private static collect(registry: VaultRegistry, vaultId: string, directory: string, files: VaultFile[],
    directories: string[], depth: number): void {
    if (depth > ShareArchiveService.MAX_DEPTH) {
      throw new Error('文件夹层级超过分享上限，未生成分享文件');
    }
    const absolute: string = directory.length === 0
      ? registry.vaultDirOf(vaultId) : registry.absoluteIn(vaultId, directory);
    const children: string[] = fileIo.listFileSync(absolute);
    children.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    for (let i = 0; i < children.length; i++) {
      const name: string = children[i];
      const relativePath: string = directory.length === 0 ? name : directory + '/' + name;
      if (NoteShareService.isExcludedVaultPath(relativePath)) {
        continue;
      }
      const childAbsolute: string = registry.absoluteIn(vaultId, relativePath);
      const stat: fileIo.Stat = fileIo.lstatSync(childAbsolute);
      if (stat.isSymbolicLink()) {
        continue;
      }
      if (stat.isDirectory()) {
        directories.push(relativePath);
        ShareArchiveService.collect(registry, vaultId, relativePath, files, directories, depth + 1);
      } else if (stat.isFile()) {
        files.push({ path: relativePath, isMarkdown: /\.(?:md|markdown)$/i.test(name) });
      }
    }
  }

  private static collectScope(registry: VaultRegistry, vaultId: string, folderPath: string, files: VaultFile[],
    directories: string[]): void {
    if (folderPath.length > 0) {
      const folderAbs: string = registry.absoluteIn(vaultId, folderPath);
      const folderStat: fileIo.Stat = fileIo.lstatSync(folderAbs);
      if (!folderStat.isDirectory() || folderStat.isSymbolicLink()) {
        throw new Error('所选路径不是可分享的文件夹');
      }
      directories.push(folderPath);
      ShareArchiveService.collect(registry, vaultId, folderPath, files, directories, 0);
    } else {
      ShareArchiveService.collect(registry, vaultId, '', files, directories, 0);
    }
  }

  private static async readSnapshot(registry: VaultRegistry, vaultId: string, path: string,
    snapshot: ShareSnapshot | null): Promise<string> {
    if (snapshot !== null && snapshot.path === path) {
      return snapshot.markdown;
    }
    // Avoid NoteService.tryReadNote here: its diagnostic log includes note paths.
    return fileIo.readTextSync(registry.absoluteIn(vaultId, path));
  }

  private static ensureDirectory(registry: VaultRegistry, payloadRel: string, relativeDirectory: string,
    createdDirectories: string[]): void {
    const segments: string[] = relativeDirectory.split('/');
    let current: string = payloadRel;
    for (let i = 0; i < segments.length; i++) {
      current += '/' + segments[i];
      if (createdDirectories.indexOf(current) >= 0) {
        continue;
      }
      fileIo.mkdirSync(registry.sharePath(current), true);
      createdDirectories.push(current);
    }
  }

  private static ensureParent(registry: VaultRegistry, payloadRel: string, relativePath: string,
    createdDirectories: string[]): void {
    const parent: string = NoteShareService.parentOf(relativePath);
    if (parent.length > 0) {
      ShareArchiveService.ensureDirectory(registry, payloadRel, parent, createdDirectories);
    }
  }

  private static archiveName(vaultId: string, folderPath: string): string {
    const source: string = folderPath.length > 0 ? folderPath : vaultId;
    const slash: number = source.lastIndexOf('/');
    const base: string = slash >= 0 ? source.substring(slash + 1) : source;
    return base.length > 0 ? base : '知识库';
  }
}
