/**
 * ApplicationBackupDialog.ets —— v1.66 应用备份导出 / 全量恢复（原型 v2 appBackupDialog）。
 * 双模式：export 直达 review，import 从 choose 选文件；分步 choose → review → confirm →
 * working → done / error。恢复提交成功后停在 done，等「查看知识库」再触发应用级重载回调。
 */
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import {
  ApplicationBackupOutcome, ApplicationBackupPreview
} from '../model/ApplicationBackupService';
import { VaultEntry } from '../model/Vault';
import { FocusRequest } from '../common/FocusRequest';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';
import { UtilityDialogShell } from './UtilityDialogShell';

@CustomDialog
export struct ApplicationBackupDialog {
  controller?: CustomDialogController;
  /** 'export' | 'import'：设置页「导出应用备份」/「从备份恢复」两种入口模式。 */
  @Prop mode: string = 'export';
  @Prop vaults: VaultEntry[] = [];
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  onExport: () => Promise<ApplicationBackupOutcome> = async (): Promise<ApplicationBackupOutcome> => {
    return { status: 'failed', detail: '应用备份导出暂不可用。', preview: null };
  };
  onChoose: () => Promise<ApplicationBackupOutcome> = async (): Promise<ApplicationBackupOutcome> => {
    return { status: 'cancelled', detail: '', preview: null };
  };
  onPrepareRestore: () => Promise<boolean> = async (): Promise<boolean> => true;
  onRestore: () => Promise<ApplicationBackupOutcome> = async (): Promise<ApplicationBackupOutcome> => {
    return { status: 'failed', detail: '应用备份恢复暂不可用。', preview: null };
  };
  onRestoreCompleted: () => Promise<void> = async (): Promise<void> => {};
  onRestoreFailed: (status: string) => void = (_status: string) => {};
  onCancel: () => void = () => {};
  onDismiss: (restored: boolean) => void = (_restored: boolean) => {};

  @State private step: string = 'review';
  @State private busy: boolean = false;
  @State private preview: ApplicationBackupPreview | null = null;
  @State private confirmed: boolean = false;
  @State private errorText: string = '';
  @State private inlineExported: boolean = false;
  @State private inlineExporting: boolean = false;
  @State private recoveryBlocked: boolean = false;
  private workingTitle: string = '';
  private workingCopy: string = '';
  private doneTitle: string = '';
  private doneCopy: string = '';
  private dismissed: boolean = false;
  private restored: boolean = false;
  private doneHandled: boolean = false;

  aboutToAppear(): void {
    this.step = this.mode === 'import' ? 'choose' : 'review';
  }

  private close(): void {
    if (this.busy || this.recoveryBlocked) {
      return;
    }
    if (this.step === 'done' && this.restored) {
      void this.finishRestoreAtDone();
      return;
    }
    this.finishClose(false);
  }

  private finishClose(wasRestored: boolean): void {
    if (this.dismissed) {
      return;
    }
    this.dismissed = true;
    this.controller?.close();
    if (!wasRestored) {
      this.onCancel();
    }
    this.onDismiss(wasRestored);
  }

  aboutToDisappear(): void {
    // 卸载兜底：恢复已提交但用户没点「查看知识库」就离开了（如外层视图切换），
    // 仍要触发应用级重载回调；doneHandled 防与 finishRestoreAtDone 重复触发。
    if (this.restored && !this.doneHandled) {
      this.doneHandled = true;
      this.onRestoreCompleted().catch((): void => {
        this.onRestoreFailed('recovery_required');
      });
    }
    if (!this.dismissed && !this.restored) {
      this.dismissed = true;
      this.onCancel();
      this.onDismiss(false);
    }
  }

  private onDialogKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ESCAPE) {
      return false;
    }
    if (this.busy || this.recoveryBlocked) {
      return true;
    }
    if (this.step === 'confirm') {
      this.step = 'review';
      this.confirmed = false;
      this.errorText = '';
      this.inlineExported = false;
      return true;
    }
    this.close();
    return true;
  }

  private async runChoose(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.step = 'working';
    this.workingTitle = '正在校验备份';
    this.workingCopy = '正在读取并校验备份文件，请稍候…';
    try {
      const outcome: ApplicationBackupOutcome = await this.onChoose();
      if (outcome.status === 'selected' && outcome.preview !== null) {
        this.preview = outcome.preview;
        this.confirmed = false;
        this.inlineExported = false;
        this.step = 'review';
      } else if (outcome.status === 'cancelled') {
        this.step = 'choose';
      } else {
        this.errorText = outcome.detail.length > 0 ? outcome.detail : this.failureFor(outcome.status);
        this.step = 'error';
      }
    } catch (_error) {
      this.errorText = '备份校验未完成。请选择有效文件后重试。';
      this.step = 'error';
    } finally {
      this.busy = false;
    }
  }

  private async exportFromReview(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.step = 'working';
    this.workingTitle = '正在打包备份';
    this.workingCopy = '正在打包并保存应用数据，请勿关闭应用。';
    try {
      const outcome: ApplicationBackupOutcome = await this.onExport();
      if (outcome.status === 'ok') {
        this.doneTitle = '应用备份已保存';
        this.doneCopy = '备份已保存到所选位置。备份包含笔记正文，请妥善保存。';
        this.step = 'done';
      } else if (outcome.status === 'cancelled') {
        this.step = 'review';
      } else {
        this.errorText = outcome.detail.length > 0 ? outcome.detail : '导出失败，原有数据未更改。';
        this.step = 'review';
      }
    } catch (_error) {
      this.errorText = '应用备份未完成，原有数据未更改。请重试。';
      this.step = 'review';
    } finally {
      this.busy = false;
    }
  }

  /** confirm 屏内联「先导出当前应用数据」：与原型的整体切模式不同，保留 import 上下文、导出后回 confirm。 */
  private async exportFromConfirm(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.inlineExporting = true;
    this.step = 'working';
    this.workingTitle = '正在打包备份';
    this.workingCopy = '正在打包并保存应用数据，请勿关闭应用。';
    try {
      const outcome: ApplicationBackupOutcome = await this.onExport();
      if (outcome.status === 'ok') {
        this.inlineExported = true;
        this.confirmed = false;
      } else if (outcome.status !== 'cancelled') {
        this.errorText = outcome.detail.length > 0 ? outcome.detail
          : '应用备份未完成，原有数据未更改。请重试。';
      }
    } catch (_error) {
      this.errorText = '应用备份未完成，原有数据未更改。请重试。';
    } finally {
      this.inlineExporting = false;
      this.busy = false;
      this.step = 'confirm';
    }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy || !this.confirmed || this.preview === null) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.step = 'working';
    this.workingTitle = '正在恢复数据';
    this.workingCopy = '正在替换当前应用数据，请勿关闭应用。';
    try {
      if (!await this.onPrepareRestore()) {
        this.errorText = '编辑中的笔记尚未安全保存，请稍后重试。';
        this.step = 'confirm';
        return;
      }
      const outcome: ApplicationBackupOutcome = await this.onRestore();
      if (outcome.status === 'ok') {
        this.restored = true;
        this.doneTitle = '数据已恢复';
        this.doneCopy = '已按备份内容替换当前数据。外部目录需重新授权，Git 访问令牌需重新填写。';
        this.step = 'done';
        return;
      }
      this.onRestoreFailed(outcome.status);
      this.errorText = outcome.detail.length > 0 ? outcome.detail : this.failureFor(outcome.status);
      this.confirmed = false;
      if (outcome.status === 'recovery_required') {
        this.recoveryBlocked = true;
      }
      this.step = 'error';
    } catch (_error) {
      this.onRestoreFailed('failed');
      this.errorText = '恢复未完成，当前数据已保持原状。请重新选择备份或稍后重试。';
      this.step = 'error';
      this.confirmed = false;
    } finally {
      this.busy = false;
    }
  }

  /** done 屏「查看知识库」：触发应用级重载；重载回调失败转 recovery_required 错误屏。 */
  private async finishRestoreAtDone(): Promise<void> {
    if (this.busy || this.doneHandled || !this.restored) {
      return;
    }
    this.doneHandled = true;
    this.busy = true;
    try {
      await this.onRestoreCompleted();
    } catch (_error) {
      this.onRestoreFailed('recovery_required');
      this.recoveryBlocked = true;
      this.busy = false;
      this.errorText = '数据已恢复，但应用尚未重新载入。请结束应用进程，再重新打开曜石笔记。';
      this.step = 'error';
      return;
    }
    this.finishClose(true);
  }

  private failureFor(status: string): string {
    if (status === 'newer') {
      return '备份由较新版本创建，请升级曜石笔记后再恢复。';
    }
    if (status === 'recovery_required') {
      return '恢复状态尚未确认。请重新打开应用以自动回滚，再重试。';
    }
    return '备份文件不可用或已损坏。原有数据未更改，请选择其他文件重试。';
  }

  private headerTitle(): string {
    if (this.inlineExporting || this.mode !== 'import') {
      return '导出应用备份';
    }
    return '从备份恢复';
  }

  private headerLead(): string {
    if (this.inlineExporting || this.mode !== 'import') {
      return '把全部本地库与应用设置一起带走';
    }
    return this.step === 'confirm' ? '恢复前，请确认替换范围' : '先检查备份，再决定是否恢复';
  }

  private overviewEyebrow(): string {
    if (this.mode === 'import' && this.preview !== null) {
      return this.preview.fileName + ' · ' + this.sizeText(this.preview.archiveBytes) +
        ' · ' + this.dateText(this.preview.createdAt);
    }
    return '一个 ZIP 文件 · 包含以下内容';
  }

  private overviewSummary(): string {
    if (this.mode === 'import' && this.preview !== null) {
      return this.preview.vaults.length.toString() + ' 个知识库 · ' +
        this.preview.fileCount.toString() + ' 个文件';
    }
    return this.vaults.length.toString() + ' 个知识库';
  }

  private overviewNames(): string {
    if (this.mode === 'import') {
      if (this.preview === null || this.preview.vaults.length === 0) {
        return '备份中没有已登记的知识库';
      }
      const names: string[] = [];
      for (let i: number = 0; i < this.preview.vaults.length; i++) {
        names.push(this.preview.vaults[i].id);
      }
      return names.join('、');
    }
    if (this.vaults.length === 0) {
      return '没有知识库，仍可备份应用设置';
    }
    const names: string[] = [];
    for (let i: number = 0; i < this.vaults.length; i++) {
      names.push(this.vaults[i].id);
    }
    return names.join('、');
  }

  private replaceSummary(): string {
    const backupCount: number = this.preview !== null ? this.preview.vaults.length : 0;
    return '当前 ' + this.vaults.length.toString() + ' 个知识库与应用偏好 → 备份中的 ' +
      backupCount.toString() + ' 个知识库与偏好';
  }

  private errorNote(): string {
    if (this.recoveryBlocked) {
      return '应用正在等待启动时继续处理恢复记录。请从系统任务管理器结束应用，再重新打开。';
    }
    return '当前数据保持原状。可以重新选择备份或取消返回。';
  }

  private dateText(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    const hour: string = date.getHours().toString().padStart(2, '0');
    const minute: string = date.getMinutes().toString().padStart(2, '0');
    return date.getFullYear().toString() + '-' + month + '-' + day + ' ' + hour + ':' + minute;
  }

  private sizeText(bytes: number): string {
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }

  private actionBackground(primary: boolean, enabled: boolean, danger: boolean): ResourceColor {
    if (primary && enabled) {
      return danger ? $r('app.color.danger') : $r('app.color.brand');
    }
    if (primary) {
      // 32.12：主 / 危险操作禁用态中性化——line 底、tertiary 字、不透明。
      return $r('app.color.line');
    }
    return $r('app.color.bg_secondary');
  }

  @Builder
  private HeaderTexts() {
    Text(this.headerTitle())
      .fontSize(FontSize.s3)
      .fontWeight(Weight.semibold)
      .fontColor($r('app.color.text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Text(this.headerLead())
      .fontSize(FontSize.caption)
      .fontColor($r('app.color.text_secondary'))
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  /** 原型 .backup-note：--nav 底、muted 字、small-r 圆角。 */
  @Builder
  private NoteText(text: string) {
    Text(text)
      .fontSize(FontSize.body2)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.bg_secondary'))
  }

  /** 原型 .backup-warning：--focus（2px）左 danger 边 + danger 6% 底。 */
  @Builder
  private WarningText(text: string) {
    Text(text)
      .fontSize(FontSize.body2)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
      .borderRadius(Radius.control)
      .border({ width: { left: 2 }, color: $r('app.color.danger') })
      .backgroundColor($r('app.color.danger_bg'))
  }

  /** 原型 .backup-inline：brand 字、触控高、左对齐内联动作。 */
  @Builder
  private InlineAction(label: string, action: () => void) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontColor($r('app.color.brand'))
      .width('100%')
      .constraintSize({ minHeight: Size.touch })
      .textAlign(TextAlign.Start)
      .enabled(!this.busy)
      .focusable(!this.busy)
      .onClick(action)
  }

  /** 原型 .backup-contents li：strong（--small/500/ink）+ small（caption/muted）。 */
  @Builder
  private BackupContentItem(title: string, detail: string) {
    Column({ space: Space.s1 }) {
      Text(title)
        .fontSize(FontSize.body2)
        .fontWeight(Weight.medium)
        .fontColor($r('app.color.text_primary'))
      Text(detail)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 原型 .backup-overview：--nav 底、eyebrow caption / h3 --large / p --small。 */
  @Builder
  private BackupOverview() {
    Column({ space: Space.s1 }) {
      Text(this.overviewEyebrow())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.overviewSummary())
        .fontSize(FontSize.s3)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
      Text(this.overviewNames())
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding(Space.s4)
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_secondary'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 原型 #appBackupChoose：directory-choice 卡 + backup-note。 */
  @Builder
  private ChooseSection() {
    Column({ space: Space.s4 }) {
      Row({ space: Space.s4 }) {
        Stack({ alignContent: Alignment.Center }) {
          Row() {
            Icon('doc', Space.s6, $r('app.color.brand'))
          }
          .width(Space.s12)
          .height(Space.s12)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_card'))
        }
        Column({ space: Space.s1 }) {
          Text('选择应用备份文件')
            .fontSize(FontSize.body1)
            .fontWeight(Weight.semibold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('选择由「导出应用备份」生成的 ZIP 文件')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('选择')
          .fontSize(FontSize.caption)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.brand'))
          .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s1 })
          .borderRadius(Radius.full)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_card'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.brand'), style: BorderStyle.Dashed })
      .backgroundColor($r('app.color.bg_secondary'))
      .constraintSize({ minHeight: Space.s16 + Space.s6 })
      .focusable(true)
      .id('app-backup-choose-card')
      .accessibilityText('选择应用备份文件，打开系统文件选择器')
      .onClick((): void => { void this.runChoose(); })
      .onAppear((): void => {
        setTimeout((): void => {
          FocusRequest.safely(this.getUIContext(), 'app-backup-choose-card');
        }, 0);
      })
      this.NoteText('单个知识库的 ZIP 请使用「导入库 → ZIP 文件」，不会替换整个应用。')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 原型 #appBackupReview：overview + contents + scope note + 失败提示 / 重选。 */
  @Builder
  private ReviewSection() {
    Column({ space: Space.s4 }) {
      this.BackupOverview()
      Column({ space: Space.s3 }) {
        this.BackupContentItem('知识库与文件', '笔记、图片附件、回收站、草稿与 Git 历史')
        this.BackupContentItem('应用设置与使用偏好', '库列表、置顶、收藏、排序、外观与编辑器设置')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      this.NoteText('不包含 Git 访问令牌、缓存和搜索索引。外部目录只备份关联信息，文件请另行备份；' +
        '恢复后需重新授权。写作统计按文件时间重新计算。')
      if (this.errorText.length > 0) {
        this.WarningText(this.errorText)
      }
      if (this.mode === 'import') {
        this.InlineAction('重新选择文件', (): void => { void this.runChoose(); })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 原型 #appBackupConfirm：overview + warning + 内联导出 + 确认勾选。 */
  @Builder
  private ConfirmSection() {
    Column({ space: Space.s4 }) {
      Column({ space: Space.s1 }) {
        Text('即将从所选备份恢复')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
        Text('替换当前全部数据？')
          .fontSize(FontSize.s3)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
        Text(this.replaceSummary())
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .backgroundColor($r('app.color.bg_secondary'))
      .alignItems(HorizontalAlign.Start)
      this.WarningText('当前全部知识库、回收站、草稿与应用设置将被备份内容替换，无法撤销。' +
        '不会合并同名库。外部目录中的文件不会被替换，恢复关联后需重新授权。')
      if (this.inlineExported) {
        this.NoteText('当前数据已导出到所选位置。')
      }
      if (this.errorText.length > 0) {
        this.WarningText(this.errorText)
      }
      this.InlineAction('先导出当前应用数据', (): void => { void this.exportFromConfirm(); })
      Row({ space: Space.s2 }) {
        if (this.confirmed) {
          Text('✓')
            .fontSize(FontSize.body2)
            .fontWeight(Weight.semibold)
            .fontColor($r('app.color.on_brand'))
            .width(Space.s5)
            .height(Space.s5)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.chip)
            .backgroundColor($r('app.color.brand'))
            .margin({ top: Space.s1 })
        } else {
          Text('')
            .width(Space.s5)
            .height(Space.s5)
            .borderRadius(Radius.chip)
            .border({ width: 2, color: $r('app.color.brand') })
            .margin({ top: Space.s1 })
        }
        Text('我了解当前数据将被替换，且无法撤销')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .constraintSize({ minHeight: Size.touch })
      .focusable(!this.busy)
      .accessibilityText(this.confirmed ? '已确认替换当前数据' : '确认替换当前数据')
      .onClick((): void => {
        if (!this.busy) {
          this.confirmed = !this.confirmed;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 原型 .backup-result-mark：s16 圆、blue-soft 底、heading 号。 */
  @Builder
  private ResultMark(mark: string) {
    Text(mark)
      .fontSize(FontSize.heading)
      .fontColor($r('app.color.brand'))
      .width(Space.s16)
      .height(Space.s16)
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.brand_bg'))
  }

  /** 原型 #appBackupWorking：backup-result 居中态。 */
  @Builder
  private WorkingSection() {
    Column({ space: Space.s3 }) {
      this.ResultMark('…')
      Text(this.workingTitle)
        .fontSize(FontSize.s3)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
      Text(this.workingCopy)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: Space.s5, bottom: Space.s5 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 原型 #appBackupDone：backup-result 居中态。 */
  @Builder
  private DoneSection() {
    Column({ space: Space.s3 }) {
      this.ResultMark('✓')
      Text(this.doneTitle)
        .fontSize(FontSize.s3)
        .fontWeight(Weight.semibold)
        .fontColor($r('app.color.text_primary'))
      Text(this.doneCopy)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: Space.s5, bottom: Space.s5 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 原型 #appBackupError：warning（具体原因）+ note（后续指引）。 */
  @Builder
  private ErrorSection() {
    Column({ space: Space.s4 }) {
      this.WarningText(this.errorText)
      this.NoteText(this.errorNote())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DialogContent() {
    Column({ space: Space.s4 }) {
      if (this.step === 'choose') {
        this.ChooseSection()
      } else if (this.step === 'review') {
        this.ReviewSection()
      } else if (this.step === 'confirm') {
        this.ConfirmSection()
      } else if (this.step === 'working') {
        this.WorkingSection()
      } else if (this.step === 'done') {
        this.DoneSection()
      } else {
        this.ErrorSection()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private Action(label: string, primary: boolean, enabled: boolean, action: () => void, danger: boolean) {
    Text(label)
      .fontSize(FontSize.body1)
      .fontWeight(FontWeight.Medium)
      .fontColor(!enabled && primary
        ? $r('app.color.text_tertiary')
        : primary ? $r('app.color.on_brand') : $r('app.color.text_primary'))
      .height(Size.touch)
      .layoutWeight(this.singleScreen ? 1 : 0)
      .constraintSize({ minWidth: this.singleScreen ? 0 : Space.s16 + Space.s8 })
      .padding({ left: Space.s5, right: Space.s5 })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.full)
      .backgroundColor(this.actionBackground(primary, enabled, danger))
      .opacity(!enabled && !primary ? 0.45 : 1)
      .enabled(enabled)
      .focusable(enabled)
      .onClick(action)
  }

  @Builder
  private DialogFooter() {
    Row({ space: Space.s3 }) {
      if (this.step === 'choose') {
        this.Action('取消', false, !this.busy, (): void => { this.close(); }, false)
        this.Action('检查并继续', true, false, (): void => { void this.runChoose(); }, false)
      } else if (this.step === 'review') {
        this.Action('取消', false, !this.busy, (): void => { this.close(); }, false)
        if (this.mode === 'import') {
          this.Action('检查并继续', true, !this.busy, (): void => {
            this.step = 'confirm';
            this.confirmed = false;
            this.errorText = '';
          }, false)
        } else {
          this.Action('导出备份', true, !this.busy, (): void => { void this.exportFromReview(); }, false)
        }
      } else if (this.step === 'confirm') {
        this.Action('上一步', false, !this.busy, (): void => {
          this.step = 'review';
          this.confirmed = false;
          this.errorText = '';
          this.inlineExported = false;
        }, false)
        // L-7/Z2（api_notes）：@Builder 按值实参是调用时快照——enabled 若传
        // `!this.busy && this.confirmed` 表达式，勾选后按钮仍冻结在禁用态、点击无效
        //（Z2 EM-B2 同症状）。勾选态必须走 if 分支（同弹窗 if/表达式照常刷新），分支内只传常量。
        if (this.confirmed) {
          this.Action('替换并恢复', true, !this.busy, (): void => {
            void this.restoreBackup();
          }, true)
        } else {
          this.Action('替换并恢复', true, false, (): void => {
            void this.restoreBackup();
          }, true)
        }
      } else if (this.step === 'working') {
        this.Action('取消', false, false, (): void => { this.close(); }, false)
        this.Action('正在处理…', true, false, (): void => {}, false)
      } else if (this.step === 'done') {
        this.Action('关闭', false, !this.busy, (): void => { this.close(); }, false)
        if (this.mode === 'import') {
          this.Action('查看知识库', true, !this.busy, (): void => { void this.finishRestoreAtDone(); }, false)
        } else {
          this.Action('完成', true, !this.busy, (): void => { this.close(); }, false)
        }
      } else if (this.recoveryBlocked) {
        this.Action('请重新打开应用', false, false, (): void => {}, false)
      } else {
        this.Action('取消', false, !this.busy, (): void => { this.close(); }, false)
        this.Action('重新选择文件', true, !this.busy, (): void => {
          this.step = 'choose';
        }, false)
      }
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      headerIcon: 'archive',
      closeLabel: '关闭应用备份',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.utilityDialogW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => { this.close(); },
      headerTexts: (): void => { this.HeaderTexts(); },
      content: (): void => { this.DialogContent(); },
      footer: (): void => { this.DialogFooter(); }
    })
    .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
  }
}
