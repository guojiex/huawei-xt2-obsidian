import { FontSize, Radius, Size, Space } from '../common/Tokens';

export interface ShareFormatOption {
  value: string;
  label: string;
  detail: string;
}

@CustomDialog
export struct ShareNoteDialog {
  controller?: CustomDialogController;
  title: string = '分享笔记';
  itemName: string = '';
  scopeDescription: string = '';
  itemSummary: string = '';
  notice: string = '';
  options: ShareFormatOption[] = [];
  onConfirm: (format: string) => void = (format: string) => {};
  @State selectedFormat: string = '';

  aboutToAppear(): void {
    if (this.options.length > 0) {
      this.selectedFormat = this.options[0].value;
    }
  }

  private confirm(): void {
    this.controller?.close();
    this.onConfirm(this.selectedFormat);
  }

  build() {
    Column({ space: Space.s3 }) {
      Row() {
        Text(this.title)
          .fontSize(FontSize.s3)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('×')
          .fontSize(FontSize.s1)
          .fontColor($r('app.color.text_secondary'))
          .width(Size.touch)
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .focusable(true)
          .onClick(() => { this.controller?.close(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Text(this.itemName)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.scopeDescription)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (this.itemSummary.length > 0) {
        Text(this.itemSummary)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      ForEach(this.options, (option: ShareFormatOption) => {
        Row({ space: Space.s2 }) {
          Text(this.selectedFormat === option.value ? '●' : '○')
            .fontSize(FontSize.body2)
            .fontColor(this.selectedFormat === option.value
              ? $r('app.color.brand') : $r('app.color.text_tertiary'))
          Column({ space: Space.s1 }) {
            Text(option.label)
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_primary'))
            Text(option.detail)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: Space.s2, bottom: Space.s2, left: Space.s2, right: Space.s2 })
        .borderRadius(Radius.control)
        .backgroundColor(this.selectedFormat === option.value
          ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
        .onClick(() => { this.selectedFormat = option.value; })
      }, (option: ShareFormatOption) => option.value)
      if (this.notice.length > 0) {
        Text(this.notice)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      Row({ space: Space.s2 }) {
        Button('准备分享')
          .width('100%')
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .enabled(this.selectedFormat.length > 0)
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
