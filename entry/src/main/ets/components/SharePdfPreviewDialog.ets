import { LengthMetrics, UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

/**
 * PDF 分页预览弹窗（v1.53 53.7，对齐 v2 原型 previewPdfShare）：
 * 点击分享面板「PDF 文档」后先逐页捕获成 JPEG，再在本弹窗内展示分页预览——
 * 规格胶囊（A4 竖版 / 浅色纸面 / 按段落分页 / 末页水印）、逐页缩略图（第 N 页 / 共 M 页）
 * 与「分享 PDF」主按钮；确认后才把逐页 JPEG 合成为 PDF 并进入文件预览。
 */
@CustomDialog
export struct SharePdfPreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  fileName: string = '';
  @Prop pageUris: string[] = [];
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  onCancel: () => void = () => {};
  @State sharing: boolean = false;
  @State errorMessage: string = '';

  private back(): void {
    this.controller?.close();
    this.onCancel();
  }

  private async share(): Promise<void> {
    if (this.sharing) {
      return;
    }
    this.sharing = true;
    this.errorMessage = '';
    try {
      await this.onConfirm();
    } catch (error) {
      this.errorMessage = shareFailureMessage(error, 'file_prepare');
    } finally {
      this.sharing = false;
    }
  }

  @Builder
  SpecChip(label: string) {
    Text(label)
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_secondary'))
  }

  @Builder
  PageThumb(uri: string, index: number) {
    Column({ space: Space.s1 }) {
      Image(uri)
        .width(Size.pdfThumbW)
        .aspectRatio(595 / 842)
        .objectFit(ImageFit.Cover)
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_secondary'))
      Text((index + 1).toString() + ' / ' + this.pageUris.length.toString())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .accessibilityText('第 ' + (index + 1).toString() + ' 页，共 ' + this.pageUris.length.toString() + ' 页')
    }
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s2 }) {
      Row({ space: Space.s1 }) {
        this.SpecChip('A4 竖版')
        this.SpecChip('浅色纸面')
        this.SpecChip('按段落分页')
        this.SpecChip('末页水印')
      }
      .width('100%')

      Row({ space: Space.s3 }) {
        Text('1 个 PDF')
          .fontSize(FontSize.caption)
          .fontWeight(600)
          .fontColor($r('app.color.text_primary'))
        Text(this.fileName)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.pageUris.length.toString() + ' 页')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(Space.s3), cross: LengthMetrics.vp(Space.s3) } }) {
          ForEach(this.pageUris, (uri: string, index: number) => {
            this.PageThumb(uri, index)
          }, (uri: string, index: number) => uri + '#' + index.toString())
        }
        .width('100%')
      }
      .width('100%')
      .padding(Space.s3)
      .borderRadius(Radius.menu)
      .backgroundColor($r('app.color.bg_secondary'))
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .layoutWeight(1)
      .constraintSize({ minHeight: 0 })

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s3 }) {
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '返回'), 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.back();
        }, true)
      UtilityDialogAction(
        UIUtils.makeBinding<string>(() => this.sharing ? '正在生成…' : '分享 PDF'),
        'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => !this.sharing),
        (): void => {
          void this.share();
        }, true)
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: 'PDF 分享',
      subtitle: this.itemName,
      headerIcon: 'doc',
      closeLabel: '关闭 PDF 预览',
      singleScreen: this.singleScreen,
      scrollContent: false,
      fillContentHeight: true,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => {
        this.back();
      },
      content: (): void => {
        this.DialogContent();
      },
      footer: (): void => {
        this.DialogFooter();
      }
    })
  }
}
