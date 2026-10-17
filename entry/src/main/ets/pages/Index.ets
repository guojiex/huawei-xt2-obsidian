/**
 * Index.ets —— 三形态布局总装（v0.1 骨架）
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
 */
import { Breakpoint } from '../model/Breakpoint';
import { VaultRegistry } from '../model/VaultRegistry';
import { VaultSidebar } from '../components/VaultSidebar';

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
  /** 当前库 id（数据源 VaultRegistry；库 CRUD 后 refreshFromRegistry） */
  @State currentVaultId: string = '';
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State sidebarCollapsed: boolean = false;
  /** 库管理视图整体替换内容区（原型 vaultsView 结构） */
  @State showVaultManager: boolean = false;

  aboutToAppear(): void {
    this.refreshFromRegistry();
  }

  /** 从注册表刷新当前库（库切换/新建/改名/删除后调用） */
  private refreshFromRegistry(): void {
    this.currentVaultId = VaultRegistry.get().currentId();
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

  build() {
    Column() {
      this.Appbar()
      Stack() {
        if (this.showVaultManager) {
          this.ManagerPlaceholder()
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
      this.EditorPane()
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
          currentVaultId: this.currentVaultId,
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
            currentVaultId: this.currentVaultId,
            onCollapse: (): void => {
              this.sidebarCollapsed = true;
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
            this.EditorPane()
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          // lg 展开：侧栏 | 编辑 | 预览 各 1/3
          Column() {
            this.EditorPane()
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
          this.EditorPane()
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
        // lg 收起：编辑扩 2/3 —— 会跨越第一条折痕，这是物理限制非 bug（T016 加红警示）
        Column() {
          this.EditorPane()
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

  /** 编辑区占位（真实编辑器 v0.2 接入；结构照原型 editor-pane） */
  @Builder
  EditorPane() {
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

      Column() {
        Text('编辑区 · v0.2')
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

  /** 库管理视图占位（T012/T013 接入真实 VaultManagerView 后移除） */
  @Builder
  ManagerPlaceholder() {
    Column({ space: 12 }) {
      Text('库管理视图 · v0.1 占位')
        .fontSize(14)
        .fontColor('#8E8E93')
      Button('返回笔记')
        .fontSize(12)
        .fontColor('#534AB7')
        .backgroundColor('#EEEDFE')
        .height(32)
        .padding({ left: 14, right: 14 })
        .onClick(() => {
          this.showVaultManager = false;
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FFFFFF')
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
