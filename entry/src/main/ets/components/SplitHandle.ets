import { Radius, Size, Space } from '../common/Tokens';

@Component
export struct SplitHandle {
  dragStarted: () => void = () => {};
  dragUpdated: (offsetX: number) => void = (offsetX: number) => {};
  dragEnded: () => void = () => {};
  resetRequested: () => void = () => {};

  @State lastTapAt: number = -1;
  @State dragging: boolean = false;

  build() {
    Stack() {
      Row()
        .width(1)
        .height('100%')
        .backgroundColor($r('app.color.line'))
      // 把手胶囊：v2 原型 `.split-control>span`（宽 --s1、高 --split-height、胶囊圆角，
      // 拖动时变主色）。只有 1px 线的话用户看不出这里可以拖。
      Row()
        .width(Space.s1)
        .height(Size.splitHandleH)
        .borderRadius(Radius.full)
        .backgroundColor(this.dragging ? $r('app.color.brand') : $r('app.color.line'))
    }
    .width(Space.s4)
    .height('100%')
    .alignContent(Alignment.Center)
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
