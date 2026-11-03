import { FontSize, Radius, Size, Space } from '../common/Tokens';

export interface ShareImagePreviewImage {
  uri: string;
  aspectRatio: number;
  scaled: boolean;
}

@CustomDialog
export struct ShareImagePreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  image: ShareImagePreviewImage = { uri: '', aspectRatio: 1, scaled: false };
  onConfirm: () => void = () => {};
  onCancel: () => void = () => {};

  private cancel(): void {
    this.controller?.close();
    this.onCancel();
  }

  private confirm(): void {
    this.onConfirm();
  }

  build() {
    Column({ space: Space.s3 }) {
      Text('长图预览')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(this.itemName + ' · 1 张长图')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.image.scaled) {
        Text('为保留全文，长图已整体按比例缩小')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      Scroll() {
        Column() {
          Image(this.image.uri)
            .width('100%')
            .aspectRatio(this.image.aspectRatio)
            .objectFit(ImageFit.Contain)
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.bg_secondary'))
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
