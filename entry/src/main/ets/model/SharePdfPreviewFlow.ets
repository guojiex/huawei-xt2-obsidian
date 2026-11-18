import fileUri from '@ohos.file.fileuri';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NotePdfDocumentService } from './NotePdfDocumentService';
import { NoteShareService } from './NoteShareService';
import { VaultRegistry } from './VaultRegistry';

const DOMAIN: number = 0x0000;
const TAG: string = 'SharePdfPreviewFlow';

/** PDF 分页预览请求：会话数据 + 弹窗布局参数 + 合成 / 取消回调（53.7 / 53.12）。 */
export class SharePdfPreviewRequest {
  itemName: string = '';
  fileName: string = '';
  sessionId: string = '';
  pageJpegs: string[] = [];
  /** 53.12：非末页裁到切片高后逐页宽高比与 A4 不同，缩略图与合成都按真实比例。 */
  pageAspects: number[] = [];
  windowWidthVp: number = 0;
  windowHeightVp: number = 0;
  singleScreen: boolean = false;
  /** 「分享 PDF」确认且合成完成后回调（pdfPath 为产物路径）。 */
  onComposed: (pdfPath: string) => void = (_pdfPath: string) => {};
  /** 返回 / 关闭预览（会话已清理）后回调。 */
  onCancelled: () => void = () => {};
}

/**
 * PDF 分页预览会话（v1.53 53.7，自 Index 拆出）：逐页 JPEG 已在会话目录。
 * ⚠️ CustomDialogController 仅在作为 @Component struct 成员变量、且在 struct
 * 内部定义时赋值才有效（官方文档）——本类是普通类，不得创建弹窗控制器，否则
 * open() 静默不显示（XT2 真机「点 PDF 分享无任何反应」根因，2026-11-18）。
 * 弹窗控制器由 ShareFlowPanel（struct）持有，本类只管会话状态、合成与清理。
 */
export class SharePdfPreviewFlow {
  private sessionId: string = '';
  private pages: string[] = [];
  private pageAspects: number[] = [];

  /** 记录会话并生成缩略图 URI 列表；弹窗 builder 由调用方 struct 组装。 */
  openSession(request: SharePdfPreviewRequest): string[] {
    this.sessionId = request.sessionId;
    this.pages = request.pageJpegs;
    this.pageAspects = request.pageAspects;
    const pageUris: string[] = [];
    for (let i: number = 0; i < request.pageJpegs.length; i++) {
      pageUris.push(fileUri.getUriFromPath(request.pageJpegs[i]));
    }
    return pageUris;
  }

  /** 合成当前会话的逐页 JPEG 为 PDF，返回产物路径（供进文件预览）。 */
  async composePdf(): Promise<string> {
    const sid: string = this.sessionId;
    if (sid.length === 0) {
      throw new Error('PDF 分页会话已失效，请返回重试');
    }
    const pages: string[] = this.pages;
    if (pages.length === 0) {
      throw new Error('PDF 分页页面缺失，请返回重试');
    }
    const aspects: number[] = this.pageAspects;
    if (aspects.length !== pages.length) {
      throw new Error('PDF 分页页面缺失，请返回重试');
    }
    const pdfPath: string = VaultRegistry.get().sharePath(sid + '/note.pdf');
    // 2026-11-15 冷启动优化：NotePdfDocumentService.exportFromPageImages 随
    // pdfService 动态化改为 async，此处 await 落盘完成后再返回。
    await NotePdfDocumentService.exportFromPageImages(pages, aspects, pdfPath);
    return pdfPath;
  }

  /** 清理会话目录（24h 过期机制兜底）；失败仅告警不掩盖原流程。 */
  cleanup(): void {
    const sessionId: string = this.sessionId;
    this.sessionId = '';
    this.pages = [];
    this.pageAspects = [];
    if (sessionId.length === 0) {
      return;
    }
    try {
      NoteShareService.removeTree(VaultRegistry.get(), sessionId);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'PDF 分页预览临时文件清理失败');
    }
  }
}
