/**
 * MarkdownFileOpenPage.ets —— v1.89：系统打开 .md 的只读预览页。
 *
 * 由 MarkdownViewAbility 在 viewData 拉起时 loadContent 到本页：不依赖任何笔记库，
 * 只读渲染 want 里那个文件的内容（载荷经 AppStorage['markdownFileOpen'] 传入）。
 * 复用 v1.74 TrashPreviewWeb（只读 setContent、外链走系统、主题随 appTheme）；
 * 不注册编辑桥、不 setEditable(true)、无保存 / 入库 / 下载入口（89.4 只读语义）。
 */
import { common } from '@kit.AbilityKit';
import { FontSize, Space, Weight } from '../common/Tokens';
import { TrashPreviewWeb } from '../components/PreviewWebView';
import { MarkdownOpenService, MarkdownOpenPayload } from '../model/MarkdownOpenService';

@Entry
@Component
struct MarkdownFileOpenPage {
  @StorageProp('markdownFileOpen') @Watch('onPayloadChanged') payloadJson: string = '';
  @State private payload: MarkdownOpenPayload | null = null;

  aboutToAppear(): void {
    // 兜早到：载荷可能在页面挂载前已写入 AppStorage。
    this.consumePayload();
  }

  onPayloadChanged(): void {
    // 兜晚到：热启动 / 异步读文件完成后写入。
    this.consumePayload();
  }

  private consumePayload(): void {
    const parsed: MarkdownOpenPayload | null = MarkdownOpenService.deserialize(this.payloadJson);
    if (parsed !== null) {
      this.payload = parsed;
    }
  }

  /** 只读页退出即结束本 ability，不留状态、不改源文件。 */
  private close(): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.terminateSelf();
  }

  @Builder
  HeaderBar() {
    Row() {
      Text(this.payload?.fileName ?? 'Markdown 预览')
        .fontSize(FontSize.body2)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('只读')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ right: Space.s3 })
      Text('关闭')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.brand'))
        .onClick(() => this.close())
        .accessibilityText('关闭预览')
    }
    .width('100%')
    .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    Column() {
      this.HeaderBar()
      if (this.payload === null) {
        Column() {
          Text('正在读取文件…')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.payload.state === MarkdownOpenService.STATE_ERROR) {
        Column({ space: Space.s2 }) {
          Text('无法预览该文件')
            .fontSize(FontSize.body1)
            .fontColor($r('app.color.text_primary'))
          Text(this.payload.message)
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(Space.s4)
      } else {
        if (this.payload.state === MarkdownOpenService.STATE_TRUNCATED) {
          Text(this.payload.message)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: Space.s4, right: Space.s4, top: Space.s2, bottom: Space.s2 })
        }
        TrashPreviewWeb({ markdown: this.payload.content })
          .width('100%')
          .layoutWeight(1)
          .accessibilityText('Markdown 文件内容，只读预览')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
