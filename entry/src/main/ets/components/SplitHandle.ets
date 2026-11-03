import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

const SPLIT_KEY_STEP: number = 16;
const SPLIT_KEY_SHIFT_STEP: number = 64;

@Component
export struct SplitHandle {
  @Prop enhanced: boolean = false;
  dragStarted: () => void = () => {};
  dragUpdated: (offsetX: number, altPressed: boolean) => void =
    (offsetX: number, altPressed: boolean) => {};
  dragEnded: () => void = () => {};
  dragCancelled: () => void = () => {};
  keyboardAdjusted: (deltaVp: number) => void = (deltaVp: number) => {};
  keyboardToLimit: (maximum: boolean) => void = (maximum: boolean) => {};
  resetRequested: () => void = () => {};
  @Prop readoutPrimary: string = '';
  @Prop readoutWidths: string = '';
  @Prop readoutStatus: string = '';

  @State lastTapAt: number = -1;
  @State dragging: boolean = false;
  @State hovered: boolean = false;
  @State focused: boolean = false;
  @State feedbackVisible: boolean = false;
  @State feedbackMessage: string = '';

  private feedbackTimer: number = -1;

  private showFeedback(message: string): void {
    if (this.feedbackTimer >= 0) {
      clearTimeout(this.feedbackTimer);
    }
    this.feedbackVisible = true;
    this.feedbackMessage = message;
    this.feedbackTimer = setTimeout((): void => {
      this.feedbackVisible = false;
      this.feedbackMessage = '';
      this.feedbackTimer = -1;
    }, 1100);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(this.enhanced ? Size.splitRailW : 1)
        .height('100%')
        .backgroundColor($r('app.color.line'))
      if (this.enhanced && (this.hovered || this.focused || this.dragging)) {
        Row()
          .width(Size.splitRailW)
          .height('100%')
          .backgroundColor($r('app.color.brand'))
          .opacity(this.dragging || this.focused ? 1 : 0.35)
      }
      Row()
        .width(this.enhanced ? Size.splitGripW : Space.s1)
        .height(this.enhanced ? Size.splitGripH : Size.splitHandleH)
        .borderRadius(Radius.full)
        .border({ width: 1, color: this.dragging || this.hovered || this.focused
          ? $r('app.color.brand') : $r('app.color.line_strong') })
        .backgroundColor(this.dragging ? $r('app.color.brand') : $r('app.color.bg_card'))
      if (this.enhanced) {
        Column({ space: Space.s1 }) {
          Row()
            .width(Size.splitGripDot)
            .height(Size.splitGripDot)
            .borderRadius(Radius.full)
            .backgroundColor(this.dragging ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
          Row()
            .width(Size.splitGripDot)
            .height(Size.splitGripDot)
            .borderRadius(Radius.full)
            .backgroundColor(this.dragging ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
          Row()
            .width(Size.splitGripDot)
            .height(Size.splitGripDot)
            .borderRadius(Radius.full)
            .backgroundColor(this.dragging ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Center)
      }
      if (this.enhanced && (this.dragging || this.feedbackVisible)) {
        Column({ space: Space.s1 }) {
          Text(this.readoutPrimary)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.bg_card'))
          Text(this.readoutWidths)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.bg_card'))
          Text(this.feedbackMessage.length > 0
            ? this.feedbackMessage
            : (this.readoutStatus.length > 0 ? this.readoutStatus : (this.dragging ? '调整中' : '栏宽已保存')))
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.bg_card'))
        }
        .width(Size.paneMinW)
        .height(Size.splitTipH)
        .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.text_primary'))
        .shadow({ radius: Space.s2, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: Space.s1 })
        .align(Alignment.Center)
        .offset({ x: 0, y: -(Size.splitGripH / 2 + Space.s3 + Size.splitTipH / 2) })
        .zIndex(4)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(Space.s4)
    .height('100%')
    .zIndex(this.enhanced ? 4 : 0)
    .responseRegion(this.enhanced
      ? { x: -(Size.splitTouchHitW - Space.s4) / 2, y: 0, width: Size.splitTouchHitW, height: '100%' }
      : { x: 0, y: 0, width: '100%', height: '100%' })
    .mouseResponseRegion(this.enhanced
      ? { x: -(Size.splitMouseHitW - Space.s4) / 2, y: 0, width: Size.splitMouseHitW, height: '100%' }
      : { x: 0, y: 0, width: '100%', height: '100%' })
    .focusable(this.enhanced)
    .tabStop(this.enhanced)
    .onHover((isHover: boolean): void => {
      if (this.enhanced) this.hovered = isHover;
    })
    .onFocus((): void => {
      if (this.enhanced) this.focused = true;
    })
    .onBlur((): void => {
      if (this.enhanced) this.focused = false;
    })
    .accessibilityText(
      '分隔条，当前比例：' + this.readoutPrimary + '，栏宽：' + this.readoutWidths +
      (this.readoutStatus.length > 0 ? '，状态：' + this.readoutStatus : '') +
      '。左右方向键按 16vp 调整，Shift 加方向键按 64vp 调整，Home 到最小宽度，' +
      'End 到最大宽度，Enter 恢复默认，Esc 取消拖动'
    )
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
        .onActionStart((): void => {
          this.dragging = true;
          this.lastTapAt = -1;
          this.feedbackMessage = '';
          if (this.feedbackTimer >= 0) {
            clearTimeout(this.feedbackTimer);
            this.feedbackTimer = -1;
          }
          this.dragStarted();
        })
        .onActionUpdate((event: GestureEvent): void => {
          let altPressed: boolean = false;
          if (event.getModifierKeyState !== undefined) {
            altPressed = event.getModifierKeyState(['Alt']);
          }
          this.dragUpdated(event.offsetX, altPressed);
        })
        .onActionEnd((): void => {
          if (!this.dragging) {
            return;
          }
          this.dragging = false;
          this.dragEnded();
          this.showFeedback('栏宽已保存');
        })
        .onActionCancel((): void => {
          if (!this.dragging) {
            return;
          }
          this.dragging = false;
          if (this.enhanced) {
            this.dragCancelled();
            this.showFeedback('已取消调整');
          } else {
            this.dragEnded();
          }
        })
    )
    .onKeyEvent((event: KeyEvent): boolean => {
      if (!this.enhanced || event.type !== KeyType.Down) {
        return false;
      }
      if (event.keyCode === KeyCode.KEYCODE_ESCAPE && this.dragging) {
        this.dragging = false;
        this.dragCancelled();
        this.showFeedback('已取消调整');
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT ||
        event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
        let shiftPressed: boolean = false;
        if (event.getModifierKeyState !== undefined) {
          shiftPressed = event.getModifierKeyState(['Shift']);
        }
        const step: number = shiftPressed ? SPLIT_KEY_SHIFT_STEP : SPLIT_KEY_STEP;
        this.keyboardAdjusted(event.keyCode === KeyCode.KEYCODE_DPAD_LEFT ? -step : step);
        this.showFeedback('栏宽已调整');
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_MOVE_HOME) {
        this.keyboardToLimit(false);
        this.showFeedback('已调整至最小宽度');
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_MOVE_END) {
        this.keyboardToLimit(true);
        this.showFeedback('已调整至最大宽度');
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_ENTER) {
        this.resetRequested();
        this.showFeedback('已恢复默认比例');
        return true;
      }
      return false;
    })
    .onClick(() => {
      const now: number = Date.now();
      if (this.lastTapAt >= 0 && now - this.lastTapAt <= 320) {
        this.lastTapAt = -1;
        this.resetRequested();
        this.showFeedback('已恢复默认比例');
      } else {
        this.lastTapAt = now;
      }
    })
  }
}
