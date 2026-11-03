import { FontSize, Radius, Size, Space } from '../common/Tokens';

@CustomDialog
export struct ShareImageSettingsDialog {
  controller?: CustomDialogController;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  @Prop initialTheme: string = 'light';
  onConfirm: (theme: string) => void = (_theme: string) => {};
  onCancel: () => void = () => {};
  @State theme: string = 'light';

  aboutToAppear(): void {
    this.theme = this.initialTheme === 'dark' ? 'dark' : 'light';
  }

  private selectTheme(theme: string): void {
    if (theme === 'light' || theme === 'dark') {
      this.theme = theme;
    }
  }

  private cancel(): void {
    this.controller?.close();
    this.onCancel();
  }

  private confirm(): void {
    const theme: string = this.theme;
    this.controller?.close();
    this.onConfirm(theme);
  }

  @Builder
  ThemeOption(theme: string, label: string) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontColor(this.theme === theme ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Size.buttonH)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .accessibilityText(label + (this.theme === theme ? '，已选中' : ''))
      .onClick(() => { this.selectTheme(theme); })
      .borderRadius(Radius.full)
      .backgroundColor(this.theme === theme ? $r('app.color.bg_card') : Color.Transparent)
  }

  build() {
    Column({ space: Space.s4 }) {
      Column({ space: Space.s1 }) {
        Text('长图设置')
          .fontSize(FontSize.s3)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('图片外观')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row({ space: Space.s1 }) {
        this.ThemeOption('light', '浅色')
        this.ThemeOption('dark', '深色')
      }
      .width('100%')
      .padding(Space.s1)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_secondary'))

      Text('只影响本次生成的长图，不改变应用主题。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: Space.s2 }) {
        Button('取消')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.cancel(); })
        Button('生成预览')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .onClick(() => { this.confirm(); })
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
    .alignItems(HorizontalAlign.Start)
  }
}
