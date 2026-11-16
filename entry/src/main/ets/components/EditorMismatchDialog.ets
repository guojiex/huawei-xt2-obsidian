import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';
import {
  EditorMismatchDiffRow,
  EDITOR_MISMATCH_KIND_ADDED,
  EDITOR_MISMATCH_KIND_COLLAPSED,
  EDITOR_MISMATCH_KIND_REMOVED,
  EDITOR_MISMATCH_KIND_SAME
} from '../model/EditorMismatchDiff';

/**
 * 「编辑内容与笔记不一致」恢复弹窗（v1.70 70.1 双栏 diff 升级，2026-11-15）：
 * git diff 式左右对照（左 = 笔记文件版本，右 = 编辑区内容），行级对齐见
 * model/EditorMismatchDiff；三出口：留在当前页面 / 以笔记文件为准 / 以编辑区为准。
 * 旧版 promptAction.showDialog 纯文本小窗已废弃（信息量不足，用户无法判断差异）。
 */
@CustomDialog
export struct EditorMismatchDialog {
  controller?: CustomDialogController;
  summary: string = '';
  rows: EditorMismatchDiffRow[] = [];
  leftHead: string = '笔记版本';
  rightHead: string = '编辑区版本';
  singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  onKeepPage: () => void = () => {};
  onUseNote: () => void = () => {};
  onUseEditor: () => void = () => {};

  private cellBackground(kind: number): ResourceColor {
    if (kind === EDITOR_MISMATCH_KIND_REMOVED) {
      return $r('app.color.diff_del_bg');
    }
    if (kind === EDITOR_MISMATCH_KIND_ADDED) {
      return $r('app.color.diff_add_bg');
    }
    if (kind === EDITOR_MISMATCH_KIND_COLLAPSED) {
      return $r('app.color.bg_sunken');
    }
    return Color.Transparent;
  }

  private cellTextColor(kind: number): ResourceColor {
    if (kind === EDITOR_MISMATCH_KIND_REMOVED) {
      return $r('app.color.danger');
    }
    if (kind === EDITOR_MISMATCH_KIND_ADDED) {
      return $r('app.color.success');
    }
    if (kind === EDITOR_MISMATCH_KIND_COLLAPSED) {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.text_primary');
  }

  @Builder
  private DiffHeads() {
    Row() {
      Text(this.leftHead)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .layoutWeight(1)
      Text(this.rightHead)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Space.s2, right: Space.s2, top: Space.s2, bottom: Space.s2 })
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
  }

  @Builder
  private DiffRows() {
    ForEach(this.rows, (row: EditorMismatchDiffRow, index: number) => {
      if (row.leftKind === EDITOR_MISMATCH_KIND_COLLAPSED) {
        Text(row.leftText.length > 0 ? row.leftText : ' ')
          .fontSize(FontSize.body2)
          .fontColor(this.cellTextColor(row.leftKind))
          .backgroundColor(this.cellBackground(row.leftKind))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
      } else {
        Row() {
          Text(row.leftText.length > 0 ? row.leftText : ' ')
            .fontSize(FontSize.body2)
            .fontColor(this.cellTextColor(row.leftKind))
            .backgroundColor(this.cellBackground(row.leftKind))
            .layoutWeight(1)
            .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
          Text(row.rightText.length > 0 ? row.rightText : ' ')
            .fontSize(FontSize.body2)
            .fontColor(this.cellTextColor(row.rightKind))
            .backgroundColor(this.cellBackground(row.rightKind))
            .layoutWeight(1)
            .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }, (row: EditorMismatchDiffRow, index: number) =>
      'mismatch-row-' + index + '-' + row.leftKind + row.rightKind)
  }

  @Builder
  private DialogContent() {
    Column({ space: Space.s3 }) {
      Text(this.summary)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      this.DiffHeads()
      Scroll() {
        Column() {
          this.DiffRows()
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DialogFooter() {
    Row({ space: Space.s2 }) {
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '留在当前页面'), 'secondary',
        this.singleScreen, UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.onKeepPage();
        })
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '以笔记文件为准'), 'secondary',
        this.singleScreen, UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.onUseNote();
        })
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '以编辑区为准'), 'primary',
        this.singleScreen, UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.onUseEditor();
        })
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '编辑内容与笔记不一致',
      subtitle: '为避免覆盖笔记，当前编辑区内容未保存。请对照两版差异后选择：',
      headerIcon: 'doc',
      closeLabel: '留在当前页面',
      singleScreen: this.singleScreen,
      scrollContent: false,
      fillContentHeight: true,
      preferredWidthVp: Size.mismatchDialogW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => {
        this.onKeepPage();
      },
      content: (): void => {
        this.DialogContent();
      },
      footer: (): void => {
        this.DialogFooter();
      }
    })
  }
}
