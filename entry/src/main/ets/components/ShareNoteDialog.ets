import { ShareLinkScope } from '../model/ShareLinkService';
import { Icon } from '../common/Icons';
import { FontSize, Motion, Radius, Size, Space } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { UtilityDialogShell } from './UtilityDialogShell';

export interface ShareFormatOption {
  value: string;
  label: string;
  detail: string;
  icon: string;
}

export interface ShareScopeOption {
  scope: ShareLinkScope;
  path: string;
  label: string;
  title: string;
  itemName: string;
  description: string;
  summary: string;
  notice: string;
  available: boolean;
  options: ShareFormatOption[];
}

@CustomDialog
export struct ShareNoteDialog {
  controller?: CustomDialogController;
  @Prop scopeOptions: ShareScopeOption[] = [];
  @Prop initialScope: ShareLinkScope = 'note';
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  onConfirm: (scope: ShareLinkScope, path: string, format: string, itemName: string) => void =
    (scope: ShareLinkScope, path: string, format: string, itemName: string) => {};
  onDismiss: () => void = () => {};
  @State selectedScope: ShareLinkScope = 'note';

  aboutToAppear(): void {
    this.selectedScope = this.initialScope;
  }

  private currentOption(): ShareScopeOption {
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      if (this.scopeOptions[i].scope === this.selectedScope && this.scopeOptions[i].available) {
        return this.scopeOptions[i];
      }
    }
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      if (this.scopeOptions[i].available) {
        return this.scopeOptions[i];
      }
    }
    return this.scopeOptions[0];
  }

  private selectScope(scope: ShareLinkScope): void {
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      if (this.scopeOptions[i].scope === scope && this.scopeOptions[i].available) {
        if (this.selectedScope !== scope) {
          this.getUIContext().animateTo({ duration: 200, curve: Motion.navCurve }, (): void => {
            this.selectedScope = scope;
          });
        }
        return;
      }
    }
  }

  private scopeFormatAreaHeight(): number {
    let maxRows: number = 0;
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      if (this.scopeOptions[i].options.length > maxRows) {
        maxRows = this.scopeOptions[i].options.length;
      }
    }
    if (maxRows === 0) {
      return 0;
    }
    const rowHeight: number = this.scopeFormatRowHeight();
    return maxRows * rowHeight + (maxRows - 1) * Space.s2;
  }

  private scopeFormatRowHeight(): number {
    return Space.s16 + Space.s2 + Space.s3;
  }

  private onDialogKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ESCAPE) {
      return false;
    }
    this.dismiss();
    event.stopPropagation();
    return true;
  }

  private dismiss(): void {
    this.controller?.close();
    this.onDismiss();
  }

  private onScopeKey(scope: ShareLinkScope, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      return this.onDialogKey(event);
    }
    let direction: number = 0;
    if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT || event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      direction = -1;
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT || event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      direction = 1;
    } else {
      return false;
    }
    let index: number = 0;
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      if (this.scopeOptions[i].scope === scope) {
        index = i;
        break;
      }
    }
    for (let i: number = 0; i < this.scopeOptions.length; i++) {
      index = (index + direction + this.scopeOptions.length) % this.scopeOptions.length;
      if (this.scopeOptions[index].available) {
        this.selectScope(this.scopeOptions[index].scope);
        return true;
      }
    }
    return true;
  }

  private chooseFormat(scope: ShareScopeOption, format: ShareFormatOption): void {
    const selectedScope: ShareLinkScope = scope.scope;
    const selectedPath: string = scope.path;
    const selectedName: string = scope.itemName;
    const selectedFormat: string = format.value;
    this.controller?.close();
    this.onConfirm(selectedScope, selectedPath, selectedFormat, selectedName);
  }

  @Builder
  ScopeTab(option: ShareScopeOption) {
    Text(option.label)
      .fontSize(FontSize.body2)
      .fontWeight(this.selectedScope === option.scope ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selectedScope === option.scope
        ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Size.buttonH)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .focusable(option.available)
      .opacity(option.available ? 1 : 0.4)
      .accessibilityText(option.label + (this.selectedScope === option.scope ? '，已选中' : ''))
      .onKeyEvent((event: KeyEvent): boolean => { return this.onScopeKey(option.scope, event); })
      .onClick(() => { this.selectScope(option.scope); })
      .borderRadius(Radius.full)
      .backgroundColor(this.selectedScope === option.scope
        ? $r('app.color.bg_card') : Color.Transparent)
  }

  @Builder
  FormatRow(scope: ShareScopeOption, option: ShareFormatOption) {
    Row({ space: Space.s3 }) {
      Row() {
        Icon(option.icon, Space.s5, $r('app.color.brand'))
      }
      .width(Space.s10)
      .height(Space.s10)
      .justifyContent(FlexAlign.Center)
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.brand_bg'))
      Column({ space: Space.s1 }) {
        Text(option.label)
          .fontSize(FontSize.body1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(option.detail)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Icon('chevronRight', Space.s5, $r('app.color.text_tertiary'))
    }
    .width('100%')
    .constraintSize({ minHeight: Space.s16 + Space.s2 })
    .padding({ left: Space.s4, right: Space.s3, top: Space.s3, bottom: Space.s3 })
    .height(this.scopeFormatRowHeight())
    .borderRadius(Radius.menu)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: Space.s2 })),
      TransitionEffect.IDENTITY))
    .accessibilityText(option.label + '，' + option.detail)
    .focusable(true)
    .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
    .onClick(() => { this.chooseFormat(scope, option); })
  }

  @Builder
  DialogContent() {
      Scroll() {
        Column({ space: Space.s4 }) {
          if (this.scopeOptions.length > 1) {
            Row({ space: Space.s1 }) {
              ForEach(this.scopeOptions, (option: ShareScopeOption) => {
                this.ScopeTab(option)
              }, (option: ShareScopeOption) => option.scope)
            }
            .width('100%')
            .padding(Space.s1)
            .borderRadius(Radius.full)
            .backgroundColor($r('app.color.bg_secondary'))
          }

          Text(this.currentOption().description)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .height(FontSize.caption * 3)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Column({ space: Space.s2 }) {
            ForEach(this.currentOption().options, (option: ShareFormatOption) => {
              this.FormatRow(this.currentOption(), option)
            }, (option: ShareFormatOption) => option.value)
          }
          .width('100%')
          .height(this.scopeFormatAreaHeight())
          .alignItems(HorizontalAlign.Start)

          Text(this.currentOption().notice)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .height(FontSize.caption * 3)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .visibility(this.currentOption().notice.length > 0 ? Visibility.Visible : Visibility.Hidden)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.windowHeightVp > 0
        ? Math.max(0, Math.min(Size.menuMaxH, this.windowHeightVp - Space.s8 * 4))
        : Size.menuMaxH })
      .scrollBar(BarState.Off)
  }

  build() {
    UtilityDialogShell({
      title: this.currentOption().title,
      subtitle: this.currentOption().itemName + ' · ' + this.currentOption().summary,
      headerIcon: 'share',
      closeLabel: '关闭分享',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      scrollContent: false,
      onClose: (): void => { this.dismiss(); },
      content: (): void => { this.DialogContent(); }
    })
  }
}
