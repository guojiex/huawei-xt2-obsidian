import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ButtonType as AgentButtonType, FunctionComponent, FunctionController } from '@kit.AgentFrameworkKit';
import { FontSize, Radius, Size, Space } from '../common/Tokens';

const DOMAIN: number = 0x0000;
const TAG: string = 'AgentKitPage';
const XIAOYI_AGENT_ID: string = 'agentb21117de704941b3ba497bd5de94f6ad';

@Entry
@Component
struct AgentKitPage {
  @State private isChecking: boolean = true;
  @State private agentSupported: boolean = false;
  @State private checkFailed: boolean = false;

  private controller: FunctionController = new FunctionController();
  private readonly xiaoyiDialogClosedListener = (): void => {
    router.back();
  };

  aboutToAppear(): void {
    this.controller.off('agentDialogClosed', this.xiaoyiDialogClosedListener);
    this.controller.on('agentDialogClosed', this.xiaoyiDialogClosedListener);
    void this.checkAgentSupport();
  }

  aboutToDisappear(): void {
    this.controller.off('agentDialogClosed', this.xiaoyiDialogClosedListener);
  }

  private async checkAgentSupport(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.agentSupported = await this.controller.isAgentSupport(context, XIAOYI_AGENT_ID);
    } catch (error) {
      const err = error as BusinessError;
      this.checkFailed = true;
      hilog.error(DOMAIN, TAG, '检查小艺支持状态失败，错误码 %{public}d', err.code);
    } finally {
      this.isChecking = false;
    }
  }

  build() {
    Column({ space: Space.s4 }) {
      Row() {
        Button('返回')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .height(Size.touch)
          .padding({ left: Space.s3, right: Space.s3 })
          .borderRadius(Radius.full)
          .backgroundColor($r('app.color.bg_card'))
          .onClick((): void => {
            router.back();
          })
        Text('Agent 对话')
          .fontSize(FontSize.body1)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(Size.appbarH)
      .padding({ left: Space.s3, right: Space.s3 })
      .border({ width: { bottom: 1 }, color: $r('app.color.line') })

      if (this.isChecking) {
        Text('正在检查小艺能力…')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
      } else if (this.checkFailed) {
        Text('暂时无法检查小艺能力，请稍后重试')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
      } else if (!this.agentSupported) {
        Text('当前设备或账号暂不支持此智能体')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
      } else {
        FunctionComponent({
          agentId: XIAOYI_AGENT_ID,
          controller: this.controller,
          options: {
            title: 'Agent 对话',
            titleFontSize: FontSize.body2,
            iconSize: Space.s5,
            iconColors: [$r('app.color.brand')],
            titleColors: [$r('app.color.brand')],
            backgroundColor: $r('app.color.brand_bg'),
            buttonType: AgentButtonType.CAPSULE,
            controlSize: ControlSize.NORMAL,
            isShowShadow: false
          },
          onError: (error: BusinessError): void => {
            hilog.error(DOMAIN, TAG, '小艺 FunctionComponent 错误码 %{public}d', error.code);
            promptAction.showToast({ message: '暂时无法打开小艺' });
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Space.s3, right: Space.s3, bottom: Space.s3 })
    .backgroundColor($r('app.color.bg_page'))
  }
}
