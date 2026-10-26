import { FontSize, Radius, Size, Space } from '../common/Tokens';

@CustomDialog
export struct RenameAgentSessionDialog {
  controller?: CustomDialogController;
  initialTitle: string = '';
  @State titleDraft: string = '';
  onConfirm: (title: string) => void = (title: string) => {};

  aboutToAppear(): void {
    this.titleDraft = this.initialTitle;
  }

  private confirm(): void {
    const title: string = this.titleDraft.trim();
    if (title.length === 0) {
      return;
    }
    this.controller?.close();
    this.onConfirm(title);
  }

  build() {
    Column({ space: Space.s3 }) {
      Text('重命名对话')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({ text: this.titleDraft, placeholder: '对话名称' })
        .height(Size.touch)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .onChange((value: string): void => { this.titleDraft = value; })
      if (this.titleDraft.trim().length === 0) {
        Text('对话名称不能为空')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      Row({ space: Space.s2 }) {
        Button('取消')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.controller?.close(); })
        Button('保存')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .enabled(this.titleDraft.trim().length > 0)
          .onClick(() => { this.confirm(); })
      }
      .width('100%')
    }
    .width(Size.drawerW)
    .padding(Space.s5)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}

@CustomDialog
export struct DeleteAgentSessionDialog {
  controller?: CustomDialogController;
  title: string = '';
  vaultName: string = '';
  onConfirm: () => void = () => {};

  private confirm(): void {
    this.controller?.close();
    this.onConfirm();
  }

  build() {
    Column({ space: Space.s3 }) {
      Text('删除这段对话？')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('「' + this.title + '」将从知识库“' + this.vaultName + '”中删除。已写入的笔记不会被删除或撤销。此操作无法恢复。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s2 }) {
        Button('取消')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .onClick(() => { this.controller?.close(); })
        Button('删除对话')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.danger_bg'))
          .onClick(() => { this.confirm(); })
      }
      .width('100%')
    }
    .width(Size.drawerW)
    .padding(Space.s5)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}
