/**
 * VaultSidebar.ets —— 侧栏（v0.2 §3.5 token 化后的版本）
 *
 * 两种挂载形态：
 *  - 嵌入（md/lg）：作为 Index Row 子项随断点等分宽（layoutWeight 由父级控制）；
 *  - 抽屉（sm）：Stack 覆盖层，显隐与遮罩由 Index 控制（asDrawer = true）。
 * 结构照原型 sidebar：当前库标题 → 搜索入口 → 文件 / 章节与操作 → 树区。
 * 库类型与管理动作放在库切换菜单中；导航开合由工作区顶栏汉堡控制。
 *
 * 视觉全部走 token（需求 4.1）：颜色 `$r('app.color.*')`、数值 `Space/Radius/FontSize/Size`。
 * 图标用统一描边 `Icon()`（见 common/Icons.ets 的 J-2 兜底说明）。
 */
import { VaultEntry } from '../model/Vault';
import { FileListSortMode, FileListSortStore } from '../model/FileTree';
import { VaultRegistry } from '../model/VaultRegistry';
import { TagCountRow } from '../model/SearchStore';
import { FileTreeView } from './FileTreeView';
import { VaultStatsStreakChip } from './VaultStatsStreakChip';
import { Icon } from '../common/Icons';
import { noteDisplayNameOfPath } from '../common/NoteDisplayName';
import { FocusRequest } from '../common/FocusRequest';
import { Space, Radius, FontSize, Size, Weight } from '../common/Tokens';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

export interface ChapterEntry {
  index: number;
  level: number;
  title: string;
  offset: number;
}

@Component
export struct VaultSidebar {
  /** 抽屉形态（sm 覆盖层）：仍由顶栏汉堡和正文遮罩控制开合。 */
  asDrawer: boolean = false;
  /** 矮窗口压缩库选择器留白并隐藏操作提示，给文件树保留可见高度。 */
  @Prop compact: boolean = false;
  /** 库列表（由 Index 单向传入；本组件只显示并发出选择回调） */
  @Prop vaults: VaultEntry[] = [];
  /** Agent 笔记区复用库选择器和文件树，但不显示管理笔记的动作。 */
  @Prop referenceOnly: boolean = false;
  /** 当前库 id（显示名 = 目录名 = id） */
  @Prop currentVaultId: string = '';
  /** 当前库内有效 Markdown 笔记数 */
  @Prop noteCount: number = 0;
  @Prop sidebarTab: string = 'files';
  /** 当前打开文件的库内相对路径（父级持有，树只画选中态） */
  @Prop currentFilePath: string = '';
  @Prop chapters: ChapterEntry[] = [];
  @Prop selectedChapterIndex: number = -1;
  /**
   * 重扫信号 + 需要显示出来的路径：**透传给 FileTreeView**（那边才是状态持有者）。
   * refreshSeq：父级每 +1 一次，树重扫一次（新建 / 改名 / 删除笔记后刷新）；
   * revealPath：父级新建笔记后置位，树自动展开它的所有父目录 ——
   * 否则建在多层子目录里的笔记建完看不见，用户会以为没建成。
   */
  @Prop refreshSeq: number = 0;
  @Prop trashRefreshSeq: number = 0;
  @Prop revealPath: string = '';
  /**
   * v2.11 标签过滤（211.6）：当前筛选标签（父级 Index 单一真源，空串 = 未过滤），
   * 透传 FileTreeView 与标签面板；切换回调也只透传。
   */
  @Prop tagFilter: string = '';
  /**
   * v2.11 标签页签数据（211.3 改稿二）：tagCounts 由 Index 统一查询后传入
   * （noteCount 降序 + tag zh 升序），FileTreeView 不再持有标签聚合数据。
   */
  @Prop tagRows: TagCountRow[] = [];
  /** 下拉菜单开关（瞬态） */
  @State menuOpen: boolean = false;
  @State collapsedChapterKeys: string[] = [];
  /**
   * 弹层宽（vp）：原型 .vault-menu 是 left:0; right:0 于 .vault-switch —— **与标题同宽**，
   * 不是固定值。侧栏宽随断点等分变化，故在卡片上 onAreaChange 实测回填。
   */
  @State menuW: number = Size.sidebarW;
  /** Agent 引用栏的侧栏实测宽（<280vp 时连写条隐藏本周圆点）。 */
  @State sidebarW: number = 0;
  /** 57.7：导航条避让高度（px，EntryAbility 发布）；底部固定内容 offset 进条带用。 */
  @StorageProp('navIndicatorHeightPx') navIndicatorHeightPx: number = 0;
  /** 切库回调（点下拉菜单中的库项） */
  onSwitchVault: (id: string) => void = (id: string) => {};
  /** 「管理库」回调（父级切换到库管理视图） */
  onManageVaults: () => void = () => {};
  /** Agent 引用栏的写作统计回调。 */
  onOpenStats: () => void = () => {};
  /** 连写条只读父级缓存值，扫描未完成显示「…」，组件自身不扫描。 */
  @Prop statsStreakDays: number = 0;
  @Prop statsTotalDays: number = 0;
  @Prop statsScanning: boolean = false;
  @Prop statsWeekFlags: boolean[] = [];
  @Prop statsTodayIndex: number = -1;
  /** v1.58 总开关：关闭时不渲染 Agent 引用栏连写条。 */
  @Prop statsEnabled: boolean = true;
  /** Agent 引用栏的焦点归还目标。 */
  @Prop statsChipId: string = 'vault-stats-streak-chip';
  /** 打开当前库快切与全文搜索。 */
  onOpenSearch: () => void = () => {};
  /** 统一导入库入口：本地目录或 Git 仓库。 */
  onImportVault: () => void = () => {};
  /**
   * 「新建笔记」回调（父级拉起新建笔记对话框）。
   * 原型侧栏底部的「新建」在这里落成**新建笔记** —— 新建库要去「库管理」页，
   * 那里本来就有「+ 新建本地笔记库」入口（原型 index.html #newLocal），两处不重复摆。
   */
  onCreateNote: () => void = () => {};
  /** 选中文件回调（向父级传递，由父级决定编辑器行为） */
  onSelectFile: (relPath: string) => void = (relPath: string) => {};
  onSidebarTabChange: (tab: string) => void = (tab: string) => {};
  onSelectChapter: (index: number) => void = (index: number) => {};
  /** 文件行尾的跨栏打开入口。 */
  onOpenOtherPane: (relPath: string) => void = (relPath: string) => {};
  onReferenceNote: (relPath: string, vaultId: string) => void =
    (relPath: string, vaultId: string) => {};
  /**
   * 「在该目录下新建笔记」回调（文件树目录行尾的 + 按钮，2026-10-18 方案 A）。
   * 侧栏自身只透传，对话框与消毒逻辑都在父级（Index）—— 与 onCreateNote 同一条链路，
   * 差别仅在于对话框预填目标目录。
   */
  onCreateInDir: (dirRelPath: string) => void = (dirRelPath: string) => {};
  /** 左滑操作条回调透传（1.6：重命名 / 移动 / 删除 / 滑到底删除），执行都在父级（Index） */
  onRenamePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onMovePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onDeletePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onSharePath: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onSwipeDelete: (relPath: string) => void = (relPath: string) => {};
  /** 回收站恢复回调，执行与原撤销条一致的恢复服务。 */
  onRestoreTrash: (relPath: string) => void = (relPath: string) => {};
  /** 回收站永久删除回调（父级拉确认弹窗）。 */
  onPurgeTrash: (relPath: string) => void = (relPath: string) => {};
  /** 清空回收站回调（55.1：父级拉清空确认弹窗）。 */
  onPurgeAllTrash: () => void = () => {};
  /** 回收站条目预览回调（74.3：点行主体弹只读预览）。 */
  onPreviewTrash: (relPath: string) => void = (relPath: string) => {};
  /** v1.71 树内拖拽移动：drop 到目录行 / 树根空白时回调，移动全链执行在父级（Index）。 */
  onDragMovePath: (relPath: string, isDir: boolean, destDir: string) => void =
    (relPath: string, isDir: boolean, destDir: string) => {};
  /** v1.71 拖拽会话开始 / 结束：父级据此启用正文栏「拖进打开」落点。侧栏只透传。 */
  onTreeDragStart: (relPath: string, isDir: boolean) => void = (relPath: string, isDir: boolean) => {};
  onTreeDragEnd: () => void = () => {};
  /** v2.11 标签过滤切换回调，透传给 FileTreeView。 */
  onTagFilterChange: (tag: string) => void = (tag: string) => {};

  /** 文件树排序模式（v1.49）：App 级偏好，本组件持有并下传 FileTreeView。 */
  @State sortMode: FileListSortMode = 'name';
  @State sortMenuOpen: boolean = false;
  private sortStore: FileListSortStore | null = null;

  aboutToAppear(): void {
    if (this.sortStore === null) {
      this.sortStore = new FileListSortStore(VaultRegistry.get().abilityContext());
    }
    this.sortMode = (this.sortStore as FileListSortStore).load();
  }

  private setSortMode(mode: FileListSortMode): void {
    this.sortMenuOpen = false;
    if (this.sortMode === mode) {
      return;
    }
    this.sortMode = mode;
    (this.sortStore as FileListSortStore).save(mode);
  }

  private sortModeLabel(): string {
    return this.sortMode === 'mtime' ? '按修改时间排序' : '按名称排序';
  }

  private chapterKey(chapter: ChapterEntry): string {
    return this.currentVaultId + ':' + this.currentFilePath + ':' + chapter.offset.toString();
  }

  private chapterFocusId(chapter: ChapterEntry): string {
    return 'vault-chapter-' + this.chapterKey(chapter);
  }

  private chapterTitleText(): string {
    if (this.currentFilePath.length === 0) {
      return '未选择笔记 · 0 个章节';
    }
    return noteDisplayNameOfPath(this.currentFilePath) + ' · ' + this.chapters.length.toString() + ' 个章节';
  }

  /** 章节行字号（原型 .chapter-jump[data-level]）：1→--large、2→--body、3/4→--small、5/6→--caption。 */
  private chapterFontSize(level: number): number {
    return level === 1 ? FontSize.s2 : level === 2 ? FontSize.body1 :
      level <= 4 ? FontSize.body2 : FontSize.caption;
  }

  /** 章节行字重（原型 font-weight）：1/2/3/5 → 600（semibold），4/6 → 400。 */
  private chapterFontWeight(level: number): number {
    return level <= 3 || level === 5 ? Weight.semibold : FontWeight.Normal;
  }

  /** 章节行行高（fp）：原型全局 line-height 1.6，行高随层级字号变化，不钉死 48vp。 */
  private chapterLineHeightFp(level: number): number {
    return this.chapterFontSize(level) * 1.6;
  }

  private hasChapterChildren(index: number): boolean {
    return index >= 0 && index + 1 < this.chapters.length &&
      this.chapters[index + 1].level > this.chapters[index].level;
  }

  private isChapterCollapsed(chapter: ChapterEntry): boolean {
    return this.collapsedChapterKeys.indexOf(this.chapterKey(chapter)) >= 0;
  }

  private isChapterHidden(index: number): boolean {
    let parentLevel: number = this.chapters[index].level;
    for (let i: number = index - 1; i >= 0; i--) {
      const candidate: ChapterEntry = this.chapters[i];
      if (candidate.level < parentLevel) {
        if (this.isChapterCollapsed(candidate)) {
          return true;
        }
        parentLevel = candidate.level;
      }
    }
    return false;
  }

  private chapterDepth(index: number): number {
    let parentLevel: number = this.chapters[index].level;
    let depth: number = 0;
    for (let i: number = index - 1; i >= 0; i--) {
      const candidate: ChapterEntry = this.chapters[i];
      if (candidate.level < parentLevel) {
        depth++;
        parentLevel = candidate.level;
      }
    }
    return depth;
  }

  private visibleChapterEntries(): ChapterEntry[] {
    const visible: ChapterEntry[] = [];
    for (let i: number = 0; i < this.chapters.length; i++) {
      if (!this.isChapterHidden(i)) {
        visible.push(this.chapters[i]);
      }
    }
    return visible;
  }

  private toggleChapter(chapter: ChapterEntry): void {
    if (!this.hasChapterChildren(chapter.index)) {
      return;
    }
    const key: string = this.chapterKey(chapter);
    const next: string[] = [];
    let found: boolean = false;
    for (let i: number = 0; i < this.collapsedChapterKeys.length; i++) {
      if (this.collapsedChapterKeys[i] === key) {
        found = true;
      } else {
        next.push(this.collapsedChapterKeys[i]);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.collapsedChapterKeys = next;
  }

  private focusChapter(chapter: ChapterEntry): void {
    FocusRequest.safely(this.getUIContext(), this.chapterFocusId(chapter));
  }

  private parentChapter(chapter: ChapterEntry): ChapterEntry | null {
    for (let i = chapter.index - 1; i >= 0; i--) {
      if (this.chapters[i].level < chapter.level) {
        return this.chapters[i];
      }
    }
    return null;
  }

  private onChapterKey(chapter: ChapterEntry, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    const visible: ChapterEntry[] = this.visibleChapterEntries();
    const position: number = visible.indexOf(chapter);
    if (position < 0) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      this.focusChapter(visible[(position + visible.length - 1) % visible.length]);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      this.focusChapter(visible[(position + 1) % visible.length]);
    } else if (event.keyCode === KeyCode.KEYCODE_MOVE_HOME) {
      this.focusChapter(visible[0]);
    } else if (event.keyCode === KeyCode.KEYCODE_MOVE_END) {
      this.focusChapter(visible[visible.length - 1]);
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) {
      if (this.hasChapterChildren(chapter.index) && !this.isChapterCollapsed(chapter)) {
        this.toggleChapter(chapter);
      } else {
        const parent: ChapterEntry | null = this.parentChapter(chapter);
        if (parent !== null) {
          this.focusChapter(parent);
        }
      }
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) {
      if (this.hasChapterChildren(chapter.index)) {
        if (this.isChapterCollapsed(chapter)) {
          this.toggleChapter(chapter);
        } else if (position + 1 < visible.length && visible[position + 1].level > chapter.level) {
          this.focusChapter(visible[position + 1]);
        }
      }
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER ||
      event.keyCode === KeyCode.KEYCODE_SPACE || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
      this.onSelectChapter(chapter.index);
    } else {
      return false;
    }
    return true;
  }

  /**
   * 库切换下拉菜单内容（照原型 vault-menu）：
   * 「切换知识库」标签 + 库项（folder 图标 + 名称，当前项尾部对勾）+ 分隔线 + 蓝色文字动作。
   *
   * 逐条对原型 .vault-menu / .vault-menu-label / .vault-option / .vault-menu-actions：
   * 容器 padding --s2 / 圆角 --r / 1px line / --float-shadow / max-height --window-min（超出内部滚动）；
   * 行高 --touch、padding --s2、圆角 --small-r、字号继承 --small(=body2)；
   * 选中 = --blue-soft 底 + --blue 字与图标；动作区通栏分隔线 + --blue 文字。
   * 库类型随各菜单项显示；主侧栏只显示库名与笔记数。
   *
   * ⚠️ 为什么走 bindPopup 而不是「Stack 内 offset 溢出的普通 Column」：
   * 后者是页面内普通子节点，而侧栏里文件树在它之后声明 —— ArkUI 同级组件
   * 后声明的绘制在上层，于是菜单会被文件树盖住（2026-10-18 实测复现）。
   * 弹层挂在窗口覆盖层上，层级高于页面内所有组件，天然不会被遮挡。
   */
  @Builder
  VaultMenu() {
    Column() {
      // 内容可滚：库多时不顶出屏幕（原型 max-height: var(--window-min); overflow:auto）
      Scroll() {
        Column() {
          // 原型 .vault-menu-label
          Text('切换知识库')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Start)
            .width('100%')
            .padding(Space.s2)

          if (this.vaults.length === 0) {
            // 原型 .vault-empty（库可被全部删除，此时菜单仍要能打开去新建）
            Text('暂无知识库')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Start)
              .width('100%')
              .padding(Space.s2)
          }

          ForEach(this.vaults, (v: VaultEntry) => {
            Row({ space: Space.s2 }) {
              // 原型 .vault-option > svg：未选中 muted，选中 --blue
              Icon('folder', 18, v.id === this.currentVaultId
                ? $r('app.color.brand') : $r('app.color.text_tertiary'))
              Text(v.id)
                .fontSize(FontSize.body2)
                .fontWeight(v.id === this.currentVaultId ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(v.id === this.currentVaultId
                  ? $r('app.color.brand') : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.vaultTypeLabel(v))
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (v.id === this.currentVaultId) {
                // 原型仅当前库带尾部对勾
                Icon('check', 18, $r('app.color.brand'))
              }
            }
            .width('100%')
            .height(Size.touch)
            .padding(Space.s2)
            .borderRadius(Radius.control)
            .backgroundColor(v.id === this.currentVaultId
              ? $r('app.color.brand_bg') : Color.Transparent)
            .onClick(() => {
              this.menuOpen = false;
              this.onSwitchVault(v.id);
            })
            // v1.10 读屏：菜单项自带文字，补「当前 / 切换」状态，否则读屏只念库名
            .accessibilityText(v.id + '，' + this.vaultTypeLabel(v) +
              (v.id === this.currentVaultId ? '，当前知识库' : '，切换到此知识库'))
          }, (v: VaultEntry) => v.id)

          // 原型 .vault-menu-actions：通栏分隔线（原型 border-top 不带左右内缩）
          Divider()
            .color($r('app.color.line'))
            .margin({ top: Space.s2 })

          // 原型 .vault-menu-actions 顺序：＋ 导入库在前，管理库…在后
          Row() {
            Text('＋ 导入库…')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.brand'))
              .layoutWeight(1)
          }
          .width('100%')
          .height(Size.touch)
          .padding(Space.s2)
          .borderRadius(Radius.control)
          .onClick(() => {
            this.menuOpen = false;
            this.onImportVault();
          })

          Row() {
            Text('管理库…')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.brand'))
              .layoutWeight(1)
          }
          .width('100%')
          .height(Size.touch)
          .padding(Space.s2)
          .borderRadius(Radius.control)
          .onClick(() => {
            this.menuOpen = false;
            this.onManageVaults();
          })

        }
        .width('100%')
      }
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      // 620 是含 padding 的外框上限，内容区要扣掉上下 --s2
      .constraintSize({ maxHeight: Size.menuMaxH - Space.s2 * 2 })
    }
    // 与库切换卡片同宽（原型 left:0; right:0），实测宽由卡片 onAreaChange 回填
    .width(this.menuW)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    // 原型 --elev-3 的单层近似（两层 CSS 阴影 ArkUI 只能合一层）
    .shadow({ radius: 30, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 10 })
  }

  /**
   * v1.49 排序菜单：两个选项，当前项尾部对勾（复用 VaultMenu 的选中视觉）。
   */
  @Builder
  SortMenu() {
    Column({ space: Space.s1 }) {
      Row({ space: Space.s2 }) {
        Text('按名称排序')
          .fontSize(FontSize.body2)
          .fontColor(this.sortMode === 'name' ? $r('app.color.brand') : $r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.sortMode === 'name') {
          Icon('check', 18, $r('app.color.brand'))
        }
      }
      .width('100%')
      .height(Size.touch)
      .padding(Space.s2)
      .borderRadius(Radius.control)
      .backgroundColor(this.sortMode === 'name' ? $r('app.color.brand_bg') : Color.Transparent)
      .onClick((): void => { this.setSortMode('name'); })
      .accessibilityText('按名称排序' + (this.sortMode === 'name' ? '，当前' : ''))

      Row({ space: Space.s2 }) {
        Text('按修改时间排序')
          .fontSize(FontSize.body2)
          .fontColor(this.sortMode === 'mtime' ? $r('app.color.brand') : $r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.sortMode === 'mtime') {
          Icon('check', 18, $r('app.color.brand'))
        }
      }
      .width('100%')
      .height(Size.touch)
      .padding(Space.s2)
      .borderRadius(Radius.control)
      .backgroundColor(this.sortMode === 'mtime' ? $r('app.color.brand_bg') : Color.Transparent)
      .onClick((): void => { this.setSortMode('mtime'); })
      .accessibilityText('按修改时间排序' + (this.sortMode === 'mtime' ? '，当前' : ''))
    }
    .width(Size.touch * 3)
    .padding(Space.s2)
    .borderRadius(Radius.menu)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.line') })
    .shadow({ radius: 30, color: $r('app.color.float_shadow'), offsetX: 0, offsetY: 10 })
  }

  /**
   * 标签页签面板（v2.11 改稿二 · 211.3）：面板标题「标签 · N 个」+ 整栏滚动列表；
   * 空态「还没有带标签的笔记」。无折叠态、无折叠记忆——页签天然承担收起。
   * 逐条对原型 .tag-panel-title / .tag-panel / .fav-empty。
   */
  @Builder
  TagsPanel() {
    Column() {
      Text(this.tagRows.length > 0
        ? '标签 · ' + this.tagRows.length.toString() + ' 个' : '标签')
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .letterSpacing(Size.pinLabelTracking)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: Space.s2, right: Space.s2, top: Space.s3, bottom: Space.s1 })

      if (this.tagRows.length > 0) {
        List() {
          ForEach(this.tagRows, (row: TagCountRow) => {
            ListItem() {
              this.TagRow(row)
            }
            .width('100%')
          }, (row: TagCountRow): string => {
            // 选中态进键：行选中样式（Z2/L-7 首帧固化同机理）靠键值刷新。
            return 'tagrow-' + row.tagKey + (row.tag === this.tagFilter ? '|on' : '|u');
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ top: Space.s1, bottom: Space.s2 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Column() {
          Text('还没有带标签的笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding(Space.s3)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .visibility(!this.referenceOnly && this.sidebarTab === 'tags' ? Visibility.Visible : Visibility.Hidden)
  }

  /**
   * 标签行（211.3）：列表行——`#` 引导符 + 标签名（超长省略）+ 行尾小字笔记数；
   * 触达 48vp，当前过滤项整行高亮（原型 .tag-row / .tag-hash / .tag-name /
   * .tag-count，选中态 .tag-row[aria-pressed]）。点按：置过滤并自动切回文件页签；
   * 再点同一行取消过滤、留在标签页签。
   */
  @Builder
  TagRow(row: TagCountRow) {
    Row({ space: Space.s2 }) {
      Text('#')
        .fontSize(FontSize.body2)
        .fontWeight(Weight.semibold)
        .fontColor(row.tag === this.tagFilter
          ? $r('app.color.brand') : $r('app.color.text_tertiary'))
      Text(row.tag)
        .fontSize(FontSize.body2)
        .fontWeight(row.tag === this.tagFilter ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(row.tag === this.tagFilter
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(row.noteCount.toString())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .constraintSize({ minHeight: Size.touch })
    .padding({ left: Space.s2, right: Space.s2 })
    .borderRadius(Radius.control)
    .backgroundColor(row.tag === this.tagFilter
      ? $r('app.color.brand_bg') : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      const next: string = row.tag === this.tagFilter ? '' : row.tag;
      this.onTagFilterChange(next);
      if (next.length > 0 && this.sidebarTab !== 'files') {
        this.onSidebarTabChange('files');
      }
    })
    .focusable(true)
    .accessibilityText('按标签筛选：#' + row.tag + '，' + row.noteCount.toString() + ' 篇笔记' +
      (row.tag === this.tagFilter ? '，当前筛选中' : ''))
  }

  private vaultTypeLabel(vault: VaultEntry): string {
    return vault.rootKind === 'external'
      ? '外部目录库' : (vault.type === 'git' ? 'Git 库' : '本地库');
  }

  /** 57.7：导航条避让高度（vp）；布局区不进安全区（AE4），固定内容压条带靠 offset。 */
  private navClearanceVp(): number {
    return px2vp(Math.max(0, this.navIndicatorHeightPx));
  }

  /** 57.7：传给 FileTreeView 的钉底簇下移量（vp）；笔记侧栏不再有覆盖底部的连写条。 */
  private fileTreeClusterOffsetVp(): number {
    if (this.referenceOnly) {
      return 0;
    }
    return this.navClearanceVp();
  }

  /** 章节末条只留一格呼吸；笔记侧栏底部不再覆盖连写卡片。 */
  private chaptersBottomClearanceVp(): number {
    if (this.referenceOnly) {
      return 0;
    }
    return Space.s1;
  }

  build() {
    // 主列铺满布局区；Agent 引用栏的连写条仍留在主流内。
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Column() {
          // 当前库名是侧栏主标题；数量只在此处显示，库类型收进切库菜单。
          Row({ space: Space.s2 }) {
            Column({ space: Space.s1 }) {
              Text(this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）')
                .fontSize(FontSize.s3)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.noteCount.toString() + ' 篇笔记')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

          if (this.menuOpen) {
            Icon('chevronUp', 16, $r('app.color.text_tertiary'))
          } else {
            Icon('chevronDown', 16, $r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s2 })
        .margin({
          top: this.compact ? Space.s2 : Space.s3,
          bottom: Space.s2
        })
        .borderRadius(Radius.control)
        .focusable(true)
        .id('vault-switcher-trigger')
        .onClick((): void => { this.menuOpen = !this.menuOpen; })
        .accessibilityText('切换知识库，当前 ' +
          (this.currentVaultId.length > 0 ? this.currentVaultId : '无库') +
          '，' + this.noteCount.toString() + ' 篇笔记')
        .accessibilityTextHint(this.menuOpen ? '收起知识库列表' : '展开知识库列表')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          if (typeof newArea.width === 'number') {
            this.menuW = newArea.width;
          }
        })
        .bindPopup(this.menuOpen, {
          builder: this.VaultMenu(),
          placement: Placement.BottomLeft,
          enableArrow: false,
          offset: { x: 0, y: Space.s2 },
          mask: false,
          autoCancel: true,
          popupColor: Color.Transparent,
          onWillDismiss: (action: DismissPopupAction): void => {
            action.dismiss();
            this.menuOpen = false;
          }
        })

        if (!this.referenceOnly) {
          Row({ space: Space.s2 }) {
            Icon('search', Size.treeIcon, $r('app.color.text_tertiary'))
            Text('搜索笔记…')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(Size.touch)
          .padding({ left: Space.s3, right: Space.s3 })
          .margin({ bottom: Space.s2 })
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.bg_card'))
          .border({ width: 1, color: $r('app.color.line') })
          .focusable(true)
          .enabled(this.currentVaultId.length > 0)
          .opacity(this.currentVaultId.length > 0 ? 1 : 0.45)
          .id('vault-sidebar-search')
          .onClick((): void => { this.onOpenSearch(); })
          .accessibilityText('搜索笔记')
          .accessibilityTextHint(this.currentVaultId.length > 0
            ? '打开当前知识库快切与全文搜索' : '暂无知识库')

          // 文件 / 章节与当前文件视图操作共用一行；目录栏最窄时每个入口仍保留 48vp 热区。
          Row() {
            Column() {
              Column() {
                Text('文件')
                  .fontSize(FontSize.body2)
                  .fontWeight(this.sidebarTab === 'files' ? 600 : FontWeight.Normal)
                  .fontColor(this.sidebarTab === 'files' ? $r('app.color.brand') : $r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              Row()
                .width(Space.s5)
                .height(Space.s1 / 2)
                .borderRadius(Radius.full)
                .backgroundColor(this.sidebarTab === 'files'
                  ? $r('app.color.brand') : Color.Transparent)
            }
            .layoutWeight(1)
            .height(Size.touch)
            .alignItems(HorizontalAlign.Center)
            .padding({ left: Space.s1, right: Space.s1 })
            .focusable(true)
            .onClick((): void => { this.onSidebarTabChange('files'); })

            // v2.11 改稿二（211.3）：标签独立页签，与文件 / 章节同款选中视觉。
            Column() {
              Column() {
                Text('标签')
                  .fontSize(FontSize.body2)
                  .fontWeight(this.sidebarTab === 'tags' ? 600 : FontWeight.Normal)
                  .fontColor(this.sidebarTab === 'tags' ? $r('app.color.brand') : $r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              Row()
                .width(Space.s5)
                .height(Space.s1 / 2)
                .borderRadius(Radius.full)
                .backgroundColor(this.sidebarTab === 'tags'
                  ? $r('app.color.brand') : Color.Transparent)
            }
            .layoutWeight(1)
            .height(Size.touch)
            .alignItems(HorizontalAlign.Center)
            .padding({ left: Space.s1, right: Space.s1 })
            .focusable(true)
            .onClick((): void => { this.onSidebarTabChange('tags'); })

            Column() {
              Column() {
                Text('章节')
                  .fontSize(FontSize.body2)
                  .fontWeight(this.sidebarTab === 'chapters' ? 600 : FontWeight.Normal)
                  .fontColor(this.sidebarTab === 'chapters' ? $r('app.color.brand') : $r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .maxLines(1)
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
              Row()
                .width(Space.s5)
                .height(Space.s1 / 2)
                .borderRadius(Radius.full)
                .backgroundColor(this.sidebarTab === 'chapters'
                  ? $r('app.color.brand') : Color.Transparent)
            }
            .layoutWeight(1)
            .height(Size.touch)
            .alignItems(HorizontalAlign.Center)
            .padding({ left: Space.s1, right: Space.s1 })
            .focusable(true)
            .onClick((): void => { this.onSidebarTabChange('chapters'); })

            if (this.sidebarTab === 'files') {
              // v1.49：排序切换入口保留在文件操作区。
              Row() {
                Icon('sort', Size.treeIcon, $r('app.color.text_secondary'))
              }
              .height(Size.touch)
              .width(Size.touch)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .id('vault-sidebar-sort')
              .onClick((): void => { this.sortMenuOpen = !this.sortMenuOpen; })
              .accessibilityText('排序方式，当前' + this.sortModeLabel())
              .bindPopup(this.sortMenuOpen, {
                builder: this.SortMenu(),
                placement: Placement.BottomLeft,
                enableArrow: false,
                offset: { x: 0, y: Space.s1 },
                mask: false,
                autoCancel: true,
                popupColor: Color.Transparent,
                onWillDismiss: (action: DismissPopupAction): void => {
                  action.dismiss();
                  this.sortMenuOpen = false;
                }
              })
              Row() {
                Icon('plus', Size.treeIcon, $r('app.color.text_secondary'))
              }
              .height(Size.touch)
              .width(Size.touch)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .id('vault-sidebar-new-note')
              .onClick(() => {
                this.onCreateNote();
              })
              .accessibilityText('新建笔记')
            }
          }
          .width('100%')
          .padding({ left: Space.s1, right: Space.s1 })
          .border({ width: { bottom: 1 }, color: $r('app.color.line') })
        }
        }
        .width('100%')
        .padding({ left: Space.s1, right: Space.s1 })

        Stack() {
          // 保持树常驻，切换章节时不丢失折叠和滚动位置。
          FileTreeView({
            vaultId: this.currentVaultId,
            currentFilePath: this.currentFilePath,
            refreshSeq: this.refreshSeq,
            sortMode: this.sortMode,
            trashRefreshSeq: this.trashRefreshSeq,
            revealPath: this.revealPath,
            referenceOnly: this.referenceOnly,
            hideOtherPane: this.asDrawer || this.compact,
            clusterOffsetVp: this.fileTreeClusterOffsetVp(),
            tagFilter: this.tagFilter,
            onSelectFile: (relPath: string): void => { this.onSelectFile(relPath); },
            onOpenOtherPane: (relPath: string): void => { this.onOpenOtherPane(relPath); },
            onReferenceNote: (relPath: string, vaultId: string): void => {
              this.onReferenceNote(relPath, vaultId);
            },
            onCreateInDir: (dirRelPath: string): void => { this.onCreateInDir(dirRelPath); },
            onRenamePath: (relPath: string, isDir: boolean): void => { this.onRenamePath(relPath, isDir); },
            onMovePath: (relPath: string, isDir: boolean): void => { this.onMovePath(relPath, isDir); },
            onDeletePath: (relPath: string, isDir: boolean): void => { this.onDeletePath(relPath, isDir); },
            onSharePath: (relPath: string, isDir: boolean): void => { this.onSharePath(relPath, isDir); },
            onSwipeDelete: (relPath: string): void => { this.onSwipeDelete(relPath); },
            onRestoreTrash: (relPath: string): void => { this.onRestoreTrash(relPath); },
            onPurgeTrash: (relPath: string): void => { this.onPurgeTrash(relPath); },
            onPurgeAllTrash: (): void => { this.onPurgeAllTrash(); },
            onPreviewTrash: (relPath: string): void => { this.onPreviewTrash(relPath); },
            onDragMovePath: (relPath: string, isDir: boolean, destDir: string): void => {
              this.onDragMovePath(relPath, isDir, destDir);
            },
            onTreeDragStart: (relPath: string, isDir: boolean): void => {
              this.onTreeDragStart(relPath, isDir);
            },
            onTreeDragEnd: (): void => { this.onTreeDragEnd(); },
            onTagFilterChange: (tag: string): void => { this.onTagFilterChange(tag); }
          })
            .width('100%')
            .height('100%')
            .visibility(this.referenceOnly || this.sidebarTab === 'files' ? Visibility.Visible : Visibility.Hidden)

          // v2.11 改稿二（211.3）：标签独立页签整栏面板，不占文件页签高度。
          this.TagsPanel()

          Column() {
            Text(this.chapterTitleText())
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ left: Space.s3, right: Space.s3, top: Space.s4, bottom: Space.s2 })
            if (this.chapters.length > 0) {
              List() {
                ForEach(this.visibleChapterEntries(), (chapter: ChapterEntry) => {
                  ListItem() {
                    Row({ space: Space.s1 }) {
                      if (this.hasChapterChildren(chapter.index)) {
                        Row() {
                          Icon(this.isChapterCollapsed(chapter) ? 'chevronRight' : 'chevronDown',
                            Space.s4, $r('app.color.text_secondary'))
                        }
                        .width(Space.s8)
                        .alignSelf(ItemAlign.Stretch)
                        .justifyContent(FlexAlign.Center)
                        .alignItems(VerticalAlign.Center)
                        .focusable(true)
                        .onClick((): void => { this.toggleChapter(chapter); })
                        .accessibilityText((this.isChapterCollapsed(chapter) ? '展开' : '折叠') +
                          '章节：' + chapter.title)
                      } else {
                        Column()
                          .width(Space.s8)
                      }
                      Text(chapter.title)
                        .fontSize(this.chapterFontSize(chapter.level))
                        .fontWeight(this.chapterFontWeight(chapter.level))
                        .lineHeight(this.chapterLineHeightFp(chapter.level))
                        .fontColor(chapter.index === this.selectedChapterIndex
                          ? $r('app.color.brand') : $r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding(Space.s2)
                        .layoutWeight(1)
                        .focusable(true)
                        .id(this.chapterFocusId(chapter))
                        .onKeyEvent((event: KeyEvent): boolean => {
                          return this.onChapterKey(chapter, event);
                        })
                        .onClick((): void => { this.onSelectChapter(chapter.index); })
                    }
                    .width('100%')
                    .padding({ left: this.chapterDepth(chapter.index) * Space.s4 })
                    .backgroundColor(chapter.index === this.selectedChapterIndex
                      ? $r('app.color.brand_bg') : Color.Transparent)
                    .borderRadius(Radius.control)
                  }
                  .width('100%')
                }, (chapter: ChapterEntry): string => {
                  const foldState: string = this.hasChapterChildren(chapter.index)
                    ? (this.isChapterCollapsed(chapter) ? 'collapsed' : 'expanded') : 'leaf';
                  const selectedState: string = chapter.index === this.selectedChapterIndex
                    ? 'selected' : 'normal';
                  return this.chapterKey(chapter) + ':' + foldState + ':' + selectedState;
                })
              }
              .layoutWeight(1)
              .width('100%')
              .padding({ bottom: this.chaptersBottomClearanceVp() })
              .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
            } else {
              Column() {
                Text(this.currentFilePath.length > 0
                  ? '这篇笔记还没有标题。编辑时插入标题，即可在这里导航。'
                  : '先打开一篇笔记')
                  .fontSize(FontSize.body2)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding(Space.s3)
              }
                .width('100%')
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
            }
          }
          .width('100%')
          .height('100%')
          .visibility(!this.referenceOnly && this.sidebarTab === 'chapters' ? Visibility.Visible : Visibility.Hidden)
        }
        .layoutWeight(1)
        .width('100%')

        // 57.7：Agent 引用侧栏（referenceOnly）保持连写条在流内原位——文件树底边因此
        // 不与安全区边界重合，expandSafeArea 天然 no-op，Agent 页维持 57.7 前现状。
        if (this.statsEnabled && this.referenceOnly && !this.asDrawer) {
          Column() {
            VaultStatsStreakChip({
              streakDays: this.statsStreakDays,
              totalDays: this.statsTotalDays,
              scanning: this.statsScanning,
              weekFlags: this.statsWeekFlags,
              todayIndex: this.statsTodayIndex,
              showDots: this.sidebarW <= 0 || this.sidebarW >= Size.statsDotsMinSidebarW,
              chipId: this.statsChipId,
              onOpenStats: (): void => { this.onOpenStats(); }
            })
          }
          .width('100%')
          .padding({ left: Space.s3, right: Space.s3, bottom: Space.s2 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_navigation'))

    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.sidebarW = newArea.width;
      }
    })
  }
}
