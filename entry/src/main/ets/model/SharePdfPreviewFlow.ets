import { fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SharePdfPreviewDialog } from '../components/SharePdfPreviewDialog';
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
 * PDF 分页预览流程（v1.53 53.7，自 Index 拆出避免巨型页文件冲突）：
 * 逐页 JPEG 已在会话目录，弹窗展示分页缩略图；「分享 PDF」确认后合成 PDF
 * 交 onComposed 进文件预览；返回则清理会话交 onCancelled 回分享面板。
 */
export class SharePdfPreviewFlow {
  private ctl: CustomDialogController | null = null;
  private sessionId: string = '';
  private pages: string[] = [];
  private pageAspects: number[] = [];

  open(request: SharePdfPreviewRequest): void {
    this.ctl?.close();
    this.sessionId = request.sessionId;
    this.pages = request.pageJpegs;
    this.pageAspects = request.pageAspects;
    const pageUris: string[] = [];
    for (let i: number = 0; i < request.pageJpegs.length; i++) {
      pageUris.push(fileUri.getUriFromPath(request.pageJpegs[i]));
    }
    this.ctl = new CustomDialogController({
      builder: SharePdfPreviewDialog({
        itemName: request.itemName,
        fileName: request.fileName,
        pageUris: pageUris,
        pageAspects: request.pageAspects,
        windowWidthVp: request.windowWidthVp,
        windowHeightVp: request.windowHeightVp,
        singleScreen: request.singleScreen,
        onConfirm: (): Promise<void> => {
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
          NotePdfDocumentService.exportFromPageImages(pages, aspects, pdfPath);
          this.ctl?.close();
          request.onComposed(pdfPath);
          return Promise.resolve();
        },
        onCancel: (): void => {
          this.cleanup();
          request.onCancelled();
        }
      }),
      alignment: request.singleScreen ? DialogAlignment.Bottom : DialogAlignment.Center,
      autoCancel: false,
      customStyle: true
    });
    this.ctl.open();
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
