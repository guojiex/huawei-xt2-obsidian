import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

export interface ShareImageWidthOption {
  id: string;
  label: string;
  hint: string;
  layoutVp: number;
  pixelRatio: number;
}

export class ShareImageWidthPresets {
  static readonly PHONE: ShareImageWidthOption = {
    id: 'phone', label: '手机', hint: '适合在聊天中查看',
    layoutVp: 360, pixelRatio: 3
  };
  static readonly WIDE: ShareImageWidthOption = {
    id: 'wide', label: '宽版', hint: '表格与代码不易换行，适合电脑查看',
    layoutVp: 720, pixelRatio: 2
  };
  static readonly PANE: ShareImageWidthOption = {
    id: 'pane', label: '跟随当前栏', hint: '与当前栏看到的一致，单屏与双屏结果不同',
    layoutVp: 0, pixelRatio: 3
  };
  static readonly ALL: ShareImageWidthOption[] = [
    ShareImageWidthPresets.PHONE,
    ShareImageWidthPresets.WIDE,
    ShareImageWidthPresets.PANE
  ];
  static findById(id: string): ShareImageWidthOption {
    for (const opt of ShareImageWidthPresets.ALL) {
      if (opt.id === id) {
        return opt;
      }
    }
    return ShareImageWidthPresets.PHONE;
  }
  static outputPxWidth(option: ShareImageWidthOption, paneWidthVp: number): number {
    const vp: number = option.layoutVp > 0 ? option.layoutVp : paneWidthVp;
    return Math.round(vp * option.pixelRatio);
  }
  static hintWithPx(option: ShareImageWidthOption, paneWidthVp: number): string {
    const px: number = ShareImageWidthPresets.outputPxWidth(option, paneWidthVp);
    return option.hint + ' · ' + px.toLocaleString() + ' px 宽';
  }
}

@CustomDialog
export struct ShareImageSettingsDialog {
  controller?: CustomDialogController;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  @Prop initialTheme: string = 'light';
  @Prop initialWidthId: string = 'phone';
  @Prop paneWidthVp: number = 0;
  onConfirm: (widthId: string, theme: string) => void = (_widthId: string, _theme: string) => {};
  onCancel: () => void = () => {};
  @State theme: string = 'light';
  @State widthId: string = 'phone';

  aboutToAppear(): void {
    this.theme = this.initialTheme === 'dark' ? 'dark' : 'light';
    this.widthId = this.initialWidthId;
  }

  private selectTheme(theme: string): void {
    if (theme === 'light' || theme === 'dark') {
      this.theme = theme;
    }
  }

  private selectWidth(id: string): void {
    this.widthId = id;
  }

  private cancel(): void {
    this.controller?.close();
    this.onCancel();
  }

  private confirm(): void {
    const widthId: string = this.widthId;
    const theme: string = this.theme;
    this.controller?.close();
    this.onConfirm(widthId, theme);
  }

  private widthHintText(): string {
    const option: ShareImageWidthOption = ShareImageWidthPresets.findById(this.widthId);
    return ShareImageWidthPresets.hintWithPx(option, this.paneWidthVp);
  }

  @Builder
  WidthOption(opt: ShareImageWidthOption) {
    Text(opt.label)
      .fontSize(FontSize.body2)
      .fontColor(this.widthId === opt.id ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Size.buttonH)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .accessibilityText(opt.label + (this.widthId === opt.id ? '，已选中' : ''))
      .onClick(() => { this.selectWidth(opt.id); })
      .borderRadius(Radius.full)
      .backgroundColor(this.widthId === opt.id ? $r('app.color.bg_card') : Color.Transparent)
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
        Row() {
          Text('图片宽度')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.widthHintText())
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        Row({ space: Space.s1 }) {
          this.WidthOption(ShareImageWidthPresets.PHONE)
          this.WidthOption(ShareImageWidthPresets.WIDE)
          this.WidthOption(ShareImageWidthPresets.PANE)
        }
        .width('100%')
        .padding(Space.s1)
        .borderRadius(Radius.full)
        .backgroundColor($r('app.color.bg_secondary'))
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
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '取消'), 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.cancel();
        }, true)
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '生成预览'), 'primary', this.singleScreen,
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
