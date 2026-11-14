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
  /** 当前打开笔记的提示文本，作为 queryText 预填进小艺输入框（仅初始文本，非系统上下文）。 */
  noteHint: string = '';

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
      // queryText 仅在组件实例化时注入，作为输入框初始文本；用户可改可删，
      // 小艺不会将其当作系统级上下文。FunctionComponent 层无 variables/context 注入字段。
      options: {
        title: 'Agent 对话',
        queryText: this.noteHint
      },
      onError: (error: BusinessError): void => {
        hilog.error(DOMAIN, TAG, '小艺 FunctionComponent 错误码 %{public}d', error.code);
        promptAction.showToast({ message: '暂时无法打开小艺' });
      }
    })
  }
}

@Builder
export function AgentKitSlotBuilder(onDialogClosed: () => void, noteHint: string): void {
  AgentKitSlot({ onDialogClosed: onDialogClosed, noteHint: noteHint })
}

export function getAgentKitSlotBuilder(): WrappedBuilder<[() => void, string]> {
  return wrapBuilder(AgentKitSlotBuilder)
}
