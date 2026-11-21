import { image } from '@kit.ImageKit';
import { webview } from '@kit.ArkWeb';
import { pdfService } from '@kit.PDFKit';
import fileIo from '@ohos.file.fs';

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
 *
 * 2026-11-20 真机修复（XT2 报「cannot read property PdfDocument of undefined」）：
 * `await import('@kit.PDFKit')` **不可用**——官方《动态加载》规格表中动态 import 支持的
 * API 形态只有 `@system.*` / `@ohos.*` / `@arkui-x.*`，`@kit.*` 是编译期 d.ts 别名、
 * 运行时无此模块名，拿到的命名空间里 pdfService 为 undefined。kit 一律静态 import
 * （与 NotePdfExportDevice 同模式）；冷启动优化不受影响——本文件仍由服务层
 * 动态 import（./NotePdfEngineDevice），首次导出 PDF 才加载。
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
   * ⚠️ getAreaPixelMap 的 bitmap 宽高与 matrix 区域（point）是 **1:1 映射，不缩放**
   * （FAQ faqs-pdf-9）：bitmap 小于区域 → 超出部分被截断；大于区域 → 空白填补；
   * PixelOptions 也无缩放选项。因此完整渲染整页必须让 bitmap = 页面 point 尺寸
   * （A4 → 595×842 px PNG）。2026-11-21 XT2 实测：bitmap 传 300×424 时预览
   * 恰好只显示页面左半，右侧内容被截断，与该规则一致。
   *
   * @param pdfPath PDF 文件路径（沙箱内）
   * @param outDir 缩略图输出目录
   * @returns 每页 PNG 路径（顺序对应页序）
   */
  static async renderPreviewPages(pdfPath: string, outDir: string): Promise<string[]> {
    const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
    const paths: string[] = [];
    try {
      const parseResult: pdfService.ParseResult = doc.loadDocument(pdfPath);
      if (parseResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF 预览渲染失败，请重试');
      }
      const pageCount: number = doc.getPageCount();
      if (pageCount <= 0) {
        throw new Error('PDF 预览渲染失败，请重试');
      }
      for (let i: number = 0; i < pageCount; i++) {
        const page: pdfService.PdfPage = doc.getPage(i);
        try {
          // PdfMatrix 单位是 point（API 参考明确 width/height 单位为 Points）。首版误传
          // 1×1（当成归一化坐标），真机渲染 1 平方 point 白边拉满全图 → 预览全空白
          // （2026-11-20 XT2 实测）。matrix 覆盖整页：x/y 归零，宽高取真实页面尺寸
          // （PdfPage.getWidth/getHeight，@since 5.0.0(12)，单位 point）。
          const pageWidthPt: number = page.getWidth();
          const pageHeightPt: number = page.getHeight();
          if (!(pageWidthPt > 0) || !(pageHeightPt > 0)) {
            throw new Error('PDF 预览渲染失败，请重试');
          }
          const matrix: pdfService.PdfMatrix = new pdfService.PdfMatrix();
          matrix.x = 0;
          matrix.y = 0;
          matrix.width = pageWidthPt;
          matrix.height = pageHeightPt;
          matrix.rotate = 0;
          // bitmap 与 matrix 区域 1:1（见方法注释）；ceil 保证 bitmap ≥ 区域，
          // 宁可右/下多 1px 白边也不截内容（FAQ：小于区域会截断）。
          const pixelMap: image.PixelMap = page.getAreaPixelMap(matrix, Math.ceil(pageWidthPt),
            Math.ceil(pageHeightPt), false, false);
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
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
  }
}
