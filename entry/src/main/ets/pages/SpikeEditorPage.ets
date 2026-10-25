import { router } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { FontSize, Size, Space } from '../common/Tokens'

@Entry
@Component
struct SpikeEditorPage {
  private controller: webview.WebviewController = new webview.WebviewController()

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(FontSize.body1)
          .onClick(() => router.back())
        Text('M0.5 输入法对照')
          .fontSize(FontSize.body1)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(Size.appbarH)
      .padding({ left: Space.s3, right: Space.s3 })

      Web({
        src: $rawfile('spike_editor/index.html'),
        controller: this.controller,
        renderMode: RenderMode.SYNC_RENDER
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
