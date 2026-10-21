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
 * 新建笔记 / 新建文件夹（2026-10-18 方案 A 改版：目录选择器 + 名称分开 + 类型切换）。
 *
 * 改版背景（用户拍板）：原来只有一个名称输入框，想建在子目录里必须手打完整路径，
 * 体感「只能建在根目录」。现在：
 *  - **目录选择器**：对话框里列出全部目录（含「根目录」选项），点开即选；
 *  - **默认目录 = 上次点过的目录**（FileTreeView 点目录行/文件行时记进
 *    `ExpandStore.lastdir`，按库记忆）；+ 按钮入口则预填那个目录；
 *  - 名称框只填名字。两者在确认时拼成完整路径，仍走 NoteService 的统一消毒。
 *
 * 2026-10-18 方案 A（用户拍板，原话「设计稿里面我要怎么新建文件夹？？？」）：
 *  - 对话框顶部加「📄笔记 / 📁文件夹」类型切换。文件夹模式建**空目录**
 *    （名称同样可带 `/` 建多层，重名加后缀，建完 lastDir 记入新文件夹）；
 *  - 目录删除同步配套：FileTreeView 目录行尾加删除按钮 → DeletePathDialog 确认
 *    → NoteService.deletePath 整棵子树移除（原先目录行只有 rename/move）。
 *
 * 为什么目录列表是**内联展开**而不是再套一个弹窗/Select：对话框自己是 CustomDialog，
 * 上面再挂弹层在 ArkUI 里层级与命中都容易出幺蛾子（v0.2 侧栏菜单刚踩过）；
 * 内联展开是一个普通 Column，命中与层级都归对话框管，最稳。
 *
 * 设计稿说明：原型 `side-foot` 的「新建」按钮**没绑任何行为**（无 id、无 JS），
 * 创建流程设计稿从未定义 —— 当前形态全部是自己补的设计。
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
  /** 创建类型：'note' 笔记 | 'folder' 空文件夹（2026-10-18 方案 A） */
  @State createType: string = 'note';
  /** 确认回调（传拼接后的原始输入 + 类型；消毒与重名处理统一在 NoteService，避免两处漂移） */
  onConfirm: (relPath: string, createType: string) => void = (relPath: string, createType: string) => {};

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
      if (this.createType === 'folder') {
        return NoteService.normalizeDirPath(this.composed());
      }
      return NoteService.normalizeRelPath(this.composed());
    } catch (error) {
      return '';
    }
  }

  /** 实时预览：目标路径 + 重名自动加后缀（与新建库同策略） */
  private hintText(): string {
    if (this.createType === 'folder') {
      let rel: string;
      try {
        rel = NoteService.normalizeDirPath(this.composed());
      } catch (error) {
        // 直接把底层原因显示出来（空名 / 选了目录还没填名字），比一句通用文案可操作
        const err = error as Error;
        return err.message;
      }
      const actual: string = NoteService.uniqueDirPath(VaultRegistry.get(), this.vaultId, rel);
      if (actual !== rel) {
        return '将创建文件夹：' + this.vaultId + '/' + actual + '（同名已存在，自动加后缀）';
      }
      return '将创建文件夹：' + this.vaultId + '/' + rel;
    }
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
    this.onConfirm(this.composed(), this.createType);
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
      Text(this.createType === 'folder' ? '新建文件夹' : '新建笔记')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.createType === 'folder'
        ? '选一个父文件夹，再填名字。建出的文件夹是空的，之后可以在里面新建笔记。'
        : '选择目录，填写名字。名称里也可以写 / 直接建更深一层的目录。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })

      // 类型切换（2026-10-18 方案 A）：📄笔记 / 📁文件夹。
      // 自绘两按钮分段控件（ArkUI 没有开箱分段组件），选中态用主色底 + 主色字。
      // 切类型不清空已输名称：用户可能先打字再切类型。
      Row({ space: 2 }) {
        Row({ space: Space.s1 }) {
          Icon('doc', 14, this.createType === 'note'
            ? $r('app.color.brand') : $r('app.color.text_secondary'))
          Text('笔记')
            .fontSize(FontSize.body3)
            .fontColor(this.createType === 'note'
              ? $r('app.color.brand') : $r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .height(Size.buttonH)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.control)
        .backgroundColor(this.createType === 'note'
          ? $r('app.color.brand_bg_solid') : Color.Transparent)
        .onClick(() => {
          this.createType = 'note';
        })

        Row({ space: Space.s1 }) {
          Icon('folder', 14, this.createType === 'folder'
            ? $r('app.color.brand') : $r('app.color.text_secondary'))
          Text('文件夹')
            .fontSize(FontSize.body3)
            .fontColor(this.createType === 'folder'
              ? $r('app.color.brand') : $r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .height(Size.buttonH)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.control)
        .backgroundColor(this.createType === 'folder'
          ? $r('app.color.brand_bg_solid') : Color.Transparent)
        .onClick(() => {
          this.createType = 'folder';
        })
      }
      .width('100%')
      .padding(2)
      .backgroundColor($r('app.color.bg_secondary'))
      .borderRadius(Radius.control)
      .margin({ bottom: Space.s3 })

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

      TextInput({ placeholder: this.createType === 'folder' ? '文件夹名称' : '笔记名称' })
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

/**
 * 删除确认（2026-10-18 方案 A 配套；1.7 起文案分流）。
 *
 * 目录与文件共用，**语义不同**（原型 note-del 文案）：
 *  - 文件 → 移入当前库回收站，可恢复（确认后走 TrashService.moveToTrash + 5 秒撤销条）；
 *  - 目录 → 连同整棵子树永久删除，**不可恢复**，不进回收站
 *    （误删一棵子树的代价不该被「撤销」轻描淡写 —— 原型目录不给滑到底删除同理）。
 */
@CustomDialog
export struct DeletePathDialog {
  controller?: CustomDialogController;
  /** 待删路径（库内相对路径） */
  relPath: string = '';
  /** 是否目录（文案不同；目录 = 整棵子树） */
  isDir: boolean = false;
  onConfirm: () => void = () => {};

  private confirm(): void {
    this.controller?.close();
    this.onConfirm();
  }

  build() {
    Column() {
      Text(this.isDir ? '删除文件夹？' : '删除笔记？')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.isDir
        ? '文件夹会连里面的所有内容一起删除，且无法恢复。'
        : '笔记会移入当前库回收站，可恢复。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })
      Text(this.relPath)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: Space.s2, right: Space.s2, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.icon)
        .margin({ bottom: Space.s3 })
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
        Text('确认删除')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.danger'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.danger') })
          .backgroundColor($r('app.color.danger_bg'))
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(Size.drawerW)
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 重命名文件 / 文件夹（1.6 左滑操作条的「重命名」，原型 note-rename / dir-rename）。
 * - 文件：输入框预填**去掉 .md** 的名字，确认时自动补回；
 * - 目录：预填目录名原样；
 * - 确认后由 Index 调 NoteService.renamePath（消毒、重名加后缀都在那边，这里只收集输入）。
 */
@CustomDialog
export struct RenamePathDialog {
  controller?: CustomDialogController;
  /** 待改名的库内相对路径 */
  relPath: string = '';
  /** 是否目录（标题 / 文案 / 是否补 .md 不同） */
  isDir: boolean = false;
  /** 预填名（文件传去掉扩展名的名字；目录传目录名） */
  initialName: string = '';
  /** 确认回调（传用户输入原文；消毒与重名处理在 NoteService.renamePath） */
  onConfirm: (newName: string) => void = (newName: string) => {};
  @State rawName: string = '';

  aboutToAppear(): void {
    this.rawName = this.initialName;
  }

  private canConfirm(): boolean {
    return this.rawName.trim().length > 0;
  }

  build() {
    Column() {
      Text(this.isDir ? '重命名文件夹' : '重命名笔记')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.isDir
        ? '文件夹名改了，里面的笔记不受影响。'
        : '文件名改了，内容不变。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })
      Text(this.relPath)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: Space.s2, right: Space.s2, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.icon)
        .margin({ bottom: Space.s3 })
      TextInput({ text: this.rawName, placeholder: this.isDir ? '文件夹名称' : '笔记名称' })
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
        Text('保存')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand'))
          .enabled(this.canConfirm())
          .opacity(this.canConfirm() ? 1 : 0.4)
          .onClick(() => {
            if (!this.canConfirm()) {
              return;
            }
            this.controller?.close();
            this.onConfirm(this.rawName);
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

/**
 * 移动文件 / 文件夹（1.6 左滑操作条的「移动」，原型 note-move / dir-move）。
 * - 内联目录选择器（与 CreateNoteDialog 同款交互，为什么内联见那边的注释）；
 * - 候选目录由 Index 传入：目录目标已剔除自身与子孙（移进自己内部 = 消失）；
 * - 确认回调传选中的目标目录（空串 = 库根目录），移动逻辑在 NoteService.movePath。
 */
@CustomDialog
export struct MovePathDialog {
  controller?: CustomDialogController;
  /** 待移动的库内相对路径 */
  relPath: string = '';
  /** 是否目录（文案不同） */
  isDir: boolean = false;
  /** 候选目录（库内相对路径；目录目标不含自身与子孙） */
  dirs: string[] = [];
  /** 预选目录（空串 = 库根目录） */
  initialDir: string = '';
  /** 确认回调（传目标目录，空串 = 库根目录） */
  onConfirm: (destDir: string) => void = (destDir: string) => {};
  @State selectedDir: string = '';
  @State pickerOpen: boolean = false;

  aboutToAppear(): void {
    this.selectedDir = this.initialDir;
  }

  /** 目标选择的一行（根目录或某个目录）；选中态用主色 + 实底（同 CreateNoteDialog.DirItem） */
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
      Text('移动「' + this.relPath.substring(this.relPath.lastIndexOf('/') + 1) + '」')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.isDir
        ? '整个文件夹连同里面的笔记一起移动。'
        : '移动到别的文件夹下（选顶层就是移到库根目录）。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })

      // 目标目录选择行（点开/收起内联列表）
      Row({ space: Space.s2 }) {
        Icon('folder', 16, $r('app.color.text_secondary'))
        Text(this.selectedDir.length > 0 ? this.selectedDir : '根目录（库顶层）')
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

      if (this.pickerOpen) {
        Scroll() {
          Column({ space: 2 }) {
            this.DirItem('', '根目录（库顶层）')
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
        Text('移动到这里')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.controller?.close();
            this.onConfirm(this.selectedDir);
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
