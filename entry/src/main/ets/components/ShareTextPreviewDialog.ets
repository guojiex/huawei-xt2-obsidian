import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

@CustomDialog
export struct ShareTextPreviewDialog {
  controller?: CustomDialogController;
  itemName: string = '';
  initialContent: string = '';
  limitations: string[] = [];
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  initialError: string = '';
  onRetryPreparation: () => Promise<void> = async (): Promise<void> => {};
  onBack: () => void = () => {};
  onConfirm: (content: string) => Promise<void> =
    async (content: string): Promise<void> => {};
  @State contentDraft: string = '';
  @State sharing: boolean = false;
  @State preparing: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.contentDraft = this.initialContent;
    this.errorMessage = this.initialError;
  }

  private back(): void {
    this.controller?.close();
    this.onBack();
  }

  private async confirm(): Promise<void> {
    if (this.sharing) {
      return;
    }
    this.sharing = true;
    this.errorMessage = '';
    try {
      await this.onConfirm(this.contentDraft);
    } catch (error) {
      this.errorMessage = shareFailureMessage(error, 'handoff');
    } finally {
      this.sharing = false;
    }
  }

  private async retryPreparation(): Promise<void> {
    if (this.preparing) {
      return;
    }
    this.preparing = true;
    this.errorMessage = '';
    try {
      await this.onRetryPreparation();
    } catch (error) {
      this.errorMessage = shareFailureMessage(error, 'text_prepare');
    } finally {
      this.preparing = false;
    }
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s3 }) {
      Text(this.itemName)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('可编辑将要交接的纯文本；此处修改不会写回笔记。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextArea({ text: this.contentDraft, placeholder: '纯文本内容' })
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .padding(Space.s3)
        .height(Size.drawerW * 0.58)
        .borderRadius(Radius.control)
        .border({ width: 1, color: $r('app.color.line') })
        .onChange((value: string): void => {
          this.contentDraft = value;
        })
      if (this.limitations.length > 0) {
        Column({ space: Space.s1 }) {
          ForEach(this.limitations, (limitation: string, index: number) => {
            Text('• ' + limitation)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }, (limitation: string, index: number) => index.toString())
        }
        .width('100%')
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s3 }) {
      UtilityDialogAction('返回格式选择', 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.back();
        }, true)
      UtilityDialogAction(
        this.initialError.length > 0
          ? (this.preparing ? '正在重试…' : '重试获取文本')
          : (this.sharing ? '正在打开…' : '分享文本'),
        'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => !this.sharing && !this.preparing),
        (): void => {
          if (this.initialError.length > 0) {
            void this.retryPreparation();
          } else {
            void this.confirm();
          }
        }, true)
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '文本分享',
      subtitle: this.itemName,
      headerIcon: 'message',
      closeLabel: '关闭文本预览',
      singleScreen: this.singleScreen,
      scrollContent: true,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => {
        this.back();
      },
      content: (): void => {
        this.DialogContent();
      },
      footer: (): void => {
        this.DialogFooter();
      }
    })
  }
}
