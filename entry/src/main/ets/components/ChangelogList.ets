/** Shared rendering for the recent and full changelog. Content is generated from changelog.json. */
import { ChangelogEntry } from '../model/ChangelogData';
import { Space, FontSize } from '../common/Tokens';

@Component
export struct ChangelogList {
  @Prop entries: ChangelogEntry[] = [];

  build() {
    Column({ space: Space.s4 }) {
      ForEach(this.entries, (entry: ChangelogEntry) => {
        Column({ space: Space.s1 }) {
          Text('v' + entry.version + ' · ' + entry.title)
            .fontSize(FontSize.body2)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(entry.date + ' · ' + entry.statusLabel)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
          ForEach(entry.changes, (change: string) => {
            Row({ space: Space.s1 }) {
              Text('·')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_secondary'))
              Text(change)
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (change: string) => change)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (entry: ChangelogEntry) => entry.version)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
