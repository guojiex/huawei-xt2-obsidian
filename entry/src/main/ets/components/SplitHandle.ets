import { Radius, Size, Space } from '../common/Tokens';
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
    }
    .width(Space.s4)
    .height('100%')
    .clip(true)
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
        })
        .onActionCancel((): void => {
          if (!this.dragging) {
            return;
          }
          this.dragging = false;
          if (this.enhanced) {
            this.dragCancelled();
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
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_MOVE_HOME) {
        this.keyboardToLimit(false);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_MOVE_END) {
        this.keyboardToLimit(true);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_ENTER) {
        this.resetRequested();
        return true;
      }
      return false;
    })
    .onClick(() => {
      const now: number = Date.now();
      if (this.lastTapAt >= 0 && now - this.lastTapAt <= 320) {
        this.lastTapAt = -1;
        this.resetRequested();
      } else {
        this.lastTapAt = now;
      }
    })
  }
}
