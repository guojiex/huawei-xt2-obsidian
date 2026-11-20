import { image } from '@kit.ImageKit';
import { webview } from '@kit.ArkWeb';

/**
 * NotePdfEngineDevice —— v1.94 PDF 导出的设备层（ArkWeb 官方引擎 + PDF Kit 渲染）。
 *
 * 2026-11-20 冷启动优化沿用 NotePdfExportDevice 的做法：ArkWeb 的 webview 与
 * PDF Kit 的 pdfService 都属启动期未用模块，本文件由服务层动态 import 加载，
 * 首次导出 PDF 时才拉起，启动图不受影响。
 *
 * 与 NotePdfExportDevice（旧位图路线）的关键差异：
 * - 旧：端侧逐页滚动截图 → JPEG → PDF Kit 把 JPEG 贴进 A4 页（文字为图片态，不可搜索）；
 * - 新：ArkWeb `createPdf` 走 Chromium print 管线，一次产出**矢量** PDF，
 *   分页由 CSS Fragmentation 原生实现（行级断页 / orphans / widows / break-inside）。
 *
 * SDK 依据（本机 API 26 SDK，逐项核对）：
 * - `WebviewController.createPdf(configuration: PdfConfiguration): Promise<PdfData>`
 *   （`@since 14`），`PdfData.pdfArrayBuffer(): Uint8Array`；
 * - `PdfConfiguration.width/height` 单位为**英寸**，A4 = 8.27 × 11.69；
 * - `PdfConfiguration.shouldPrintBackground` 默认 false——代码块底色 / 表格线 / callout
 *   底色都依赖它，故本实现固定为 true；
 * - `PdfConfiguration` 无页眉 / 页脚 / 页码字段，故本引擎不提供页码；
 * - PDF Kit：`new pdfService.PdfDocument()` → `loadDocument(path)` 返回 `ParseResult`
 *   枚举（`PARSE_SUCCESS` = 0），取页用 `getPage(index)`（非 getPageByIndex），
 *   渲染用 `PdfPage.getAreaPixelMap(matrix, bitmapWidth, bitmapHeight, isGray, drawAnnotations)`；
 * - ImageKit：`image.createImagePacker()` → `packing(pixelMap, option): Promise<ArrayBuffer>`。
 */
export class NotePdfEngineDevice {
  /**
   * 用 ArkWeb 官方引擎把当前 Web 页面导出为 PDF 字节流。
   *
   * 调用前提：controller 必须已绑定 Web 组件（SDK：17100001 Init error）。
   * 产物是矢量 PDF（文本可选中可搜索），分页由 Chromium print 管线按
   * `PdfConfiguration` 的纸宽重新布局并分页——web 侧需有 `@media print` 规则
   * 解除视口高度 / 滚动约束（见 web/mdpreview/build.mjs 的 @media print 块）。
   */
  static async createPdfBytes(controller: webview.WebviewController,
    widthInch: number, heightInch: number): Promise<Uint8Array> {
    const config: webview.PdfConfiguration = {
      width: widthInch,
      height: heightInch,
      marginTop: 0,
      marginBottom: 0,
      marginLeft: 0,
      marginRight: 0,
      scale: 1.0,
      // 打印背景色：代码块底色、表格线、callout 底色都依赖它，否则纸面一片白。
      shouldPrintBackground: true
    };
    const data: webview.PdfData = await controller.createPdf(config);
    const bytes: Uint8Array = data.pdfArrayBuffer();
    if (bytes.length === 0) {
      throw new Error('PDF 生成失败，请重试');
    }
    return bytes;
  }

  /**
   * 把 PDF 各页渲染为 PNG 位图，供预览弹窗展示缩略图。
   *
   * 预览渲染**真实产物**——旧位图路线里预览图与最终 PDF 同源但尺寸不同；
   * 本路线统一到「预览即产物」，避免用户看到的和拿到的不一致。
   *
   * @param pdfPath PDF 文件路径（沙箱内）
   * @param outDir 缩略图输出目录
   * @param targetWidthPx 缩略图宽度（像素），高度按 A4 比例推算
   * @returns 每页 PNG 路径（顺序对应页序）
   */
  static async renderPreviewPages(pdfPath: string, outDir: string,
    targetWidthPx: number): Promise<string[]> {
    const pdfServiceModule: ESObject = await import('@kit.PDFKit');
    const pdfService: ESObject = pdfServiceModule.pdfService;
    const doc: ESObject = new pdfService.PdfDocument();
    const parseResult: number = doc.loadDocument(pdfPath);
    if (parseResult !== pdfService.ParseResult.PARSE_SUCCESS) {
      throw new Error('PDF 预览渲染失败，请重试');
    }
    const paths: string[] = [];
    try {
      const pageCount: number = doc.getPageCount();
      if (pageCount <= 0) {
        throw new Error('PDF 预览渲染失败，请重试');
      }
      for (let i: number = 0; i < pageCount; i++) {
        const page: ESObject = doc.getPage(i);
        if (!page) {
          continue;
        }
        try {
          const matrix: ESObject = new pdfService.PdfMatrix();
          matrix.x = 0;
          matrix.y = 0;
          matrix.width = 1;
          matrix.height = 1;
          matrix.rotate = 0;
          // 渲染尺寸单位为 point（1 inch = 72 point）；按 A4 比例推算高度。
          const heightPx: number = Math.round(targetWidthPx * 842 / 595);
          const pixelMap: ESObject = page.getAreaPixelMap(matrix, targetWidthPx, heightPx,
            false, false);
          const outPath: string = outDir + '/preview-' + (i + 1).toString() + '.png';
          await NotePdfEngineDevice.writePngTo(pixelMap, outPath);
          paths.push(outPath);
        } finally {
          page.release();
        }
      }
    } finally {
      doc.releaseDocument();
    }
    if (paths.length === 0) {
      throw new Error('PDF 预览渲染失败，请重试');
    }
    return paths;
  }

  private static async writePngTo(pixelMap: image.PixelMap, path: string): Promise<void> {
    const packer: image.ImagePacker = image.createImagePacker();
    const option: image.PackingOption = {
      format: 'image/png',
      quality: 100
    };
    const data: ArrayBuffer = await packer.packing(pixelMap, option);
    const fileIoModule: ESObject = await import('@ohos.file.fs');
    const fileIo: ESObject = fileIoModule.default;
    const file: ESObject = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
  }
}
