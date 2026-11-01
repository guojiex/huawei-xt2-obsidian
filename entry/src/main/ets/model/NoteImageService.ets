/** Copy a user-selected Gallery image into the note's vault and create its Markdown reference. */
import { common } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { VaultRegistry } from './VaultRegistry';
import { VaultBinaryImportSource, VaultAccess } from './VaultAccess';

export interface NoteImageImportResult {
  markdownReference: string;
  assetPath: string;
}

interface NoteImageSelectedAsset {
  uri: string;
  displayName: string;
}

class SelectedImageBinarySource implements VaultBinaryImportSource {
  byteLength: number;
  private sourceFd: number;
  private uri: string;

  constructor(uri: string, sourceFd: number, byteLength: number) {
    this.uri = uri;
    this.sourceFd = sourceFd;
    this.byteLength = byteLength;
  }

  async copyToPath(destinationPath: string): Promise<void> {
    await fileIo.copyFile(this.sourceFd, destinationPath);
  }

  readBytes(): Uint8Array {
    const file: fileIo.File = fileIo.openSync(this.uri, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(this.byteLength);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read !== this.byteLength) {
        throw new Error('所选图片读取不完整');
      }
      return new Uint8Array(buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }
}

export class NoteImageService {
  private static readonly IMAGE_EXTENSIONS: string[] = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'];
  private static filenameSequence: number = 0;

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
    let selectedFile: fileIo.File | undefined = undefined;
    try {
      const asset: NoteImageSelectedAsset = await NoteImageService.selectedAsset(context, uri);
      const extension: string = NoteImageService.imageExtension(asset.displayName);
      const noteDir: string = NoteImageService.parentDirectory(notePath);
      const attachmentDir: string = noteDir.length > 0 ? noteDir + '/attachments' : 'attachments';
      const access: VaultAccess = registry.accessFor(vaultId);
      phase = '创建附件目录';
      if (!access.exists(attachmentDir)) {
        access.ensureDir(attachmentDir);
      } else if (access.stat(attachmentDir)?.isDir !== true) {
        throw new Error('附件目录位置已被文件占用');
      }

      const filename: string = NoteImageService.uniqueFilename(registry, vaultId, attachmentDir,
        asset.displayName, extension);
      const assetPath: string = attachmentDir + '/' + filename;
      const markdownReference: string = NoteImageService.markdownReference(notePath, assetPath);
      phase = '打开所选图片';
      const sourceFile: fileIo.File = fileIo.openSync(asset.uri, fileIo.OpenMode.READ_ONLY);
      selectedFile = sourceFile;
      phase = '读取图片大小';
      const size: number = fileIo.statSync(sourceFile.fd).size;
      if (size <= 0) {
        throw new Error('所选图片内容为空');
      }
      const binarySource: VaultBinaryImportSource = new SelectedImageBinarySource(asset.uri, sourceFile.fd, size);
      phase = '复制图片';
      await access.writeNewBinary(assetPath, binarySource);
      return {
        markdownReference: markdownReference,
        assetPath: assetPath
      };
    } catch (error) {
      const err = error as Error;
      throw new Error(phase + '失败：' + err.message);
    } finally {
      if (selectedFile !== undefined) {
        fileIo.closeSync(selectedFile);
      }
    }
  }

  /** Remove only the exact attachment created by this import when the note changed meanwhile. */
  static removeImportedImage(registry: VaultRegistry, vaultId: string, assetPath: string): void {
    try {
      registry.accessFor(vaultId).remove(assetPath);
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

    NoteImageService.filenameSequence++;
    const base: string = 'image-' + Date.now().toString() + '-' +
      NoteImageService.filenameSequence.toString() + '-' + stem;
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
      return registry.accessFor(vaultId).exists(relativePath);
    } catch (error) {
      return false;
    }
  }
}
