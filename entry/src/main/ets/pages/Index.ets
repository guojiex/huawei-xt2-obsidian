/**
 * Index.ets —— 三形态布局总装 + 库模型接线（v0.1）
 *
 * 为什么三栏自绘而不用 FoldSplitContainer（api_notes.md A2-bis，2026-10-17 已否决）：
 * ① 它的「三分栏」不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」，横排列只有 2 个，
 *    做不出「侧栏 | 编辑 | 预览」三列；
 * ② 分栏比例只有预设枚举 LAYOUT_1V1 / LAYOUT_3V2 / LAYOUT_2V3，无 1:1:1，
 *    也表达不了「md 收起 → 编辑|预览 各 50%」这类动态栏宽矩阵；
 * ③ 它为双折叠悬停态设计，三折叠三屏态不在其模型内。
 * 「一栏 = 一整块物理屏、栏边界压折痕」只有按断点等分自绘能保证（plan.md R5）。
 *
 * 断点只用 windowSizeChange + px2vp（api_notes.md A3 ✅），不用 getFoldDisplayMode 做分支（A3）。
 * 布局矩阵（plan.md）：
 *   sm：单栏 + 抽屉侧栏（Stack 覆盖层，汉堡开关）
 *   md：侧栏 | 编辑 各 50%；收起 → 编辑 | 预览 各 50%（不跨折痕）
 *   lg：侧栏 | 编辑 | 预览 各 1/3；收起 → 编辑 2/3（跨第一条折痕，T016 红警示）| 预览 1/3
 *
 * 库模型接线：库列表/当前库 @State 持有、操作后从 VaultRegistry 刷新（单一数据源）；
 * 对话框按操作拉起（每次新建 CustomDialogController 传新鲜参数，避免 builder 参数过期）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { Breakpoint } from '../model/Breakpoint';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerView } from '../components/VaultManagerView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';

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

@Entry
@Component
struct Index {
  /** 断点档位（EntryAbility 写入 AppStorage；@Watch 在档位变化时收敛抽屉态） */
  @StorageProp('breakpoint') @Watch('onBreakpointChanged') breakpoint: string = Breakpoint.SM;
  /** 窗口宽度 vp（状态栏显示用） */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
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

  /** 对话框控制器：每次拉起重 建（传新鲜目标参数），不复用旧实例防参数过期 */
  private createDialogCtl: CustomDialogController | null = null;
  private renameDialogCtl: CustomDialogController | null = null;
  private deleteDialogCtl: CustomDialogController | null = null;

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

  /** 当前库名（显示名 = 目录名 = id；注册表兜底） */
  private currentVaultName(): string {
    return this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）';
  }

  /** 顶栏汉堡：sm = 抽屉开关；md/lg = 唤回收起的侧栏（spec 非功能约束） */
  private onHamburger(): void {
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = !this.drawerOpen;
    } else {
      this.sidebarCollapsed = false;
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
    .backgroundColor('#F2F2F7')
  }

  /** 顶栏：汉堡（sm 抽屉开关 / md+lg 收起唤回）、标题=当前库名、「库管理」入口 */
  @Builder
  Appbar() {
    Row() {
      Text('☰')
        .fontSize(18)
        .fontColor('#8E8E93')
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .onClick(() => {
          this.onHamburger();
        })
      Text(this.currentVaultName())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1C1C1E')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 10, right: 10 })
      Text('库管理')
        .fontSize(12)
        .fontColor('#8E8E93')
        .height(28)
        .padding({ left: 10, right: 10 })
        .onClick(() => {
          this.showVaultManager = true;
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: '#E5E5EA' })
    .backgroundColor('#FFFFFF')
  }

  /** sm：单栏内容 + 抽屉侧栏覆盖层（Stack，汉堡开关，点遮罩关闭） */
  @Builder
  SmContent() {
    Stack({ alignContent: Alignment.Start }) {
      this.EditorPane(false)
      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.35)')
          .onClick(() => {
            this.drawerOpen = false;
          })
        VaultSidebar({
          asDrawer: true,
          vaults: this.vaults,
          currentVaultId: this.currentVaultId,
          onSwitchVault: (id: string): void => {
            this.doSwitchVault(id);
          },
          onManageVaults: (): void => {
            this.drawerOpen = false;
            this.showVaultManager = true;
          }
        })
          .width(280)
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
            onCollapse: (): void => {
              this.sidebarCollapsed = true;
            },
            onSwitchVault: (id: string): void => {
              this.doSwitchVault(id);
            },
            onManageVaults: (): void => {
              this.showVaultManager = true;
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { right: 1 }, color: '#E5E5EA' })

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
          .border({ width: { left: 1 }, color: '#E5E5EA' })
        }
      } else if (this.breakpoint === Breakpoint.MD) {
        // md 收起：腾出的那一栏给预览 → 编辑 | 预览 各一整块屏，仍不跨折痕
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
        .border({ width: { left: 1 }, color: '#E5E5EA' })
      } else {
        // lg 收起：编辑扩 2/3 —— 会跨越第一条折痕，这是物理限制非 bug；
        // 编辑区内渲染红色虚线折痕警示（位置见 EditorPane 注释）+ 预览 1/3
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
        .border({ width: { left: 1 }, color: '#E5E5EA' })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 编辑区占位（真实编辑器 v0.2 接入；结构照原型 editor-pane）。
   * showHingeWarning：lg 收起态专用——编辑区扩到 2/3 会跨第一条折痕。
   * 这是物理限制不是 bug：折痕位置硬件固定，某栏占不止一块屏必然横跨折痕（原型标红）。
   * 警示线位置 = 编辑区宽的 50%：第一条折痕在整体宽度 1/3 处，编辑区占整体 2/3，
   * 1/3 ÷ 2/3 = 50%。折痕实际坐标只做日志采集（TODO(真机校准)），不进布局算式（FR-003）。
   */
  @Builder
  EditorPane(showHingeWarning: boolean) {
    Column() {
      Row() {
        Text('源模式')
          .fontSize(12)
          .fontColor('#8E8E93')
      }
      .width('100%')
      .height(34)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { bottom: 1 }, color: '#E5E5EA' })
      .backgroundColor('#FFFFFF')

      Stack() {
        Column() {
          Text('编辑区 · v0.2')
            .fontSize(14)
            .fontColor('#8E8E93')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#FFFFFF')

        if (showHingeWarning) {
          // 被内容横跨的折痕：红色虚线竖标（零宽 Column + 左边框），照原型 .hinge.crossed
          Column()
            .width(0)
            .height('100%')
            .border({ width: { left: 2 }, color: '#E0483C', style: BorderStyle.Dashed })
            .position({ x: '50%' })
          Text('被内容横跨')
            .fontSize(10)
            .fontColor('#E0483C')
            .position({ x: '50%', y: 10 })
            .translate({ x: 4 })
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 预览区占位（真实预览 v0.2 接入；结构照原型 preview-pane） */
  @Builder
  PreviewPane() {
    Column() {
      Row() {
        Text('预览')
          .fontSize(12)
          .fontColor('#8E8E93')
      }
      .width('100%')
      .height(34)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .border({ width: { bottom: 1 }, color: '#E5E5EA' })
      .backgroundColor('#FFFFFF')

      Column() {
        Text('预览 · v0.2')
          .fontSize(14)
          .fontColor('#8E8E93')
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
  }

  /** 库管理视图：整体替换内容区，自带返回（原型 vaultsView 结构） */
  @Builder
  ManagerView() {
    VaultManagerView({
      vaults: this.vaults,
      currentVaultId: this.currentVaultId,
      onBack: (): void => {
        this.showVaultManager = false;
      },
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
      Text(this.currentVaultName())
        .fontSize(12)
        .fontColor('#8E8E93')
        .maxLines(1)
      Blank()
      Text(formLabelOf(this.breakpoint) + ' · ' + Math.round(this.windowWidthVp) + 'vp')
        .fontSize(12)
        .fontColor('#8E8E93')
    }
    .width('100%')
    .height(26)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: '#E5E5EA' })
    .backgroundColor('#FAFAFC')
  }
}
