/** Whole-app backup and full-replacement restore flow for v1.66. */
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import {
  ApplicationBackupOutcome, ApplicationBackupPreview, ApplicationBackupVaultPreview
} from '../model/ApplicationBackupService';
import { VaultEntry } from '../model/Vault';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';
import { UtilityDialogShell } from './UtilityDialogShell';

@CustomDialog
export struct ApplicationBackupDialog {
  controller?: CustomDialogController;
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

  @State private step: string = 'home';
  @State private busy: boolean = false;
  @State private preview: ApplicationBackupPreview | null = null;
  @State private confirmed: boolean = false;
  @State private errorText: string = '';
  @State private successText: string = '';
  private dismissed: boolean = false;
  private restored: boolean = false;
  private recoveryBlocked: boolean = false;

  private close(): void {
    if (this.busy || this.recoveryBlocked) {
      return;
    }
    this.finishClose(false);
  }

  private finishClose(wasRestored: boolean): void {
    if (this.dismissed) {
      return;
    }
    this.dismissed = true;
    this.restored = wasRestored;
    this.controller?.close();
    if (!wasRestored) {
      this.onCancel();
    }
    this.onDismiss(wasRestored);
  }

  aboutToDisappear(): void {
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
      this.step = 'preview';
      this.confirmed = false;
      this.errorText = '';
      return true;
    }
    this.close();
    return true;
  }

  private async exportBackup(): Promise<boolean> {
    if (this.busy) {
      return false;
    }
    this.busy = true;
    this.errorText = '';
    this.successText = '';
    this.step = 'exporting';
    let saved: boolean = false;
    try {
      const outcome: ApplicationBackupOutcome = await this.onExport();
      if (outcome.status === 'ok') {
        saved = true;
        this.successText = '应用备份已保存到所选位置。';
        this.step = 'export_done';
      } else if (outcome.status === 'cancelled') {
        this.step = 'home';
      } else {
        this.errorText = outcome.detail.length > 0 ? outcome.detail : '导出失败，原有数据未更改。';
        this.step = 'home';
      }
    } catch (_error) {
      this.errorText = '应用备份未完成，原有数据未更改。请重试。';
      this.step = 'home';
    } finally {
      this.busy = false;
    }
    return saved;
  }

  private async chooseBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.successText = '';
    this.step = 'choosing';
    try {
      const outcome: ApplicationBackupOutcome = await this.onChoose();
      if (outcome.status === 'selected' && outcome.preview !== null) {
        this.preview = outcome.preview;
        this.confirmed = false;
        this.step = 'preview';
      } else if (outcome.status === 'cancelled') {
        this.step = 'home';
      } else {
        this.errorText = outcome.detail.length > 0 ? outcome.detail : this.failureFor(outcome.status);
        this.step = 'home';
      }
    } catch (_error) {
      this.errorText = '备份校验未完成。请选择有效文件后重试。';
      this.step = 'home';
    } finally {
      this.busy = false;
    }
  }

  private async exportBeforeRestore(): Promise<void> {
    const exported: boolean = await this.exportBackup();
    if (exported) {
      this.step = 'confirm';
      this.confirmed = false;
      this.errorText = '';
    }
  }

  private async restoreBackup(): Promise<void> {
    if (this.busy || !this.confirmed || this.preview === null) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.step = 'restoring';
    try {
      if (!await this.onPrepareRestore()) {
        this.errorText = '编辑中的笔记尚未安全保存，请稍后重试。';
        this.step = 'confirm';
        this.busy = false;
        return;
      }
      const outcome: ApplicationBackupOutcome = await this.onRestore();
      if (outcome.status === 'ok') {
        try {
          await this.onRestoreCompleted();
        } catch (_refreshError) {
          this.onRestoreFailed('recovery_required');
          this.recoveryBlocked = true;
          this.errorText = '数据已恢复，但应用尚未重新载入。请结束应用进程，再重新打开曜石笔记。';
          this.step = 'recovery_required';
          this.confirmed = false;
          return;
        }
        this.finishClose(true);
        return;
      }
      this.onRestoreFailed(outcome.status);
      this.errorText = outcome.detail.length > 0 ? outcome.detail : this.failureFor(outcome.status);
      if (outcome.status === 'recovery_required') {
        this.recoveryBlocked = true;
        this.step = 'recovery_required';
        this.errorText = outcome.detail.length > 0 ? outcome.detail : this.failureFor(outcome.status);
      } else {
        this.step = 'confirm';
      }
      this.confirmed = false;
    } catch (_error) {
      this.onRestoreFailed('failed');
      this.errorText = '恢复未完成。请重试或重新选择备份；若已提示重启，请先重新打开应用。';
      this.step = 'confirm';
      this.confirmed = false;
    } finally {
      this.busy = false;
    }
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

  private vaultLocationText(rootKind: string): string {
    return rootKind === 'external' ? '外部目录（不含目录内容）' : '沙箱库（完整内容）';
  }

  @Builder
  private VaultRows(vaults: VaultEntry[]) {
    if (vaults.length === 0) {
      Text('尚无已登记的知识库；应用偏好、草稿与回收站仍会纳入备份。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    } else {
      Column({ space: Space.s1 }) {
        ForEach(vaults, (vault: VaultEntry): void => {
          Row({ space: Space.s2 }) {
            Text(vault.id)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.vaultLocationText(vault.rootKind === 'external' ? 'external' : 'sandbox'))
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
        }, (vault: VaultEntry): string => vault.id)
      }
      .width('100%')
    }
  }

  @Builder
  private PreviewVaultRows(preview: ApplicationBackupPreview) {
    if (preview.vaults.length === 0) {
      Text('备份中没有已登记的知识库')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    } else {
      Column({ space: Space.s1 }) {
        ForEach(preview.vaults, (vault: ApplicationBackupVaultPreview): void => {
          Row({ space: Space.s2 }) {
            Text(vault.id)
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.vaultLocationText(vault.rootKind))
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
        }, (vault: ApplicationBackupVaultPreview): string => vault.id)
      }
      .width('100%')
    }
  }

  @Builder
  private DialogContent() {
    Column({ space: Space.s3 }) {
      if (this.step === 'home' || this.step === 'export_done' || this.step === 'exporting' ||
        this.step === 'choosing') {
        Text('导出为单个 ZIP，恢复会完整替换当前全部沙箱库与应用偏好。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        this.VaultRows(this.vaults)
        Text('包含：沙箱库、回收站、草稿、Agent 本地记录及偏好。排除：搜索索引、缓存与 Git 令牌。外部目录只保存登记信息。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
        if (this.successText.length > 0) {
          Text(this.successText)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.brand'))
            .width('100%')
        }
        if (this.busy) {
          Text(this.step === 'exporting' ? '正在打包并保存应用数据…' : '正在选择并校验备份…')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      } else if (this.step === 'preview' || this.step === 'confirm' || this.step === 'restoring' ||
        this.step === 'recovery_required') {
        if (this.preview !== null) {
          Text(this.preview.fileName)
            .fontSize(FontSize.body2)
            .fontWeight(Weight.semibold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.dateText(this.preview.createdAt) + ' · ' + this.sizeText(this.preview.archiveBytes) +
            ' · ' + this.preview.vaults.length.toString() + ' 个知识库 · ' +
            this.preview.fileCount.toString() + ' 个文件')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          this.PreviewVaultRows(this.preview)
          if (this.step === 'preview') {
            Text('已完成格式、条目、安全路径与内容校验；尚未修改当前数据。')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          } else {
            Text('将全量替换当前全部沙箱知识库、回收站、草稿、Agent 记录与应用偏好。外部目录内容、搜索索引、缓存与令牌不会从备份恢复。')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.danger'))
              .width('100%')
            Row({ space: Space.s2 }) {
              Text(this.confirmed ? '✓' : '□')
                .fontSize(FontSize.body1)
                .fontColor($r('app.color.brand'))
              Text('我已了解，并确认替换当前全部应用数据')
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: Space.s2, bottom: Space.s2 })
            .focusable(!this.busy)
            .accessibilityText(this.confirmed ? '已确认全量替换' : '确认全量替换')
            .onClick((): void => {
              if (!this.busy) {
                this.confirmed = !this.confirmed;
              }
            })
          }
        }
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
        if (this.busy) {
          Text('正在恢复应用数据…请勿关闭应用。')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        } else if (this.step === 'recovery_required') {
          Text('应用正在等待启动时继续处理恢复记录。请从系统任务管理器结束应用，再重新打开。')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private Action(label: string, primary: boolean, enabled: boolean, action: () => void) {
    Text(label)
      .fontSize(FontSize.body2)
      .fontWeight(Weight.semibold)
      .fontColor(primary && enabled ? $r('app.color.on_brand') : $r('app.color.text_primary'))
      .height(Size.touch)
      .padding({ left: Space.s4, right: Space.s4 })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.full)
      .backgroundColor(primary && enabled ? $r('app.color.brand') : $r('app.color.bg_secondary'))
      .opacity(enabled ? 1 : 0.45)
      .enabled(enabled)
      .focusable(enabled)
      .onClick(action)
  }

  @Builder
  private DialogFooter() {
    Row({ space: Space.s2 }) {
      if (this.step === 'preview') {
        this.Action('取消', false, !this.busy, (): void => { this.close(); })
        this.Action('查看替换范围', true, !this.busy, (): void => {
          this.step = 'confirm';
          this.confirmed = false;
          this.errorText = '';
        })
      } else if (this.step === 'confirm') {
        this.Action('上一步', false, !this.busy, (): void => {
          this.step = 'preview';
          this.confirmed = false;
          this.errorText = '';
        })
        this.Action('先导出当前数据', false, !this.busy, (): void => {
          void this.exportBeforeRestore();
        })
        this.Action('替换并恢复', true, !this.busy && this.confirmed, (): void => {
          void this.restoreBackup();
        })
      } else if (this.step === 'recovery_required') {
        this.Action('请重新打开应用', false, false, (): void => {})
      } else if (this.step === 'export_done') {
        this.Action('返回', false, !this.busy, (): void => {
          this.step = 'home';
          this.successText = '';
        })
        this.Action('完成', true, !this.busy, (): void => { this.close(); })
      } else if (this.step === 'home') {
        this.Action('导出应用备份', true, !this.busy, (): void => { void this.exportBackup(); })
        this.Action('从备份恢复', false, !this.busy, (): void => { void this.chooseBackup(); })
      } else {
        this.Action('关闭', false, !this.busy, (): void => { this.close(); })
        this.Action('重新选择', true, !this.busy, (): void => { void this.chooseBackup(); })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '应用数据备份',
      subtitle: '完整导出与恢复',
      closeLabel: '关闭应用备份',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.utilityDialogW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => { this.close(); },
      content: (): void => { this.DialogContent(); },
      footer: (): void => { this.DialogFooter(); }
    })
    .onKeyEvent((event: KeyEvent): boolean => { return this.onDialogKey(event); })
  }
}
