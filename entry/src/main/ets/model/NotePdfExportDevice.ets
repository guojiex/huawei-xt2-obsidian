import fileIo from '@ohos.file.fs';
import { pdfService } from '@kit.PDFKit';
import { NotePdfDocumentService } from './NotePdfDocumentService';

/**
 * NotePdfExportDevice —— v1.53 导出 PDF 的设备层（HMS PDF Kit 调用本体）。
 *
 * 2026-11-15 冷启动优化（XT2 trace）：pdfService（@kit.PDFKit）属启动期未用模块（82 个之一），
 * 从 NotePdfDocumentService 拆到本文件，由服务层动态 import 加载 —— 首次导出 PDF 才拉起。
 * 合成逻辑与注释自服务层原样搬移，行为不变（api_notes AD1：「图片→PDF」路线）。
 */
export class NotePdfExportDevice {
  /**
   * 逐页 JPEG 合成 A4 竖版 PDF。
   * pageAspects 为逐页真实宽高比（53.12 非末页裁到切片高后不再是 A4 比例）：
   * 图片按真实比例等比缩放宽贴 A4 宽、顶部对齐，下方留白即自然分页留白。
   * 任一步失败：清理半成品 PDF 后抛错；releaseDocument 兜底释放。
   * 入参合法性（空页 / 超上限 / 分页数量不匹配）由服务层在拉起本层之前校验。
   */
  static exportFromPageImages(pageJpegs: string[], pageAspects: number[], pdfPath: string): void {
    NotePdfExportDevice.removeIfPresent(pdfPath);
    const document: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      if (!document.createDocument(NotePdfDocumentService.A4_WIDTH_PT,
        NotePdfDocumentService.A4_HEIGHT_PT)) {
        throw new Error('PDF 文档创建失败，请重试');
      }
      for (let i: number = 0; i < pageJpegs.length; i++) {
        const aspect: number = pageAspects[i];
        if (!(aspect > 0)) {
          throw new Error('PDF 分页结果无效，请重试');
        }
        const drawWidth: number = Math.min(NotePdfDocumentService.A4_WIDTH_PT,
          NotePdfDocumentService.A4_HEIGHT_PT * aspect);
        const page: pdfService.PdfPage = document.insertBlankPage(i,
          NotePdfDocumentService.A4_WIDTH_PT, NotePdfDocumentService.A4_HEIGHT_PT);
        page.addImageObject(pageJpegs[i], 0, 0, drawWidth, drawWidth / aspect);
        page.release();
      }
      // createDocument 实测（模拟器 PDF-1.7）自带一张初始空白页：逐图 insertBlankPage 后
      // 该页悬在文档末尾，导出的 PDF 会多一张空白尾页。删除富余页；
      // 若实现不建初始页（getPageCount 恰等于图片数）则无需删除。
      const surplus: number = document.getPageCount() - pageJpegs.length;
      if (surplus > 0) {
        document.deletePage(pageJpegs.length, surplus);
      }
      if (!document.saveDocument(pdfPath)) {
        throw new Error('PDF 保存失败，请重试');
      }
    } catch (error) {
      NotePdfExportDevice.removeIfPresent(pdfPath);
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
