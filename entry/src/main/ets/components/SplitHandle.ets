import { Radius, Space } from '../common/Tokens';

@Component
export struct SplitHandle {
  dragStarted: () => void = () => {};
  dragUpdated: (offsetX: number) => void = (offsetX: number) => {};
  dragEnded: () => void = () => {};
  resetRequested: () => void = () => {};

  @State lastTapAt: number = -1;

  build() {
    Column() {
      Row()
        .width(1)
        .height('100%')
        .backgroundColor($r('app.color.line'))
    }
    .width(Space.s4)
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .borderRadius(Radius.control)
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
        .onActionStart((): void => { this.dragStarted(); })
        .onActionUpdate((event: GestureEvent): void => { this.dragUpdated(event.offsetX); })
        .onActionEnd((): void => { this.dragEnded(); })
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
