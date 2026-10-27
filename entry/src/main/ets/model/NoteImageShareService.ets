import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { NoteShareService } from './NoteShareService';
import { VaultRegistry } from './VaultRegistry';

/** 预览全文截图分页；每一页最多占一个 Share Kit record。 */
export class NoteImageShareService {
  private static nextId: number = 0;
  static readonly MAX_PAGES: number = 500;

  static pageTops(scrollHeight: number, viewportHeight: number): number[] {
    if (!Number.isFinite(scrollHeight) || !Number.isFinite(viewportHeight) ||
      scrollHeight <= 0 || viewportHeight <= 0) {
      throw new Error('分享预览没有可用的页面尺寸');
    }
    const pageCount: number = Math.max(1, Math.ceil(scrollHeight / viewportHeight));
    if (pageCount > NoteImageShareService.MAX_PAGES) {
      throw new Error('笔记超过 ' + NoteImageShareService.MAX_PAGES.toString() +
        ' 张图片的分享上限；请改用 Markdown / ZIP');
    }
    const tops: number[] = [];
    for (let i = 0; i < pageCount; i++) {
      tops.push(i * viewportHeight);
    }
    return tops;
  }

  static createSession(registry: VaultRegistry): string {
    NoteShareService.pruneExpired(registry);
    const id: string = 'image-' + Date.now().toString() + '-' + NoteImageShareService.nextId.toString();
    NoteImageShareService.nextId++;
    fileIo.mkdirSync(registry.sharePath(id), true);
    return id;
  }

  static pagePath(registry: VaultRegistry, sessionId: string, pageIndex: number): string {
    if (pageIndex < 0 || pageIndex >= NoteImageShareService.MAX_PAGES) {
      throw new Error('分享图片页码超出上限');
    }
    let pageNumber: string = (pageIndex + 1).toString();
    while (pageNumber.length < 3) {
      pageNumber = '0' + pageNumber;
    }
    return registry.sharePath(sessionId + '/page-' + pageNumber + '.jpg');
  }

  static async writeJpeg(filePath: string, pixelMap: image.PixelMap): Promise<void> {
    let file: fileIo.File | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      file = fileIo.openSync(filePath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      packer = image.createImagePacker();
      await packer.packToFile(pixelMap, file.fd, { format: 'image/jpeg', quality: 92 });
    } finally {
      try {
        if (packer !== null) {
          await packer.release();
        }
      } finally {
        try {
          if (file !== null) {
            fileIo.closeSync(file);
          }
        } finally {
          await pixelMap.release();
        }
      }
    }
  }
}
