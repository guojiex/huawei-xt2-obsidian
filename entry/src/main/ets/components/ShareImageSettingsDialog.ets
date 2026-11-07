import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

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

  @Builder
  DialogContent() {
    Column({ space: Space.s3 }) {
      Column({ space: Space.s1 }) {
        Text('图片宽度')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
        Row() {
          Text('跟随当前栏')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text('排版宽度沿用当前笔记栏，随窗口形态和分栏宽度变化。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: Space.s1 }) {
        Text('图片外观')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
        Row({ space: Space.s1 }) {
          this.ThemeOption('light', '浅色')
          this.ThemeOption('dark', '深色')
        }
        .width('100%')
        .padding(Space.s1)
        .borderRadius(Radius.full)
        .backgroundColor($r('app.color.bg_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Text('只影响本次生成的长图，不改变应用主题。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s3 }) {
      UtilityDialogAction('取消', 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.cancel();
        }, true)
      UtilityDialogAction('生成预览', 'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.confirm();
        }, true)
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '长图设置',
      subtitle: '只影响本次生成的长图',
      headerIcon: 'image',
      closeLabel: '关闭长图设置',
      singleScreen: this.singleScreen,
      scrollContent: false,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => {
        this.cancel();
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
