/**
 * PreviewBlockToolbarAnchor —— 预览块上下文工具条的锚点挂载（Blank 锚位 + bindPopup 工具条）。
 * 从 Index.ets 拆出（Phase 3 重构）：工具条视图（TableToolbarAction / BlockToolbarContent）
 * 迁入本组件；打开状态与几何布局由 Index 持有，经 @Prop 快照下行、经回调上行。
 * 可见性门控（hasBlockToolbarForPane）留在 Index 的薄包装里。
 */
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';

export interface BlockToolbarAction {
  id: string;
  icon: string;
  accessibilityText: string;
  onActivate: () => void;
}

@Component
export struct PreviewBlockToolbarAnchor {
  /** 本实例挂在哪一侧（left/right） */
  pane: string = 'left';
  /** 注册的块工具条动作（由 Index 持有；空数组 = 仅表格锚点工具条） */
  blockToolbarActions: BlockToolbarAction[] = [];
  // ---- 父组件下行（Index 持有真源） ----
  @Prop blockToolbarOpen: boolean = false;
  @Prop blockToolbarPane: string = 'left';
  @Prop blockToolbarPlacement: Placement = Placement.BottomLeft;
  @Prop blockToolbarOffsetX: number = 0;
  @Prop blockToolbarOffsetY: number = Space.s2;
  @Prop blockToolbarWidth: number = 0;
  @Prop blockToolbarMaxHeight: number = 0;
  // ---- 父组件上行回调 ----
  blockToolbarAnchorGeometry: (pane: string) => number[] = (pane: string): number[] => [0, 0, 0, 0];
  closeBlockToolbar: (restoreFocus: boolean) => void = (restoreFocus: boolean): void => {};
  openBlockPropertyPanel: (pane: string) => void = (pane: string): void => {};
  applyTableStructureOperation: (pane: string, type: string, side: string) => void =
    (pane: string, type: string, side: string): void => {};
  tableToolbarForPane: (pane: string) => boolean = (pane: string): boolean => false;
  tableToolbarCanDeleteRow: (pane: string) => boolean = (pane: string): boolean => false;

  @Builder
  TableToolbarAction(text: string, label: string, type: string, side: string, enabled: boolean) {
    Text(text)
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_primary'))
      .width(Size.touch)
      .height(Size.touch)
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.icon)
      .enabled(enabled)
      .onClick((): void => {
        this.closeBlockToolbar(false);
        if (type === 'more') {
          this.openBlockPropertyPanel(this.blockToolbarPane);
        } else {
          this.applyTableStructureOperation(this.blockToolbarPane, type, side);
        }
      })
      .accessibilityText(label)
  }

  @Builder
  BlockToolbarContent() {
    Row({ space: Space.s1 }) {
      if (this.tableToolbarForPane(this.blockToolbarPane)) {
        this.TableToolbarAction('下加行', '下方加行', 'insertRow', 'down', true)
        this.TableToolbarAction('右加列', '右侧加列', 'insertColumn', 'right', true)
        this.TableToolbarAction('删除', '删除当前行', 'deleteRow', 'down',
          this.tableToolbarCanDeleteRow(this.blockToolbarPane))
        this.TableToolbarAction('更多', '更多表格操作', 'more', '', true)
      } else {
        ForEach(this.blockToolbarActions.slice(0, 4), (action: BlockToolbarAction) => {
          Row() {
            Icon(action.icon, Space.s5, $r('app.color.text_primary'))
          }
          .width(Size.touch)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .onClick((): void => {
            this.closeBlockToolbar(false);
            action.onActivate();
          })
          .accessibilityText(action.accessibilityText)
        }, (action: BlockToolbarAction) => action.id)
        if (this.blockToolbarActions.length > 0) {
          Row() {
            Icon('more', Space.s5, $r('app.color.text_primary'))
          }
          .width(Size.touch)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .onClick((): void => {
            this.openBlockPropertyPanel(this.blockToolbarPane);
          })
          .accessibilityText('更多')
        }
      }
    }
    .width(this.blockToolbarWidth)
    .constraintSize({ maxHeight: this.blockToolbarMaxHeight })
    .padding({ left: Space.s2, right: Space.s2, top: Space.s2, bottom: Space.s2 })
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
    .onKeyEvent((event: KeyEvent): void => {
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.closeBlockToolbar(true);
      }
    })
  }

  build() {
    Blank()
      .width(this.blockToolbarAnchorGeometry(this.pane)[2])
      .height(this.blockToolbarAnchorGeometry(this.pane)[3])
      .position({
        x: this.blockToolbarAnchorGeometry(this.pane)[0],
        y: this.blockToolbarAnchorGeometry(this.pane)[1]
      })
      .hitTestBehavior(HitTestMode.None)
      .bindPopup(this.blockToolbarOpen && this.blockToolbarPane === this.pane, {
        builder: this.BlockToolbarContent(),
        placement: this.blockToolbarPlacement,
        enableArrow: false,
        offset: { x: this.blockToolbarOffsetX, y: this.blockToolbarOffsetY },
        mask: false,
        autoCancel: true,
        popupColor: Color.Transparent,
        onWillDismiss: (action: DismissPopupAction): void => {
          action.dismiss();
          this.closeBlockToolbar(false);
        }
      })
  }
}
