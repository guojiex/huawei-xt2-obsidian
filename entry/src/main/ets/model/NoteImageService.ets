/** Copy a user-selected Gallery image into the note's vault and create its Markdown reference. */
import { common } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { VaultRegistry } from './VaultRegistry';

export interface NoteImageImportResult {
  markdownReference: string;
  assetPath: string;
}

interface NoteImageSelectedAsset {
  uri: string;
  displayName: string;
}

export class NoteImageService {
  private static readonly IMAGE_EXTENSIONS: string[] = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'];

  /** Picker URIs are resolved through PhotoAccessHelper's temporary authorization. */
  private static async selectedAsset(context: common.UIAbilityContext, uri: string):
    Promise<NoteImageSelectedAsset> {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    const predicates: dataSharePredicates.DataSharePredicates =
      new dataSharePredicates.DataSharePredicates().equalTo(photoAccessHelper.PhotoKeys.URI, uri);
    const result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> = await helper.getAssets({
      fetchColumns: [],
      predicates: predicates
    });
    try {
      if (result.getCount() === 0) {
        throw new Error('系统未授权读取所选图片');
      }
      const asset: photoAccessHelper.PhotoAsset = await result.getFirstObject();
      return { uri: asset.uri, displayName: asset.displayName };
    } finally {
      result.close();
    }
  }

  /** Returns the first Picker result URI, or an empty string when the user cancelled. */
  static selectedUri(photoUris: string[]): string {
    return photoUris.length > 0 ? photoUris[0] : '';
  }

  /**
   * Import one Picker-selected image next to the current note in an `attachments` folder.
   * The relative path stays inside the note directory so it remains valid through vault moves.
   */
  static async importPickedImage(registry: VaultRegistry, context: common.UIAbilityContext,
    vaultId: string, notePath: string, uri: string): Promise<NoteImageImportResult> {
    if (uri.length === 0 || notePath.length === 0) {
      throw new Error('请先选择一篇笔记和一张图片');
    }

    let phase: string = '读取所选图片信息';
    let attachmentDirAbs: string = '';
    let createdAttachmentDir: boolean = false;
    let targetAbs: string = '';
    let copyStarted: boolean = false;
    let source: fileIo.File | undefined = undefined;
    try {
      const asset: NoteImageSelectedAsset = await NoteImageService.selectedAsset(context, uri);
      const extension: string = NoteImageService.imageExtension(asset.displayName);
      const noteDir: string = NoteImageService.parentDirectory(notePath);
      const attachmentDir: string = noteDir.length > 0 ? noteDir + '/attachments' : 'attachments';
      attachmentDirAbs = registry.absoluteIn(vaultId, attachmentDir);
      phase = '创建附件目录';
      if (!fileIo.accessSync(attachmentDirAbs)) {
        fileIo.mkdirSync(attachmentDirAbs);
        createdAttachmentDir = true;
      } else if (!fileIo.statSync(attachmentDirAbs).isDirectory()) {
        throw new Error('附件目录位置已被文件占用');
      }

      const filename: string = NoteImageService.uniqueFilename(registry, vaultId, attachmentDir,
        asset.displayName, extension);
      const assetPath: string = attachmentDir + '/' + filename;
      phase = '打开所选图片';
      const sourceFile: fileIo.File = fileIo.openSync(asset.uri, fileIo.OpenMode.READ_ONLY);
      source = sourceFile;
      phase = '读取图片大小';
      const size: number = fileIo.statSync(sourceFile.fd).size;
      if (size <= 0) {
        throw new Error('所选图片内容为空');
      }
      targetAbs = registry.absoluteIn(vaultId, assetPath);
      phase = '复制图片';
      copyStarted = true;
      await fileIo.copyFile(sourceFile.fd, targetAbs);
      phase = '校验图片副本';
      const copiedSize: number = fileIo.statSync(targetAbs).size;
      NoteImageService.validateCopiedSize(size, copiedSize);
      return {
        markdownReference: NoteImageService.markdownReference(notePath, assetPath),
        assetPath: assetPath
      };
    } catch (error) {
      if (copyStarted && targetAbs.length > 0) {
        try {
          fileIo.unlinkSync(targetAbs);
        } catch (cleanupError) {
          // A failed copy may not have created a destination file.
        }
      }
      if (createdAttachmentDir && attachmentDirAbs.length > 0) {
        try {
          fileIo.rmdirSync(attachmentDirAbs);
        } catch (cleanupError) {
          // The directory may no longer be empty; leave unrelated content intact.
        }
      }
      const err = error as Error;
      throw new Error(phase + '失败：' + err.message);
    } finally {
      if (source !== undefined) {
        fileIo.closeSync(source);
      }
    }
  }

  /** Remove only the exact attachment created by this import when the note changed meanwhile. */
  static removeImportedImage(registry: VaultRegistry, vaultId: string, assetPath: string): void {
    try {
      fileIo.unlinkSync(registry.absoluteIn(vaultId, assetPath));
    } catch (error) {
      // Best effort; callers report that the note changed and do not insert a stale reference.
    }
  }

  /** Reject an empty or truncated copy before its Markdown reference is inserted. */
  static validateCopiedSize(sourceSize: number, copiedSize: number): void {
    if (sourceSize <= 0 || copiedSize !== sourceSize) {
      throw new Error('图片副本不完整');
    }
  }

  /** Create an encoded Markdown destination, including Unicode and punctuation in file names. */
  static markdownReference(notePath: string, assetPath: string): string {
    const noteDir: string = NoteImageService.parentDirectory(notePath);
    const prefix: string = noteDir.length > 0 ? noteDir + '/' : '';
    if (!assetPath.startsWith(prefix)) {
      throw new Error('图片引用必须位于当前笔记目录内');
    }
    const relativePath: string = assetPath.substring(prefix.length);
    const encoded: string[] = relativePath.split('/');
    for (let i = 0; i < encoded.length; i++) {
      encoded[i] = encodeURIComponent(encoded[i]);
    }
    return '![图片](<' + encoded.join('/') + '>)';
  }

  private static parentDirectory(notePath: string): string {
    const slash: number = notePath.lastIndexOf('/');
    return slash >= 0 ? notePath.substring(0, slash) : '';
  }

  private static imageExtension(displayName: string): string {
    const dot: number = displayName.lastIndexOf('.');
    const extension: string = dot >= 0 ? displayName.substring(dot + 1).toLowerCase() : '';
    if (NoteImageService.IMAGE_EXTENSIONS.indexOf(extension) < 0) {
      throw new Error('暂不支持此图片格式');
    }
    return extension;
  }

  private static uniqueFilename(registry: VaultRegistry, vaultId: string, attachmentDir: string,
    displayName: string, extension: string): string {
    const dot: number = displayName.lastIndexOf('.');
    let stem: string = dot > 0 ? displayName.substring(0, dot) : 'image';
    stem = stem.replace(/[\\/]/g, '_').replace(/[\u0000-\u001f\u007f]/g, '').replace(/^\.+/, '').trim();
    if (stem.length === 0) {
      stem = 'image';
    }
    if (stem.length > 120) {
      stem = stem.substring(0, 120);
    }

    const base: string = 'image-' + Date.now().toString() + '-' + stem;
    let suffix: number = 1;
    let candidate: string = base + '.' + extension;
    while (NoteImageService.pathExists(registry, vaultId, attachmentDir + '/' + candidate)) {
      suffix++;
      candidate = base + '-' + suffix.toString() + '.' + extension;
    }
    return candidate;
  }

  private static pathExists(registry: VaultRegistry, vaultId: string, relativePath: string): boolean {
    try {
      return fileIo.accessSync(registry.absoluteIn(vaultId, relativePath));
    } catch (error) {
      return false;
    }
  }
}
