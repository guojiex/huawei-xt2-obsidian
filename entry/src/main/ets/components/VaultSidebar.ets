/**
 * VaultSidebar.ets —— 侧栏骨架（v0.1）
 *
 * 两种挂载形态：
 *  - 嵌入（md/lg）：作为 Index Row 子项随断点等分宽（layoutWeight 由父级控制）；
 *  - 抽屉（sm）：Stack 覆盖层，显隐与遮罩由 Index 控制（asDrawer = true）。
 * 结构照原型 sidebar：库切换器头部 → 目录头（「收起 «」入口）→ 树区占位（v0.2）→ 底部「管理库」。
 * 树区/切换器下拉为 v0.2 / T010 接线，此处先落骨架与回调链路。
 */
@Component
export struct VaultSidebar {
  /** 抽屉形态（sm 覆盖层）：不显示「收起 «」——抽屉关掉即可，无收起语义 */
  asDrawer: boolean = false;
  /** 当前库 id（显示名 = 目录名 = id） */
  @Prop currentVaultId: string = '';
  /** 「收起 «」回调（嵌入形态：父级收起侧栏） */
  onCollapse: () => void = () => {};
  /** 「管理库」回调（父级切换到库管理视图） */
  onManageVaults: () => void = () => {};

  build() {
    Column() {
      // 头部区：库切换器卡片（T010 接线下拉菜单；先展示当前库与路径）
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
        Text('▾')
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
