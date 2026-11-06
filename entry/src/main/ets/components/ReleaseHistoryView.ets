/** Full offline version history; Index owns its title and back navigation. */
import { bundleManager } from '@kit.AbilityKit';
import { CHANGELOG_ENTRIES } from '../model/ChangelogData';
import { releasedEntries } from '../model/ChangelogFilter';
import { ChangelogList } from './ChangelogList';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

@Component
export struct ReleaseHistoryView {
  /** v1.32 32.9：已安装版本（运行时读包信息，不写死）；空串 = 读取失败，不过滤。 */
  @State installedVersion: string = '';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.installedVersion = info.versionName;
    } catch (error) {
      // 读不到安装版本不清空更新日志：留空串 = 不过滤，保留原有信息展示
      this.installedVersion = '';
    }
  }

  build() {
    Scroll() {
      Column({ space: Space.s4 }) {
        Column() {
          // v1.32 32.9：完整版本记录同一规则——只显示版本号 ≤ 已安装版本的条目（原型 releasedEntries）
          if (releasedEntries(CHANGELOG_ENTRIES, this.installedVersion).length === 0) {
            Text('当前版本的更新说明将在发布后显示。')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding(Space.s4)
          } else {
            ChangelogList({ entries: releasedEntries(CHANGELOG_ENTRIES, this.installedVersion) })
          }
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
