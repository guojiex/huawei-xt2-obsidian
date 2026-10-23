/** v0.4 当前库文件名搜索与最近打开面板。 */
import { FontSize, Radius, Size, Space } from '../common/Tokens';

@Component
export struct QuickSwitcher {
  @Prop filePaths: string[] = [];
  @Prop recentPaths: string[] = [];
  onSelect: (relPath: string) => void = (relPath: string) => {};
  onClose: () => void = () => {};
  @State query: string = '';

  private visiblePaths(): string[] {
    const normalized: string = this.query.trim().toLowerCase();
    if (normalized.length === 0) {
      return this.recentPaths;
    }
    const matches: string[] = [];
    for (let i = 0; i < this.filePaths.length; i++) {
      const path: string = this.filePaths[i];
      const name: string = this.fileName(path);
      if (name.toLowerCase().indexOf(normalized) >= 0 || path.toLowerCase().indexOf(normalized) >= 0) {
        matches.push(path);
      }
    }
    return matches;
  }

  private fileName(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private isDuplicate(path: string): boolean {
    const name: string = this.fileName(path);
    let count: number = 0;
    for (let i = 0; i < this.filePaths.length; i++) {
      if (this.fileName(this.filePaths[i]) === name) {
        count++;
      }
    }
    return count > 1;
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.mask'))
      .onClick(() => {
        this.onClose();
      })

      Row() {
        Column({ space: Space.s2 }) {
          TextInput({ text: this.query, placeholder: '输入笔记名称或部分路径' })
            .fontSize(FontSize.body1)
            .fontColor($r('app.color.text_primary'))
            .height(Size.touch)
            .padding({ left: Space.s3, right: Space.s3 })
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.bg_secondary'))
            .onChange((value: string) => {
              this.query = value;
            })

          Row() {
            Text(this.query.trim().length === 0 ? '最近打开' : '搜索结果')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(this.visiblePaths().length.toString())
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: Space.s3, bottom: Space.s1 })

          if (this.visiblePaths().length === 0) {
            Column() {
              Text(this.query.trim().length > 0
                ? '没有匹配的笔记' : (this.filePaths.length === 0 ? '当前库还没有 Markdown 笔记' : '还没有最近打开的笔记'))
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            List({ space: Space.s1 }) {
              ForEach(this.visiblePaths(), (path: string) => {
                ListItem() {
                  Row() {
                    Column() {
                      Text(this.fileName(path))
                        .fontSize(FontSize.body1)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.isDuplicate(path)) {
                        Text(path)
                          .fontSize(FontSize.caption)
                          .fontColor($r('app.color.text_tertiary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Text('打开')
                      .fontSize(FontSize.body3)
                      .fontColor($r('app.color.brand'))
                  }
                  .width('100%')
                  .height(Size.itemH)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .borderRadius(Radius.control)
                  .backgroundColor($r('app.color.bg_card'))
                  .onClick(() => {
                    this.onSelect(path);
                  })
                }
              }, (path: string) => path)
            }
            .layoutWeight(1)
            .width('100%')
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 560, maxHeight: '75%' })
        .padding(Space.s4)
        .borderRadius(Radius.dialog)
        .backgroundColor($r('app.color.bg_card'))
        .shadow(ShadowStyle.OUTER_DEFAULT_LG)
        .onClick(() => {
          // Consume taps on the quick-box so they do not close it through the mask.
        })
      }
      .width('100%')
      .padding(Space.s6)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
  }
}
