/** Explicit confirmation for the v0.5 data reset. */
import { Space, Radius, FontSize, Size } from '../common/Tokens';

@CustomDialog
export struct ResetDataDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = () => {};
  @State confirmation: string = '';

  build() {
    Column({ space: Space.s3 }) {
      Text('重置所有数据？')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('所有本地笔记库、草稿、回收站、最近打开、同步配置和访问令牌都会被清除，且无法恢复。远端仓库不会被修改。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text('应用会关闭。重新打开后恢复首次安装的样例笔记库，应用授权也会重置。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: this.confirmation, placeholder: '输入“重置”以确认' })
        .height(Size.touch)
        .fontSize(FontSize.body1)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .onChange((value: string) => { this.confirmation = value; })
      Row({ space: Space.s2 }) {
        Button('取消')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(Radius.button)
          .onClick(() => { this.controller?.close(); })
        Button('确认重置')
          .layoutWeight(1)
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.danger_bg'))
          .borderRadius(Radius.button)
          .enabled(this.confirmation === '重置')
          .onClick(() => {
            if (this.confirmation !== '重置') {
              return;
            }
            this.controller?.close();
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .padding(Space.s5)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
  }
}
