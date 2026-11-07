import { UIUtils } from '@kit.ArkUI';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { shareFailureMessage } from '../model/UserErrorMessages';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

/**
 * ShareFilePreviewDialog.ets —— 分享面板「文件详情」阶段（分享面板设计 §2：
 * 标题「ZIP 分享 / Markdown 分享」，主体＝文件名 + 带图标清单 + 数量信息，
 * 底部＝返回 · 分享文件）。外壳与导入库共用 UtilityDialogShell（§4）。
 */
@CustomDialog
export struct ShareFilePreviewDialog {
  controller?: CustomDialogController;
  @Prop fileName: string = '';
  @Prop format: string = '';
  @Prop itemName: string = '';
  @Prop noteCount: number = 0;
  @Prop imageCount: number = 0;
  @Prop entries: string[] = [];
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  @Prop initialError: string = '';
  @Prop canShare: boolean = true;
  onBack: () => void = () => {};
  onConfirm: () => Promise<void> = async (): Promise<void> => {};
  onRetryPreparation: () => Promise<void> = async (): Promise<void> => {};
  @State sharing: boolean = false;
  @State preparing: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.errorMessage = this.initialError;
  }

  // §2：文件详情标题按实际格式「ZIP 分享 / Markdown 分享」
  private detailTitle(): string {
    return this.format === 'ZIP' ? 'ZIP 分享' : 'Markdown 分享';
  }

  // 摘要行（标题下）：名称 · N 篇笔记 · M 张本地配图
  private headerSummary(): string {
    if (!this.canShare) {
      return '文件准备失败';
    }
    let summary: string = this.itemName + ' · ' + this.noteCount.toString() + ' 篇笔记';
    if (this.imageCount > 0) {
      summary += ' · ' + this.imageCount.toString() + ' 张本地配图';
    }
    return summary;
  }

  // §2 数量信息首段：1 个 ZIP / 1 个 Markdown 文件
  private metaLead(): string {
    return this.format === 'ZIP' ? '1 个 ZIP' : '1 个 Markdown 文件';
  }

  private entryIcon(path: string): string {
    const lower: string = path.toLowerCase();
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') || lower.endsWith('.gif') || lower.endsWith('.svg')) {
      return 'image';
    }
    return 'doc';
  }

  private back(): void {
    this.controller?.close();
    this.onBack();
  }

  private async share(): Promise<void> {
    if (this.sharing) {
      return;
    }
    this.sharing = true;
    this.errorMessage = '';
    try {
      await this.onConfirm();
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
      this.errorMessage = shareFailureMessage(error, 'file_prepare');
    } finally {
      this.preparing = false;
    }
  }

  @Builder
  FileRow(path: string) {
    Row({ space: Space.s3 }) {
      Icon(this.entryIcon(path), Space.s5, $r('app.color.text_secondary'))
      Text(path)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: Space.s10 })
    .padding({ left: Space.s2, right: Space.s2, top: Space.s1, bottom: Space.s1 })
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s4 }) {
      // 预览台面（原型 #sharePreview）：--nav 底、--small-r 圆角、--s4 内边距
      Column({ space: Space.s2 }) {
        Text(this.fileName)
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        if (this.entries.length > 0) {
          // 文件清单（原型 .share-files）：--line 描边卡片、--r 圆角、--s2 内边距、
          // 行高 --s10、图标 --muted，最高 --window-min 一半
          Scroll() {
            Column() {
              ForEach(this.entries, (path: string) => {
                this.FileRow(path)
              }, (path: string) => path)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxHeight: Size.menuMaxH * 0.5 })
          .scrollBar(BarState.Off)
          .padding(Space.s2)
          .border({ width: 1, color: $r('app.color.line') })
          .borderRadius(Radius.menu)
        }
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.bg_secondary'))
      .alignItems(HorizontalAlign.Start)

      // 数量信息（原型 #shareMeta）：首段 --ink/600，其余 --muted/--caption
      if (this.canShare) {
        Row({ space: Space.s3 }) {
          Text(this.metaLead())
            .fontSize(FontSize.caption)
            .fontWeight(600)
            .fontColor($r('app.color.text_primary'))
          Text(this.noteCount.toString() + ' 篇笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
          if (this.imageCount > 0) {
            Text(this.imageCount.toString() + ' 张图片')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
          }
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
      UtilityDialogAction('返回', 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => true), (): void => { this.back(); }, true)
      if (this.canShare) {
        UtilityDialogAction(this.sharing ? '正在打开…' : '分享文件', 'primary',
          this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.sharing),
          (): void => { void this.share(); }, true)
      } else {
        UtilityDialogAction(this.preparing ? '正在重试…' : '重试生成', 'primary',
          this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.preparing),
          (): void => { void this.retryPreparation(); }, true)
      }
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: this.detailTitle(),
      subtitle: this.headerSummary(),
      headerIcon: 'doc',
      closeLabel: '关闭文件预览',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => { this.back(); },
      content: (): void => { this.DialogContent(); },
      footer: (): void => { this.DialogFooter(); }
    })
  }
}
