import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';

@CustomDialog
export struct ShareTextPreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  initialContent: string = '';
  limitations: string[] = [];
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  initialError: string = '';
  onRetryPreparation: () => Promise<void> = async (): Promise<void> => {};
  onBack: () => void = () => {};
  onConfirm: (content: string) => Promise<void> =
    async (content: string): Promise<void> => {};
  @State contentDraft: string = '';
  @State sharing: boolean = false;
  @State preparing: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.contentDraft = this.initialContent;
    this.errorMessage = this.initialError;
  }

  private back(): void {
    this.controller?.close();
    this.onBack();
  }

  private async confirm(): Promise<void> {
    if (this.sharing) {
      return;
    }
    this.sharing = true;
    this.errorMessage = '';
    try {
      await this.onConfirm(this.contentDraft);
    } catch (error) {
      const err = error as Error;
      this.errorMessage = err.message.length > 0 ? err.message : '系统分享面板无法接收此文本，请改用 Markdown / ZIP';
    } finally {
      this.sharing = false;
    }
  }

  private async retryPreparation(): Promise<void> {
    if (this.preparing) {
      return;
    }
    this.preparing = true;
    this.errorMessage = '';
    try {
      await this.onRetryPreparation();
    } catch (error) {
      const err = error as Error;
      this.errorMessage = err.message.length > 0 ? err.message : '文本准备失败，请重试';
    } finally {
      this.preparing = false;
    }
  }

  build() {
    Column({ space: Space.s3 }) {
      Row() {
        Row({ space: Space.s3 }) {
          Row() {
            Icon('message', Space.s5, $r('app.color.brand'))
          }
          .width(Space.s10)
          .height(Space.s10)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.brand_bg'))
          Column({ space: Space.s1 }) {
            Text('文本分享')
              .fontSize(FontSize.s3)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.itemName)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        Text('×')
          .fontSize(FontSize.s1)
          .fontColor($r('app.color.text_secondary'))
          .width(Size.touch)
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .accessibilityText('关闭文本预览')
          .focusable(true)
          .onClick(() => { this.back(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: Space.s3 }) {
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
          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.danger'))
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxHeight: this.windowHeightVp > 0
        ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s8 * 7))
        : Size.menuMaxH })
      .scrollBar(BarState.Off)
      Row({ space: Space.s2 }) {
        Button('返回格式选择')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.back(); })
        Button(this.initialError.length > 0
          ? (this.preparing ? '正在重试…' : '重试获取文本')
          : (this.sharing ? '正在打开…' : '分享文本'))
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .enabled(!this.sharing && !this.preparing)
          .onClick(() => {
            if (this.initialError.length > 0) {
              void this.retryPreparation();
            } else {
              void this.confirm();
            }
          })
      }
      .width('100%')
    }
    .width(this.windowWidthVp > 0
      ? Math.max(0, Math.min(Size.shareW, this.windowWidthVp - Space.s8))
      : Size.shareW)
    .constraintSize({ maxHeight: this.windowHeightVp > 0
      ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s6))
      : Size.menuMaxH })
    .padding(Space.s5)
    .borderRadius(this.singleScreen
      ? { topLeft: Radius.dialog, topRight: Radius.dialog, bottomLeft: 0, bottomRight: 0 }
      : Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}
