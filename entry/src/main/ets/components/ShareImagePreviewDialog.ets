import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { ShareImageWidthOption, ShareImageWidthPresets } from './ShareImageSettingsDialog';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

export interface ShareImagePreviewImage {
  uri: string;
  aspectRatio: number;
  width: number;
  height: number;
  theme: string;
  scaled: boolean;
  widthId: string;
}

@CustomDialog
export struct ShareImagePreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  @Prop widthVp: number = 0;
  @Prop paneWidthVp: number = 0;
  @Prop initialWidthId: string = 'phone';
  @Prop initialTheme: string = 'light';
  @Prop initialError: string = '';
  image: ShareImagePreviewImage = { uri: '', aspectRatio: 1, width: 0, height: 0, theme: 'light', scaled: false, widthId: 'phone' };
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  onGenerate: (widthId: string, theme: string) => void = (_widthId: string, _theme: string): void => {};
  onCancel: () => void = () => {};
  @State sharing: boolean = false;
  @State selectedWidthId: string = 'phone';
  @State selectedTheme: string = 'light';
  @State settingsChanged: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.errorMessage = this.initialError;
    this.selectedWidthId = this.initialWidthId;
    this.selectedTheme = this.initialTheme === 'dark' ? 'dark' : 'light';
    this.settingsChanged = this.image.uri.length > 0 &&
      (this.selectedWidthId !== this.image.widthId || this.selectedTheme !== this.image.theme);
  }

  private back(): void {
    this.controller?.close();
    this.onCancel();
  }

  private selectWidth(id: string): void {
    this.selectedWidthId = id;
    this.refreshSettingsChanged();
  }

  private selectTheme(theme: string): void {
    if (theme === 'light' || theme === 'dark') {
      this.selectedTheme = theme;
      this.refreshSettingsChanged();
    }
  }

  private refreshSettingsChanged(): void {
    this.settingsChanged = this.image.uri.length === 0 ||
      this.selectedWidthId !== this.image.widthId || this.selectedTheme !== this.image.theme;
  }

  private widthSummary(): string {
    const option: ShareImageWidthOption = ShareImageWidthPresets.findById(this.selectedWidthId);
    const widthVp: number = option.layoutVp > 0 ? option.layoutVp :
      (this.paneWidthVp > 0 ? this.paneWidthVp : this.widthVp);
    return option.label + (widthVp > 0 ? ' · ' + Math.round(widthVp).toString() + ' vp' : '');
  }

  private canSharePreview(): boolean {
    return this.image.uri.length > 0 && !this.settingsChanged;
  }

  private generatePreview(): void {
    if (this.sharing) {
      return;
    }
    this.errorMessage = '';
    const widthId: string = this.selectedWidthId;
    const theme: string = this.selectedTheme;
    this.controller?.close();
    this.onGenerate(widthId, theme);
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
  WidthOption(opt: ShareImageWidthOption) {
    Text(opt.label)
      .fontSize(FontSize.caption)
      .fontColor(this.selectedWidthId === opt.id ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Space.s8)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .accessibilityText(opt.label + (this.selectedWidthId === opt.id ? '，已选中' : ''))
      .onClick(() => { this.selectWidth(opt.id); })
      .borderRadius(Radius.full)
      .backgroundColor(this.selectedWidthId === opt.id ? $r('app.color.bg_card') : Color.Transparent)
  }

  @Builder
  ThemeOption(theme: string, label: string) {
    Text(label)
      .fontSize(FontSize.caption)
      .fontColor(this.selectedTheme === theme ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Space.s8)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .accessibilityText(label + (this.selectedTheme === theme ? '，已选中' : ''))
      .onClick(() => { this.selectTheme(theme); })
      .borderRadius(Radius.full)
      .backgroundColor(this.selectedTheme === theme ? $r('app.color.bg_card') : Color.Transparent)
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s2 }) {
      Row({ space: Space.s2 }) {
        Text('宽度')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width(Space.s10)
        Row({ space: Space.s1 }) {
          this.WidthOption(ShareImageWidthPresets.PHONE)
          this.WidthOption(ShareImageWidthPresets.WIDE)
          this.WidthOption(ShareImageWidthPresets.PANE)
        }
        .layoutWeight(1)
        .padding(Space.s1)
        .borderRadius(Radius.full)
        .backgroundColor($r('app.color.bg_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: Space.s2 }) {
        Text('外观')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width(Space.s10)
        Row({ space: Space.s1 }) {
          this.ThemeOption('light', '浅色')
          this.ThemeOption('dark', '深色')
        }
        .layoutWeight(1)
        .padding(Space.s1)
        .borderRadius(Radius.full)
        .backgroundColor($r('app.color.bg_secondary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

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
          }

          if (this.image.scaled) {
            Text('为满足图片预算，长图已整体缩小至 ' + this.image.width.toString() + ' px 宽')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
        }
        .width('100%')
      }

      Scroll() {
        if (this.image.uri.length > 0) {
          Image(this.image.uri)
            .width('100%')
            .aspectRatio(this.image.aspectRatio)
            .objectFit(ImageFit.Contain)
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.bg_card'))
        } else {
          Text('选择图片宽度和外观后，生成长图预览。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: Space.s6, bottom: Space.s6 })
        }
      }
      .width('100%')
      .padding(Space.s3)
      .borderRadius(Radius.menu)
      .backgroundColor($r('app.color.bg_secondary'))
      .scrollBar(BarState.Off)
      .align(Alignment.Center)
      .layoutWeight(1)
      .constraintSize({ minHeight: 0 })

      if (this.settingsChanged && this.image.uri.length > 0) {
        Text('设置已更改，重新生成后可预览')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
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
    .height('100%')
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
        this.canSharePreview() ? (this.sharing ? '正在打开…' : '分享图片') :
          (this.image.uri.length > 0 ? '重新生成预览' : '生成预览'),
        'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => !this.sharing),
        (): void => {
          if (this.canSharePreview()) {
            void this.share();
          } else {
            this.generatePreview();
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

  private dialogMaxHeight(): number {
    if (this.windowHeightVp <= 0) {
      return Size.menuMaxH;
    }
    if (this.singleScreen) {
      return this.windowHeightVp * 0.86;
    }
    return Math.max(0, this.windowHeightVp - Space.s8 * 2);
  }

}
