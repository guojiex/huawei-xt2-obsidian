import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FunctionComponent, FunctionController } from '@kit.AgentFrameworkKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AgentKitSlot';
const XIAOYI_AGENT_ID: string = 'agentb21117de704941b3ba497bd5de94f6ad';

@Component
struct AgentKitSlot {
  onDialogClosed: () => void = (): void => {};

  private controller: FunctionController = new FunctionController();
  private readonly dialogClosedListener = (): void => {
    this.onDialogClosed();
  };

  aboutToAppear(): void {
    this.controller.off('agentDialogClosed', this.dialogClosedListener);
    this.controller.on('agentDialogClosed', this.dialogClosedListener);
  }

  aboutToDisappear(): void {
    this.controller.off('agentDialogClosed', this.dialogClosedListener);
  }

  build() {
    FunctionComponent({
      agentId: XIAOYI_AGENT_ID,
      controller: this.controller,
      options: { title: 'Agent 对话' },
      onError: (error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, '小艺 FunctionComponent 错误码 %{public}d', error.code);
        promptAction.showToast({ message: '暂时无法打开小艺' });
      }
    })
  }
}

@Builder
export function AgentKitSlotBuilder(onDialogClosed: () => void): void {
  AgentKitSlot({ onDialogClosed: onDialogClosed })
}

export function getAgentKitSlotBuilder(): WrappedBuilder<[() => void]> {
  return wrapBuilder(AgentKitSlotBuilder)
}
