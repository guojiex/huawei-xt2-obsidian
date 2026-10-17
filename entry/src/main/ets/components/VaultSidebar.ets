/**
 * VaultSidebar.ets —— 侧栏（v0.1）
 *
 * 两种挂载形态：
 *  - 嵌入（md/lg）：作为 Index Row 子项随断点等分宽（layoutWeight 由父级控制）；
 *  - 抽屉（sm）：Stack 覆盖层，显隐与遮罩由 Index 控制（asDrawer = true）。
 * 结构照原型 sidebar：库切换器头部（下拉列库，当前项高亮）→ 目录头（「收起 «」入口）
 * → 树区占位（v0.2）→ 底部「管理库」。
 * 切库/列表刷新：数据源是 Index 的 @State（经 @Link/@Prop 下传），CRUD 后由 Index 统一刷新。
 */
import { VaultEntry } from '../model/Vault';

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

  build() {
    Column() {
      // 头部区：库切换器卡片 + 下拉菜单（Stack 覆盖层，照原型 vault-switch/vault-menu）
      Stack({ alignContent: Alignment.TopStart }) {
        Row({ space: 7 }) {
          Text('▤')
            .fontSize(13)
            .fontColor('#8E8E93')
          Column() {
            Text(this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1C1C1E')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('vaults/' + this.currentVaultId)
              .fontSize(11)
              .fontColor('#8E8E93')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.menuOpen ? '▴' : '▾')
            .fontSize(10)
            .fontColor('#8E8E93')
        }
        .width('100%')
        .padding(10)
        .margin(8)
        .borderRadius(9)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E5E5EA' })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.menuOpen = !this.menuOpen;
        })

        // 下拉菜单：列全部库（当前高亮）+ 分隔线 + 「管理库…」（无 Git 导入——v0.3）
        if (this.menuOpen) {
          Column() {
            ForEach(this.vaults, (v: VaultEntry) => {
              Row({ space: 7 }) {
                Text(v.id)
                  .fontSize(12)
                  .fontColor(v.id === this.currentVaultId ? '#534AB7' : '#1C1C1E')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text('本地')
                  .fontSize(10)
                  .fontColor(v.id === this.currentVaultId ? '#534AB7' : '#8E8E93')
                  .padding({ left: 6, right: 6 })
                  .borderRadius(20)
                  .border({
                    width: 1,
                    color: v.id === this.currentVaultId ? '#534AB7' : '#E5E5EA'
                  })
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(7)
              .backgroundColor(v.id === this.currentVaultId ? '#EEEDFE' : '#FFFFFF')
              .onClick(() => {
                this.menuOpen = false;
                this.onSwitchVault(v.id);
              })
            }, (v: VaultEntry) => v.id)

            Divider()
              .color('#E5E5EA')
              .margin({ left: 4, right: 4, top: 4, bottom: 4 })

            Row() {
              Text('管理库…')
                .fontSize(12)
                .fontColor('#1C1C1E')
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .borderRadius(7)
            .onClick(() => {
              this.menuOpen = false;
              this.onManageVaults();
            })
          }
          .width('100%')
          .margin(8)
          .offset({ y: 62 })
          .padding(4)
          .borderRadius(9)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E5E5EA' })
        }
      }
      .width('100%')

      // 目录头：标签 + 收起入口（收起只在嵌入形态有意义，照原型 side-head）
      Row() {
        Text('目录')
          .fontSize(12)
          .fontColor('#8E8E93')
        Blank()
        if (!this.asDrawer) {
          Text('收起 «')
            .fontSize(11)
            .fontColor('#8E8E93')
            .padding({ left: 4, right: 4 })
            .borderRadius(5)
            .onClick(() => {
              this.onCollapse();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })

      // 树区占位（真实文件树 v0.2 接入）
      Column() {
        Text('文件树 · v0.2')
          .fontSize(14)
          .fontColor('#8E8E93')
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 底部：「管理库」入口（照原型 side-foot）
      Row() {
        Text('管理库')
          .fontSize(12)
          .fontColor('#1C1C1E')
          .height(32)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E5E5EA' })
          .borderRadius(8)
          .onClick(() => {
            this.onManageVaults();
          })
      }
      .width('100%')
      .padding(8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFC')
  }
}
