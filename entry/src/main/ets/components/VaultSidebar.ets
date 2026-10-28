/**
 * VaultSidebar.ets —— 侧栏（v0.2 §3.5 token 化后的版本）
 *
 * 两种挂载形态：
 *  - 嵌入（md/lg）：作为 Index Row 子项随断点等分宽（layoutWeight 由父级控制）；
 *  - 抽屉（sm）：Stack 覆盖层，显隐与遮罩由 Index 控制（asDrawer = true）。
 * 结构照原型 sidebar：库切换器卡片（下拉列库，当前项高亮）→ 目录头（「收起 «」入口）
 * → 树区占位（v0.2 M1 接入）→ 底部「管理库 / 新建」。
 *
 * 视觉全部走 token（需求 4.1）：颜色 `$r('app.color.*')`、数值 `Space/Radius/FontSize/Size`。
 * 图标用统一描边 `Icon()`（见 common/Icons.ets 的 J-2 兜底说明）。
 */
import { VaultEntry } from '../model/Vault';
import { FileTreeView } from './FileTreeView';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

export interface ChapterEntry {
  index: number;
  level: number;
  title: string;
  offset: number;
}

@Component
export struct VaultSidebar {
  /** 抽屉形态（sm 覆盖层）：不显示「收起 «」——抽屉关掉即可，无收起语义 */
  asDrawer: boolean = false;
  /** 矮窗口压缩库选择器留白并隐藏操作提示，给文件树保留可见高度。 */
  @Prop compact: boolean = false;
  /** 库列表（由 Index 单向传入；本组件只显示并发出选择回调） */
  @Prop vaults: VaultEntry[] = [];
  /** Agent 笔记区复用库选择器和文件树，但不显示管理笔记的动作。 */
  @Prop referenceOnly: boolean = false;
  /** 当前库 id（显示名 = 目录名 = id） */
  @Prop currentVaultId: string = '';
  /** 当前库内有效 Markdown 笔记数 */
  @Prop noteCount: number = 0;
  /** 当前打开文件的库内相对路径（父级持有，树只画选中态） */
  @Prop currentFilePath: string = '';
  @Prop chapters: ChapterEntry[] = [];
  @Prop selectedChapterIndex: number = -1;
  /**
   * 重扫信号 + 需要显示出来的路径：**透传给 FileTreeView**（那边才是状态持有者）。
   * refreshSeq：父级每 +1 一次，树重扫一次（新建 / 改名 / 删除笔记后刷新）；
   * revealPath：父级新建笔记后置位，树自动展开它的所有父目录 ——
   * 否则建在多层子目录里的笔记建完看不见，用户会以为没建成。
   */
  @Prop refreshSeq: number = 0;
  @Prop revealPath: string = '';
  /** 下拉菜单开关（瞬态） */
  @State menuOpen: boolean = false;
  @State sidebarTab: string = 'files';
  /**
   * 弹层宽（vp）：原型 .vault-menu 是 left:0; right:0 于 .vault-switch —— **与卡片同宽**，
   * 不是固定值。侧栏宽随断点等分变化，故在卡片上 onAreaChange 实测回填。
   */
  @State menuW: number = Size.sidebarW;
  /** 「收起 «」回调（嵌入形态：父级收起侧栏） */
  onCollapse: () => void = () => {};
  /** 切库回调（点下拉菜单中的库项） */
  onSwitchVault: (id: string) => void = (id: string) => {};
  /** 「管理库」回调（父级切换到库管理视图） */
  onManageVaults: () => void = () => {};
  /** 从当前库下拉菜单分享整个知识库。 */
  onShareVault: () => void = () => {};
  /**
   * 「导入 Git 仓库…」回调（原型 vault-menu 第二个动作项，走「导入仓库」页）。
   * Git 同步是 v0.3 能力，此处只做导航跳转。
   */
  onImportGit: () => void = () => {};
  /**
   * 「新建笔记」回调（父级拉起新建笔记对话框）。
   * 原型侧栏底部的「新建」在这里落成**新建笔记** —— 新建库要去「库管理」页，
   * 那里本来就有「+ 新建本地笔记库」入口（原型 index.html #newLocal），两处不重复摆。
   */
  onCreateNote: () => void = () => {};
  /** 选中文件回调（向父级传递，由父级决定编辑器行为） */
  onSelectFile: (relPath: string) => void = (relPath: string) => {};
  onSelectChapter: (index: number) => void = (index: number) => {};
  /** 文件行尾的跨栏打开入口。 */
  onOpenOtherPane: (relPath: string) => void = (relPath: string) => {};
  onReferenceNote: (relPath: string, vaultId: string) => void =
    (relPath: string, vaultId: string) => {};
  /**
   * 「在该目录下新建笔记」回调（文件树目录行尾的 + 按钮，2026-10-18 方案 A）。
   * 侧栏自身只透传，对话框与消毒逻辑都在父级（Index）—— 与 onCreateNote 同一条链路，
   * 差别仅在于对话框预填目标目录。
   */
  onCreateInDir: (dirRelPath: string) => void = (dirRelPath: string) => {};
  /** 左滑操作条回调透传（1.6：重命名 / 移动 / 删除 / 滑到底删除），执行都在父级（Index） */
  onRenamePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onMovePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onDeletePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onSharePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onSwipeDelete: (relPath: string) => void = (relPath: string) => {};
  /** 「回收站」回调（side-foot 第二按钮，1.8 回收站视图入口） */
  onOpenTrash: () => void = () => {};

  /**
   * 库类型徽标（照原型 .vbadge）：全圆胶囊（--r-full）、fs-caption、Medium；
   * local = brand 字 + brand_bg 底（.vbadge.local），git = success 字 + success_bg 底（.vbadge.git）。
   * 与选中态无关 —— 原型里徽标颜色只由库类型决定。
   */
  @Builder
  VaultBadge(v: VaultEntry) {
    Text(v.type === 'git' ? 'Git' : '本地')
      .fontSize(FontSize.caption)
      .fontWeight(FontWeight.Medium)
      .fontColor(v.type === 'git' ? $r('app.color.success') : $r('app.color.brand'))
      .padding({ top: 2, bottom: 2, left: Space.s2, right: Space.s2 })
      .borderRadius(Radius.full)
      .backgroundColor(v.type === 'git' ? $r('app.color.success_bg') : $r('app.color.brand_bg'))
  }

  /**
   * 库切换下拉菜单内容（照原型 vault-menu：库项 + 分隔线 + 「管理库…」+「导入 Git 仓库…」）。
   * 逐条对原型：容器 padding --sp-2 / 圆角 --r-menu / elev-3；行 --vitem：48 高、
   * padding 8/12、圆角 --r-control、字号 --fs-body1；选中 = brand 字 + --brand-bg 底 + 500。
   *
   * ⚠️ 为什么走 bindPopup 而不是「Stack 内 offset 溢出的普通 Column」：
   * 后者是页面内普通子节点，而侧栏里文件树在它之后声明 —— ArkUI 同级组件
   * 后声明的绘制在上层，于是菜单会被文件树盖住（2026-10-18 实测复现）。
   * 弹层挂在窗口覆盖层上，层级高于页面内所有组件，天然不会被遮挡。
   */
  @Builder
  VaultMenu() {
    Column() {
      ForEach(this.vaults, (v: VaultEntry) => {
        Row({ space: Space.s2 }) {
          Text(v.id)
            .fontSize(FontSize.body1)
            .fontWeight(v.id === this.currentVaultId ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(v.id === this.currentVaultId
              ? $r('app.color.brand') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.VaultBadge(v)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .borderRadius(Radius.control)
        .backgroundColor(v.id === this.currentVaultId
          ? $r('app.color.brand_bg') : Color.Transparent)
        .onClick(() => {
          this.menuOpen = false;
          this.onSwitchVault(v.id);
        })
      }, (v: VaultEntry) => v.id)

      // 分隔线（原型 .sep：1px line，上下 --sp-1 / 左右 --sp-2 边距）
      Divider()
        .color($r('app.color.line'))
        .margin({ top: Space.s1, bottom: Space.s1, left: Space.s2, right: Space.s2 })

      // 动作项（原型 data-act 行：纯文字，不带图标）
      Row() {
        Text('管理库…')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .borderRadius(Radius.control)
      .onClick(() => {
        this.menuOpen = false;
        this.onManageVaults();
      })

      Row() {
        Text('导入 Git 仓库…')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .borderRadius(Radius.control)
      .onClick(() => {
        this.menuOpen = false;
        this.onImportGit();
      })

      Row() {
        Text('分享知识库…')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s3, right: Space.s3 })
      .borderRadius(Radius.control)
      .onClick(() => {
        this.menuOpen = false;
        this.onShareVault();
      })
    }
    // 与库切换卡片同宽（原型 left:0; right:0），实测宽由卡片 onAreaChange 回填
    .width(this.menuW)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    // 原型 --elev-3 的单层近似（两层 CSS 阴影 ArkUI 只能合一层）
    .shadow({ radius: 30, color: '#2E000000', offsetX: 0, offsetY: 10 })
  }

  private vaultTypeLabel(): string {
    for (let i: number = 0; i < this.vaults.length; i++) {
      if (this.vaults[i].id === this.currentVaultId) {
        return this.vaults[i].type === 'git' ? 'Git 库' : '本地库';
      }
    }
    return '本地库';
  }

  build() {
    Column() {
      // 头部区外包一层：水平 padding 做「卡片离侧栏边缘」的视觉 inset（原型 --sp-3 = 12）。
      // ⚠️ inset 不能写在卡片自己的 margin 上再配 width('100%')：ArkUI 的百分比取父级
      // 内容盒的 100%，margin 加在盒外 → 卡片实际占宽 = 侧栏宽 + 2×margin，右缘越过
      // 栏间分隔线伸进编辑区（2026-10-18 用户实测）。外包层 padding 在盒内，天然不溢出。
      Column() {
        // 库切换器卡片（点击弹出库列表，见 VaultMenu）——照原型 .vault-switch：
        // padding --sp-3 / 圆角 --r-card / 边框 line / --elev-1 / gap --sp-3。
        Row({ space: Space.s3 }) {
          // 原型 .vs-icon：32×32 圆角块（--r-icon），brand_bg 底 + brand 色图标
          Row() {
            Icon('folder', 18, $r('app.color.brand'))
          }
          .width(Space.s8)
          .height(Space.s8)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand_bg'))

          Column({ space: 2 }) {
            Text(this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）')
              .fontSize(FontSize.body1)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.vaultTypeLabel() + ' · ' + this.noteCount + ' 篇')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Icon(this.menuOpen ? 'chevronUp' : 'chevronDown', 16, $r('app.color.text_tertiary'))
        }
        // 此时 100% = 外包层的 content 盒 → 刚好放下，不再溢出侧栏
        .width('100%')
        .padding({
          top: this.compact ? Space.s2 : Space.s3,
          bottom: this.compact ? Space.s2 : Space.s3,
          left: Space.s3,
          right: Space.s3
        })
        .margin({
          top: this.compact ? Space.s1 : Space.s3,
          bottom: this.compact ? Space.s1 : Space.s2
        })
        .borderRadius(Radius.card)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.line') })
        // 原型 --elev-1 的单层近似
        .shadow({ radius: 8, color: '#0F000000', offsetX: 0, offsetY: 2 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.menuOpen = !this.menuOpen;
        })
        // 实测卡片宽回填弹层宽（原型 vault-menu 与卡片同宽，见 menuW 注释）
        .onAreaChange((oldArea: Area, newArea: Area) => {
          if (typeof newArea.width === 'number') {
            this.menuW = newArea.width;
          }
        })
        // 下拉菜单：弹层挂窗口覆盖层（高于文件树），列全部库（当前高亮）+ 分隔线 + 「管理库…」+「导入 Git 仓库…」
        .bindPopup(this.menuOpen, {
          builder: this.VaultMenu(),
          placement: Placement.BottomLeft,
          // 关掉弹层自带小箭头（默认 true）：原型 vault-menu 没有气泡箭头
          enableArrow: false,
          // 弹层贴卡片左缘 → offset 只补下间距（原型 margin-top --sp-2）
          offset: { x: 0, y: Space.s2 },
          mask: false,
          autoCancel: true,
          popupColor: Color.Transparent,
          onWillDismiss: (action: DismissPopupAction): void => {
            // 点菜单外 / 返回键收起：框架先回调这里，必须显式 dismiss() 才真正消失；
            // 同时把 menuOpen 置回 false，chevron 图标才不会停在「已展开」
            action.dismiss();
            this.menuOpen = false;
          }
        })
      }
      .width('100%')
      .padding({ left: Space.s3, right: Space.s3 })

      if (!this.referenceOnly) {
        // 目录头：标签 + 头部「＋」(vault 根目录新建) + 收起入口
        Row() {
          Text('目录')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_tertiary'))
          Blank()
          Row() {
            Icon('plus', 16, $r('app.color.text_tertiary'))
          }
          .height(Size.touch)
          .width(Size.touch)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.icon)
          .onClick(() => {
            this.onCreateNote();
          })
          if (!this.asDrawer) {
            Row({ space: Space.s1 }) {
              Text('收起')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_tertiary'))
              Icon('collapse', 12, $r('app.color.text_tertiary'))
            }
            .height(Size.touch)
            .padding({ left: Space.s2, right: Space.s2 })
            .borderRadius(Radius.icon)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.onCollapse();
            })
          }
        }
        .width('100%')
        .padding({ left: Space.s4, right: Space.s2 })
      }

      if (!this.referenceOnly) {
        Row() {
          Row() {
            Text('文件')
              .fontSize(FontSize.body3)
              .fontColor(this.sidebarTab === 'files' ? $r('app.color.brand') : $r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .layoutWeight(1)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .border({ width: { bottom: 2 }, color: this.sidebarTab === 'files'
            ? $r('app.color.brand') : $r('app.color.line') })
          .onClick((): void => { this.sidebarTab = 'files'; })

          Row() {
            Text('章节')
              .fontSize(FontSize.body3)
              .fontColor(this.sidebarTab === 'chapters' ? $r('app.color.brand') : $r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }
          .layoutWeight(1)
          .height(Size.touch)
          .justifyContent(FlexAlign.Center)
          .border({ width: { bottom: 2 }, color: this.sidebarTab === 'chapters'
            ? $r('app.color.brand') : $r('app.color.line') })
          .onClick((): void => { this.sidebarTab = 'chapters'; })
        }
        .width('100%')
        .padding({ left: Space.s3, right: Space.s3 })
      }

      Stack() {
        // 保持树常驻，切换章节时不丢失折叠和滚动位置。
        FileTreeView({
          vaultId: this.currentVaultId,
          currentFilePath: this.currentFilePath,
          refreshSeq: this.refreshSeq,
          revealPath: this.revealPath,
          referenceOnly: this.referenceOnly,
          onSelectFile: (relPath: string): void => { this.onSelectFile(relPath); },
          onOpenOtherPane: (relPath: string): void => { this.onOpenOtherPane(relPath); },
          onReferenceNote: (relPath: string, vaultId: string): void => {
            this.onReferenceNote(relPath, vaultId);
          },
          onCreateInDir: (dirRelPath: string): void => { this.onCreateInDir(dirRelPath); },
          onRenamePath: (relPath: string, isDir: boolean): void => { this.onRenamePath(relPath, isDir); },
          onMovePath: (relPath: string, isDir: boolean): void => { this.onMovePath(relPath, isDir); },
          onDeletePath: (relPath: string, isDir: boolean): void => { this.onDeletePath(relPath, isDir); },
          onSharePath: (relPath: string, isDir: boolean): void => { this.onSharePath(relPath, isDir); },
          onSwipeDelete: (relPath: string): void => { this.onSwipeDelete(relPath); }
        })
          .width('100%')
          .height('100%')
          .visibility(this.referenceOnly || this.sidebarTab === 'files' ? Visibility.Visible : Visibility.Hidden)

        Column() {
          Text(this.currentFilePath.length > 0 ? this.currentFilePath : '未选择笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s2 })
          if (this.chapters.length > 0) {
            List() {
              ForEach(this.chapters, (chapter: ChapterEntry) => {
                ListItem() {
                  Row({ space: Space.s2 }) {
                    Text('H' + chapter.level.toString())
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_tertiary'))
                      .width(Space.s6)
                    Text(chapter.title)
                      .fontSize(chapter.level <= 2 ? FontSize.body2 : FontSize.body3)
                      .fontColor(chapter.index === this.selectedChapterIndex
                        ? $r('app.color.brand') : $r('app.color.text_primary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .height(Size.touch)
                  .padding({ left: Space.s2 + (chapter.level - 1) * Space.s3, right: Space.s3 })
                  .backgroundColor(chapter.index === this.selectedChapterIndex
                    ? $r('app.color.brand_bg') : $r('app.color.bg_page'))
                  .borderRadius(Radius.control)
                  .onClick((): void => { this.onSelectChapter(chapter.index); })
                }
                .width('100%')
              })
            }
            .layoutWeight(1)
            .width('100%')
          } else {
            Column() {
              Text(this.currentFilePath.length > 0 ? '当前笔记没有章节' : '先打开一篇笔记')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .height('100%')
        .visibility(!this.referenceOnly && this.sidebarTab === 'chapters' ? Visibility.Visible : Visibility.Hidden)
      }
      .layoutWeight(1)
      .width('100%')

      if (!this.referenceOnly && !this.compact) {
        Text('← 左滑显示操作；滑到底移入回收站，可撤销')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.RIGHT)
          .padding({ top: Space.s1, left: Space.s4, right: Space.s4, bottom: Space.s3 })

        Row({ space: Space.s2 }) {
          Text('管理库')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_primary'))
            .height(Size.buttonH)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.bg_card'))
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(Radius.control)
            .onClick(() => {
              this.onManageVaults();
            })
          Text('回收站')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_primary'))
            .height(Size.buttonH)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.bg_card'))
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(Radius.control)
            .onClick(() => {
              this.onOpenTrash();
            })
        }
        .width('100%')
        .padding(Space.s3)
        .border({ width: { top: 1 }, color: $r('app.color.line') })
        .backgroundColor($r('app.color.bg_card'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
