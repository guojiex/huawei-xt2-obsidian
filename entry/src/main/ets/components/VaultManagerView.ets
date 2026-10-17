/**
 * VaultManagerView.ets —— 库管理视图（原型 vaultsView 结构）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（T013 接线），自带「返回笔记」。
 * 卡片列表：当前库高亮；每卡「设为当前 / 改名 / 删除」。
 * 铁律：无 Git 导入入口（v0.3）；删除按钮直接拉起不可逆确认对话框（文案在 VaultDialogs）。
 */
import { VaultEntry } from '../model/Vault';

@Component
export struct VaultManagerView {
  /** 库列表（与 Index @State 双向绑定，CRUD 后由 Index 刷新） */
  @Link vaults: VaultEntry[];
  /** 当前库 id（高亮用） */
  @Prop currentVaultId: string = '';
  onBack: () => void = () => {};
  onSetCurrent: (id: string) => void = (id: string) => {};
  onRename: (id: string) => void = (id: string) => {};
  onDelete: (id: string) => void = (id: string) => {};
  onCreate: () => void = () => {};

  build() {
    Scroll() {
      Column() {
        // 返回入口（管理视图自带返回，spec T013）
        Row() {
          Text('‹ 返回笔记')
            .fontSize(12)
            .fontColor('#534AB7')
            .onClick(() => {
              this.onBack();
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 标题「笔记库」只保留在顶栏（2.7b：A 轮顶栏切标题后此处与之重复，删；
        // 原型 2026-10-17 同样删了内容区重复大标题）
        Text('每个库是 vaults/ 下的一个独立目录，各自独立同步')
          .fontSize(12)
          .fontColor('#8E8E93')
          .margin({ top: 4, bottom: 16 })

        // 库卡片列表（当前库高亮，照原型 vcard）
        Column({ space: 10 }) {
          ForEach(this.vaults, (v: VaultEntry) => {
            Column() {
              Row({ space: 8 }) {
                Text(v.id)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#1C1C1E')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text('本地')
                  .fontSize(10)
                  .fontColor('#534AB7')
                  .padding({ left: 6, right: 6 })
                  .borderRadius(20)
                  .border({ width: 1, color: '#534AB7' })
                  .backgroundColor('#EEEDFE')
                if (v.id === this.currentVaultId) {
                  Text('当前')
                    .fontSize(10)
                    .fontColor('#8E8E93')
                    .padding({ left: 6, right: 6 })
                    .borderRadius(20)
                    .border({ width: 1, color: '#E5E5EA' })
                }
              }
              .margin({ bottom: 5 })

              Text('vaults/' + v.id + ' · 不参与同步')
                .fontSize(12)
                .fontColor('#8E8E93')

              // 操作行：设为当前（非当前库才有）/ 改名 / 删除
              Row({ space: 6 }) {
                if (v.id !== this.currentVaultId) {
                  Text('设为当前')
                    .fontSize(12)
                    .fontColor('#1C1C1E')
                    .height(28)
                    .padding({ left: 10, right: 10 })
                    .textAlign(TextAlign.Center)
                    .borderRadius(8)
                    .border({ width: 1, color: '#E5E5EA' })
                    .backgroundColor('#FAFAFC')
                    .onClick(() => {
                      this.onSetCurrent(v.id);
                    })
                }
                Text('改名')
                  .fontSize(12)
                  .fontColor('#1C1C1E')
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .border({ width: 1, color: '#E5E5EA' })
                  .backgroundColor('#FAFAFC')
                  .onClick(() => {
                    this.onRename(v.id);
                  })
                Text('删除')
                  .fontSize(12)
                  .fontColor('#A32D2D')
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .border({ width: 1, color: '#A32D2D' })
                  .backgroundColor('#FCEBEB')
                  .onClick(() => {
                    this.onDelete(v.id);
                  })
              }
              .margin({ top: 9 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(11)
            .border({
              width: 1,
              color: v.id === this.currentVaultId ? '#534AB7' : '#E5E5EA'
            })
            .backgroundColor(v.id === this.currentVaultId ? '#EEEDFE' : '#FFFFFF')
          }, (v: VaultEntry) => v.id)
        }
        .width('100%')
        .margin({ bottom: 14 })

        // 新建入口（无 Git 导入——v0.3 才有）
        Text('+ 新建本地笔记库')
          .fontSize(12)
          .fontColor('#8E8E93')
          .width('100%')
          .padding(14)
          .textAlign(TextAlign.Center)
          .borderRadius(11)
          .border({ width: 1, color: '#E5E5EA', style: BorderStyle.Dashed })
          .onClick(() => {
            this.onCreate();
          })

        // 底部说明（照原型 last 框，去掉 Git 相关行——v0.1 无 Git 库）
        Column() {
          Text('名称即目录名：改名会连 vaults/ 下的目录一起改。')
            .fontSize(12)
            .fontColor('#8E8E93')
          Text('删除语义：本地库连内容永久删除，不可恢复。')
            .fontSize(12)
            .fontColor('#8E8E93')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(10)
        .borderRadius(9)
        .border({ width: 1, color: '#E5E5EA', style: BorderStyle.Dashed })
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 30 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .scrollBar(BarState.Off)
  }
}
