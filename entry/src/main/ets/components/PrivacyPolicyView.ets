import { webview } from '@kit.ArkWeb';
import { FontSize, Size, Space } from '../common/Tokens';
import { pageGutter } from '../model/PageGutter';

const PRIVACY_POLICY_URL: string =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2064689818977197760';

@Component
export struct PrivacyPolicyView {
  onClose: () => void = () => {};

  // 一多缩进：顶栏左右留白随断点放大；正文由远端网页自身响应式排版
  @StorageProp('breakpoint') breakpoint: string = 'sm';
  @StorageProp('windowHeightVp') windowHeightVp: number = 0;

  private headerGutter(): number {
    return pageGutter(this.breakpoint, this.windowHeightVp, Space.s4);
  }

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
      .padding({ left: this.headerGutter(), right: this.headerGutter() })

      Stack() {
        Web({ src: PRIVACY_POLICY_URL, controller: this.controller })
          // v1.86 86.1：Web 默认 OverScrollMode.NEVER 无过滚动反馈（api_notes AJ1）。
          .overScrollMode(OverScrollMode.ALWAYS)
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
