/**
 * Index.ets —— 三形态布局总装 + 库模型接线（v0.1 骨架 / v0.2 视觉基线）
 *
 * 为什么三栏自绘而不用 FoldSplitContainer（api_notes.md A2-bis）：
 * ① 它的「三分栏」不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」，横排列只有 2 个；
 * ② 分栏比例只有预设枚举 LAYOUT_1V1 / LAYOUT_3V2 / LAYOUT_2V3，无 1:1:1；
 * ③ 它为双折叠悬停态设计，三折叠三屏态不在其模型内。
 * （2026-10-18 官方答复亦确认：布局适配优先基于响应式断点，精确对齐折痕非官方要求）
 *
 * 断点只用 windowSizeChange + px2vp（api_notes.md A3 ✅），不用 getFoldDisplayMode 做分支。
 * 布局矩阵：
 *   sm：单栏（编辑 / 预览二选一，顶部分段控件切换）+ 抽屉侧栏
 *   md：侧栏 | 编辑 各 50%；收起 → 编辑 | 预览 各 50%
 *   lg：侧栏 | 编辑 | 预览 各 1/3；收起 → 编辑 2/3（跨第一条折痕，红警示）| 预览 1/3
 *
 * v0.2 §3.5：本文件视觉全部走 token —— 颜色 `$r('app.color.*')`（深色自动切另一套）、
 * 数值 `Space/Radius/FontSize/Size/Motion`（common/Tokens.ets）、图标 `Icon()`（common/Icons.ets）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { Breakpoint } from '../model/Breakpoint';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { NoteService } from '../model/NoteService';
import { VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerView } from '../components/VaultManagerView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';
import { CreateNoteDialog } from '../components/NoteDialogs';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

const DOMAIN: number = 0x0000;
const TAG: string = 'Index';

/** 状态栏形态标签（与原型 FORMS 一致） */
function formLabelOf(bp: string): string {
  if (bp === Breakpoint.SM) {
    return '外屏合起';
  }
  if (bp === Breakpoint.MD) {
    return '展开双屏';
  }
  return '三屏展开';
}

/** 单屏态分段控件的单个按钮 */
@Extend(Text)
function segItem(active: boolean) {
  .fontSize(FontSize.body3)
  .fontColor(active ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
  .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
  .height(28)
  .padding({ left: Space.s3, right: Space.s3 })
  .textAlign(TextAlign.Center)
  .borderRadius(Radius.full)
  .backgroundColor(active ? $r('app.color.bg_card') : Color.Transparent)
}

@Entry
@Component
struct Index {
  /** 断点档位（EntryAbility 写入 AppStorage；@Watch 在档位变化时收敛抽屉态） */
  @StorageProp('breakpoint') @Watch('onBreakpointChanged') breakpoint: string = Breakpoint.SM;
  /** 窗口宽度 vp（状态栏显示用） */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
  /** display.getFoldStatus() 读数（调试用，-1 = 没取到；api_notes A1） */
  @StorageProp('foldStatus') foldStatus: number = -1;
  /**
   * 折痕中心 x（**px**，多条逗号分隔；'-' = 没取到。api_notes A2 采集通道，不参与布局）。
   * 存 px 而不是 vp：官方提醒 px2vp 应在 UI 上下文换算，故在页面侧 statusRightText() 里转。
   */
  @StorageProp('creasePx') creasePx: string = '-';
  /** 库列表（单一数据源 VaultRegistry；CRUD 后 refreshFromRegistry） */
  @State vaults: VaultEntry[] = [];
  /** 当前库 id */
  @State currentVaultId: string = '';
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State sidebarCollapsed: boolean = false;
  /** 库管理视图整体替换内容区（原型 vaultsView 结构） */
  @State showVaultManager: boolean = false;
  /**
   * 当前打开文件的**库内相对路径**（如 `docs/架构.md`）。
   *
   * 为什么放在这里而不是放在文件树组件里（需求 1.4）：
   * 折叠父目录只改变「哪些行可见」，不应连带改变正在编辑的文件。
   * 若当前文件由树持有，折叠动作会导致它被清掉（或被迫写例外逻辑绕过清理）。
   * 放在总装页还有一个额外好处：侧栏选中态、编辑区标题、以后的预览来源共用同一份状态，
   * 不存在三处各记一份然后不同步的可能。
   */
  @State currentFilePath: string = '';
  /**
   * 文件树重扫信号（每次 +1 触发一次 rescan）。
   * 为什么不用「更聪明」的方案：树组件自己不知道外部什么时候改了磁盘
   * （没有文件监听），用显式信号换确定性和简单性。
   */
  @State treeSeq: number = 0;
  /**
   * 需要树展开到可见的目标路径。建完笔记置位 → 树展开它的父目录 → 立刻看得见。
   */
  @State revealPath: string = '';
  /** 单屏态「编辑 / 预览」二选一（v0.2 §3.4-3.3）。
   * 只有一块屏放不下两栏；md/lg 两栏同时可见，这个状态不参与布局。
   */
  @State smMode: string = 'edit';

  /** 对话框控制器：每次拉起重建（传新鲜目标参数），不复用旧实例防参数过期 */
  private createDialogCtl: CustomDialogController | null = null;
  private renameDialogCtl: CustomDialogController | null = null;
  private deleteDialogCtl: CustomDialogController | null = null;
  private createNoteCtl: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.refreshFromRegistry();
  }

  /** 从注册表刷新库列表与当前库（切库/新建/改名/删除后调用） */
  private refreshFromRegistry(): void {
    const reg: VaultRegistry = VaultRegistry.get();
    this.vaults = reg.list();
    this.currentVaultId = reg.currentId();
  }

  /** 档位变化：抽屉语义只在 sm；切到 md/lg 强制收抽屉，防止回 sm 时意外打开 */
  private onBreakpointChanged(): void {
    if (this.breakpoint !== Breakpoint.SM) {
      this.drawerOpen = false;
    }
  }

  /**
   * 系统返回键/侧滑返回拦截（需求 2.7b；api_notes I-1 / I3.1 已真机核实：侧滑同样触发）。
   * 按优先级依次消费：① sm 抽屉打开 → 关抽屉；② 库管理视图 → 回笔记视图；
   * ③ sm 预览态 → 回编辑态；④ 都不是 → 返 false 走系统默认（退出应用）。
   */
  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.showVaultManager) {
      this.showVaultManager = false;
      return true;
    }
    if (this.breakpoint === Breakpoint.SM && this.smMode === 'preview') {
      this.smMode = 'edit';
      return true;
    }
    return false;
  }

  /** 当前库名（显示名 = 目录名 = id；注册表兜底） */
  private currentVaultName(): string {
    return this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）';
  }

  /**
   * 选中文件。
   * 单屏态额外做两件事：关抽屉 + 回编辑态 —— 在只有一个栏位的地方点了文件，
   * 默认意图是「看/改它」，而不是开抽屉也不看 preview。
   */
  private onSelectFile(relPath: string): void {
    this.currentFilePath = relPath;
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = false;
      this.smMode = 'edit';
    }
  }

  /** 状态栏右侧读数：形态 · vp · FS:N（有折痕时追加 · C:x,y，px 在此换算成 vp） */
  private statusRightText(): string {
    let s: string = formLabelOf(this.breakpoint) + ' · ' + Math.round(this.windowWidthVp) + 'vp' +
      ' · FS:' + this.foldStatus;
    if (this.creasePx !== '-') {
      s += ' · C:' + this.creaseVpText();
    }
    return s;
  }

  /** 折痕 px 串 → vp 串（页面侧换算，UI 上下文里 px2vp 才可靠） */
  private creaseVpText(): string {
    const parts: string[] = this.creasePx.split(',');
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      const px: number = parseInt(parts[i], 10);
      out += (i === 0 ? '' : ',') + (isNaN(px) ? '?' : Math.round(px2vp(px)).toString());
    }
    return out;
  }

  /** 顶栏汉堡：sm = 抽屉开关；md/lg = 收起/唤回切换（toggle） */
  private onHamburger(): void {
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = !this.drawerOpen;
    } else {
      this.sidebarCollapsed = !this.sidebarCollapsed;
    }
  }

  // ===== 库操作（对话框确认后执行；失败 toast + 日志，注册表不落半状态） =====

  private doSwitchVault(id: string): void {
    try {
      VaultRegistry.get().setCurrent(id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('切换库失败', error);
    }
  }

  private doCreateVault(name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const entry: VaultEntry = reg.createLocal(name);
      // 原型行为：新建后自动切到新库（doCreate → switchVault）
      reg.setCurrent(entry.id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('新建库失败', error);
    }
  }

  private doRenameVault(id: string, name: string): void {
    try {
      VaultRegistry.get().rename(id, name);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('改名失败', error);
    }
  }

  private doDeleteVault(id: string): void {
    try {
      VaultRegistry.get().remove(id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /**
   * 新建笔记（顺序不能乱）：
   * 1. `normalizeRelPath` —— 消毒 + 补 `.md`（非法输入在这一步就抛错，不会落到磁盘）；
   * 2. `createNote` —— 逐级补建父目录 + 写空文件，重名自动加后缀；
   * 3. 置 currentFilePath / revealPath / treeSeq —— 让用户立刻看到刚建的那篇。
   * 失败一律 toast，且**不改动任何 UI 状态**（笔记没建成就不该「选中」它）。
   */
  private doCreateNote(rawName: string): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeRelPath(rawName);
      const actual: string = NoteService.createNote(reg, this.currentVaultId, rel);
      this.currentFilePath = actual;
      this.revealPath = actual;
      this.treeSeq++;
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
        this.smMode = 'edit';
      }
    } catch (error) {
      this.toastRegistryError('新建笔记失败', error);
    }
  }

  /** 注册表操作失败：固定文案 toast + 详细原因进 hilog（不把异常原文弹给用户） */
  private toastRegistryError(prefix: string, error: Object): void {
    const err = error as Error;
    hilog.warn(DOMAIN, TAG, '%{public}s: %{public}s', prefix, err.message ?? JSON.stringify(error));
    promptAction.showToast({ message: prefix });
  }

  // ===== 对话框拉起（每次新建 controller 传新鲜参数） =====

  private openCreateDialog(): void {
    this.createDialogCtl = new CustomDialogController({
      builder: CreateVaultDialog({
        onConfirm: (name: string): void => {
          this.doCreateVault(name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createDialogCtl.open();
  }

  private openCreateNoteDialog(): void {
    this.createNoteCtl = new CustomDialogController({
      builder: CreateNoteDialog({
        vaultId: this.currentVaultId,
        onConfirm: (rawName: string): void => {
          this.doCreateNote(rawName);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createNoteCtl.open();
  }

  private openRenameDialog(id: string): void {
    this.renameDialogCtl = new CustomDialogController({
      builder: RenameVaultDialog({
        initialName: id,
        onConfirm: (name: string): void => {
          this.doRenameVault(id, name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.renameDialogCtl.open();
  }

  private openDeleteDialog(id: string): void {
    this.deleteDialogCtl = new CustomDialogController({
      builder: DeleteVaultDialog({
        vaultId: id,
        onConfirm: (): void => {
          this.doDeleteVault(id);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deleteDialogCtl.open();
  }

  // ===== 视觉构件 =====

  /** 顶栏图标按钮：视觉 22，热区 48（4.x 修正 v0.1 的 32×32 不足） */
  @Builder
  IconButton(name: string, color: ResourceColor, onTap: () => void) {
    Row() {
      Icon(name, 22, color)
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .onClick(onTap)
  }

  /** 单屏态「编辑 / 预览」分段控件（SegmentedButton 观感） */
  @Builder
  SegToggle() {
    Row({ space: 2 }) {
      Text('编辑')
        .segItem(this.smMode === 'edit')
        .onClick(() => {
          this.smMode = 'edit';
        })
      Text('预览')
        .segItem(this.smMode === 'preview')
        .onClick(() => {
          this.smMode = 'preview';
        })
    }
    .padding(2)
    .borderRadius(Radius.full)
    .backgroundColor($r('app.color.bg_secondary'))
  }

  /** 栏头：标题 + （单屏态才有的）编辑/预览切换 */
  @Builder
  PaneHead(title: string) {
    Row() {
      Text(title)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.breakpoint === Breakpoint.SM) {
        this.SegToggle()
      }
    }
    .width('100%')
    .height(Size.paneHeadH)
    .padding({ left: Space.s4, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  build() {
    Column() {
      this.Appbar()
      Stack() {
        if (this.showVaultManager) {
          this.ManagerView()
        } else if (this.breakpoint === Breakpoint.SM) {
          this.SmContent()
        } else {
          this.WideContent()
        }
      }
      .layoutWeight(1)
      .width('100%')
      this.Statusbar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /**
   * 顶栏（需求 2.7）：笔记视图 = 汉堡（sm 抽屉 / md+lg 收起唤回）+ 标题 +「库管理」；
   * 库管理视图 = 左上角换返回箭头 + 标题「笔记库」，右侧入口收敛。
   * v0.2 §3.5：高度 56vp、标题 20fp/700、图标热区 48、颜色走 token。
   */
  @Builder
  Appbar() {
    Row() {
      if (this.showVaultManager) {
        // 次级视图顶栏返回是硬要求（api_notes I3），不依赖系统返回可否拦截
        this.IconButton('back', $r('app.color.text_primary'), (): void => {
          this.showVaultManager = false;
        })
      } else {
        this.IconButton('menu', $r('app.color.text_secondary'), (): void => {
          this.onHamburger();
        })
      }
      // 原型 VIEW_TITLE：次级视图标题固定为视图名，不显示当前库名
      Text(this.showVaultManager ? '笔记库' : this.currentVaultName())
        .fontSize(FontSize.s2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Space.s2, right: Space.s2 })
      if (!this.showVaultManager) {
        Text('库管理')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .height(Size.touch)
          .padding({ left: Space.s3, right: Space.s3 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.control)
          .onClick(() => {
            this.showVaultManager = true;
          })
      }
    }
    .width('100%')
    .height(Size.appbarH)
    .padding({ left: Space.s1, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  /** sm：单栏内容（编辑 / 预览二选一）+ 抽屉侧栏覆盖层（Stack，汉堡开关，点遮罩关闭） */
  @Builder
  SmContent() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.smMode === 'preview') {
        this.PreviewPane()
      } else {
        this.EditorPane(false)
      }
      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.mask'))
          .onClick(() => {
            this.drawerOpen = false;
          })
        VaultSidebar({
          asDrawer: true,
          vaults: this.vaults,
          currentVaultId: this.currentVaultId,
          currentFilePath: this.currentFilePath,
          refreshSeq: this.treeSeq,
          revealPath: this.revealPath,
          onSwitchVault: (id: string): void => {
            this.doSwitchVault(id);
          },
          onManageVaults: (): void => {
            this.drawerOpen = false;
            this.showVaultManager = true;
          },
          onCreateNote: (): void => {
            this.drawerOpen = false;
            this.openCreateNoteDialog();
          },
          onSelectFile: (relPath: string): void => {
            this.onSelectFile(relPath);
          }
        })
          .width(Size.drawerW)
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** md/lg：Row 等分（layoutWeight 精确等分，栏边界压折痕） */
  @Builder
  WideContent() {
    Row() {
      if (!this.sidebarCollapsed) {
        // 侧栏（嵌入形态）
        Column() {
          VaultSidebar({
            asDrawer: false,
            vaults: this.vaults,
            currentVaultId: this.currentVaultId,
            currentFilePath: this.currentFilePath,
            refreshSeq: this.treeSeq,
            revealPath: this.revealPath,
            onCollapse: (): void => {
              this.sidebarCollapsed = true;
            },
            onSwitchVault: (id: string): void => {
              this.doSwitchVault(id);
            },
            onManageVaults: (): void => {
              this.showVaultManager = true;
            },
            onCreateNote: (): void => {
              this.openCreateNoteDialog();
            },
            onSelectFile: (relPath: string): void => {
              this.onSelectFile(relPath);
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { right: 1 }, color: $r('app.color.line') })

        if (this.breakpoint === Breakpoint.MD) {
          // md 展开：侧栏 | 编辑 各 50%（预览隐藏，原型 applyForm）
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          // lg 展开：侧栏 | 编辑 | 预览 各 1/3
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
          Column() {
            this.PreviewPane()
          }
          .layoutWeight(1)
          .height('100%')
          .border({ width: { left: 1 }, color: $r('app.color.line') })
        }
      } else if (this.breakpoint === Breakpoint.MD) {
        // md 收起：腾出的那一栏给预览 → 编辑 | 预览 各一整块屏
        Column() {
          this.EditorPane(false)
        }
        .layoutWeight(1)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      } else {
        // lg 收起：编辑扩 2/3 —— 会跨越第一条折痕，这是物理限制非 bug；
        // 编辑区内渲染红色虚线折痕警示 + 预览 1/3
        Column() {
          this.EditorPane(true)
        }
        .layoutWeight(2)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 编辑区占位（真实编辑器 v0.2 M2 接入）。
   * showHingeWarning：lg 收起态专用——编辑区扩到 2/3 会跨第一条折痕。
   * 警示线位置 = 编辑区宽的 50%：第一条折痕在整体 1/3 处，编辑区占 2/3，1/3 ÷ 2/3 = 50%。
   * 折痕实际坐标只做读数（api_notes A2：真机返回不可用 / 模拟器可用），**不进布局算式**。
   */
  @Builder
  EditorPane(showHingeWarning: boolean) {
    Column() {
      this.PaneHead(this.currentFilePath.length > 0 ? this.currentFilePath : '源模式')

      Stack() {
        Column({ space: Space.s3 }) {
          Text('编辑区 · v0.2')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_tertiary'))
          // 选中文件后这里显示它的库内路径，用来验证「点侧栏 → 编辑区吃到同一份状态」
          if (this.currentFilePath.length > 0) {
            Text(this.currentFilePath)
              .fontSize(FontSize.s3)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_card'))

        if (showHingeWarning) {
          // 被内容横跨的折痕：红色虚线竖标（零宽 Column + 左边框）
          Column()
            .width(0)
            .height('100%')
            .border({ width: { left: 2 }, color: $r('app.color.danger'), style: BorderStyle.Dashed })
            .position({ x: '50%' })
          Text('被内容横跨')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .position({ x: '50%', y: Space.s3 })
            .translate({ x: Space.s1 })
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 预览区占位（真实预览 v0.2 M3 接入） */
  @Builder
  PreviewPane() {
    Column() {
      this.PaneHead('预览')

      Column() {
        Text('预览 · v0.2')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
  }

  /** 库管理视图：整体替换内容区；返回走顶栏 ‹ 与 onBackPress，组件不自带（2.7c） */
  @Builder
  ManagerView() {
    VaultManagerView({
      vaults: this.vaults,
      currentVaultId: this.currentVaultId,
      onSetCurrent: (id: string): void => {
        this.doSwitchVault(id);
      },
      onRename: (id: string): void => {
        this.openRenameDialog(id);
      },
      onDelete: (id: string): void => {
        this.openDeleteDialog(id);
      },
      onCreate: (): void => {
        this.openCreateDialog();
      }
    })
  }

  /** 状态栏：当前库 + 档位 + vp 宽度（spec FR：状态栏联动断点） */
  @Builder
  Statusbar() {
    Row() {
      // TEMP-MARKER：验证选中链路用，验证完删掉的第三行
      Text(this.currentVaultName() + ' | ' + this.currentFilePath)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
      Blank()
      Text(this.statusRightText())
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Size.statusbarH)
    .padding({ left: Space.s3, right: Space.s3 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }
}
