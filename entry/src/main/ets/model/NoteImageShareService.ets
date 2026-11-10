import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { NoteShareService } from './NoteShareService';
import { VaultRegistry } from './VaultRegistry';

/** 完整笔记长图的目标尺寸；渲染仍按视口分段，交付时合成为一个 PixelMap 和一个 JPEG。 */
export interface NoteImageShareGeometry {
  width: number;
  height: number;
  scale: number;
  pixelsPerVp: number;
}

export class NoteImageShareService {
  private static nextId: number = 0;
  /** 单个 PixelMap 使用比 SDK 128 MB 序列化上限更低的预算，给编码和临时截图留余量。 */
  static readonly MAX_PIXEL_MAP_BYTES: number = 96 * 1024 * 1024;
  static readonly MIN_IMAGE_WIDTH: number = 640;
  /** 最大内部捕获段数；这些段只用于合成长图，不会分别交给系统分享。 */
  static readonly MAX_PAGES: number = 500;

  static pageTops(scrollHeight: number, viewportHeight: number): number[] {
    if (!Number.isFinite(scrollHeight) || !Number.isFinite(viewportHeight) ||
      scrollHeight <= 0 || viewportHeight <= 0) {
      throw new Error('分享预览没有可用的页面尺寸');
    }
    const pageCount: number = Math.max(1, Math.ceil(scrollHeight / viewportHeight));
    if (pageCount > NoteImageShareService.MAX_PAGES) {
      throw new Error('笔记超过单张长图分享上限；请改用 Markdown / ZIP');
    }
    const tops: number[] = [];
    for (let i = 0; i < pageCount; i++) {
      tops.push(i * viewportHeight);
    }
    return tops;
  }

  static longImageGeometry(pixelWidth: number, pixelViewportHeight: number,
    scrollHeight: number, viewportHeight: number): NoteImageShareGeometry {
    if (!Number.isFinite(pixelWidth) || !Number.isFinite(pixelViewportHeight) ||
      !Number.isFinite(scrollHeight) || !Number.isFinite(viewportHeight) ||
      pixelWidth <= 0 || pixelViewportHeight <= 0 || scrollHeight <= 0 || viewportHeight <= 0) {
      throw new Error('无法确定长图尺寸，请改用 Markdown / ZIP');
    }
    const pixelsPerVp: number = pixelViewportHeight / viewportHeight;
    const sourceHeight: number = Math.ceil(scrollHeight * pixelsPerVp);
    const sourceBytes: number = pixelWidth * sourceHeight * 4;
    let scale: number = sourceBytes > NoteImageShareService.MAX_PIXEL_MAP_BYTES
      ? Math.sqrt(NoteImageShareService.MAX_PIXEL_MAP_BYTES / sourceBytes) : 1;
    let width: number = Math.max(1, Math.floor(pixelWidth * scale));
    let height: number = Math.max(1, Math.ceil(sourceHeight * scale));
    while (width * height * 4 > NoteImageShareService.MAX_PIXEL_MAP_BYTES) {
      scale *= 0.999;
      width = Math.max(1, Math.floor(pixelWidth * scale));
      height = Math.max(1, Math.ceil(sourceHeight * scale));
    }
    if (width < NoteImageShareService.MIN_IMAGE_WIDTH) {
      throw new Error('笔记过长，无法生成清晰的单张长图；请改用 Markdown / ZIP');
    }
    return { width: width, height: height, scale: scale, pixelsPerVp: pixelsPerVp };
  }

  static createLongImage(geometry: NoteImageShareGeometry): image.PixelMap {
    return image.createPixelMapSync({
      size: { width: geometry.width, height: geometry.height },
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true
    });
  }

  /** 将一段截图缩放到目标尺寸后，写入完整长图的指定纵向位置。 */
  static async appendSegment(source: image.PixelMap, destination: image.PixelMap,
    destinationY: number, width: number, height: number): Promise<void> {
    if (destinationY < 0 || width <= 0 || height <= 0) {
      throw new Error('长图分段位置无效');
    }
    const destinationInfo = await destination.getImageInfo();
    if (width !== destinationInfo.size.width || destinationY + height > destinationInfo.size.height) {
      throw new Error('长图分段超出目标图片范围');
    }
    const sourceInfo = await source.getImageInfo();
    await source.scale(width / sourceInfo.size.width, height / sourceInfo.size.height);
    const scaledInfo = await source.getImageInfo();
    if (scaledInfo.size.width !== width || scaledInfo.size.height !== height) {
      throw new Error('长图分段缩放尺寸不匹配');
    }
    const pixels: ArrayBuffer = new ArrayBuffer(width * height * 4);
    const sourceArea: image.PositionArea = {
      pixels: pixels,
      offset: 0,
      stride: width * 4,
      region: { x: 0, y: 0, size: { width: width, height: height } }
    };
    await source.readPixels(sourceArea);
    const destinationArea: image.PositionArea = {
      pixels: pixels,
      offset: 0,
      stride: width * 4,
      region: { x: 0, y: destinationY, size: { width: width, height: height } }
    };
    await destination.writePixels(destinationArea);
  }

  static createSession(registry: VaultRegistry): string {
    NoteShareService.pruneExpired(registry);
    const id: string = 'image-' + Date.now().toString() + '-' + NoteImageShareService.nextId.toString();
    NoteImageShareService.nextId++;
    fileIo.mkdirSync(registry.sharePath(id), true);
    return id;
  }

  static imagePath(registry: VaultRegistry, sessionId: string): string {
    return registry.sharePath(sessionId + '/note.jpg');
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

  /** v1.53 PDF 逐页写盘：与 writeJpeg 同参数，但不释放 pixelMap（调用方 finally 统一 release，逐页循环复用长图分段模式）。 */
  static async writeJpegTo(filePath: string, pixelMap: image.PixelMap): Promise<void> {
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
        if (file !== null) {
          fileIo.closeSync(file);
        }
      }
    }
  }
}
