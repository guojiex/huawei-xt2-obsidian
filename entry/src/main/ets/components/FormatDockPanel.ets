/**
 * FormatDockPanel —— 停靠格式栏（专业 ProfFormatDock / 简单 SimpleFormatDock 共用一套按钮与弹层）。
 * 从 Index.ets 拆出（Phase 3 重构）：Aa 面板（FormatMenu）、表格网格（TableGridPicker）、
 * 插入图片等按钮视图迁入本组件；弹层互斥状态（formatMenuOpen / tableGridOpen）仍由 Index
 * 持有，经 @Prop 快照下行、经回调上行。dockKind 决定 build() 分发到哪种停靠栏。
 */
import { FocusRequest } from '../common/FocusRequest';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { DEFAULT_EDITOR_EXPERIENCE, EditorExperienceMode } from '../model/EditorExperiencePolicy';
import { PreviewEditHistoryAction } from './PreviewWebView';

@Component
export struct FormatDockPanel {
  /** 本实例挂在哪一侧停靠栏（left/right） */
  pane: string = 'left';
  /** 'prof' → 专业停靠栏；'simple' → 简单模式停靠栏（含「完成编辑」） */
  dockKind: string = 'prof';
  // ---- 父组件下行（Index 持有真源） ----
  @Prop formatMenuOpen: boolean = false;
  @Prop formatMenuPane: string = 'left';
  @Prop formatPopupPlacement: Placement = Placement.Top;
  @Prop formatPopupOffsetX: number = 0;
  @Prop formatPopupOffsetY: number = -Space.s2;
  @Prop formatMenuWidth: number = Size.formatMenuW;
  @Prop formatMenuMaxHeight: number =
    Size.touch * 6 + Space.s2 * 6 + Size.touch + Space.s6 * 2 + Size.touch + Space.s2;
  @Prop tableGridOpen: boolean = false;
  @Prop tableGridPane: string = 'left';
  @Prop tableGridFocusedRows: number = 1;
  @Prop tableGridFocusedColumns: number = 1;
  @Prop experienceMode: EditorExperienceMode = DEFAULT_EDITOR_EXPERIENCE;
  @Prop leftPaneWidthVp: number = 0;
  @Prop rightPaneWidthVp: number = 0;
  @Prop leftCodeBlockActive: boolean = false;
  @Prop rightCodeBlockActive: boolean = false;
  private readonly tableGridRowOptions: number[] = [1, 2, 3, 4, 5, 6, 7, 8];
  private readonly tableGridColumnOptions: number[] = [1, 2, 3, 4, 5, 6];
  // ---- 父组件上行回调 ----
  isPaneEditable: (pane: string) => boolean = (pane: string): boolean => false;
  paneFilePath: (pane: string) => string = (pane: string): string => '';
  isImagePickerBusy: (pane: string) => boolean = (pane: string): boolean => false;
  toggleFormatMenu: (pane: string) => void = (pane: string): void => {};
  closeFormatMenu: (restoreEditor?: boolean) => void = (restoreEditor?: boolean): void => {};
  applyEditorFormat: (kind: string, pane: string) => void = (kind: string, pane: string): void => {};
  recordFormatAnchorArea: (pane: string, area: Area) => void = (pane: string, area: Area): void => {};
  onFormatMenuKey: (pane: string, event: KeyEvent) => void = (pane: string, event: KeyEvent): void => {};
  toggleTableGrid: (pane: string) => void = (pane: string): void => {};
  insertTableFromGrid: (pane: string, rows: number, columns: number) => void =
    (pane: string, rows: number, columns: number): void => {};
  onTableGridCellKey: (pane: string, rows: number, columns: number, event: KeyEvent) => boolean =
    (pane: string, rows: number, columns: number, event: KeyEvent): boolean => false;
  tableGridCellFocusId: (pane: string, rows: number, columns: number) => string =
    (pane: string, rows: number, columns: number): string => '';
  pickImageForCurrentNote: (pane: string) => void = (pane: string): void => {};
  applyFormatHistoryAction: (action: PreviewEditHistoryAction) => void =
    (action: PreviewEditHistoryAction): void => {};
  isSingleScreenLayout: () => boolean = (): boolean => false;
  finishSimpleEditingFor: (pane: string) => void = (pane: string): void => {};
  recordPaneWidth: (pane: string, widthVp: number) => void = (pane: string, widthVp: number): void => {};

  /** v1.30 30.2：格式按钮序列（Aa/B/I/任务/表格/图片）；专业浮条与简单模式停靠栏共用，按钮集合不变（30.7） */
  @Builder
  FormatActionsRow(pane: string, gap: number) {
    Row({ space: gap }) {
      Row() {
        Text('Aa')
          .fontSize(FontSize.s3)
          .fontColor($r('app.color.text_primary'))
      }
      .width(Size.touch)
      .height(Size.touch)
      .justifyContent(FlexAlign.Center)
      .borderRadius(Radius.full)
      .enabled(this.isPaneEditable(pane))
      .onClick((): void => {
        this.toggleFormatMenu(pane);
      })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.recordFormatAnchorArea(pane, newArea);
      })
      .onKeyEvent((event: KeyEvent): void => { this.onFormatMenuKey(pane, event); })
      .bindPopup(this.formatMenuOpen && this.formatMenuPane === pane, {
        builder: this.FormatMenu(),
        placement: this.formatPopupPlacement,
        enableArrow: false,
        offset: { x: this.formatPopupOffsetX, y: this.formatPopupOffsetY },
        mask: false,
        autoCancel: true,
        popupColor: Color.Transparent,
        onWillDismiss: (action: DismissPopupAction): void => {
          action.dismiss();
          this.closeFormatMenu();
        }
      })
      this.FormatAction('B', 'bold', pane)
      if ((pane === 'right' ? this.rightPaneWidthVp : this.leftPaneWidthVp) >= 280) {
        this.FormatAction('I', 'italic', pane)
      }
      this.FormatAction('☐', 'task', pane)
      if (this.experienceMode === 'simple') {
        this.TableInsertAction(pane)
      }
      if (this.paneFilePath(pane).length > 0) {
        this.ImageFormatAction(pane)
      }
    }
  }

  @Builder
  FormatAction(label: string, kind: string, pane: string) {
    Row() {
      if (kind === 'task') {
        Icon('task', Space.s5, $r('app.color.text_primary'))
      } else {
        Text(label)
          .fontSize(FontSize.s3)
          .fontWeight(kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane))
    .onClick((): void => { this.applyEditorFormat(kind, pane); })
    // v1.10 读屏：kind === 'task' 只画图标，没有可见文字，统一用 label 当名称
    .accessibilityText(label)
  }

  @Builder
  ImageFormatAction(pane: string) {
    Row() {
      // L-7/Z2：全局 @Builder 按值实参不随状态刷新，忙碌色必须走 if 分支，不能写成三元实参
      if (this.isImagePickerBusy(pane)) {
        Icon('image', Space.s5, $r('app.color.text_tertiary'))
      } else {
        Icon('image', Space.s5, $r('app.color.text_primary'))
      }
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane) && !this.isImagePickerBusy(pane))
    .onClick((): void => { this.pickImageForCurrentNote(pane); })
    .accessibilityText(this.isImagePickerBusy(pane) ? '正在选择图片' : '插入图片')
  }

  @Builder
  TableGridCell(pane: string, rows: number, columns: number, selected: boolean) {
    Row() {
      Text(`${rows}×${columns}`)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_primary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.control)
    .backgroundColor(selected ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
    .focusable(true)
    .id(this.tableGridCellFocusId(pane, rows, columns))
    .enabled(this.isPaneEditable(pane))
    .onAppear((): void => {
      if (selected && this.tableGridOpen && this.tableGridPane === pane) {
        FocusRequest.safely(this.getUIContext(), this.tableGridCellFocusId(pane, rows, columns));
      }
    })
    .onKeyEvent((event: KeyEvent): boolean => {
      return this.onTableGridCellKey(pane, rows, columns, event);
    })
    .onClick((): void => {
      this.insertTableFromGrid(pane, rows, columns);
    })
    .accessibilityText(`插入 ${rows} 行 ${columns} 列表格`)
  }

  @Builder
  TableGridPicker(pane: string) {
    Column({ space: Space.s2 }) {
      Text('选择表格大小')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Scroll() {
        Column({ space: Space.s1 }) {
          ForEach(this.tableGridRowOptions, (rows: number): void => {
            Row({ space: Space.s1 }) {
              ForEach(this.tableGridColumnOptions, (columns: number): void => {
                this.TableGridCell(pane, rows, columns,
                  this.tableGridFocusedRows === rows && this.tableGridFocusedColumns === columns)
              }, (columns: number): string => String(columns))
            }
            .width('100%')
          }, (rows: number): string => String(rows))
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(Size.touch, this.formatMenuMaxHeight - Size.touch * 2) })
      .scrollBar(BarState.Auto)
    }
    .width(Size.touch * 6 + Space.s1 * 5 + Space.s5 * 2)
    .constraintSize({ maxHeight: this.formatMenuMaxHeight })
    .padding(Space.s5)
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
  }

  @Builder
  TableInsertAction(pane: string) {
    Row() {
      Icon('plus', Space.s5, $r('app.color.text_primary'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .enabled(this.isPaneEditable(pane))
    .onClick((): void => { this.toggleTableGrid(pane); })
    .bindPopup(this.tableGridOpen && this.tableGridPane === pane, {
      builder: this.TableGridPicker(pane),
      // v1.46 46.9：格式栏停靠栏顶后，表格网格向下弹（原 Placement.Top 会顶出栏外）
      placement: Placement.Bottom,
      enableArrow: false,
      mask: false,
      autoCancel: true,
      popupColor: Color.Transparent
    })
    .accessibilityText('插入表格')
  }

  @Builder
  FormatCell(glyph: string, caption: string, kind: string) {
    Column({ space: Space.s1 }) {
      Text(glyph)
        .fontSize(FontSize.s2)
        .fontColor(kind === 'code' && (this.formatMenuPane === 'right'
          ? this.rightCodeBlockActive : this.leftCodeBlockActive)
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
      Text(caption)
        .fontSize(FontSize.caption)
        .fontColor(kind === 'code' && (this.formatMenuPane === 'right'
          ? this.rightCodeBlockActive : this.leftCodeBlockActive)
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
    }
    .width('100%')
    .constraintSize({ minHeight: Size.touch })
    .padding({ top: Space.s2, bottom: Space.s2 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .backgroundColor(kind === 'code' && (this.formatMenuPane === 'right'
      ? this.rightCodeBlockActive : this.leftCodeBlockActive)
      ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
    .enabled(this.isPaneEditable(this.formatMenuPane))
    .onClick((): void => {
      this.closeFormatMenu();
      this.applyEditorFormat(kind, this.formatMenuPane);
    })
  }

  @Builder
  FormatHistoryButton(action: PreviewEditHistoryAction, label: string) {
    Row({ space: Space.s2 }) {
      Icon(action, Space.s4, $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.control)
    .onClick((): void => { this.applyFormatHistoryAction(action); })
    .accessibilityText(label)
  }

  @Builder
  FormatMenu() {
    Column() {
      Row() {
        Text('文字与段落')
          .fontSize(FontSize.s2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('完成')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .focusable(true)
          .onClick((): void => { this.closeFormatMenu(true); })
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s5, right: Space.s5 })
      .alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: Space.s4 }) {
          Column() {
            Text('段落')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('Aa', '正文', 'paragraph') }
              GridCol() { this.FormatCell('H1', '1 级标题', 'h1') }
              GridCol() { this.FormatCell('H2', '2 级标题', 'h2') }
              GridCol() { this.FormatCell('H3', '3 级标题', 'h3') }
              GridCol() { this.FormatCell('H4', '4 级标题', 'h4') }
              GridCol() { this.FormatCell('H5', '5 级标题', 'h5') }
              GridCol() { this.FormatCell('H6', '6 级标题', 'h6') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          Column() {
            Text('文字')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('B', '加粗', 'bold') }
              GridCol() { this.FormatCell('I', '斜体', 'italic') }
              GridCol() { this.FormatCell('</>', '行内代码', 'inlineCode') }
              GridCol() { this.FormatCell('```', '代码块', 'code') }
              GridCol() { this.FormatCell('↗', '链接', 'link') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4 })
          Column() {
            Text('列表与引用')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            GridRow({ columns: 3, gutter: { x: Space.s2, y: Space.s2 } }) {
              GridCol() { this.FormatCell('≡', '无序列表', 'list') }
              GridCol() { this.FormatCell('1.', '有序列表', 'ordered') }
              GridCol() { this.FormatCell('☑', '待办', 'task') }
              GridCol() { this.FormatCell('❞', '引用', 'quote') }
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4 })
          Row({ space: Space.s2 }) {
            this.FormatHistoryButton('undo', '撤销')
            this.FormatHistoryButton('redo', '重做')
          }
          .width('100%')
          .border({ width: { top: 1 }, color: $r('app.color.line') })
          .padding({ top: Space.s4, left: Space.s5, right: Space.s5 })
        }
        .width('100%')
        .margin({ top: Space.s4 })
        .padding({ left: Space.s5, right: Space.s5, bottom: Space.s5 })
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(0, this.formatMenuMaxHeight - Size.touch - Space.s5) })
      .scrollBar(BarState.Auto)
    }
    .width(this.formatMenuWidth)
    .constraintSize({ maxHeight: this.formatMenuMaxHeight })
    .padding({ top: Space.s5 })
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 80, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 24 })
    .onKeyEvent((event: KeyEvent): void => { this.onFormatMenuKey(this.formatMenuPane, event); })
  }

  /** v1.30 30.4：「完成编辑」—— 收起软键盘并结束编辑焦点，读屏名「完成编辑」 */
  @Builder
  SimpleDoneAction(pane: string) {
    Row() {
      Icon('keyboardDone', Space.s5, $r('app.color.brand'))
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.icon)
    .margin({ left: Space.s2 })
    .onClick((): void => { this.finishSimpleEditingFor(pane); })
    .accessibilityText('完成编辑')
  }

  /**
   * v1.32 32.2：专业模式格式栏停靠 —— 与 v1.30 简单模式停靠栏同形（v2 规则
   * `.window:not(.simple-mode) …>.edit-tools`）：该栏顶部整行（内容区上方）、底部细线、
   * bg_card 底、无阴影圆角；宽屏按钮靠左（左内边距 s5）、单屏居中（s3）；无「完成编辑」按钮——
   * 专业模式走 PaneHead 编辑/预览切换。内容区经 layoutWeight 收缩，源码末行不被遮挡。
   * 仅编辑状态显示，预览时隐藏（沿用既有规则）。
   * v1.46 46.9：停靠位从栏底移到栏顶 —— OFFSET_WITH_CARET 只保证光标可见，
   * 栏底停靠被软键盘盖住（XT2 真机实测），栏顶不依赖窗口底部避让空间。
   */
  @Builder
  ProfFormatDock(pane: string) {
    Row() {
      Scroll() {
        Row({ space: Space.s1 }) {
          this.FormatActionsRow(pane, Space.s1)
        }
        .constraintSize({ minWidth: '100%' })
        .justifyContent(this.isSingleScreenLayout() ? FlexAlign.Center : FlexAlign.Start)
        .padding({
          left: this.isSingleScreenLayout() ? Space.s3 : Space.s5,
          right: Space.s3
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height(Size.touch + Space.s1 * 2)
    .padding({
      top: Space.s1,
      bottom: Space.s1
    })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.recordPaneWidth(pane, newArea.width);
      }
    })
  }

  /**
   * v1.30 30.2/30.3：简单模式停靠格式栏 —— 该栏顶部整行（内容区上方）：通栏宽、
   * 底部分隔线、bg_card 底、无阴影圆角；宽屏按钮靠左、完成编辑靠右；单屏按钮居中、
   * 完成编辑在末尾；按钮超出横向滑动。内容区经 layoutWeight 自动收缩，末行不被遮挡。
   * v1.46 46.9：停靠位从栏底移到栏顶 —— OFFSET_WITH_CARET 下栏底停靠被软键盘盖住。
   */
  @Builder
  SimpleFormatDock(pane: string) {
    Row() {
      Scroll() {
        Row({ space: Space.s1 }) {
          this.FormatActionsRow(pane, Space.s1)
          if (this.isSingleScreenLayout()) {
            this.SimpleDoneAction(pane)
          }
        }
        .constraintSize({ minWidth: '100%' })
        .justifyContent(this.isSingleScreenLayout() ? FlexAlign.Center : FlexAlign.Start)
        .padding({
          left: this.isSingleScreenLayout() ? Space.s3 : Space.s5,
          right: Space.s3
        })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      if (!this.isSingleScreenLayout()) {
        this.SimpleDoneAction(pane)
      }
    }
    .width('100%')
    .height(Size.touch + Space.s1 * 2)
    .padding({
      top: Space.s1,
      bottom: Space.s1,
      right: this.isSingleScreenLayout() ? 0 : Space.s3
    })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.recordPaneWidth(pane, newArea.width);
      }
    })
  }

  build() {
    if (this.dockKind === 'prof') {
      this.ProfFormatDock(this.pane)
    } else {
      this.SimpleFormatDock(this.pane)
    }
  }
}
