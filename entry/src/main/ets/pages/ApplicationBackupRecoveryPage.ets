/** Fail-closed startup screen shown when an interrupted restore cannot be rolled back safely. */
import { FontSize, Space, Weight } from '../common/Tokens';

@Entry
@Component
struct ApplicationBackupRecoveryPage {
  @StorageProp('applicationBackupRecoveryError') recoveryError: string = '';

  build() {
    Column({ space: Space.s4 }) {
      Text('应用数据恢复尚未完成')
        .fontSize(FontSize.s3)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('应用已暂停打开知识库，避免继续写入处于恢复中的数据。请从系统最近任务中结束应用后重新打开；启动时会继续处理恢复记录。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (this.recoveryError.length > 0) {
        Text(this.recoveryError)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Start)
    .padding(Space.s8)
    .backgroundColor($r('app.color.bg_page'))
  }
}
