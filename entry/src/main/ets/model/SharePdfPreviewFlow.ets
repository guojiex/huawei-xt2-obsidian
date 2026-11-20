import fileUri from '@ohos.file.fileuri';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NoteShareService } from './NoteShareService';
import { VaultRegistry } from './VaultRegistry';

const DOMAIN: number = 0x0000;
const TAG: string = 'SharePdfPreviewFlow';

/** PDF 分页预览请求：会话数据 + 弹窗布局参数 + 确认 / 取消回调（53.7 / 53.12）。 */
export class SharePdfPreviewRequest {
  itemName: string = '';
  fileName: string = '';
  sessionId: string = '';
  /**
   * v1.94：产物已生成（ArkWeb 官方引擎），这里传的是**预览缩略图**路径
   * （PDF Kit 从真实 PDF 渲染的页图），不再是端侧逐页截图的 JPEG。
   */
  previewImages: string[] = [];
  /** 逐页宽高比；官方引擎产出恒为 A4 比例，缺省时弹窗回退 A4。 */
  pageAspects: number[] = [];
  /** v1.94：已生成的 PDF 产物路径（确认后直接进文件预览，无需再合成）。 */
  pdfPath: string = '';
  windowWidthVp: number = 0;
  windowHeightVp: number = 0;
  singleScreen: boolean = false;
  /** 「分享 PDF」确认后回调（pdfPath 为产物路径）。 */
  onComposed: (pdfPath: string) => void = (_pdfPath: string) => {};
  /** 返回 / 关闭预览（会话已清理）后回调。 */
  onCancelled: () => void = () => {};
}

/**
 * PDF 分页预览会话（v1.53 53.7，自 Index 拆出）。
 * ⚠️ CustomDialogController 仅在作为 @Component struct 成员变量、且在 struct
 * 内部定义时赋值才有效（官方文档）——本类是普通类，不得创建弹窗控制器，否则
 * open() 静默不显示（XT2 真机「点 PDF 分享无任何反应」根因，2026-11-18）。
 * 弹窗控制器由 ShareFlowPanel（struct）持有，本类只管会话状态与清理。
 *
 * v1.94：官方引擎路线下 PDF 产物在预览前就已生成，本类不再负责合成
 * （旧版 composePdf 把逐页 JPEG 合成 PDF）；composePdf 保留为「返回已有产物路径」。
 */
export class SharePdfPreviewFlow {
  private sessionId: string = '';
  private previewImages: string[] = [];
  private pageAspects: number[] = [];
  private pdfPath: string = '';

  /** 记录会话并生成缩略图 URI 列表；弹窗 builder 由调用方 struct 组装。 */
  openSession(request: SharePdfPreviewRequest): string[] {
    this.sessionId = request.sessionId;
    this.previewImages = request.previewImages;
    this.pageAspects = request.pageAspects;
    this.pdfPath = request.pdfPath;
    const pageUris: string[] = [];
    for (let i: number = 0; i < request.previewImages.length; i++) {
      pageUris.push(fileUri.getUriFromPath(request.previewImages[i]));
    }
    return pageUris;
  }

  /**
   * 返回已生成的 PDF 产物路径。
   * v1.94：官方引擎在预览前已落盘，确认时无需再合成；旧位图路线的合成逻辑已下线。
   */
  async composePdf(): Promise<string> {
    const path: string = this.pdfPath;
    if (path.length === 0) {
      throw new Error('PDF 分页会话已失效，请返回重试');
    }
    return path;
  }

  /** 清理会话目录（24h 过期机制兜底）；失败仅告警不掩盖原流程。 */
  cleanup(): void {
    const sessionId: string = this.sessionId;
    this.sessionId = '';
    this.previewImages = [];
    this.pageAspects = [];
    this.pdfPath = '';
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
