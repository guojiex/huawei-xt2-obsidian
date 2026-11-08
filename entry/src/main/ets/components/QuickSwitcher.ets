/** v0.4 当前库文件名搜索与最近打开面板；v1.35 增加「当前库 / 全部库」范围与跨库结果分组。 */
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { FullTextSearchResult } from '../model/SearchIndex';
import { CrossVaultSearchOutcome, CrossVaultSearchGroup, CrossVaultHit } from '../model/CrossVaultSearchService';
import { UtilityDialogShell } from './UtilityDialogShell';

@Component
export struct QuickSwitcher {
  @Prop filePaths: string[] = [];
  @Prop recentPaths: string[] = [];
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  /** 已登记库数量：仅多于一个库时显示范围分段与范围说明（35.1）。 */
  @Prop vaultCount: number = 1;
  @Prop currentVaultId: string = '';
  searchContent: (query: string, onProgress: (completed: number, total: number) => void) =>
    Promise<FullTextSearchResult[]> = (query: string,
      onProgress: (completed: number, total: number) => void): Promise<FullTextSearchResult[]> =>
    Promise.resolve([]);
  /** 「全部库」逐库搜索（35.2）；mode 与 searchMode 同域：'name' 文件名与路径，'content' 正文。 */
  searchAllVaults: (query: string, mode: string, onVaultStart: (vaultName: string) => void) =>
    Promise<CrossVaultSearchOutcome> = (query: string, mode: string,
      onVaultStart: (vaultName: string) => void): Promise<CrossVaultSearchOutcome> => {
      const empty: CrossVaultSearchOutcome = { groups: [], skippedVaultNames: [] };
      return Promise.resolve(empty);
    };
  /** 面板关闭时终止未完成的逐库搜索（技术约束：关闭面板即取消）。 */
  cancelAllVaultSearch: () => void = () => {};
  onSelect: (vaultId: string, relPath: string) => void = (vaultId: string, relPath: string) => {};
  onClose: () => void = () => {};
  @State query: string = '';
  @State searchMode: string = 'name';
  /** 搜索范围：每次打开面板默认「当前库」，不记忆上次范围（35.1）。 */
  @State searchScope: string = 'current';
  @State fullTextResults: FullTextSearchResult[] = [];
  @State fullTextSearching: boolean = false;
  @State fullTextProgress: string = '';
  @State fullTextError: string = '';
  @State allVaultResults: CrossVaultSearchGroup[] = [];
  @State allVaultSearching: boolean = false;
  @State allVaultProgress: string = '';
  @State allVaultError: string = '';
  /** 「全部库」搜索中被跳过的暂不可读库名（35.6）。 */
  @State skippedVaultNames: string[] = [];
  @State skippedExpanded: boolean = false;
  private searchTimer: number = -1;
  private searchRequestId: number = 0;
  private allVaultRequestId: number = 0;

  aboutToDisappear(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.searchRequestId++;
    this.cancelAllVaultSearch();
    this.allVaultRequestId++;
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
    if (this.searchScope === 'all') {
      // 模式参与「全部库」搜索的取数口径，切换后重新逐库执行。
      this.scheduleAllVaultSearch();
    } else if (mode === 'content') {
      this.scheduleFullTextSearch();
    } else if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  /** 切换搜索范围（35.1）：不记忆、每次打开仍默认「当前库」；切到「全部库」立即按当前输入逐库搜索。 */
  private setSearchScope(scope: string): void {
    if (this.searchScope === scope) {
      return;
    }
    this.searchScope = scope;
    this.searchRequestId++;
    this.allVaultRequestId++;
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.allVaultResults = [];
    this.allVaultError = '';
    this.allVaultProgress = '';
    this.allVaultSearching = false;
    this.skippedVaultNames = [];
    this.skippedExpanded = false;
    if (scope === 'all' && this.query.trim().length > 0) {
      this.scheduleAllVaultSearch();
    }
  }

  private onQueryChanged(value: string): void {
    this.query = value;
    if (this.searchScope === 'all') {
      this.scheduleAllVaultSearch();
      return;
    }
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

  /** 「全部库」搜索防抖：修改查询即推进请求号，旧逐库结果不再落屏（技术约束）。 */
  private scheduleAllVaultSearch(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.allVaultRequestId++;
    const requestId: number = this.allVaultRequestId;
    const query: string = this.query.trim();
    this.allVaultResults = [];
    this.allVaultError = '';
    this.allVaultProgress = '';
    this.skippedVaultNames = [];
    this.skippedExpanded = false;
    if (query.length === 0) {
      this.allVaultSearching = false;
      return;
    }
    this.allVaultSearching = true;
    this.allVaultProgress = '正在搜索…';
    this.searchTimer = setTimeout((): void => {
      this.searchTimer = -1;
      void this.runAllVaultSearch(query, requestId);
    }, 180);
  }

  private async runAllVaultSearch(query: string, requestId: number): Promise<void> {
    try {
      const outcome: CrossVaultSearchOutcome = await this.searchAllVaults(query, this.searchMode,
        (vaultName: string): void => {
          if (requestId !== this.allVaultRequestId) {
            return;
          }
          this.allVaultProgress = '正在搜索 ' + vaultName + '…';
        });
      if (requestId === this.allVaultRequestId) {
        this.allVaultResults = outcome.groups;
        this.skippedVaultNames = outcome.skippedVaultNames;
        this.allVaultSearching = false;
        this.allVaultProgress = '';
      }
    } catch (_error) {
      if (requestId === this.allVaultRequestId) {
        this.allVaultSearching = false;
        this.allVaultProgress = '';
        this.allVaultError = '跨库搜索失败；原因未确定。请检查知识库后重试。';
      }
    }
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
    } catch (_error) {
      if (requestId === this.searchRequestId) {
        this.fullTextSearching = false;
        this.fullTextProgress = '';
        this.fullTextError = '正文搜索失败；原因未确定。请检查当前知识库后重试。';
      }
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

  private allVaultTotalHits(): number {
    let total: number = 0;
    for (let i = 0; i < this.allVaultResults.length; i++) {
      total += this.allVaultResults[i].hits.length;
    }
    return total;
  }

  @Builder
  ScopeOption(scope: string, label: string) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontColor(this.searchScope === scope ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Size.buttonH)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .accessibilityText(label + (this.searchScope === scope ? '，已选中' : ''))
      .onClick(() => {
        this.setSearchScope(scope);
      })
      .borderRadius(Radius.full)
      .backgroundColor(this.searchScope === scope ? $r('app.color.bg_card') : Color.Transparent)
      .id('quick-switcher-scope-' + scope)
  }

  @Builder
  AllVaultGroupHeader(group: CrossVaultSearchGroup) {
    Row() {
      Text(group.vaultId + (group.isCurrentVault ? ' · 当前' : ''))
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(group.hits.length.toString())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s1 })
  }

  @Builder
  AllVaultResultRow(group: CrossVaultSearchGroup, hit: CrossVaultHit) {
    Column({ space: Space.s1 }) {
      Row() {
        Column({ space: Space.s1 }) {
          Text(this.displayName(hit.path))
            .fontSize(FontSize.body1)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text() {
            Span(group.vaultId)
              .fontColor($r('app.color.brand'))
              .fontWeight(FontWeight.Medium)
            Span(' · ' + hit.path)
              .fontColor($r('app.color.text_tertiary'))
          }
          .fontSize(FontSize.caption)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('打开')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      if (hit.excerpt.length > 0) {
        Text(hit.excerpt)
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
    .borderRadius(Radius.control)
    .backgroundColor($r('app.color.bg_card'))
    .accessibilityText(group.vaultId + '，' + this.displayName(hit.path) + '，' + hit.path)
    .onClick(() => {
      this.onSelect(group.vaultId, hit.path);
    })
  }

  @Builder
  CenteredHint(text: string) {
    Column() {
      Text(text)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s2 }) {
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
            .id('quick-switcher-search-input')
            .onChange((value: string) => {
              this.onQueryChanged(value);
            })

          if (this.vaultCount > 1) {
            Row({ space: Space.s1 }) {
              this.ScopeOption('current', '当前库')
              this.ScopeOption('all', '全部库')
            }
            .width('100%')
            .padding(Space.s1)
            .borderRadius(Radius.full)
            .backgroundColor($r('app.color.bg_secondary'))
          }

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
            Text(this.searchScope === 'all'
              ? '全部库'
              : (this.searchMode === 'name'
                ? (this.query.trim().length === 0 ? '最近打开' : '搜索结果')
                : (this.query.trim().length === 0 ? '正文搜索' : '匹配笔记')))
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text((this.searchScope === 'all'
              ? this.allVaultTotalHits()
              : (this.searchMode === 'name'
                ? this.visiblePaths().length : this.fullTextResults.length)).toString())
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding({ top: Space.s3, bottom: Space.s1 })

          if (this.searchScope === 'all' && this.allVaultSearching) {
            Column() {
              Text(this.allVaultProgress)
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else if (this.searchScope === 'all' && this.allVaultError.length > 0) {
            this.CenteredHint(this.allVaultError)
          } else if (this.searchScope === 'all' && this.query.trim().length === 0) {
            this.CenteredHint('输入关键词，搜索全部知识库')
          } else if (this.searchScope === 'all' && this.allVaultTotalHits() === 0) {
            this.CenteredHint('全部知识库中没有匹配的笔记')
          } else if (this.searchScope === 'all') {
            List({ space: Space.s1 }) {
              ForEach(this.allVaultResults, (group: CrossVaultSearchGroup) => {
                ListItem() {
                  this.AllVaultGroupHeader(group)
                }
                ForEach(group.hits, (hit: CrossVaultHit) => {
                  ListItem() {
                    this.AllVaultResultRow(group, hit)
                  }
                }, (hit: CrossVaultHit) => group.vaultId + '/' + hit.path)
              }, (group: CrossVaultSearchGroup) => group.vaultId)
            }
            .layoutWeight(1)
            .width('100%')
          } else if (this.searchMode === 'content' && this.fullTextSearching) {
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
                    this.onSelect(this.currentVaultId, result.path);
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
                    this.onSelect(this.currentVaultId, path);
                  })
                }
              }, (path: string) => path)
            }
            .layoutWeight(1)
            .width('100%')
          }

          if (this.searchScope === 'all' && this.skippedVaultNames.length > 0) {
            Column({ space: Space.s1 }) {
              Row() {
                Text('已跳过 ' + this.skippedVaultNames.length.toString() + ' 个暂不可读的库')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_tertiary'))
                Blank()
                Text(this.skippedExpanded ? '收起' : '展开')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.brand'))
              }
              .width('100%')
              .id('quick-switcher-skip-hint')
              .accessibilityText('已跳过 ' + this.skippedVaultNames.length.toString() +
                ' 个暂不可读的库，' + (this.skippedExpanded ? '收起库名列表' : '展开库名列表'))
              .onClick(() => {
                this.skippedExpanded = !this.skippedExpanded;
              })
              if (this.skippedExpanded) {
                ForEach(this.skippedVaultNames, (name: string) => {
                  Text(name)
                    .fontSize(FontSize.caption)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                }, (name: string) => name)
              }
            }
            .width('100%')
            .padding({ top: Space.s2 })
          }

          if (this.vaultCount > 1) {
            Text(this.searchScope === 'all'
              ? '逐库搜索全部知识库，当前库在前；点开其他库的笔记会切换到该库。'
              : '只搜索当前知识库。')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
        }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: this.singleScreen ? Alignment.Bottom : Alignment.Center }) {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.mask'))
        .onClick(() => { this.onClose(); })

      UtilityDialogShell({
        title: '快切与搜索',
        closeLabel: '关闭快切与搜索',
        singleScreen: this.singleScreen,
        scrollContent: false,
        windowWidthVp: this.windowWidthVp,
        windowHeightVp: this.windowHeightVp,
        onClose: this.onClose,
        content: (): void => { this.DialogContent(); }
      })
    }
    .width('100%')
    .height('100%')
  }
}
