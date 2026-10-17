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
  /** 下拉菜单开关（瞬态） */
  @State menuOpen: boolean = false;
  /** 「收起 «」回调（嵌入形态：父级收起侧栏） */
  onCollapse: () => void = () => {};
  /** 切库回调（点下拉菜单中的库项） */
  onSwitchVault: (id: string) => void = (id: string) => {};
  /** 「管理库」回调（父级切换到库管理视图） */
  onManageVaults: () => void = () => {};
  /** 「新建」回调（父级拉起新建对话框） */
  onCreateVault: () => void = () => {};

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

  build() {
    Column() {
      // 头部区：库切换器卡片 + 下拉菜单（Stack 覆盖层，照原型 vault-switch/vault-menu）
      Stack({ alignContent: Alignment.TopStart }) {
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
        .width('100%')
        .height(Size.itemH)
        .padding({ left: Space.s3, right: Space.s3 })
        .margin({ left: Space.s2, right: Space.s2, top: Space.s2 })
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.line') })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.menuOpen = !this.menuOpen;
        })

        // 下拉菜单：列全部库（当前高亮）+ 分隔线 + 「管理库…」（无 Git 导入——v0.3）
        if (this.menuOpen) {
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
              .height(Size.buttonH)
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

            Row() {
              Text('管理库…')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            .height(Size.buttonH)
            .padding({ left: Space.s2, right: Space.s2 })
            .borderRadius(Radius.icon)
            .onClick(() => {
              this.menuOpen = false;
              this.onManageVaults();
            })
          }
          .width('100%')
          .padding(Space.s1)
          .margin({ left: Space.s2, right: Space.s2 })
          .offset({ y: Size.itemH + Space.s3 })
          .borderRadius(Radius.menu)
          .backgroundColor($r('app.color.bg_tertiary'))
          .border({ width: 1, color: $r('app.color.line') })
          .shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 6 })
        }
      }
      .width('100%')

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

      // 树区占位（真实文件树 v0.2 M1 接入）
      Column() {
        Text('文件树 · v0.2')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)

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
        Text('新建')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(Size.buttonH)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(Radius.control)
          .onClick(() => {
            this.onCreateVault();
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
