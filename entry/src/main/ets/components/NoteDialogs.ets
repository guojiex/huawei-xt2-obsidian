/**
 * NoteDialogs.ets —— 笔记级对话框（v0.2 起：先有「新建笔记」）
 *
 * 与 VaultDialogs 的分工：那边管库的新建/改名/删除，这边管库里笔记文件的操作。
 * v0.2 §3.5 已交付 token，故本文件的样式**直接走 token**，不带 v0.1 那套硬编码色值。
 */
import { NoteService } from '../model/NoteService';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

/**
 * 新建笔记。
 *
 * 为什么一个输入框同时管「文件」和「目录」：输入 `工程/流式系统/笔记` 就会连目录一起建出来。
 * 单独做一个「新建文件夹」入口成本不小（UI + 状态 + 空目录语义），而用路径表达既够用又直观
 * ——顺带也让文件树的多层缩进/引导线变得可验证。
 */
@CustomDialog
export struct CreateNoteDialog {
  controller?: CustomDialogController;
  /** 当前库 id（用于重名预览） */
  vaultId: string = '';
  @State rawName: string = '';
  /** 确认回调（传原始输入；消毒与重名处理统一在 NoteService，避免两处漂移） */
  onConfirm: (relPath: string) => void = (relPath: string) => {};

  /** 归一化结果；不合法返回空串（`<` 这类字符会被消毒掉，故先看消毒后是否还剩下东西） */
  private normalized(): string {
    try {
      return NoteService.normalizeRelPath(this.rawName);
    } catch (error) {
      return '';
    }
  }

  /** 实时预览：目标路径 + 重名自动加后缀（与新建库同策略） */
  private hintText(): string {
    const rel: string = this.normalized();
    if (rel.length === 0) {
      return '名称不能为空，也不能只由 / \\ : * ? " < > | 组成';
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
    this.onConfirm(this.rawName);
  }

  build() {
    Column() {
      Text('新建笔记')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('可写子目录，例如「工程/流式系统/笔记」，目录会自动建出来。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })

      TextInput({ placeholder: '笔记名称' })
        .height(Size.buttonH)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
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
