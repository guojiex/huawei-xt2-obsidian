import { router } from '@kit.ArkUI'

@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('曜石笔记')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 8 })

      Text('先接入 GitHub 笔记库，再开始浏览和编辑')
        .fontSize(13)
        .fontColor('#666666')
        .margin({ bottom: 24 })

      Button('接入 GitHub 笔记库')
        .onClick(() => {
          router.pushUrl({ url: 'pages/SyncPage' })
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
