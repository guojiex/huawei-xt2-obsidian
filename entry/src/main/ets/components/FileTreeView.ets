/**
 * FileTreeView.ets —— 真实文件树（v0.2 M1 需求 1.1 / 1.2 / 1.3 / 1.4 / 1.5）
 *
 * 渲染约定（照原型 tree-row）：
 *  - **缩进即引导线**：每一级不是「加个 padding」，而是一个 24vp 宽的格子，格子画左边框
 *    —— 既产生 24vp 缩进，又产生一条竖向线；相邻行首尾相接，视觉上跨行连续（需求 1.5）。
 *    这么写是为了不引入第二套几何（避免 padding 与线条各算一次、以后改一处忘另一处）。
 *  - **目录 vs 文件**：目录 = 主色图标 + 500 字重 + 折叠箭头；文件 = 中性图标 + 400 字重。
 *  - **扁平渲染**：FileTree.scan 已经把「父目录折叠 → 子树不出现」处理掉，
 *    这里只按数组逐行画，不做递归组件（ArkUI 递归组件容易踩 status 复用）。
 *
 * 状态归属：
 *  - 展开状态 = 组件内 @State + ExpandStore 按库持久化（需求 1.3）；
 *  - **当前文件提给父级**（Index），理由见需求 1.4：折叠父目录不应改变正在编辑的文件，
 *    而「正在编辑什么」属于跨栏共享状态（侧栏选中态 + 编辑区标题 + 预览区来源同源），
 *    放在树里会让折叠动作连带改到它。这里只**回传选择**，不自己决定是否关闭。
 *
 * 后续 1.6（左滑三档）会落在 ListItem.swipeAction —— 已核实 API 24 存在
 * （sdk/default/openharmony/ets/component/list_item.d.ts:563），故本文件从一开始就用 List/ListItem。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileTree, ExpandStore, TreeNode } from '../model/FileTree';
import { VaultRegistry } from '../model/VaultRegistry';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

const TREE_DOMAIN: number = 0x0002;
const TREE_TAG: string = 'FileTreeView';

@Component
export struct FileTreeView {
  /** 当前库 id（切库由 @Watch 触发重扫） */
  @Prop @Watch('onVaultChanged') vaultId: string = '';
  /** 当前打开文件的库内相对路径（父级持有；这里只用于画选中态） */
  @Prop currentFilePath: string = '';
  /** 重扫信号：父级 +1 → onRefresh → reload */
  @Prop @Watch('onRefresh') refreshSeq: number = 0;
  /** 需要展开到可见的目标路径（父级新建笔记后置位） */
  @Prop @Watch('onReveal') revealPath: string = '';
  /** 选中文件回调（把相对路径交给父级，由父级决定编辑器要做什么） */
  onSelectFile: (relPath: string) => void = (relPath: string) => {};
  /**
   * 「在这个目录下新建笔记」回调（目录行尾的 + 按钮，2026-10-18 方案 A 用户拍板）。
   * 为什么要有它：侧栏底部「新建笔记」永远从根开始，想在目录里建必须手打完整路径；
   * 设计稿（原型）在这一块是空白（footer 的「新建」是个没绑行为的死按钮），
   * 所以入口形态是我们自己补的 —— 目录行 + 预填路径的对话框。
   */
  onCreateInDir: (dirRelPath: string) => void = (dirRelPath: string) => {};
  /**
   * 「删除这个目录」回调（目录行尾的删除按钮，2026-10-18 方案 A 配套）。
   * 为什么要有它：方案 A 补上「新建空文件夹」后，建了文件夹却删不掉 ——
   * 目录行原先只有 rename/move（1.6 的左滑三档还没落码），删除入口先以
   * 行尾常驻按钮的形式补上，确认框走 DeletePathDialog，整棵子树移除。
   * ⚠️ 只加在目录行：文件行的删除等 1.6 左滑一起做，避免满树 trash 图标后又要拆。
   */
  onDeleteDir: (dirRelPath: string) => void = (dirRelPath: string) => {};

  @State nodes: TreeNode[] = [];
  @State expanded: string[] = [];
  private store: ExpandStore | null = null;

  aboutToAppear(): void {
    this.ensureStore();
    this.reload();
  }

  private ensureStore(): void {
    if (this.store === null) {
      this.store = new ExpandStore(VaultRegistry.get().abilityContext());
    }
  }

  private onVaultChanged(): void {
    this.reload();
  }

  private onRefresh(): void {
    this.reload();
  }

  /**
   * 展开目标笔记的所有父目录并重扫（reveal）。
   * 例如 `工程/流式系统/笔记.md` → 祖先目录是 `工程`、`工程/流式系统`。
   */
  private onReveal(): void {
    if (this.revealPath.length === 0) {
      return;
    }
    this.ensureStore();
    const segs: string[] = this.revealPath.split('/');
    const next: string[] = [];
    for (let i = 0; i < this.expanded.length; i++) {
      next.push(this.expanded[i]);
    }
    let acc: string = '';
    for (let i = 0; i < segs.length - 1; i++) {
      acc = i === 0 ? segs[0] : acc + '/' + segs[i];
      if (next.indexOf(acc) < 0) {
        next.push(acc);
      }
    }
    this.expanded = next;
    const store: ExpandStore = this.store as ExpandStore;
    store.save(this.vaultId, next);
    this.rescan();
  }

  /** 重扫：读出该库的展开状态 → scan → 刷新可见行 */
  private reload(): void {
    this.ensureStore();
    if (this.vaultId.length === 0) {
      this.nodes = [];
      return;
    }
    const store: ExpandStore = this.store as ExpandStore;
    this.expanded = store.load(this.vaultId);
    hilog.info(TREE_DOMAIN, TREE_TAG, '扫描库 %{public}s，已展开 %{public}d 个目录',
      this.vaultId, this.expanded.length);
    this.rescan();
  }

  /** 按当前 expanded 重新扫描库目录 */
  private rescan(): void {
    if (this.vaultId.length === 0) {
      this.nodes = [];
      return;
    }
    const rootAbs: string = VaultRegistry.get().vaultDirOf(this.vaultId);
    this.nodes = FileTree.scan(rootAbs, this.expanded);
    hilog.info(TREE_DOMAIN, TREE_TAG, '扫描 %{public}s：%{public}d 行可见 | %{public}s',
      this.vaultId, this.nodes.length, FileTree.describe(this.nodes));
  }

  private isExpanded(relPath: string): boolean {
    return this.expanded.indexOf(relPath) >= 0;
  }

  /** 展开/折叠：换整个数组触发刷新，并立刻落盘（需求 1.3） */
  private toggleDir(relPath: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.expanded.length; i++) {
      if (this.expanded[i] === relPath) {
        found = true;
      } else {
        next.push(this.expanded[i]);
      }
    }
    if (!found) {
      next.push(relPath);
    }
    this.expanded = next;
    const store: ExpandStore = this.store as ExpandStore;
    store.save(this.vaultId, next);
    this.rescan();
  }

  /** 缩进格子数 = 层级数（depth=0 的行不长缩进、也没有引导线） */
  private levelsOf(depth: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < depth; i++) {
      out.push(i);
    }
    return out;
  }

  build() {
    // 根节点必须是**唯一**容器：空态与列表走 if/else 挂在同一个 Column 下，
    // 不能在 build 里提前 return（ArkTS 会报 10905210：只允许一个根节点）。
    Column() {
      if (this.nodes.length === 0) {
        this.EmptyHint()
      } else {
        this.TreeList()
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  /** 空库提示（新建库、或库里全是别的文件类型时） */
  @Builder
  EmptyHint() {
    Column() {
      Icon('doc', 24, $r('app.color.text_tertiary'))
      Text('库里还没有笔记')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: Space.s2 })
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  TreeList() {
    List() {
      ForEach(this.nodes, (n: TreeNode) => {
        ListItem() {
          Row() {
            ForEach(this.levelsOf(n.depth), (lv: number) => {
              Column()
                .width(Size.treeIndent)
                .height('100%')
                .border({ width: { left: 1 }, color: $r('app.color.line') })
                // 整行只允许有一个命中目标：缩进格和文本都不参与命中，点击一律冒泡到外层 Row
                .hitTestBehavior(HitTestMode.None)
            }, (lv: number) => lv.toString())

            Row({ space: Space.s2 }) {
              if (n.isDir) {
                Icon(this.isExpanded(n.relPath) ? 'chevronDown' : 'chevronRight',
                  14, $r('app.color.text_tertiary'))
              } else {
                // 占位：让文件名与目录名左对齐（文件没有箭头，用等宽空白顶替）
                Column()
                  .width(14)
                  .height(14)
              }
              Icon(n.isDir ? 'folder' : 'doc', 18,
                n.isDir ? $r('app.color.brand') : $r('app.color.text_secondary'))
              Text(n.name)
                .fontSize(FontSize.body2)
                .fontWeight(n.isDir ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(!n.isDir && n.relPath === this.currentFilePath
                  ? $r('app.color.brand') : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .layoutWeight(1)
            .height(Size.itemH)
            .padding({ left: Space.s2, right: Space.s3 })
            .alignItems(VerticalAlign.Center)
            // 见下方 onClick 的踩坑说明：不把子控件排除在命中之外，点文件名会「点不动」
            .hitTestBehavior(HitTestMode.None)

            // 目录行尾的「+」：在该目录下新建笔记（仅目录行有）。
            // ⚠️ 位置有讲究：必须是内容 Row 的**兄弟**，不能塞进那个 Row 里 ——
            // 内容 Row 整体设了 HitTestMode.None（子树透明，让点击冒泡到外层行），
            // 塞进去的按钮也会变透明、点不动。放在外层行下，它自己吃点击，
            // 不会误触展开/折叠（ArkUI 点击不向祖先行冒泡，最近的处理者消费）。
            if (n.isDir) {
              Row() {
                Icon('plus', 16, $r('app.color.text_secondary'))
              }
              .width(Size.touch)
              .height(Size.touch)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .onClick(() => {
              hilog.info(TREE_DOMAIN, TREE_TAG, '行内新建：目录 %{public}s', n.relPath);
              this.onCreateInDir(n.relPath);
              })

              // 目录行尾的删除（2026-10-18 方案 A 配套）：与 + 同样必须是内容 Row 的
              // 兄弟（塞进去会被 HitTestMode.None 透明掉，见上方 + 的说明）。
              // 危险色常驻可能太吵，先用 tertiary，确认框里才是 danger。
              Row() {
                Icon('trash', 14, $r('app.color.text_tertiary'))
              }
              .width(Size.touch)
              .height(Size.touch)
              .margin({ left: Space.s1 })
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .borderRadius(Radius.icon)
              .onClick(() => {
                hilog.info(TREE_DOMAIN, TREE_TAG, '行内删除：目录 %{public}s', n.relPath);
                this.onDeleteDir(n.relPath);
              })
            }
          }
          .width('100%')
          .height(Size.itemH)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.control)
          .backgroundColor(!n.isDir && n.relPath === this.currentFilePath
            ? $r('app.color.brand_bg_solid') : Color.Transparent)
          // ⚠️ 踩坑（模拟器实测 2026-10-18）：行内子控件（图标 / 文件名 Text）会**吃掉点击**，
          // 点文件名「点不动」，只有点行的空白处才响应 —— 而目录行因为箭头图标在左侧、
          // 早期测试点到了图标附近才看起来正常。修法是给行内的缩进格与内容 Row 都设
          // `HitTestMode.None`，让整行的点击统一冒泡到这个外层 Row 的 onClick 上。
          .onClick(() => {
            if (n.isDir) {
              this.toggleDir(n.relPath);
            } else if (n.relPath !== this.currentFilePath) {
              this.onSelectFile(n.relPath);
            }
          })
        }
        .width('100%')
        .padding({ right: Space.s2 })
      }, (n: TreeNode) => n.relPath)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: Space.s4 })
    .scrollBar(BarState.Auto)
    .backgroundColor($r('app.color.bg_page'))
  }
}
