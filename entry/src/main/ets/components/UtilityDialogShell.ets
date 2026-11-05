import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { Icon } from '../common/Icons';

@Component
export struct UtilityDialogShell {
  title: string = '';
  subtitle: string = '';
  headerIcon: string = '';
  closeLabel: string = '关闭弹窗';
  singleScreen: boolean = false;
  scrollContent: boolean = true;
  preferredWidthVp: number = Size.utilityDialogW;
  windowWidthVp: number = 0;
  windowHeightVp: number = 0;
  onClose: () => void = () => {};
  @BuilderParam content: () => void = this.EmptyContent;
  @BuilderParam footer: () => void = this.EmptyFooter;

  @Builder
  private EmptyContent() {}

  @Builder
  private EmptyFooter() {}

  private dialogWidth(): number {
    if (this.singleScreen) {
      return Math.max(0, this.windowWidthVp);
    }
    return this.windowWidthVp > 0
      ? Math.max(0, Math.min(this.preferredWidthVp, this.windowWidthVp - Space.s8))
      : this.preferredWidthVp;
  }

  private dialogMaxHeight(): number {
    return this.windowHeightVp > 0
      ? this.windowHeightVp * (this.singleScreen ? 0.86 : 0.8)
      : Size.menuMaxH;
  }

  private contentMaxHeight(): number {
    return Math.max(0, this.dialogMaxHeight() - Space.s16 * 3);
  }

  build() {
    Column({ space: Space.s3 }) {
      if (this.singleScreen) {
        Row()
          .width(Space.s10)
          .height(Space.s1)
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.line'))
          .alignSelf(ItemAlign.Center)
      }
      Row({ space: Space.s3 }) {
        if (this.headerIcon.length > 0) {
          Row() {
            Icon(this.headerIcon, Space.s5, $r('app.color.brand'))
          }
          .width(Space.s10)
          .height(Space.s10)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.brand_bg'))
        }
        Column({ space: Space.s1 }) {
          Text(this.title)
            .fontSize(FontSize.s3)
            .fontWeight(600)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('×')
          .width(Space.s10)
          .height(Space.s10)
          .fontSize(FontSize.s1)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.bg_secondary'))
          .accessibilityText(this.closeLabel)
          .focusable(true)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.scrollContent) {
        Scroll() {
          this.content()
        }
        .width('100%')
        .constraintSize({ maxHeight: this.contentMaxHeight() })
        .scrollBar(BarState.Off)
      } else {
        this.content()
      }

      this.footer()
    }
    .width(this.dialogWidth())
    .constraintSize({ maxHeight: this.dialogMaxHeight() })
    .padding({
      left: Space.s5,
      right: Space.s5,
      top: this.singleScreen ? Space.s3 : Space.s5,
      bottom: Space.s5
    })
    .borderRadius(this.singleScreen
      ? { topLeft: Radius.dialog * 2, topRight: Radius.dialog * 2, bottomLeft: 0, bottomRight: 0 }
      : Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .shadow(ShadowStyle.OUTER_DEFAULT_LG)
    .alignItems(HorizontalAlign.Start)
  }
}

@Builder
export function UtilityDialogAction(
  label: string,
  tone: string,
  singleScreen: boolean,
  enabled: boolean,
  onClick: () => void,
  keyboardFocusable: boolean = false
) {
  Text(label)
    .fontSize(FontSize.body1)
    .fontWeight(FontWeight.Medium)
    .fontColor(tone === 'secondary'
      ? $r('app.color.text_primary') : $r('app.color.on_brand'))
    .height(Size.touch)
    .layoutWeight(singleScreen ? 1 : 0)
    .padding({ left: Space.s5, right: Space.s5 })
    .textAlign(TextAlign.Center)
    .borderRadius(Radius.full)
    .backgroundColor(tone === 'secondary'
      ? $r('app.color.bg_secondary')
      : tone === 'danger' ? $r('app.color.danger') : $r('app.color.brand'))
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.45)
    .onClick(onClick)
    .focusable(keyboardFocusable && enabled)
}
