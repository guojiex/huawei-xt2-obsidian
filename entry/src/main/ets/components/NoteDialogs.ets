/**
 * NoteDialogs.ets —— 笔记级对话框（v0.2 起：先有「新建笔记」）
 *
 * 与 VaultDialogs 的分工：那边管库的新建/改名/删除，这边管库里笔记文件的操作。
 * v0.2 §3.5 已交付 token，故本文件的样式**直接走 token**，不带 v0.1 那套硬编码色值。
 */
import { NoteService } from '../model/NoteService';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';
import { Icon } from '../common/Icons';

/**
 * 新建笔记（2026-10-18 改版：目录选择器 + 名称分开）。
 *
 * 改版背景（用户拍板）：原来只有一个名称输入框，想建在子目录里必须手打完整路径，
 * 体感「只能建在根目录」。现在：
 *  - **目录选择器**：对话框里列出全部目录（含「根目录」选项），点开即选；
 *  - **默认目录 = 上次点过的目录**（FileTreeView 点目录行/文件行时记进
 *    `ExpandStore.lastdir`，按库记忆）；+ 按钮入口则预填那个目录；
 *  - 名称框只填名字。两者在确认时拼成完整路径，仍走 NoteService 的统一消毒。
 *
 * 为什么目录列表是**内联展开**而不是再套一个弹窗/Select：对话框自己是 CustomDialog，
 * 上面再挂弹层在 ArkUI 里层级与命中都容易出幺蛾子（v0.2 侧栏菜单刚踩过）；
 * 内联展开是一个普通 Column，命中与层级都归对话框管，最稳。
 *
 * 设计稿说明：原型 `side-foot` 的「新建」按钮**没绑任何行为**（无 id、无 JS），
 * 笔记创建流程设计稿从未定义 —— 当前形态全部是自己补的设计。
 */
@CustomDialog
export struct CreateNoteDialog {
  controller?: CustomDialogController;
  /** 当前库 id（用于重名预览） */
  vaultId: string = '';
  /** 全部可选目录（库内相对路径，`FileTree.allDirs` 扫出来；不含根本身） */
  dirs: string[] = [];
  /** 预选目录（+ 按钮入口 / 上次记忆）；空串 = 根目录 */
  initialDir: string = '';
  /** 名称（不含目录；确认时与 selectedDir 拼接） */
  @State rawName: string = '';
  /** 当前选中的目标目录（空串 = 根目录） */
  @State selectedDir: string = '';
  /** 目录列表展开状态 */
  @State pickerOpen: boolean = false;
  /** 确认回调（传拼接后的原始输入；消毒与重名处理统一在 NoteService，避免两处漂移） */
  onConfirm: (relPath: string) => void = (relPath: string) => {};

  aboutToAppear(): void {
    this.selectedDir = this.initialDir;
  }

  /** 目录 + 名称 → 待创建的库内相对路径（原始串，消毒在 NoteService） */
  private composed(): string {
    if (this.selectedDir.length === 0) {
      return this.rawName;
    }
    return this.selectedDir + '/' + this.rawName;
  }

  /** 归一化结果；不合法返回空串（确认按钮的禁用态看它） */
  private normalized(): string {
    try {
      return NoteService.normalizeRelPath(this.composed());
    } catch (error) {
      return '';
    }
  }

  /** 实时预览：目标路径 + 重名自动加后缀（与新建库同策略） */
  private hintText(): string {
    let rel: string;
    try {
      rel = NoteService.normalizeRelPath(this.composed());
    } catch (error) {
      // 直接把底层原因显示出来（空名 / 选了目录还没填名字），比一句通用文案可操作
      const err = error as Error;
      return err.message;
    }
    const actual: string = NoteService.uniqueRelPath(VaultRegistry.get(), this.vaultId, rel);
    if (actual !== rel) {
      return this.vaultId + '/' + actual + '（同名已存在，自动加后缀）';
    }
    return this.vaultId + '/' + rel;
  }

  private confirm(): void {
    if (this.normalized().length === 0) {
      return;
    }
    this.controller?.close();
    this.onConfirm(this.composed());
  }

  /** 目录选择的一行（根目录或某个目录）；选中态用主色 + 实底，不引入新图标 */
  @Builder
  DirItem(rel: string, label: string) {
    Row({ space: Space.s2 }) {
      Icon('folder', 14, this.selectedDir === rel
        ? $r('app.color.brand') : $r('app.color.text_secondary'))
      Text(label)
        .fontSize(FontSize.body3)
        .fontColor(this.selectedDir === rel
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s2, right: Space.s2 })
    .borderRadius(Radius.icon)
    .backgroundColor(this.selectedDir === rel
      ? $r('app.color.brand_bg_solid') : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectedDir = rel;
      this.pickerOpen = false;
    })
  }

  build() {
    Column() {
      Text('新建笔记')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('选择目录，填写名字。名称里也可以写 / 直接建更深一层的目录。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })

      // 目录选择行：点开/收起内联目录列表
      Row({ space: Space.s2 }) {
        Icon('folder', 16, $r('app.color.text_secondary'))
        Text(this.selectedDir.length > 0 ? this.selectedDir : '根目录')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Icon(this.pickerOpen ? 'chevronUp' : 'chevronDown', 14, $r('app.color.text_tertiary'))
      }
      .width('100%')
      .height(Size.buttonH)
      .padding({ left: Space.s3, right: Space.s3 })
      .backgroundColor($r('app.color.bg_secondary'))
      .borderRadius(Radius.control)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.pickerOpen = !this.pickerOpen;
      })

      // 内联目录列表：根目录恒为第一项，其余按扫描顺序；固定高度内部滚
      if (this.pickerOpen) {
        Scroll() {
          Column({ space: 2 }) {
            this.DirItem('', '根目录')
            ForEach(this.dirs, (d: string) => {
              this.DirItem(d, d)
            }, (d: string) => d)
          }
        }
        .width('100%')
        .height(160)
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .padding(Space.s1)
        .margin({ top: Space.s1 })
      }

      TextInput({ placeholder: '笔记名称' })
        .height(Size.buttonH)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .margin({ top: Space.s2 })
        .onChange((value: string) => {
          this.rawName = value;
        })

      Text(this.hintText())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: Space.s2 })

      Row({ space: Space.s2 }) {
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => {
            this.controller?.close();
          })
        Text('创建')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand'))
          .enabled(this.normalized().length > 0)
          .opacity(this.normalized().length > 0 ? 1 : 0.4)
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: Space.s4 })
    }
    .width(Size.drawerW)
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}
