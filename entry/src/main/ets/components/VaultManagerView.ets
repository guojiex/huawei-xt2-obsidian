/**
 * VaultManagerView.ets —— 库管理视图（原型 vaultsView 结构，v0.2 §3.5 token 化）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（T013 接线）。
 * 返回走 Index 顶栏返回箭头（2.7 硬要求，2.7c 起本组件不再自带返回入口）。
 * 卡片列表：当前库高亮；每卡「设为当前 / 改名 / 删除」。
 * 铁律：无 Git 导入入口（v0.3）；删除按钮直接拉起不可逆确认对话框（文案在 VaultDialogs）。
 *
 * 视觉：token 化 + **内容页限宽 760vp 居中**（需求 4.9 —— 三屏 1061vp 下不把设置项拉成一整行）。
 */
import { VaultEntry } from '../model/Vault';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

/** 小操作按钮的统一样式参数（高度 40 = 可点但有分量，圆角 control） */
@Extend(Text)
function actionBtn(tone: ResourceColor) {
  .fontSize(FontSize.body3)
  .fontColor(tone)
  .height(Size.buttonH)
  .padding({ left: Space.s3, right: Space.s3 })
  .textAlign(TextAlign.Center)
  .borderRadius(Radius.control)
  .backgroundColor($r('app.color.bg_secondary'))
}

@Component
export struct VaultManagerView {
  /** 库列表（与 Index @State 双向绑定，CRUD 后由 Index 刷新） */
  @Link vaults: VaultEntry[];
  /** 当前库 id（高亮用） */
  @Prop currentVaultId: string = '';
  onSetCurrent: (id: string) => void = (id: string) => {};
  onRename: (id: string) => void = (id: string) => {};
  onDelete: (id: string) => void = (id: string) => {};
  onCreate: () => void = () => {};

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
    Scroll() {
      Column() {
        // 返回入口已删（2.7c）；标题「笔记库」只保留在顶栏（2.7b）。
        Column() {
          Text('每个库是 vaults/ 下的一个独立目录，各自独立同步')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ bottom: Space.s4 })

          // 库卡片列表（当前库高亮，照原型 vcard）
          Column({ space: Space.s3 }) {
            ForEach(this.vaults, (v: VaultEntry) => {
              Column() {
                Row({ space: Space.s2 }) {
                  Text(v.id)
                    .fontSize(FontSize.body1)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  this.Tag('本地', true)
                  if (v.id === this.currentVaultId) {
                    this.Tag('当前', false)
                  }
                }
                .width('100%')

                Text('vaults/' + v.id + ' · 不参与同步')
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .margin({ top: Space.s1 })

                // 操作行：设为当前（非当前库才有）/ 改名 / 删除
                Row({ space: Space.s2 }) {
                  if (v.id !== this.currentVaultId) {
                    Text('设为当前')
                      .actionBtn($r('app.color.text_primary'))
                      .onClick(() => {
                        this.onSetCurrent(v.id);
                      })
                  }
                  Text('改名')
                    .actionBtn($r('app.color.text_primary'))
                    .onClick(() => {
                      this.onRename(v.id);
                    })
                  Text('删除')
                    .actionBtn($r('app.color.danger'))
                    .backgroundColor($r('app.color.danger_bg'))
                    .onClick(() => {
                      this.onDelete(v.id);
                    })
                }
                .width('100%')
                .margin({ top: Space.s3 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(Space.s4)
              .borderRadius(Radius.card)
              .border({
                width: 1,
                color: v.id === this.currentVaultId
                  ? $r('app.color.brand') : $r('app.color.line')
              })
              .backgroundColor(v.id === this.currentVaultId
                ? $r('app.color.brand_bg_solid') : $r('app.color.bg_card'))
            }, (v: VaultEntry) => v.id)
          }
          .width('100%')
          .margin({ bottom: Space.s4 })

          // 新建入口（无 Git 导入——v0.3 才有）
          Text('+ 新建本地笔记库')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .height(Size.itemH)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.card)
            .border({ width: 1, color: $r('app.color.line_strong'), style: BorderStyle.Dashed })
            .onClick(() => {
              this.onCreate();
            })

          // 底部说明（照原型 last 框，去掉 Git 相关行——v0.1 无 Git 库）
          Column({ space: Space.s1 }) {
            Text('名称即目录名：改名会连 vaults/ 下的目录一起改。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
            Text('删除语义：本地库连内容永久删除，不可恢复。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.s4)
          .borderRadius(Radius.card)
          .backgroundColor($r('app.color.bg_secondary'))
          .margin({ top: Space.s4 })
        }
        // 需求 4.9：内容页限宽 760vp 居中
        .width('100%')
        .constraintSize({ maxWidth: Size.contentMaxW })
      }
      .width('100%')
      .padding({ left: Space.s5, right: Space.s5, top: Space.s5, bottom: Space.s8 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.bg_page'))
    .scrollBar(BarState.Off)
  }
}
