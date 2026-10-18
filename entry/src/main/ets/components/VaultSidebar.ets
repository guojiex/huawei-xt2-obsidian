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

@Component
export struct VaultSidebar {
  /** 抽屉形态（sm 覆盖层）：不显示「收起 «」——抽屉关掉即可，无收起语义 */
  asDrawer: boolean = false;
  /** 库列表（与 Index @State 双向绑定，切库/CRUD 后刷新） */
  @Link vaults: VaultEntry[];
  /** 当前库 id（显示名 = 目录名 = id） */
  @Prop currentVaultId: string = '';
  /** 当前打开文件的库内相对路径（父级持有，树只画选中态） */
  @Prop currentFilePath: string = '';
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
  /** 「收起 «」回调（嵌入形态：父级收起侧栏） */
  onCollapse: () => void = () => {};
  /** 切库回调（点下拉菜单中的库项） */
  onSwitchVault: (id: string) => void = (id: string) => {};
  /** 「管理库」回调（父级切换到库管理视图） */
  onManageVaults: () => void = () => {};
  /**
   * 「新建笔记」回调（父级拉起新建笔记对话框）。
   * 原型侧栏底部的「新建」在这里落成**新建笔记** —— 新建库要去「库管理」页，
   * 那里本来就有「+ 新建本地笔记库」入口（原型 index.html #newLocal），两处不重复摆。
   */
  onCreateNote: () => void = () => {};
  /** 选中文件回调（向父级传递，由父级决定编辑器行为） */
  onSelectFile: (relPath: string) => void = (relPath: string) => {};

  /** 胶囊标签（本地 / 当前）—— 圆角 chip 场景 */
  @Builder
  Tag(text: string, active: boolean) {
    Text(text)
      .fontSize(FontSize.caption)
      .fontColor(active ? $r('app.color.brand') : $r('app.color.text_tertiary'))
      .padding({ left: Space.s2, right: Space.s2 })
      .borderRadius(Radius.chip)
      .border({ width: 1, color: active ? $r('app.color.brand') : $r('app.color.line') })
  }

  /**
   * 库切换下拉菜单内容（照原型 vault-menu：库项 + 分隔线 + 「管理库…」）。
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
            .fontSize(FontSize.body3)
            .fontColor(v.id === this.currentVaultId
              ? $r('app.color.brand') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.Tag('本地', v.id === this.currentVaultId)
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s2, right: Space.s2 })
        .borderRadius(Radius.icon)
        .backgroundColor(v.id === this.currentVaultId
          ? $r('app.color.brand_bg_solid') : Color.Transparent)
        .onClick(() => {
          this.menuOpen = false;
          this.onSwitchVault(v.id);
        })
      }, (v: VaultEntry) => v.id)

      Divider()
        .color($r('app.color.line'))
        .margin({ top: Space.s1, bottom: Space.s1 })

      Row({ space: Space.s2 }) {
        Icon('folder', 16, $r('app.color.text_secondary'))
        Text('管理库…')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s2, right: Space.s2 })
      .borderRadius(Radius.icon)
      .onClick(() => {
        this.menuOpen = false;
        this.onManageVaults();
      })
    }
    .width(Size.sidebarW)
    .padding(Space.s1)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 6 })
  }

  build() {
    Column() {
      // 头部区外包一层：水平 padding 做「卡片离侧栏边缘」的视觉 inset。
      // ⚠️ inset 不能写在卡片自己的 margin 上再配 width('100%')：ArkUI 的百分比取父级
      // 内容盒的 100%，margin 加在盒外 → 卡片实际占宽 = 侧栏宽 + 2×margin，右缘越过
      // 栏间分隔线伸进编辑区（2026-10-18 用户实测）。外包层 padding 在盒内，天然不溢出。
      Column() {
        // 库切换器卡片（点击弹出库列表，见 VaultMenu）
        Row({ space: Space.s2 }) {
          Icon('folder', 18, $r('app.color.text_secondary'))
          Column({ space: 2 }) {
            Text(this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('vaults/' + this.currentVaultId)
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
        .height(Size.itemH)
        .padding({ left: Space.s3, right: Space.s3 })
        .margin({ top: Space.s2 })
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.line') })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.menuOpen = !this.menuOpen;
        })
        // 下拉菜单：弹层挂窗口覆盖层（高于文件树），列全部库（当前高亮）+ 分隔线 + 「管理库…」
        .bindPopup(this.menuOpen, {
          builder: this.VaultMenu(),
          placement: Placement.BottomLeft,
          // 卡片左缘与侧栏左缘相距外包层 padding（s2），弹层贴卡片左缘 → offset 只补下间距
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
      .padding({ left: Space.s2, right: Space.s2 })

      // 目录头：标签 + 收起入口（收起只在嵌入形态有意义，照原型 side-head）
      Row() {
        Text('目录')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        if (!this.asDrawer) {
          // 热区补足 48（v0.1 遗留缺陷：原热区约 16vp）
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

      // 真实文件树（v0.2 M1 需求 1.1–1.5）。
      // 当前文件由父级持有并在两处之间传递：折叠父目录不会连带清掉它（需求 1.4）。
      FileTreeView({
        vaultId: this.currentVaultId,
        currentFilePath: this.currentFilePath,
        refreshSeq: this.refreshSeq,
        revealPath: this.revealPath,
        onSelectFile: (relPath: string): void => {
          this.onSelectFile(relPath);
        }
      })
        .layoutWeight(1)
        .width('100%')

      // 底部：「管理库 / 新建」入口（照原型 side-foot）
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
        Text('新建笔记')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(Size.buttonH)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(Radius.control)
          .onClick(() => {
            this.onCreateNote();
          })
      }
      .width('100%')
      .padding(Space.s3)
      .border({ width: { top: 1 }, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
