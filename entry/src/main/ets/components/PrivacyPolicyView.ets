import { webview } from '@kit.ArkWeb';
import { FontSize, Size, Space } from '../common/Tokens';

const PRIVACY_POLICY_URL: string =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2064689818977197760';

@Component
export struct PrivacyPolicyView {
  onClose: () => void = () => {};

  @State private loadStatus: string = 'loading';
  private controller: webview.WebviewController = new webview.WebviewController();

  private retryLoading(): void {
    this.loadStatus = 'loading';
    try {
      this.controller.loadUrl(PRIVACY_POLICY_URL);
    } catch {
      this.loadStatus = 'failed';
    }
  }

  build() {
    Column() {
      Row({ space: Space.s4 }) {
        Text('‹ 返回关于')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .focusable(true)
          .accessibilityText('返回关于')
          .onClick((): void => { this.onClose(); })
        Text('隐私政策')
          .fontSize(FontSize.s3)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s4, right: Space.s4 })

      Stack() {
        Web({ src: PRIVACY_POLICY_URL, controller: this.controller })
          .javaScriptAccess(true)
          .onPageBegin((): void => {
            this.loadStatus = 'loading';
          })
          .onPageEnd((): void => {
            if (this.loadStatus === 'loading') {
              this.loadStatus = 'loaded';
            }
          })
          .onErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.loadStatus = 'failed';
            }
          })
          .onHttpErrorReceive((event) => {
            if (event.request.isMainFrame()) {
              this.loadStatus = 'failed';
            }
          })
          .onSslErrorEventReceive((event) => {
            event.handler.handleCancel();
            this.loadStatus = 'failed';
          })
          .width('100%')
          .height('100%')

        if (this.loadStatus !== 'loaded') {
          Column({ space: Space.s4 }) {
            Text(this.loadStatus === 'failed' ? '暂时无法加载隐私政策' : '正在加载隐私政策…')
              .fontSize(FontSize.body1)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
            if (this.loadStatus === 'failed') {
              Text('请检查网络连接后重试，或稍后再试。')
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
              Text('重试 ›')
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.brand'))
                .height(Size.touch)
                .focusable(true)
                .accessibilityText('重试加载隐私政策')
                .onClick((): void => { this.retryLoading(); })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding(Space.s5)
          .backgroundColor($r('app.color.bg_page'))
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
