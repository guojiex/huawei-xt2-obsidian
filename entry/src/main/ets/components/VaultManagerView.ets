/**
 * VaultManagerView.ets —— 库管理视图（原型 vaultsView 结构，v0.2 §3.5 token 化）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（T013 接线）。
 * 返回走 Index 顶栏返回箭头（2.7 硬要求，2.7c 起本组件不再自带返回入口）。
 * 卡片列表：当前库高亮；每卡「设为当前 / 改名 / 删除或解除关联」。
 * v1.5：本地目录库与沙箱库并列显示；「导入库」入口由 Index 拉起统一来源对话框。
 *
 * 视觉：token 化 + **内容页限宽 760vp 居中**（需求 4.9 —— 三屏 1061vp 下不把设置项拉成一整行）。
 */
import { VaultEntry } from '../model/Vault';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

export interface VaultManagerShareSummary {
  vaultId: string;
  noteCount: number;
}

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
  @Prop shareSummaries: VaultManagerShareSummary[] = [];
  onSetCurrent: (id: string) => void = (id: string) => {};
  onShare: (id: string, focusId: string) => void = (id: string, focusId: string) => {};
  onRename: (id: string) => void = (id: string) => {};
  onDelete: (id: string) => void = (id: string) => {};
  onCreate: () => void = () => {};
  onImportVault: () => void = () => {};

  private vaultHasNoNotes(vaultId: string): boolean {
    for (let i: number = 0; i < this.shareSummaries.length; i++) {
      if (this.shareSummaries[i].vaultId === vaultId) {
        return this.shareSummaries[i].noteCount === 0;
      }
    }
    return false;
  }

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
          Text('每个库在应用中独立管理')
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
                  this.Tag(v.rootKind === 'external' ? '本地目录' : (v.type === 'git' ? 'Git' : '本地'),
                    v.rootKind === 'external' || v.type !== 'git')
                  if (v.id === this.currentVaultId) {
                    this.Tag('当前', false)
                  }
                }
                .width('100%')

                Text(v.rootKind === 'external'
                  ? '已关联原目录 · 直接读写，不复制文件'
                  : 'vaults/' + v.id + (v.type === 'git' ? ' · Git 仓库' : ' · 不参与同步'))
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .margin({ top: Space.s1 })

                // 操作行：设为当前（非当前库才有）/ 分享 / 改名 / 删除
                Row({ space: Space.s2 }) {
                  if (v.id !== this.currentVaultId) {
                    Text('设为当前')
                      .actionBtn($r('app.color.text_primary'))
                      .onClick(() => {
                        this.onSetCurrent(v.id);
                      })
                  }
                  Text('分享')
                    .actionBtn(this.vaultHasNoNotes(v.id)
                      ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
                    .padding({ left: Space.s2, right: Space.s2 })
                    .enabled(!this.vaultHasNoNotes(v.id))
                    .focusable(!this.vaultHasNoNotes(v.id))
                    .id('vault-manager-share-' + v.id)
                    .accessibilityText(this.vaultHasNoNotes(v.id)
                      ? '分享知识库，已禁用，这个库还没有笔记' : '分享知识库')
                    .onClick(() => {
                      this.onShare(v.id, 'vault-manager-share-' + v.id);
                    })
                  Text('改名')
                    .actionBtn($r('app.color.text_primary'))
                    .onClick(() => {
                      this.onRename(v.id);
                    })
                  Text(v.rootKind === 'external' ? '解除关联' : '删除')
                    .actionBtn(v.rootKind === 'external'
                      ? $r('app.color.text_primary') : $r('app.color.danger'))
                    .backgroundColor(v.rootKind === 'external'
                      ? $r('app.color.bg_secondary') : $r('app.color.danger_bg'))
                    .onClick(() => {
                      this.onDelete(v.id);
                    })
                }
                .width('100%')
                .margin({ top: Space.s3 })
                if (this.vaultHasNoNotes(v.id)) {
                  Text('这个库还没有笔记')
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                    .margin({ top: Space.s1 })
                }
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

          // 本地库新建与两种来源统一导入入口
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

          Text('+ 导入库')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .height(Size.itemH)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.card)
            .border({ width: 1, color: $r('app.color.line_strong'), style: BorderStyle.Dashed })
            .margin({ top: Space.s2 })
            .onClick(() => { this.onImportVault(); })

          // 解除关联只移除 App 记录，外部目录和原文件保留
          Column({ space: Space.s1 }) {
            Text('本地库改名会改 vaults/ 目录名；外部库改名只改 App 内显示名称。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
            Text('删除本地库会清除其内容；解除外部目录关联会保留原目录与文件。')
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
