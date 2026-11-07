import { promptAction, UIUtils } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitBranchNameValidation, validateGitBranchName } from '../git/GitBranchName';
import { GitNativeService } from '../git/GitNativeService';
import { Git2ActionOptions, Git2FileChange, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

type GitSyncResult = 'none' | 'success' | 'stale' | 'auth' | 'network' | 'local';

@CustomDialog
export struct GitSyncDialog {
  controller?: CustomDialogController;
  @Prop vaultId: string = '';
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @State pushBranch: string = 'xt2';
  @State branchDraft: string = 'xt2';
  @State branchEditing: boolean = false;
  @State branchError: string = '';
  @State remoteLabel: string = '';
  @State transportLabel: string = 'HTTPS';
  @State trackingBranch: string = '';
  @State authUsername: string = '';
  @State tokenInput: string = '';
  @State credentialEditorOpen: boolean = false;
  @State hasStoredToken: boolean = false;
  @State statusReady: boolean = false;
  @State trackingKnown: boolean = false;
  @State remoteBranchMissing: boolean = false;
  @State localCommitPending: boolean = false;
  @State syncIncludesCommit: boolean = false;
  @State aheadCount: number = 0;
  @State behindCount: number = 0;
  @State statusEntryCount: number = 0;
  @State changes: Git2FileChange[] = [];
  @State lastPushAt: number = 0;
  @State commitMessage: string = '';
  @State authorName: string = '';
  @State authorEmail: string = '';
  @State busy: boolean = false;
  @State checkingRemoteOnly: boolean = false;
  @State progressText: string = '';
  @State currentStep: number = -1;
  @State completedStep: number = -1;
  @State statusMessage: string = '';
  @State result: GitSyncResult = 'none';
  @State resultTitle: string = '';
  @State resultBody: string = '';
  onBusyChange: (busy: boolean) => void = (_busy: boolean) => {};
  onDismiss: () => void = () => {};

  private hasDismissed: boolean = false;

  aboutToAppear(): void {
    const entry: VaultEntry | null = this.findVaultEntry();
    if (entry === null) {
      this.showLocalFailure('当前 Git 库不可用，请返回主页重新打开同步页。');
      return;
    }
    this.pushBranch = entry.pushBranch ?? 'xt2';
    this.branchDraft = this.pushBranch;
    this.trackingBranch = entry.branch ?? '';
    this.authUsername = entry.authUsername ?? '';
    this.lastPushAt = entry.lastSyncAt ?? 0;
    this.remoteLabel = this.remoteHostPath(entry.remote ?? '');
    this.transportLabel = (entry.remote ?? '').toLowerCase().startsWith('https://') ? 'HTTPS' : 'Git';
    this.commitMessage = '更新 0 个文件（曜石笔记）';
    try {
      const storedToken: string | null = GitCredentialStore.getToken(this.vaultId);
      this.hasStoredToken = storedToken !== null && storedToken.length > 0;
      if (!this.hasStoredToken) {
        this.credentialEditorOpen = true;
      }
    } catch (_error) {
      this.hasStoredToken = false;
      this.credentialEditorOpen = true;
    }
    this.refreshLocalStatus();
  }

  private findVaultEntry(): VaultEntry | null {
    const entries: VaultEntry[] = VaultRegistry.get().list();
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === this.vaultId && entries[i].type === 'git') {
        return entries[i];
      }
    }
    return null;
  }

  private remoteHostPath(url: string): string {
    const scheme: number = url.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const authorityEnd: number = url.indexOf('/', authorityStart);
    const authority: string = url.substring(authorityStart,
      authorityEnd >= 0 ? authorityEnd : url.length);
    const host: string = authority.substring(authority.lastIndexOf('@') + 1).split(':')[0];
    if (authorityEnd < 0) {
      return host;
    }
    let pathEnd: number = url.length;
    const query: number = url.indexOf('?', authorityEnd);
    const fragment: number = url.indexOf('#', authorityEnd);
    if (query >= 0 && query < pathEnd) {
      pathEnd = query;
    }
    if (fragment >= 0 && fragment < pathEnd) {
      pathEnd = fragment;
    }
    return host + url.substring(authorityEnd, pathEnd);
  }

  private refreshLocalStatus(): void {
    if (VaultRegistry.get().currentId() !== this.vaultId) {
      this.statusReady = false;
      this.statusMessage = '当前库已切换，请返回主页重新打开同步页。';
      return;
    }
    try {
      const registry: VaultRegistry = VaultRegistry.get();
      const state: Git2RepositoryState =
        GitNativeService.repositoryState(registry.vaultDirOf(this.vaultId), this.pushBranch);
      this.statusReady = true;
      this.trackingKnown = state.trackingKnown;
      this.aheadCount = state.aheadCount;
      this.behindCount = state.behindCount;
      this.statusEntryCount = state.statusEntryCount;
      this.changes = state.changes;
      if (this.trackingKnown && this.aheadCount === 0) {
        this.localCommitPending = false;
      }
      this.commitMessage = this.defaultCommitMessage();
      this.statusMessage = '';
    } catch (_error) {
      this.statusReady = false;
      this.statusMessage = '无法读取本地 Git 状态；请刷新后再决定是否推送。';
    }
  }

  private defaultCommitMessage(): string {
    return '更新 ' + this.changes.length.toString() + ' 个文件（曜石笔记）';
  }

  private defaultBranchMessage(): string {
    const validation: GitBranchNameValidation = validateGitBranchName(this.branchDraft);
    if (!validation.valid) {
      return validation.reason;
    }
    if (this.trackingBranch.length > 0 && this.branchDraft === this.trackingBranch) {
      return '推送会直接更新远端 ' + this.trackingBranch +
        '，仍只允许快进；建议使用单独分支，在电脑上合并。';
    }
    return '只影响当前库；在电脑上把该分支合并到 ' + this.trackingTargetLabel() + '。';
  }

  private isTrackingBranchTarget(): boolean {
    return this.trackingBranch.length > 0 && this.pushBranch === this.trackingBranch;
  }

  private trackingTargetLabel(): string {
    return this.trackingBranch.length > 0 ? this.trackingBranch : '跟踪分支未知';
  }

  private remoteStepIndex(): number {
    return this.syncIncludesCommit ? 2 : 0;
  }

  private progressStepLabels(): string[] {
    return this.syncIncludesCommit
      ? ['暂存改动', '创建提交', '检查远端 ' + this.pushBranch, '推送 ' + this.pushBranch]
      : ['检查远端 ' + this.pushBranch, '推送 ' + this.pushBranch];
  }

  private shouldCommitChanges(): boolean {
    return this.statusEntryCount > 0 && !this.localCommitPending;
  }

  private waitingStatusText(): string {
    if (this.remoteBranchMissing) {
      return '已确认远端无此分支 · ' + this.statusEntryCount.toString() + ' 个未提交改动';
    }
    if (this.trackingKnown) {
      return this.aheadCount.toString() + ' 个已提交 · ' +
        this.statusEntryCount.toString() + ' 个未提交改动';
    }
    if (this.localCommitPending) {
      return '本地提交待远端确认 · ' + this.statusEntryCount.toString() + ' 个未提交改动';
    }
    return '待推送数量未知 · ' + this.statusEntryCount.toString() + ' 个未提交改动';
  }

  private primaryActionEnabled(): boolean {
    return !this.busy && this.canPush() &&
      (!this.shouldCommitChanges() || (this.authorName.trim().length > 0 &&
        this.authorEmail.trim().length > 0));
  }

  private primaryActionLabel(): string {
    if (this.busy) {
      return this.checkingRemoteOnly ? '正在检查远端…' : '正在推送…';
    }
    return this.shouldCommitChanges() ? '提交并推送' : '推送';
  }

  private saveBranch(): void {
    const validation: GitBranchNameValidation = validateGitBranchName(this.branchDraft);
    if (!validation.valid) {
      this.branchError = validation.reason;
      return;
    }
    try {
      VaultRegistry.get().updateGitPushBranch(this.vaultId, this.branchDraft);
      this.pushBranch = this.branchDraft;
      this.remoteBranchMissing = false;
      this.branchEditing = false;
      this.branchError = '';
      this.result = 'none';
      this.refreshLocalStatus();
      this.focusBranchChange();
      promptAction.showToast({ message: '当前库将推送到 ' + this.pushBranch });
    } catch (_error) {
      this.branchError = '分支设置未能保存，请重试。';
    }
  }

  private restoreDefaultBranch(): void {
    this.branchDraft = 'xt2';
    this.branchError = '';
  }

  private cancelBranchEdit(): void {
    this.branchDraft = this.pushBranch;
    this.branchError = '';
    this.branchEditing = false;
    this.focusBranchChange();
  }

  private focusBranchChange(): void {
    setTimeout((): void => {
      this.getUIContext().getFocusController().requestFocus('git-sync-branch-change');
    }, 0);
  }

  private onBranchKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_ENTER) {
      this.saveBranch();
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      this.cancelBranchEdit();
      return true;
    }
    return false;
  }

  private effectiveToken(): string {
    if (this.tokenInput.length > 0) {
      return this.tokenInput;
    }
    try {
      return GitCredentialStore.getToken(this.vaultId) ?? '';
    } catch (_error) {
      return '';
    }
  }

  private isGitHubRemote(): boolean {
    return this.remoteLabel.toLowerCase().startsWith('github.com/') ||
      this.remoteLabel.toLowerCase().startsWith('www.github.com/');
  }

  private makeActionOptions(operation: 'stage' | 'commit' | 'fetch' | 'push',
    token: string, trackSyncProgress: boolean = false): Git2ActionOptions {
    const options: Git2ActionOptions = {
      operation: operation,
      repositoryPath: VaultRegistry.get().vaultDirOf(this.vaultId),
      targetBranch: this.pushBranch,
      onProgress: (progress: Git2Progress): void => {
        this.progressText = GitNativeService.progressLabel(progress);
        if (!trackSyncProgress || !this.busy || progress.operation === undefined) {
          return;
        }
        const step: number = this.remoteStepIndex() + (progress.operation === 'push' ? 1 : 0);
        const label: string = progress.operation === 'push'
          ? '推送到 ' + this.pushBranch + '…'
          : '检查远端 ' + this.pushBranch + '…';
        if (this.currentStep !== step) {
          this.setStep(step, label);
        } else {
          this.progressText = GitNativeService.progressLabel(progress);
        }
      }
    };
    if (token.length > 0) {
      if (this.isGitHubRemote()) {
        options.bearerToken = token;
      } else {
        options.username = this.authUsername.trim();
        options.password = token;
      }
    }
    return options;
  }

  private saveCredentialsAfterRemoteSuccess(token: string): void {
    try {
      VaultRegistry.get().updateGitAuthUsername(this.vaultId,
        this.isGitHubRemote() ? '' : this.authUsername.trim());
    } catch (_error) {
      this.statusMessage = '远端操作已完成，但用户名设置未能保存。';
    }
    if (token.length > 0) {
      try {
        GitCredentialStore.saveToken(this.vaultId, token);
        this.hasStoredToken = true;
        this.credentialEditorOpen = false;
        this.tokenInput = '';
      } catch (_error) {
        this.statusMessage = '令牌未能安全保存；下次同步时需要重新填写。';
      }
    }
  }

  private async refreshRemoteStatus(): Promise<void> {
    if (this.busy || !this.statusReady || VaultRegistry.get().currentId() !== this.vaultId) {
      return;
    }
    const token: string = this.effectiveToken();
    if (token.length > 0 && !this.isGitHubRemote() && this.authUsername.trim().length === 0) {
      this.result = 'auth';
      this.resultTitle = '需要用户名';
      this.resultBody = '请填写此 Git 服务对应的用户名后重试。';
      this.credentialEditorOpen = true;
      return;
    }
    this.remoteBranchMissing = false;
    this.startBusy(true);
    this.progressText = '正在检查远端 ' + this.pushBranch + '…';
    try {
      const result: string = await GitNativeService.action(this.makeActionOptions('fetch', token));
      this.saveCredentialsAfterRemoteSuccess(token);
      this.refreshLocalStatus();
      this.remoteBranchMissing = result === 'missing';
      this.result = 'none';
      this.statusMessage = result === 'missing'
        ? '远端尚无 ' + this.pushBranch + ' 分支；本地跟踪状态仍未知。'
        : '已更新 ' + this.pushBranch + ' 的本地跟踪状态。';
    } catch (error) {
      this.showOperationFailure(error, '远端状态检查');
    } finally {
      this.finishBusy();
    }
  }

  private async runPrimaryAction(): Promise<void> {
    if (this.busy || !this.canPush()) {
      return;
    }
    if (VaultRegistry.get().currentId() !== this.vaultId || this.findVaultEntry() === null) {
      this.showLocalFailure('当前 Git 库已变化；本次未开始推送。');
      return;
    }
    if (this.shouldCommitChanges() &&
      (this.authorName.trim().length === 0 || this.authorEmail.trim().length === 0)) {
      this.showLocalFailure('请填写提交者名称和邮箱；工作区改动尚未暂存。');
      return;
    }
    const token: string = this.effectiveToken();
    if (token.length > 0 && !this.isGitHubRemote() && this.authUsername.trim().length === 0) {
      this.result = 'auth';
      this.resultTitle = '需要用户名';
      this.resultBody = '请填写此 Git 服务对应的用户名后重试。';
      this.credentialEditorOpen = true;
      return;
    }

    this.startBusy();
    const hasLocalChanges: boolean = this.syncIncludesCommit;
    this.result = 'none';
    this.statusMessage = '';
    try {
      if (hasLocalChanges) {
        this.setStep(0, '暂存改动…');
        await GitNativeService.action(this.makeActionOptions('stage', token));

        this.setStep(1, '创建本地提交…');
        const commitOptions: Git2ActionOptions = this.makeActionOptions('commit', token);
        const message: string = this.commitMessage.trim();
        commitOptions.message = message.length > 0 ? message : this.defaultCommitMessage();
        commitOptions.authorName = this.authorName.trim();
        commitOptions.authorEmail = this.authorEmail.trim();
        await GitNativeService.action(commitOptions);
        this.localCommitPending = true;
        this.completedStep = 1;
      }

      this.setStep(this.remoteStepIndex(), '检查远端 ' + this.pushBranch + '…');
      await GitNativeService.action(this.makeActionOptions('push', token, true));
      this.saveCredentialsAfterRemoteSuccess(token);
      this.remoteBranchMissing = false;
      this.localCommitPending = false;
      try {
        this.lastPushAt = Date.now();
        VaultRegistry.get().recordGitSync(this.vaultId, this.lastPushAt);
      } catch (_error) {
        this.statusMessage = '推送成功，但上次推送时间未能保存。';
      }
      this.result = 'success';
      this.resultTitle = '已推送到 ' + this.pushBranch;
      this.resultBody = '在电脑上把 ' + this.pushBranch + ' 合并到 ' +
        this.trackingTargetLabel() + '。';
      this.completedStep = this.remoteStepIndex() + 1;
      this.progressText = '推送完成';
      this.refreshLocalStatus();
    } catch (error) {
      this.showOperationFailure(error, 'Git 同步');
      this.refreshLocalStatus();
    } finally {
      this.finishBusy();
    }
  }

  private canPush(): boolean {
    if (!this.statusReady) {
      return false;
    }
    if (this.statusEntryCount > 0) {
      return true;
    }
    return this.remoteBranchMissing || this.localCommitPending ||
      (this.trackingKnown && this.aheadCount > 0);
  }

  private startBusy(checkingRemoteOnly: boolean = false): void {
    this.busy = true;
    this.checkingRemoteOnly = checkingRemoteOnly;
    this.syncIncludesCommit = !checkingRemoteOnly && this.shouldCommitChanges();
    this.currentStep = -1;
    this.completedStep = -1;
    this.progressText = '准备中…';
    this.onBusyChange(true);
  }

  private finishBusy(): void {
    this.busy = false;
    this.checkingRemoteOnly = false;
    this.currentStep = -1;
    this.onBusyChange(false);
  }

  private setStep(step: number, label: string): void {
    this.completedStep = step - 1;
    this.currentStep = step;
    this.progressText = label;
  }

  private showOperationFailure(error: Error | Object, operation: string): void {
    const message: string = (error as BusinessError).message ?? String(error);
    const lower: string = message.toLowerCase();
    this.result = lower.includes('401') || lower.includes('403') || lower.includes('unauthorized') ||
      lower.includes('forbidden') || lower.includes('authentication') ? 'auth' :
      message.includes('已前进') || lower.includes('non-fast-forward') ? 'stale' :
      this.checkingRemoteOnly || this.currentStep >= this.remoteStepIndex() ? 'network' : 'local';
    if (this.result === 'stale') {
      this.resultTitle = '远端已前进';
      this.resultBody = '本次未推送，本地提交已保留。可改推到其他分支，再在电脑上合并。';
    } else if (this.result === 'auth') {
      this.resultTitle = '令牌无效或没有写权限';
      this.resultBody = '本次未推送，本地提交已保留。请更换令牌或检查仓库写权限。';
      this.credentialEditorOpen = true;
    } else if (this.result === 'network') {
      this.resultTitle = '网络连接失败';
      this.resultBody = '本次未推送，本地提交已保留；检查网络后可以重试。';
    } else {
      this.resultTitle = operation + '未完成';
      this.resultBody = '当前状态未确认；请刷新 Git 状态后再决定是否重试。';
    }
    this.progressText = '失败';
  }

  private showLocalFailure(message: string): void {
    this.result = 'local';
    this.resultTitle = '同步未开始';
    this.resultBody = message;
    this.progressText = '失败';
  }

  private formatLastPush(): string {
    if (this.lastPushAt <= 0) {
      return '暂无记录';
    }
    const date: Date = new Date(this.lastPushAt);
    const month: string = ('0' + (date.getMonth() + 1).toString()).slice(-2);
    const day: string = ('0' + date.getDate().toString()).slice(-2);
    const hour: string = ('0' + date.getHours().toString()).slice(-2);
    const minute: string = ('0' + date.getMinutes().toString()).slice(-2);
    return month + '-' + day + ' ' + hour + ':' + minute;
  }

  private dismiss(): void {
    if (this.busy) {
      return;
    }
    this.controller?.close();
    this.restoreFocus();
  }

  private restoreFocus(): void {
    if (this.hasDismissed) {
      return;
    }
    this.hasDismissed = true;
    this.tokenInput = '';
    this.onDismiss();
  }

  private dismissResult(): void {
    if (this.result === 'success') {
      this.dismiss();
      return;
    }
    this.result = 'none';
    this.resultTitle = '';
    this.resultBody = '';
  }

  @Builder
  private StatusRow(label: string, value: string, detail: string = '') {
    Row({ space: Space.s3 }) {
      Text(label)
        .width(Space.s16 + Space.s2)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
      Column({ space: Space.s1 }) {
        Text(value)
          .fontSize(FontSize.body3)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (detail.length > 0) {
          Text(detail)
            .fontSize(FontSize.caption)
            .fontColor(this.isTrackingBranchTarget() && label === '推送分支'
              ? $r('app.color.danger') : $r('app.color.text_secondary'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (label === '推送分支') {
        Text('更改')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.brand'))
          .padding({ left: Space.s2, right: Space.s2 })
          .height(Size.touch)
          .focusable(true)
          .id('git-sync-branch-change')
          .enabled(!this.busy)
          .onClick((): void => {
            this.branchDraft = this.pushBranch;
            this.branchEditing = true;
            this.result = 'none';
          })
      }
    }
    .width('100%')
    .padding({ top: Space.s2, bottom: Space.s2 })
  }

  @Builder
  private ChangeRow(change: Git2FileChange) {
    Row({ space: Space.s3 }) {
      Text(change.status)
        .width(Space.s5)
        .height(Space.s5)
        .fontSize(FontSize.caption)
        .fontFamily('monospace')
        .fontWeight(FontWeight.Bold)
        .textAlign(TextAlign.Center)
        .fontColor(change.status === 'A' ? $r('app.color.success')
          : change.status === 'D' ? $r('app.color.danger') : $r('app.color.brand'))
        .backgroundColor(change.status === 'A' ? $r('app.color.success_bg')
          : change.status === 'D' ? $r('app.color.danger_bg') : $r('app.color.brand_bg'))
        .borderRadius(Radius.control)
        .accessibilityText(change.status === 'A' ? '新增' : change.status === 'D' ? '删除' : '修改')
      Text(change.path)
        .layoutWeight(1)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .accessibilityText((change.status === 'A' ? '新增：' :
          change.status === 'D' ? '删除：' : '修改：') + change.path)
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s2, right: Space.s2 })
  }

  @Builder
  private BranchEditor() {
    Column({ space: Space.s2 }) {
      Text('推送到分支')
        .fontSize(FontSize.body3)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      TextInput({ placeholder: 'xt2', text: this.branchDraft })
        .fontSize(FontSize.body3)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .border({ width: 1, color: this.branchError.length > 0
          ? $r('app.color.danger') : $r('app.color.line') })
        .accessibilityText('推送分支')
        .accessibilityDescription(this.branchError.length > 0 ? this.branchError : this.defaultBranchMessage())
        .onChange((value: string): void => {
          this.branchDraft = value;
          const validation: GitBranchNameValidation = validateGitBranchName(value);
          this.branchError = validation.valid ? '' : validation.reason;
        })
        .onSubmit((): void => { this.saveBranch(); })
        .onKeyEvent((event: KeyEvent): boolean => { return this.onBranchKey(event); })
      Text(this.branchError.length > 0 ? this.branchError : this.defaultBranchMessage())
        .fontSize(FontSize.caption)
        .fontColor(this.branchError.length > 0 || this.branchDraft === this.trackingBranch
          ? $r('app.color.danger') : $r('app.color.text_secondary'))
        .width('100%')
        .accessibilityText(this.branchError.length > 0 ? this.branchError : this.defaultBranchMessage())
      Row({ space: Space.s2 }) {
        Text('恢复默认 xt2')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: Space.s2, right: Space.s2 })
          .onClick((): void => { this.restoreDefaultBranch(); })
        Blank()
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: Space.s2, right: Space.s2 })
          .onClick((): void => { this.cancelBranchEdit(); })
        Text('保存')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.brand'))
          .padding({ left: Space.s2, right: Space.s2 })
          .enabled(validateGitBranchName(this.branchDraft).valid && !this.busy)
          .onClick((): void => { this.saveBranch(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
    .backgroundColor($r('app.color.bg_secondary'))
  }

  @Builder
  private ProgressSteps() {
    Column({ space: Space.s2 }) {
      ForEach(this.progressStepLabels(),
        (label: string, index: number): void => {
          Row({ space: Space.s3 }) {
            Icon(index <= this.completedStep ? 'check' : index === this.currentStep ? 'sync' : 'doc',
              Space.s4, index <= this.completedStep ? $r('app.color.success')
                : index === this.currentStep ? $r('app.color.brand') : $r('app.color.text_tertiary'))
            Text(label)
              .fontSize(FontSize.body3)
              .fontColor(index <= this.completedStep || index === this.currentStep
                ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          }
          .width('100%')
          .accessibilityText((index <= this.completedStep ? '已完成：' :
            index === this.currentStep ? '进行中：' : '待处理：') + label)
        }, (label: string): string => label)
    }
    .width('100%')
    .padding(Space.s4)
    .borderRadius(Radius.card)
    .backgroundColor($r('app.color.bg_secondary'))
    .accessibilityGroup(true)
  }

  @Builder
  private ResultPanel() {
    if (this.result !== 'none') {
      Column({ space: Space.s2 }) {
        Row({ space: Space.s2 }) {
          Icon(this.result === 'success' ? 'check' : 'doc', Space.s5,
            this.result === 'success' ? $r('app.color.success') : $r('app.color.danger'))
          Text(this.resultTitle)
            .fontSize(FontSize.body2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        }
        Text(this.resultBody)
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        if (this.result === 'stale') {
          Text('改推到其他分支')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.brand'))
            .padding({ top: Space.s1, bottom: Space.s1 })
            .onClick((): void => {
              this.branchDraft = this.pushBranch;
              this.branchEditing = true;
            })
        }
        if (this.result === 'auth') {
          Text('更换令牌')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.brand'))
            .onClick((): void => { this.credentialEditorOpen = true; })
        }
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .backgroundColor(this.result === 'success' ? $r('app.color.success_bg')
        : $r('app.color.danger_bg'))
      .accessibilityText(this.resultTitle + '。' + this.resultBody)
    }
  }

  @Builder
  private CredentialEditor() {
    if (this.credentialEditorOpen) {
      Column({ space: Space.s2 }) {
        if (!this.isGitHubRemote()) {
          TextInput({ placeholder: '用户名（Gitee / GitLab）', text: this.authUsername })
            .fontSize(FontSize.body3)
            .onChange((value: string): void => { this.authUsername = value; })
            .accessibilityText('Git 用户名')
        }
        TextInput({ placeholder: this.hasStoredToken ? '输入新令牌以替换' : '访问令牌',
          text: this.tokenInput })
          .type(InputType.Password)
          .fontSize(FontSize.body3)
          .onChange((value: string): void => { this.tokenInput = value; })
          .accessibilityText('Git 访问令牌')
      }
      .width('100%')
    } else {
      Text(this.hasStoredToken ? 'HTTPS · 令牌已保存在本机' : 'HTTPS · 需要访问令牌时可在此填写')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
  }

  @Builder
  private DialogContent() {
    Column({ space: Space.s3 }) {
      Column() {
        this.StatusRow('远端', this.remoteLabel, this.transportLabel + ' · ' +
          (this.hasStoredToken ? '令牌已保存在本机' : '令牌未保存'))
        Divider().color($r('app.color.line'))
        this.StatusRow('推送分支', this.pushBranch,
          (this.pushBranch === 'xt2' ? '默认分支' : '自定义分支') + '；在电脑上合并到 ' +
          this.trackingTargetLabel())
        Divider().color($r('app.color.line'))
        this.StatusRow('待推送', this.waitingStatusText(), '上次推送：' + this.formatLastPush())
      }
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4 })
      .border({ width: 1, color: $r('app.color.line') })
      .borderRadius(Radius.card)

      if (this.branchEditing) {
        this.BranchEditor()
      }

      this.CredentialEditor()

      if (this.statusEntryCount > 0) {
        Row() {
          Text('本地改动')
            .fontSize(FontSize.body3)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text(this.shouldCommitChanges() ? '推送时一并提交' : '本次不会提交')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        Scroll() {
          Column() {
            ForEach(this.changes, (change: Git2FileChange): void => {
              this.ChangeRow(change)
            }, (change: Git2FileChange): string => change.path)
          }
          .width('100%')
        }
        .width('100%')
        .height(Math.min(Size.touch * 4 + Space.s6, Size.touch * this.changes.length))
        .scrollBar(BarState.Auto)

        if (this.shouldCommitChanges()) {
          TextInput({ placeholder: this.defaultCommitMessage(), text: this.commitMessage })
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_primary'))
            .onChange((value: string): void => { this.commitMessage = value; })
            .accessibilityText('提交说明')
          TextInput({ placeholder: '提交者名称', text: this.authorName })
            .fontSize(FontSize.body3)
            .onChange((value: string): void => { this.authorName = value; })
            .accessibilityText('提交者名称')
          TextInput({ placeholder: '提交者邮箱', text: this.authorEmail })
            .fontSize(FontSize.body3)
            .onChange((value: string): void => { this.authorEmail = value; })
            .accessibilityText('提交者邮箱')
        } else {
          Text('本次只推送已创建的本地提交；这些未提交改动会保留。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      } else if (this.remoteBranchMissing) {
        Text('已确认远端尚无该分支；可以首次推送当前提交。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else if (this.trackingKnown && this.aheadCount > 0) {
        Text('将推送 ' + this.aheadCount.toString() + ' 个已提交的更新')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else if (this.localCommitPending) {
        Text('本地提交仍待远端确认；可重试，或先检查远端状态。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else if (!this.trackingKnown) {
        Text('待推送数量未知 · ' + this.statusEntryCount.toString() +
          ' 个未提交改动；联网检查后才能确认远端状态。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else {
        Text('本地没有待推送的内容；远端状态以联网检查为准。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }

      if (!this.remoteBranchMissing && this.behindCount > 0) {
        Text('远端已前进 ' + this.behindCount.toString() + ' 个提交；手机端不合并。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      if (this.statusMessage.length > 0) {
        Text(this.statusMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .accessibilityText(this.statusMessage)
      }
      if (this.busy && this.currentStep >= 0) {
        this.ProgressSteps()
      }
      if (this.busy) {
        Text(this.progressText)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .accessibilityText('同步进度：' + this.progressText)
      }
      this.ResultPanel()
      if (!this.busy && this.result === 'none' && !this.trackingKnown && this.statusReady) {
        Text('检查远端状态')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.brand'))
          .padding({ top: Space.s1, bottom: Space.s1 })
          .onClick((): void => { void this.refreshRemoteStatus(); })
      }
    }
    .width('100%')
    .accessibilityGroup(true)
  }

  @Builder
  private DialogFooter() {
    Row({ space: Space.s2 }) {
      UtilityDialogAction(this.busy ? '取消' : '关闭', 'secondary',
        this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.busy), (): void => { this.dismiss(); })
      if (this.result === 'success') {
        UtilityDialogAction('完成', 'primary', this.singleScreen, UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.dismiss();
        })
      } else if (this.result !== 'none') {
        UtilityDialogAction('重试', 'primary', this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.busy), (): void => {
          this.dismissResult();
          void this.runPrimaryAction();
        })
      } else {
        UtilityDialogAction(this.primaryActionLabel(),
          'primary', this.singleScreen, UIUtils.makeBinding<boolean>(() => this.primaryActionEnabled()),
          (): void => { void this.runPrimaryAction(); })
      }
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '同步到 Git',
      subtitle: this.vaultId + ' · 推送到 ' + this.pushBranch,
      headerIcon: 'sync',
      closeLabel: '关闭同步页',
      singleScreen: this.singleScreen,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => { this.dismiss(); },
      content: (): void => { this.DialogContent(); },
      footer: (): void => { this.DialogFooter(); }
    })
  }
}
