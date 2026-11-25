import { webview } from '@kit.ArkWeb';
import { NotePdfEngineDevice } from './NotePdfEngineDevice';

/**
 * NotePdfEngineService —— v1.94 PDF 导出服务层（ArkWeb 官方引擎路线）。
 *
 * 官方引擎的分工（见 docs/releases/v1.94/需求文档.md §3.1）：
 * - 分页由 Chromium print 管线按 CSS 纸宽重新布局并分页，原生支持行级断页、
 *   orphans / widows、break-inside / break-after；
 * - 产物是矢量 PDF（文字可选中可搜索、任意放大清晰）；
 * - 不拉起系统打印 UI、不需要 ohos.permission.PRINT，字节流直接进应用沙箱，
 *   因此天然适配「生成 → 预览 → 分享」的现有链路。
 *
 * 2026-11-20 冷启动优化：设备层（ArkWeb webview + PDF Kit pdfService）动态 import，
 * 首次导出 PDF 时才加载。
 *
 * 2026-11-25 旧位图链路（NotePdfDocumentService / NotePdfExportDevice /
 * pdfPagination.mjs，v1.53~v1.93）随 v1.94 验收收口删除，本类承接其仍被
 * 引用的 A4 point 常量与 syscap 检测；需要旧实现时查 Git 历史。
 */
export class NotePdfEngineService {
  /** A4 纸型（英寸）——PdfConfiguration.width/height 的单位是英寸。 */
  static readonly A4_WIDTH_INCH: number = 8.27;
  static readonly A4_HEIGHT_INCH: number = 11.69;
  /** A4 纸型（point）——PDF Kit 页坐标系单位，捕获层视口按此比例取整。 */
  static readonly A4_WIDTH_PT: number = 595;
  static readonly A4_HEIGHT_PT: number = 842;
  /** 单文件页数上限（与旧路线一致，需求 53.1）；超限提示改用 Markdown / ZIP。 */
  static readonly MAX_PAGES: number = 100;

  /** AD4：syscap 未核实，必须运行时检测；不支持时分享面板不显示 PDF 入口。 */
  static isSupported(): boolean {
    return canIUse('SystemCapability.OfficeService.PDFService.Core');
  }

  /**
   * 生成矢量 PDF 并写入沙箱指定路径，返回产物路径。
   *
   * @param controller 捕获层 Web 的 controller（ArkWeb 官方引擎入口）
   * @param pdfPath 产物路径（沙箱内）
   */
  static async exportFromWeb(controller: webview.WebviewController, pdfPath: string): Promise<string> {
    const deviceModule: ESObject = await import('./NotePdfEngineDevice');
    const device: ESObject = deviceModule.NotePdfEngineDevice;
    const bytes: Uint8Array = await device.createPdfBytes(controller,
      NotePdfEngineService.A4_WIDTH_INCH, NotePdfEngineService.A4_HEIGHT_INCH);
    await NotePdfEngineService.writeBytesTo(bytes, pdfPath);
    return pdfPath;
  }

  /**
   * 把已生成的 PDF 逐页渲染为 PNG，供预览弹窗展示缩略图。
   * 预览即产物——用户看到的分页与最终 PDF 完全一致。
   */
  static async renderPreview(pdfPath: string, outDir: string): Promise<string[]> {
    const deviceModule: ESObject = await import('./NotePdfEngineDevice');
    const device: ESObject = deviceModule.NotePdfEngineDevice;
    return device.renderPreviewPages(pdfPath, outDir);
  }

  /** 写入沙箱文件；失败清理半成品后抛错（避免留下损坏的 PDF）。 */
  private static async writeBytesTo(bytes: Uint8Array, path: string): Promise<void> {
    const fileIoModule: ESObject = await import('@ohos.file.fs');
    const fileIo: ESObject = fileIoModule.default;
    const file: ESObject = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, bytes.buffer);
    } catch (error) {
      fileIo.closeSync(file);
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
      } catch (_cleanupError) {
        // 清理失败不掩盖原错误；会话目录有 24 小时过期机制兜底。
      }
      throw new Error('PDF 保存失败，请重试');
    }
    fileIo.closeSync(file);
  }
}
