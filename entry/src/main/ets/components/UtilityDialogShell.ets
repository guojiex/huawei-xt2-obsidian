import { Binding } from '@kit.ArkUI';
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
  fillContentHeight: boolean = false;
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
    if (this.windowHeightVp <= 0) {
      return Size.menuMaxH;
    }
    if (this.singleScreen) {
      return this.windowHeightVp * 0.86;
    }
    // 32.13：宽屏弹窗限定在应用窗口内 —— 上下边距各 ≥ s8，超出部分在弹窗内滚动。
    return Math.max(0, this.windowHeightVp - Space.s8 * 2);
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

      if (this.fillContentHeight) {
        Column() {
          this.content()
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.scrollContent) {
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
    .constraintSize({
      minHeight: this.fillContentHeight ? this.dialogMaxHeight() : 0,
      maxHeight: this.dialogMaxHeight()
    })
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
  // 2026-11-07 EM-B2 回归修复：全局 @Builder 多参按值传参不触发动态渲染（官方 arkts-builder
  // 限制 3），7e40407 lambda 化后 footer 里 enabled 不再随弹窗状态刷新、创建按钮永远禁用。
  // 改按回调传递（UIUtils.makeBinding，API 20+）——官方文档指定的多参全局 @Builder 状态刷新方式。
  enabled: Binding<boolean>,
  onClick: () => void,
  keyboardFocusable: boolean = false
) {
  Text(label)
    .fontSize(FontSize.body1)
    .fontWeight(FontWeight.Medium)
    // v1.32 32.12：主 / 危险操作禁用态中性化——--line 底、--muted 字、不透明
    //（半透明蓝在深色下像可点）；次要操作禁用沿用 45% 不透明度（原型 utility-actions 规则）
    .fontColor(!enabled.value && tone !== 'secondary'
      ? $r('app.color.text_tertiary')
      : tone === 'secondary' ? $r('app.color.text_primary') : $r('app.color.on_brand'))
    .height(Size.touch)
    .layoutWeight(singleScreen ? 1 : 0)
    .padding({ left: Space.s5, right: Space.s5 })
    .textAlign(TextAlign.Center)
    .borderRadius(Radius.full)
    .backgroundColor(!enabled.value && tone !== 'secondary'
      ? $r('app.color.line')
      : tone === 'secondary'
        ? $r('app.color.bg_secondary')
        : tone === 'danger' ? $r('app.color.danger') : $r('app.color.brand'))
    .enabled(enabled.value)
    .opacity(!enabled.value && tone === 'secondary' ? 0.45 : 1)
    .onClick(onClick)
    .focusable(keyboardFocusable && enabled.value)
}
