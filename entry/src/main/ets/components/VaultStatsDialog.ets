/**
 * VaultStatsDialog.ets —— 写作统计面板外壳（v1.58 58.4，原型 #statsDialog）
 *
 * 宽屏居中弹窗 / 单屏半模态复用 UtilityDialogShell + CustomDialogController
 * （与导入库 / Git 同步同款外壳，32.13 窗口内限高由 shell 保证）。
 * 不再替换内容区、不再是全屏二级页；关闭后焦点由 Index 归还触发入口。
 *
 * ⚠️ CustomDialog 的 @Prop 不会随父组件状态刷新（ImportVaultDialog 文件头结论），
 * 所以扫描结果与三态由本组件自己的 @State 持有：aboutToAppear 发起一次重算
 * （52.1「进页重算」不落盘缓存），父侧 onRequestScan 同时把结果回写给侧栏连写条。
 *
 * 红线（51.6 / 52.4）：统计值只本地计算与展示；本文件不埋点、不写日志、不上报。
 */
import { VaultStatsModel, VaultStatsScanOutcome, emptyStatsModel } from '../model/VaultStatsService';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';
import { UtilityDialogShell } from './UtilityDialogShell';
import { VaultStatsView } from './VaultStatsView';

@CustomDialog
export struct VaultStatsDialog {
  controller?: CustomDialogController;
  @Prop vaultName: string = '';
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  /** 打开即重算：父侧执行一次扫描并把同一结果回写给侧栏连写条。 */
  onRequestScan: () => Promise<VaultStatsScanOutcome> = async (): Promise<VaultStatsScanOutcome> => {
    const outcome: VaultStatsScanOutcome = { model: null, failed: true };
    return outcome;
  };
  onDismiss: () => void = () => {};

  @State private model: VaultStatsModel = emptyStatsModel();
  @State private scanning: boolean = true;
  @State private scanFailed: boolean = false;
  private alive: boolean = true;
  private hasDismissed: boolean = false;

  aboutToAppear(): void {
    void this.loadStats();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private async loadStats(): Promise<void> {
    try {
      const outcome: VaultStatsScanOutcome = await this.onRequestScan();
      if (!this.alive) {
        return;
      }
      this.scanFailed = outcome.failed;
      this.model = outcome.model !== null ? outcome.model : emptyStatsModel();
    } catch (_error) {
      if (!this.alive) {
        return;
      }
      this.scanFailed = true;
      this.model = emptyStatsModel();
    }
    if (this.alive) {
      this.scanning = false;
    }
  }

  private close(): void {
    this.controller?.close();
    if (this.hasDismissed) {
      return;
    }
    this.hasDismissed = true;
    this.onDismiss();
  }

  /** 头部：火焰徽标（暖色 14% 底）+ 标题 + 库名 / 口径副标题 + shell 自带关闭按钮。 */
  @Builder
  DialogHeaderTexts() {
    Row({ space: Space.s3 }) {
      Row() {
        Icon('flame', Space.s5, $r('app.color.cb_warn'))
      }
      .width(Space.s10)
      .height(Space.s10)
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.cb_warn_bg'))
      .justifyContent(FlexAlign.Center)

      Column({ space: Space.s1 }) {
        Text('写作统计')
          .fontSize(FontSize.s3)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(this.vaultName.length > 0
          ? this.vaultName + ' · 只在本机统计' : '只在本机统计')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DialogContent() {
    VaultStatsView({
      vaultName: this.vaultName,
      model: this.model,
      scanFailed: this.scanFailed,
      scanning: this.scanning,
      singleScreen: this.singleScreen,
      windowWidthVp: this.windowWidthVp
    })
  }

  build() {
    UtilityDialogShell({
      title: '写作统计',
      subtitle: this.vaultName.length > 0
        ? this.vaultName + ' · 只在本机统计' : '只在本机统计',
      closeLabel: '关闭写作统计',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.statsDialogW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => { this.close(); },
      content: (): void => { this.DialogContent(); },
      headerTexts: (): void => { this.DialogHeaderTexts(); }
    })
  }
}
