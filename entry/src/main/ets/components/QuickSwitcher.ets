/** v0.4 当前库文件名搜索与最近打开面板。 */
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { FullTextSearchResult } from '../model/SearchIndex';

@Component
export struct QuickSwitcher {
  @Prop filePaths: string[] = [];
  @Prop recentPaths: string[] = [];
  searchContent: (query: string, onProgress: (completed: number, total: number) => void) =>
    Promise<FullTextSearchResult[]> = (query: string,
      onProgress: (completed: number, total: number) => void): Promise<FullTextSearchResult[]> =>
    Promise.resolve([]);
  onSelect: (relPath: string) => void = (relPath: string) => {};
  onClose: () => void = () => {};
  @State query: string = '';
  @State searchMode: string = 'name';
  @State fullTextResults: FullTextSearchResult[] = [];
  @State fullTextSearching: boolean = false;
  @State fullTextProgress: string = '';
  @State fullTextError: string = '';
  @State boxLeft: number = 0;
  @State boxTop: number = 0;
  @State boxWidth: number = 0;
  @State boxHeight: number = 0;
  private searchTimer: number = -1;
  private searchRequestId: number = 0;

  aboutToDisappear(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.searchRequestId++;
  }

  private setSearchMode(mode: string): void {
    if (this.searchMode === mode) {
      return;
    }
    this.searchMode = mode;
    this.searchRequestId++;
    this.fullTextResults = [];
    this.fullTextError = '';
    this.fullTextSearching = false;
    if (mode === 'content') {
      this.scheduleFullTextSearch();
    } else if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  private onQueryChanged(value: string): void {
    this.query = value;
    if (this.searchMode === 'content') {
      this.scheduleFullTextSearch();
    }
  }

  private scheduleFullTextSearch(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.searchRequestId++;
    const requestId: number = this.searchRequestId;
    const query: string = this.query.trim();
    this.fullTextResults = [];
    this.fullTextError = '';
    this.fullTextProgress = '';
    if (query.length === 0) {
      this.fullTextSearching = false;
      return;
    }
    this.fullTextSearching = true;
    this.fullTextProgress = '正在搜索…';
    this.searchTimer = setTimeout((): void => {
      this.searchTimer = -1;
      void this.runFullTextSearch(query, requestId);
    }, 180);
  }

  private async runFullTextSearch(query: string, requestId: number): Promise<void> {
    try {
      const results: FullTextSearchResult[] = await this.searchContent(query,
        (completed: number, total: number): void => {
          if (requestId !== this.searchRequestId) {
            return;
          }
          this.fullTextProgress = total > 0
            ? '正在建立索引 ' + completed.toString() + ' / ' + total.toString()
            : '正在搜索…';
        });
      if (requestId === this.searchRequestId) {
        this.fullTextResults = results;
        this.fullTextSearching = false;
        this.fullTextProgress = '';
      }
    } catch (error) {
      if (requestId === this.searchRequestId) {
        this.fullTextSearching = false;
        this.fullTextProgress = '';
        this.fullTextError = (error as Error).message;
      }
    }
  }

  // 外层 Row 横向铺满屏幕，左右空白的点击会落到 Row；按实测卡片区域区分内外点击。
  private updateBoxBounds(area: Area): void {
    const x: Length | undefined = area.globalPosition.x;
    const y: Length | undefined = area.globalPosition.y;
    if (typeof x === 'number' && typeof y === 'number' &&
      typeof area.width === 'number' && typeof area.height === 'number') {
      this.boxLeft = x;
      this.boxTop = y;
      this.boxWidth = area.width;
      this.boxHeight = area.height;
    }
  }

  private handleBoxClick(event: ClickEvent): void {
    if (this.boxWidth <= 0 || this.boxHeight <= 0) {
      return;
    }
    const insideBox: boolean = event.windowX >= this.boxLeft &&
      event.windowX <= this.boxLeft + this.boxWidth &&
      event.windowY >= this.boxTop &&
      event.windowY <= this.boxTop + this.boxHeight;
    if (!insideBox) {
      this.onClose();
    }
  }

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

  /** 快切主标题按 v2 隐藏扩展名，完整路径仍用于区分同名文件。 */
  private displayName(path: string): string {
    const name: string = this.fileName(path);
    const lowerName: string = name.toLowerCase();
    if (lowerName.endsWith('.markdown')) {
      return name.substring(0, name.length - '.markdown'.length);
    }
    if (lowerName.endsWith('.md')) {
      return name.substring(0, name.length - '.md'.length);
    }
    return name;
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
          Row() {
            Text('快切与搜索')
              .fontSize(FontSize.s3)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Text('×')
              .fontSize(FontSize.s1)
              .fontColor($r('app.color.text_secondary'))
              .width(Size.touch)
              .height(Size.touch)
              .textAlign(TextAlign.Center)
              .focusable(true)
              .onClick(() => { this.onClose(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          TextInput({
            text: this.query,
            placeholder: '搜索文件名、路径或正文'
          })
            .fontSize(FontSize.body1)
            .fontColor($r('app.color.text_primary'))
            .height(Size.touch)
            .padding({ left: Space.s3, right: Space.s3 })
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.bg_secondary'))
            .onChange((value: string) => {
              this.onQueryChanged(value);
            })

          Row({ space: Space.s2 }) {
            Text('文件名与路径')
              .fontSize(FontSize.caption)
              .fontColor(this.searchMode === 'name' ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
              .fontWeight(this.searchMode === 'name' ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              .borderRadius(Radius.control)
              .backgroundColor(this.searchMode === 'name' ? $r('app.color.bg_secondary') : Color.Transparent)
              .onClick(() => {
                this.setSearchMode('name');
              })
            Text('正文')
              .fontSize(FontSize.caption)
              .fontColor(this.searchMode === 'content' ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
              .fontWeight(this.searchMode === 'content' ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
              .borderRadius(Radius.control)
              .backgroundColor(this.searchMode === 'content' ? $r('app.color.bg_secondary') : Color.Transparent)
              .onClick(() => {
                this.setSearchMode('content');
              })
          }
          .width('100%')

          Row() {
            Text(this.searchMode === 'name'
              ? (this.query.trim().length === 0 ? '最近打开' : '搜索结果')
              : (this.query.trim().length === 0 ? '正文搜索' : '匹配笔记'))
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text((this.searchMode === 'name'
              ? this.visiblePaths().length : this.fullTextResults.length).toString())
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: Space.s3, bottom: Space.s1 })

          if (this.searchMode === 'content' && this.fullTextSearching) {
            Column() {
              Text(this.fullTextProgress)
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchMode === 'content' && this.fullTextError.length > 0) {
            Column() {
              Text(this.fullTextError)
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchMode === 'content' && this.query.trim().length === 0) {
            Column() {
              Text(this.filePaths.length === 0 ? '当前库还没有 Markdown 笔记' : '输入关键词搜索当前库正文')
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchMode === 'content' && this.fullTextResults.length === 0) {
            Column() {
              Text(this.filePaths.length === 0 ? '当前库还没有 Markdown 笔记' : '当前库没有匹配结果')
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchMode === 'content') {
            List({ space: Space.s1 }) {
              ForEach(this.fullTextResults, (result: FullTextSearchResult) => {
                ListItem() {
                  Column({ space: Space.s1 }) {
                    Row() {
                      Column({ space: Space.s1 }) {
                        Text(this.displayName(result.path))
                          .fontSize(FontSize.body1)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(result.path)
                          .fontSize(FontSize.caption)
                          .fontColor($r('app.color.text_tertiary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Text('打开')
                        .fontSize(FontSize.body3)
                        .fontColor($r('app.color.brand'))
                    }
                    Text(result.excerpt)
                      .width('100%')
                      .fontSize(FontSize.caption)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
                  .borderRadius(Radius.control)
                  .backgroundColor($r('app.color.bg_card'))
                  .onClick(() => {
                    this.onSelect(result.path);
                  })
                }
              }, (result: FullTextSearchResult) => result.path)
            }
            .layoutWeight(1)
            .width('100%')
          } else if (this.visiblePaths().length === 0) {
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
                      Text(this.displayName(path))
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
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.updateBoxBounds(newArea);
        })
        .onClick((event: ClickEvent) => {
          this.handleBoxClick(event);
        })
      }
      .width('100%')
      .padding(Space.s6)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Top)
      .onClick((event: ClickEvent) => {
        this.handleBoxClick(event);
      })
    }
    .width('100%')
    .height('100%')
  }
}
