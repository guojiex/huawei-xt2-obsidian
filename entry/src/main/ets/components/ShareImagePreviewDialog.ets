import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

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

  @Builder
  DialogContent() {
    Column({ space: Space.s3 }) {
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

      if (this.image.uri.length > 0) {
        Column({ space: Space.s1 }) {
          Row({ space: Space.s3 }) {
            Text('1 张长图')
              .fontSize(FontSize.caption)
              .fontWeight(600)
              .fontColor($r('app.color.text_primary'))
            Text(this.image.width.toString() + ' × ' + this.image.height.toString() + ' px')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
            Text(this.image.theme === 'dark' ? '深色' : '浅色')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
          }

          if (this.image.scaled) {
            Text('为满足图片预算，长图已整体缩小至 ' + this.image.width.toString() + ' px 宽')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .width('100%')

        Scroll() {
          Image(this.image.uri)
            .width('100%')
            .aspectRatio(this.image.aspectRatio)
            .objectFit(ImageFit.Contain)
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.bg_card'))
        }
        .width('100%')
        .constraintSize({ maxHeight: this.stageMaxHeight() })
        .padding(Space.s4)
        .borderRadius(Radius.menu)
        .backgroundColor($r('app.color.bg_secondary'))
        .scrollBar(BarState.Off)
        .align(Alignment.Center)
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
        Button('改用 Markdown / ZIP')
          .height(Size.buttonH)
          .fontSize(FontSize.body2)
          .onClick(() => { this.back(); })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s3 }) {
      UtilityDialogAction('返回', 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.back();
        }, true)
      UtilityDialogAction(
        this.image.uri.length > 0
          ? (this.sharing ? '正在打开…' : '分享图片')
          : (this.retrying ? '正在生成…' : '重试生成'),
        'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => !this.sharing && !this.retrying),
        (): void => {
          if (this.image.uri.length > 0) {
            void this.share();
          } else {
            void this.retry();
          }
        }, true)
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '长图分享',
      subtitle: this.itemName,
      headerIcon: 'image',
      closeLabel: '关闭长图预览',
      singleScreen: this.singleScreen,
      scrollContent: false,
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

  private dialogMaxHeight(): number {
    if (this.windowHeightVp <= 0) {
      return Size.menuMaxH;
    }
    if (this.singleScreen) {
      return this.windowHeightVp * 0.86;
    }
    return Math.max(0, this.windowHeightVp - Space.s8 * 2);
  }

  private stageMaxHeight(): number {
    return Math.max(0, this.dialogMaxHeight() - Space.s16 * 7);
  }
}
