import { fileIo } from '@kit.CoreFileKit';
import { pdfService } from '@kit.PDFKit';

/**
 * NotePdfDocumentService —— v1.53 导出 PDF：HMS PDF Kit 封装（需求 53.1）。
 *
 * 「图片→PDF」路线（api_notes AD1）：逐页 JPEG 经 addImageObject 全幅贴到 A4 页面。
 * 零权限（AD1 声明无 @permission）；设备支持未核实（AD4），调用方必须先 isSupported()。
 * 文字为图片态（不可选中 / 复制），页眉 / 页码不做（v1.53 §3）。
 */
export class NotePdfDocumentService {
  static readonly A4_WIDTH_PT: number = 595;
  static readonly A4_HEIGHT_PT: number = 842;
  /** 单文件页数上限（需求 53.1）；超限由调用方提示改用 Markdown / ZIP。 */
  static readonly MAX_PAGES: number = 100;

  /** AD4：syscap 未核实，必须运行时检测；不支持时分享面板不显示 PDF 入口。 */
  static isSupported(): boolean {
    return canIUse('SystemCapability.OfficeService.PDFService.Core');
  }

  /**
   * 逐页 JPEG 合成 A4 竖版 PDF。
   * 任一步失败：清理半成品 PDF 后抛错；releaseDocument 兜底释放。
   */
  static exportFromPageImages(pageJpegs: string[], pdfPath: string): void {
    if (pageJpegs.length === 0) {
      throw new Error('没有可导出的 PDF 页面');
    }
    if (pageJpegs.length > NotePdfDocumentService.MAX_PAGES) {
      throw new Error('笔记超过单文件 PDF 页数上限；请改用 Markdown / ZIP');
    }
    NotePdfDocumentService.removeIfPresent(pdfPath);
    const document: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      if (!document.createDocument(NotePdfDocumentService.A4_WIDTH_PT,
        NotePdfDocumentService.A4_HEIGHT_PT)) {
        throw new Error('PDF 文档创建失败，请重试');
      }
      for (let i: number = 0; i < pageJpegs.length; i++) {
        const page: pdfService.PdfPage = document.insertBlankPage(i,
          NotePdfDocumentService.A4_WIDTH_PT, NotePdfDocumentService.A4_HEIGHT_PT);
        page.addImageObject(pageJpegs[i], 0, 0,
          NotePdfDocumentService.A4_WIDTH_PT, NotePdfDocumentService.A4_HEIGHT_PT);
        page.release();
      }
      if (!document.saveDocument(pdfPath)) {
        throw new Error('PDF 保存失败，请重试');
      }
    } catch (error) {
      NotePdfDocumentService.removeIfPresent(pdfPath);
      throw new Error((error as Error).message);
    } finally {
      document.releaseDocument();
    }
  }

  private static removeIfPresent(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_error) {
      // 清理半成品失败不掩盖原错误；目标文件由会话目录 24h 过期机制兜底。
    }
  }
}
