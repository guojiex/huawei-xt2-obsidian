import { FontSize, Radius, Size, Space } from '../common/Tokens';

export interface ShareImagePreviewPage {
  uri: string;
  aspectRatio: number;
  pageNumber: number;
}

@CustomDialog
export struct ShareImagePreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  pages: ShareImagePreviewPage[] = [];
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  private cancel(): void {
    this.controller?.close();
    this.onCancel();
  }

  private confirm(): void {
    this.controller?.close();
    this.onConfirm();
  }

  build() {
    Column({ space: Space.s3 }) {
      Text('分享图片预览')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(this.itemName + ' · ' + this.pages.length.toString() + ' 张')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Scroll() {
        Column({ space: Space.s3 }) {
          ForEach(this.pages, (page: ShareImagePreviewPage) => {
            Column({ space: Space.s1 }) {
              Text('第 ' + page.pageNumber.toString() + ' 张')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
              Image(page.uri)
                .width('100%')
                .aspectRatio(page.aspectRatio)
                .objectFit(ImageFit.Contain)
                .borderRadius(Radius.control)
                .backgroundColor($r('app.color.bg_secondary'))
            }
            .width('100%')
          }, (page: ShareImagePreviewPage) => page.pageNumber.toString())
        }
        .width('100%')
        .padding({ right: Space.s1 })
      }
      .width('100%')
      .height(Size.drawerW * 0.75)
      Row({ space: Space.s2 }) {
        Button('返回格式选择')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.cancel(); })
        Button('打开分享面板')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.confirm(); })
      }
      .width('100%')
    }
    .width(Size.drawerW)
    .padding(Space.s5)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}
