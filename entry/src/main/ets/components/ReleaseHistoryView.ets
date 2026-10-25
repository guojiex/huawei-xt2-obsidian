/** Full offline version history; Index owns its title and back navigation. */
import { CHANGELOG_ENTRIES } from '../model/ChangelogData';
import { ChangelogList } from './ChangelogList';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

@Component
export struct ReleaseHistoryView {
  build() {
    Scroll() {
      Column({ space: Space.s4 }) {
        Text('这里包含开发阶段记录；只有标记“已发布”的版本表示正式发布。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Column() {
          ChangelogList({ entries: CHANGELOG_ENTRIES })
        }
        .width('100%')
        .padding(Space.s4)
        .borderRadius(Radius.card)
        .border({ width: 1, color: $r('app.color.line') })
        .backgroundColor($r('app.color.bg_card'))
      }
      .width('100%')
      .constraintSize({ maxWidth: Size.contentMaxW })
      .padding({ left: Space.s5, right: Space.s5, top: Space.s5, bottom: Space.s8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .scrollBar(BarState.Off)
  }
}
