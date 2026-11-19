/**
 * MarkdownFileOpenPage.ets —— v1.89：系统打开 .md 的只读预览页。
 *
 * 由 MarkdownViewAbility 在 viewData 拉起时 loadContent 到本页：不依赖任何笔记库，
 * 只读渲染 want 里那个文件的内容（载荷经 AppStorage['markdownFileOpen'] 传入）。
 * 复用 v1.74 TrashPreviewWeb（只读 setContent、外链走系统、主题随 appTheme）；
 * 不注册编辑桥、不 setEditable(true)、无保存 / 入库 / 下载入口（89.4 只读语义）。
 */
import { common } from '@kit.AbilityKit';
import { FontSize, Size, Space } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { TrashPreviewWeb } from '../components/PreviewWebView';
import { MarkdownOpenService, MarkdownOpenPayload } from '../model/MarkdownOpenService';

@Entry
@Component
struct MarkdownFileOpenPage {
  @StorageProp('markdownFileOpen') @Watch('onPayloadChanged') payloadJson: string = '';
  @State private payload: MarkdownOpenPayload | null = null;
  // 与主应用 Index 同款断点消费：顶栏高度 / gutter 随窗口档位变化（观感一致，仍免库）。
  @StorageProp('breakpoint') breakpoint: string = 'sm';
  @StorageProp('windowHeightVp') windowHeightVp: number = 0;

  /** 顶栏高度：sm / 矮屏 56vp，其余 72vp（对齐 Index.appbarHeightVp）。 */
  private appbarHeightVp(): number {
    return this.breakpoint === 'sm' || (this.windowHeightVp > 0 && this.windowHeightVp < 480)
      ? Size.appbarH : Size.appbarWideH;
  }

  /** 左右 gutter：sm / 矮屏 s2，md s3，lg s5（对齐 Index.workspaceGutter）。 */
  private workspaceGutter(): number {
    if (this.breakpoint === 'sm' || (this.windowHeightVp > 0 && this.windowHeightVp < 480)) {
      return Space.s2;
    }
    return this.breakpoint === 'md' ? Space.s3 : Space.s5;
  }

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

  /** 顶栏同款 Index.Appbar：返回图标 + 库名位（此处为文件名）+ 右侧只读标记，token 全部复用。 */
  @Builder
  HeaderBar() {
    Row() {
      // 左侧返回按钮：48vp 热区 / 22vp 图标，与 Index.IconButton('back') 同款观感。
      Row() {
        Icon('back', Space.s5 + Space.s1, $r('app.color.text_primary'))
      }
      .width(Size.touch)
      .height(Size.touch)
      .justifyContent(FlexAlign.Center)
      .onClick(() => this.close())
      .accessibilityText('关闭预览')
      // 标题位：对齐 Index 次级视图标题（body1 / Medium / text_primary / 省略）。
      Text(this.payload?.fileName ?? 'Markdown 预览')
        .fontSize(FontSize.body1)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Space.s2, right: Space.s2 })
      // 只读标记：替代主应用顶栏右侧图标位。
      Text('只读')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ right: Space.s1 })
    }
    .width('100%')
    .height(this.appbarHeightVp())
    .padding({ left: this.workspaceGutter(), right: this.workspaceGutter() })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
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
