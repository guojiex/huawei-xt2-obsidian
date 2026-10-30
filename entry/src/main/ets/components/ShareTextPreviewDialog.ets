import { FontSize, Radius, Size, Space } from '../common/Tokens';

@CustomDialog
export struct ShareTextPreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  initialContent: string = '';
  limitations: string[] = [];
  onBack: () => void = () => {};
  onConfirm: (content: string) => void = (content: string) => {};
  @State contentDraft: string = '';

  aboutToAppear(): void {
    this.contentDraft = this.initialContent;
  }

  private back(): void {
    this.controller?.close();
    this.onBack();
  }

  private confirm(): void {
    this.controller?.close();
    this.onConfirm(this.contentDraft);
  }

  build() {
    Column({ space: Space.s3 }) {
      Row() {
        Text('文本分享预览')
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
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('可编辑将要交接的纯文本；此处修改不会写回笔记。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextArea({ text: this.contentDraft, placeholder: '纯文本内容' })
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .padding(Space.s3)
        .height(Size.drawerW * 0.58)
        .borderRadius(Radius.control)
        .border({ width: 1, color: $r('app.color.line') })
        .onChange((value: string): void => { this.contentDraft = value; })
      if (this.limitations.length > 0) {
        Column({ space: Space.s1 }) {
          ForEach(this.limitations, (limitation: string, index: number) => {
            Text('• ' + limitation)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }, (limitation: string, index: number) => index.toString())
        }
        .width('100%')
      }
      Row({ space: Space.s2 }) {
        Button('返回格式选择')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.back(); })
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
