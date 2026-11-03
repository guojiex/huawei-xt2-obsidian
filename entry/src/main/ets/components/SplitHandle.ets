import { Radius, Size, Space } from '../common/Tokens';

@Component
export struct SplitHandle {
  @Prop enhanced: boolean = false;
  dragStarted: () => void = () => {};
  dragUpdated: (offsetX: number) => void = (offsetX: number) => {};
  dragEnded: () => void = () => {};
  resetRequested: () => void = () => {};

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
    .accessibilityText('拖动调整分栏宽度，双击恢复默认')
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
        .onActionStart((): void => {
          this.dragging = true;
          this.dragStarted();
        })
        .onActionUpdate((event: GestureEvent): void => { this.dragUpdated(event.offsetX); })
        .onActionEnd((): void => {
          this.dragging = false;
          this.dragEnded();
        })
        .onActionCancel((): void => {
          this.dragging = false;
          this.dragEnded();
        })
    )
    .onClick(() => {
      const now: number = Date.now();
      if (this.lastTapAt >= 0 && now - this.lastTapAt <= 350) {
        this.lastTapAt = -1;
        this.resetRequested();
      } else {
        this.lastTapAt = now;
      }
    })
  }
}
