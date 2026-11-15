/**
 * NotePdfDocumentService —— v1.53 导出 PDF：HMS PDF Kit 封装（需求 53.1）。
 *
 * 「图片→PDF」路线（api_notes AD1）：逐页 JPEG 经 addImageObject 全幅贴到 A4 页面。
 * 零权限（AD1 声明无 @permission）；设备支持未核实（AD4），调用方必须先 isSupported()。
 * 文字为图片态（不可选中 / 复制），页眉 / 页码不做（v1.53 §3）。
 *
 * 2026-11-15 冷启动优化（XT2 trace）：pdfService（@kit.PDFKit）从本文件静态依赖改为
 * 设备层（NotePdfExportDevice）动态 import —— 首次导出 PDF 时才加载，启动图不再拉起。
 * 入参校验仍在本层完成，超限 / 非法分页在拉起设备层之前就拒绝。
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

  /** 逐页 JPEG 合成 A4 竖版 PDF；合成本体在设备层（失败清理半成品后抛错）。 */
  static async exportFromPageImages(pageJpegs: string[], pageAspects: number[],
    pdfPath: string): Promise<void> {
    if (pageJpegs.length === 0) {
      throw new Error('没有可导出的 PDF 页面');
    }
    if (pageJpegs.length > NotePdfDocumentService.MAX_PAGES) {
      throw new Error('笔记超过单文件 PDF 页数上限；请改用 Markdown / ZIP');
    }
    if (pageAspects.length !== pageJpegs.length) {
      throw new Error('PDF 分页结果无效，请重试');
    }
    const deviceModule: ESObject = await import('./NotePdfExportDevice');
    const device: ESObject = deviceModule.NotePdfExportDevice;
    device.exportFromPageImages(pageJpegs, pageAspects, pdfPath);
  }
}
