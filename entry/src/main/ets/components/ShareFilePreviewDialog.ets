import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

@CustomDialog
export struct ShareFilePreviewDialog {
  controller?: CustomDialogController;
  @Prop fileName: string = '';
  @Prop format: string = '';
  @Prop summary: string = '';
  @Prop entries: string[] = [];
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  onBack: () => void = () => {};
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  @State sharing: boolean = false;
  @State errorMessage: string = '';

  private entryIcon(path: string): string {
    const lower: string = path.toLowerCase();
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') || lower.endsWith('.gif') || lower.endsWith('.svg')) {
      return 'image';
    }
    return 'doc';
  }

  private onDialogKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ESCAPE) {
      return false;
    }
    this.back();
    event.stopPropagation();
    return true;
  }

  private back(): void {
    this.controller?.close();
    this.onBack();
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
      const err = error as Error;
      this.errorMessage = err.message.length > 0 ? err.message : '系统分享面板无法打开，请重试';
    } finally {
      this.sharing = false;
    }
  }

  @Builder
  FileRow(path: string) {
    Row({ space: Space.s3 }) {
      Icon(this.entryIcon(path), Space.s5, $r('app.color.text_secondary'))
      Text(path)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minHeight: Size.itemH })
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
    .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
  }

  build() {
    Column({ space: Space.s3 }) {
      Row({ space: Space.s3 }) {
        Icon('doc', Space.s5, $r('app.color.brand'))
        Column({ space: Space.s1 }) {
          Text('文件分享')
            .fontSize(FontSize.s3)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.fileName)
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
          .accessibilityText('关闭文件预览')
          .focusable(true)
          .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
          .onClick(() => { this.controller?.close(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.format + ' · ' + this.summary)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Text('文件清单')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Scroll() {
        Column() {
          ForEach(this.entries, (path: string) => {
            this.FileRow(path)
          }, (path: string) => path)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.windowHeightVp > 0
        ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s8 * 7 - Space.s4))
        : Size.menuMaxH })
      .scrollBar(BarState.Off)
      .border({ width: 1, color: $r('app.color.line') })
      .borderRadius(Radius.menu)
      .backgroundColor($r('app.color.bg_secondary'))

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }

      Row({ space: Space.s2 }) {
        Text('返回')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .height(Size.buttonH)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .focusable(true)
          .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
          .onClick(() => { this.back(); })
        Text(this.sharing ? '正在打开…' : '分享文件')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_brand'))
          .height(Size.buttonH)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.brand'))
          .focusable(true)
          .enabled(!this.sharing)
          .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
          .onClick(() => { void this.share(); })
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
