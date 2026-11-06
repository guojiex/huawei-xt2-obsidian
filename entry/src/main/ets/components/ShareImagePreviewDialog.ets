import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';

export interface ShareImagePreviewImage {
  uri: string;
  aspectRatio: number;
  width: number;
  height: number;
  theme: string;
  scaled: boolean;
}

@CustomDialog
export struct ShareImagePreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  @Prop widthVp: number = 0;
  @Prop initialError: string = '';
  image: ShareImagePreviewImage = { uri: '', aspectRatio: 1, width: 0, height: 0, theme: 'light', scaled: false };
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  onRetry: () => Promise<void> = async (): Promise<void> => {};
  onCancel: () => void = () => {};
  onChangeSettings: () => void = () => {};
  @State sharing: boolean = false;
  @State retrying: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.errorMessage = this.initialError;
  }

  private back(): void {
    this.controller?.close();
    this.onCancel();
  }

  private changeSettings(): void {
    this.controller?.close();
    this.onChangeSettings();
  }

  private async retry(): Promise<void> {
    if (this.retrying) {
      return;
    }
    this.retrying = true;
    this.errorMessage = '';
    try {
      await this.onRetry();
    } catch (error) {
      this.errorMessage = shareFailureMessage(error, 'image_prepare');
    } finally {
      this.retrying = false;
    }
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
      this.errorMessage = shareFailureMessage(error, 'handoff');
    } finally {
      this.sharing = false;
    }
  }

  build() {
    Column({ space: Space.s3 }) {
      Row({ space: Space.s3 }) {
        Row() {
          Icon('image', Space.s5, $r('app.color.brand'))
        }
        .width(Space.s10)
        .height(Space.s10)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.brand_bg'))
        Column({ space: Space.s1 }) {
          Text('长图分享')
            .fontSize(FontSize.s3)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.itemName)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('×')
          .fontSize(FontSize.s1)
          .fontColor($r('app.color.text_secondary'))
          .width(Size.touch)
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .accessibilityText('关闭长图预览')
          .focusable(true)
          .onClick(() => { this.back(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Row({ space: Space.s3 }) {
        Column({ space: Space.s1 }) {
          Text('图片宽度 · 跟随当前栏' +
            (this.widthVp > 0 ? ' · ' + Math.round(this.widthVp).toString() + ' vp' : ''))
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_primary'))
          Text('图片外观 · ' + (this.image.theme === 'dark' ? '深色' : '浅色'))
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('更改')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.buttonH)
          .textAlign(TextAlign.Center)
          .accessibilityText('更改长图设置')
          .onClick(() => { this.changeSettings(); })
      }
      .width('100%')
      Text('1 张长图 · ' + this.image.width.toString() + ' × ' + this.image.height.toString() + ' px · ' +
        (this.image.theme === 'dark' ? '深色' : '浅色'))
        .visibility(this.image.uri.length > 0 ? Visibility.Visible : Visibility.None)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.image.scaled) {
        Text('为满足图片预算，长图已整体缩小至 ' + this.image.width.toString() + ' px 宽')
          .visibility(this.image.uri.length > 0 ? Visibility.Visible : Visibility.None)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      if (this.image.uri.length > 0) {
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
        .constraintSize({ maxHeight: this.windowHeightVp > 0
          ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s8 * 7 - Space.s4))
          : Size.menuMaxH })
        .scrollBar(BarState.Off)
      } else {
        Text('长图预览将在生成后显示。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      if (this.errorMessage.length > 0) {
        Button('改用 Markdown / ZIP')
          .height(Size.buttonH)
          .fontSize(FontSize.body2)
          .onClick(() => { this.back(); })
      }
      Row({ space: Space.s2 }) {
        Button('返回')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.back(); })
        Button(this.image.uri.length > 0
          ? (this.sharing ? '正在打开…' : '分享图片')
          : (this.retrying ? '正在生成…' : '重试生成'))
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          // v1.32 32.12：主按钮禁用态中性化——--line 底、--muted 字、不透明
          .fontColor(this.sharing || this.retrying
            ? $r('app.color.text_tertiary') : $r('app.color.on_brand'))
          .backgroundColor(this.sharing || this.retrying
            ? $r('app.color.line') : $r('app.color.brand'))
          .enabled(!this.sharing && !this.retrying)
          .onClick(() => {
            if (this.image.uri.length > 0) {
              void this.share();
            } else {
              void this.retry();
            }
          })
      }
      .width('100%')
    }
    .width(this.windowWidthVp > 0
      ? Math.max(0, Math.min(Size.shareW, this.windowWidthVp - Space.s8))
      : Size.shareW)
    .constraintSize({ maxHeight: this.windowHeightVp > 0
      ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s8 * 2))
      : Size.menuMaxH })
    .padding(Space.s5)
    .borderRadius(this.singleScreen
      ? { topLeft: Radius.dialog, topRight: Radius.dialog, bottomLeft: 0, bottomRight: 0 }
      : Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}
