import { promptAction, UIUtils } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitBranchNameValidation, validateGitBranchName } from '../git/GitBranchName';
import { GitNativeService } from '../git/GitNativeService';
import { applyRemoteAuth, isGitHubRemote } from '../git/GitRemoteAuth';
import { Git2ActionOptions, Git2DiffLine, Git2FileChange, Git2FileDiff, Git2FileDiffs, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { FontSize, Radius, Size, Space, Weight } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { FocusRequest } from '../common/FocusRequest';
import { UtilityDialogAction } from './UtilityDialogShell';

type GitSyncResult = 'none' | 'success' | 'stale' | 'auth' | 'network' | 'local';
type GitSyncRetryAction = 'sync' | 'remoteStatus' | 'pull';

/** v1.76：同步从 CustomDialog 浮窗改为占满内容区的全屏页（与设置页同范式）。 */
@Component
export struct GitSyncDialog {
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
  @State tokenVisible: boolean = false;
  @State credentialEditorOpen: boolean = false;
  @State retryAction: GitSyncRetryAction = 'sync';
  @State requiresNewToken: boolean = false;
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
  // v1.75 逐行差异：手风琴单开路径 + 当前展示数据 + 展开中状态。
  // diffCache 是普通字段（Map 变化不触发 V1 @State 刷新），用 diffVersion 递增驱动 UI 更新。
  @State expandedDiffPath: string = '';
  @State activeFileDiff: Git2FileDiff | null = null;
  @State diffLoading: boolean = false;
  @State diffVersion: number = 0;
  private diffCache: Map<string, Git2FileDiff | null> = new Map<string, Git2FileDiff | null>();
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
  @State pulling: boolean = false;
  // v2.10：恢复后缺 .git 的库进入「重新关联远端」卡片态（应用备份不含 Git 历史）。
  @State missingGit: boolean = false;
  @State reattachUrl: string = '';
  @State reattachError: string = '';
  onBusyChange: (busy: boolean) => void = (_busy: boolean) => {};
  /** v1.76：请求退出全屏页（Index 收到后把 topView 切回 note 并还原焦点）。 */
  onDismiss: () => void = () => {};
  onPulled: () => void = () => {};

  private hasDismissed: boolean = false;

  aboutToAppear(): void {
    this.expandedDiffPath = '';
    this.activeFileDiff = null;
    this.diffCache.clear();
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
    this.reattachUrl = entry.remote ?? '';
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
    void this.refreshLocalStatus();
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

  private async refreshLocalStatus(): Promise<void> {
    if (VaultRegistry.get().currentId() !== this.vaultId) {
      this.statusReady = false;
      this.statusMessage = '当前库已切换，请返回主页重新打开同步页。';
      return;
    }
    try {
      const registry: VaultRegistry = VaultRegistry.get();
      const state: Git2RepositoryState =
        await GitNativeService.repositoryState(registry.vaultDirOf(this.vaultId), this.pushBranch);
      this.statusReady = true;
      this.missingGit = false;
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
      void this.loadFileDiffs();
    } catch (_error) {
      // v2.10：仓库打不开且 .git 缺失（典型：应用备份恢复后）→ 进「重新关联远端」卡片态。
      if (this.probeMissingGit()) {
        this.missingGit = true;
        this.statusReady = false;
        this.statusMessage = '';
        return;
      }
      this.statusReady = false;
      this.statusMessage = '无法读取本地 Git 状态；请刷新后再决定是否推送。';
    }
  }

  /** v2.10：复核 vaultDir 下是否真的没有 .git（fileIo 不可用时维持原报错路径）。 */
  private probeMissingGit(): boolean {
    try {
      return !fileIo.accessSync(VaultRegistry.get().vaultDirOf(this.vaultId) + '/.git');
    } catch (_error) {
      return false;
    }
  }

  // v1.75：一次 native 调用取回全部未提交文件的逐行差异，缓存在 diffCache。
  // 失败只影响行尾统计 / 展开视图，不阻断提交推送主流程。
  private async loadFileDiffs(): Promise<void> {
    this.diffCache.clear();
    try {
      const result: Git2FileDiffs = await GitNativeService.fileDiffs(
        VaultRegistry.get().vaultDirOf(this.vaultId));
      for (const file of result.files) {
        this.diffCache.set(file.path, file);
      }
    } catch (_error) {
      // 逐行差异不可用时保留清单本身；展开会给出「无法读取」提示。
    }
    this.diffVersion++;
    this.autoSelectFirstDiff();
  }

  /** v1.77：进入同步页即选中首个有差异的文件，右栏不再是一大片空白占位。 */
  private autoSelectFirstDiff(): void {
    if (this.expandedDiffPath.length > 0 || this.changes.length === 0) {
      return;
    }
    for (const change of this.changes) {
      const cached: Git2FileDiff | null | undefined = this.diffCache.get(change.path);
      if (cached !== undefined && cached !== null) {
        this.expandedDiffPath = change.path;
        this.activeFileDiff = cached;
        return;
      }
    }
  }

  private diffStatOf(path: string): string {
    const file: Git2FileDiff | null | undefined = this.diffCache.get(path);
    if (file === undefined || file === null) {
      return '';
    }
    let added: number = 0;
    let removed: number = 0;
    for (const line of file.lines) {
      if (line.origin === '+') added++;
      else if (line.origin === '-') removed++;
    }
    return '+' + added.toString() + ' −' + removed.toString();
  }

  private async toggleDiff(path: string): Promise<void> {
    if (this.expandedDiffPath === path) {
      this.expandedDiffPath = '';
      this.activeFileDiff = null;
      return;
    }
    this.expandedDiffPath = path;
    const cached: Git2FileDiff | null | undefined = this.diffCache.get(path);
    if (cached !== undefined) {
      this.activeFileDiff = cached;
      return;
    }
    // 缓存未命中（如初次预取失败）：按需单独取一次。
    this.diffLoading = true;
    try {
      const result: Git2FileDiffs = await GitNativeService.fileDiffs(
        VaultRegistry.get().vaultDirOf(this.vaultId));
      let found: Git2FileDiff | null = null;
      for (const file of result.files) {
        this.diffCache.set(file.path, file);
        if (file.path === path) found = file;
      }
      this.activeFileDiff = found;
    } catch (_error) {
      this.activeFileDiff = null;
    }
    this.diffLoading = false;
    this.diffVersion++;
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
      if (this.pulling) {
        return '正在拉取…';
      }
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
      void this.refreshLocalStatus();
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
      FocusRequest.safely(this.getUIContext(), 'git-sync-branch-change');
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
    // remoteLabel 是 host/path 形式；git/GitRemoteAuth 的 host 解析兼容该形态。
    return isGitHubRemote(this.remoteLabel);
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
    applyRemoteAuth(options, this.remoteLabel, this.authUsername.trim(), token);
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
        this.tokenVisible = false;
        this.requiresNewToken = false;
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
      this.retryAction = 'remoteStatus';
      this.requiresNewToken = false;
      this.credentialEditorOpen = true;
      return;
    }
    this.remoteBranchMissing = false;
    this.startBusy(true);
    this.progressText = '正在检查远端 ' + this.pushBranch + '…';
    try {
      const result: string = await GitNativeService.action(this.makeActionOptions('fetch', token));
      this.saveCredentialsAfterRemoteSuccess(token);
      await this.refreshLocalStatus();
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

  private makePullOptions(token: string): Git2ActionOptions {
    const options: Git2ActionOptions = {
      operation: 'pull',
      repositoryPath: VaultRegistry.get().vaultDirOf(this.vaultId),
      targetBranch: this.trackingBranch,
      onProgress: (progress: Git2Progress): void => {
        this.progressText = GitNativeService.progressLabel(progress);
      }
    };
    applyRemoteAuth(options, this.remoteLabel, this.authUsername.trim(), token);
    return options;
  }

  private canPull(): boolean {
    return this.trackingBranch.length > 0 && this.statusReady && this.statusEntryCount === 0;
  }

  private async runPullAction(): Promise<void> {
    if (this.busy || !this.canPull() || VaultRegistry.get().currentId() !== this.vaultId) {
      return;
    }
    const token: string = this.effectiveToken();
    if (token.length > 0 && !this.isGitHubRemote() && this.authUsername.trim().length === 0) {
      this.result = 'auth';
      this.resultTitle = '需要用户名';
      this.resultBody = '请填写此 Git 服务对应的用户名后重试。';
      this.retryAction = 'pull';
      this.requiresNewToken = false;
      this.credentialEditorOpen = true;
      return;
    }
    this.pulling = true;
    this.startBusy();
    this.progressText = '正在拉取 ' + this.trackingBranch + '…';
    try {
      const pullResult: string = await GitNativeService.action(this.makePullOptions(token));
      this.saveCredentialsAfterRemoteSuccess(token);
      if (pullResult === 'fast-forwarded') {
        this.onPulled();
        this.result = 'success';
        this.resultTitle = '已拉取远端更新';
        this.resultBody = '本地已快进合并远端 ' + this.trackingBranch + ' 的新提交。';
      } else {
        this.result = 'none';
        this.statusMessage = '远端 ' + this.trackingBranch + ' 没有新提交，本地已是最新。';
      }
      this.progressText = '拉取完成';
      await this.refreshLocalStatus();
    } catch (error) {
      this.showPullFailure(error);
      await this.refreshLocalStatus();
    } finally {
      this.pulling = false;
      this.finishBusy();
    }
  }

  private showPullFailure(error: Error | Object): void {
    const message: string = (error as BusinessError).message ?? String(error);
    const lower: string = message.toLowerCase();
    this.retryAction = 'pull';
    this.requiresNewToken = false;
    if (message.includes('未提交更改')) {
      this.result = 'local';
      this.resultTitle = '本地有未提交更改';
      this.resultBody = '拉取未开始。请先提交并推送本地改动，再拉取远端更新。';
    } else if (message.includes('未推送提交') || message.includes('拒绝合并')) {
      this.result = 'stale';
      this.resultTitle = '本地有未推送提交';
      this.resultBody = '为避免合并冲突，拉取已取消。请先推送到远端，或在电脑上处理后再拉取。';
    } else if (lower.includes('401') || lower.includes('403') ||
      lower.includes('unauthorized') || lower.includes('forbidden') ||
      lower.includes('authentication')) {
      this.result = 'auth';
      this.requiresNewToken = true;
      this.resultTitle = '拉取远端更新时认证失败';
      this.resultBody = '令牌可能已失效或缺少读取权限；本地库内容未变。输入新令牌后重试拉取。';
      this.credentialEditorOpen = true;
    } else {
      this.result = 'network';
      this.resultTitle = '拉取远端更新失败';
      this.resultBody = '本地库内容未变；检查网络后可重试拉取。';
    }
    this.progressText = '失败';
  }

  /** v2.10：远端地址校验，返回空串表示可用；错误文案直接进卡片。 */
  private reattachUrlIssue(): string {
    const url: string = this.reattachUrl.trim();
    if (url.length === 0) {
      return '请填写远端仓库地址。';
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '远端地址必须以 http:// 或 https:// 开头。';
    }
    const schemePos: number = url.indexOf('://');
    const authorityStart: number = schemePos + 3;
    const authorityEnd: number = url.indexOf('/', authorityStart);
    const authority: string = url.substring(authorityStart,
      authorityEnd >= 0 ? authorityEnd : url.length);
    if (authority.length === 0) {
      return '远端地址缺少主机名。';
    }
    if (authority.includes('@')) {
      return '地址中不能内嵌账号或令牌；凭据请在下方单独填写。';
    }
    return '';
  }

  /** v2.10：缺 .git 的库重新关联远端——本地只重建 .git，笔记文件零改动。 */
  private async runReattach(): Promise<void> {
    if (this.busy || !this.missingGit || VaultRegistry.get().currentId() !== this.vaultId) {
      return;
    }
    const issue: string = this.reattachUrlIssue();
    if (issue.length > 0) {
      this.reattachError = issue;
      return;
    }
    const token: string = this.effectiveToken();
    const remote: string = this.reattachUrl.trim();
    if (token.length > 0 && !isGitHubRemote(remote) && this.authUsername.trim().length === 0) {
      this.reattachError = '此 Git 服务需要先填写用户名。';
      this.credentialEditorOpen = true;
      return;
    }
    this.reattachError = '';
    this.startBusy();
    this.progressText = '正在重新关联远端…';
    try {
      const options: Git2ActionOptions = {
        operation: 'reattach',
        repositoryPath: VaultRegistry.get().vaultDirOf(this.vaultId),
        // targetBranch 取库注册的 clone 分支（trackingBranch），缺省回退推送分支。
        targetBranch: this.trackingBranch.length > 0 ? this.trackingBranch : this.pushBranch,
        remoteUrl: remote,
        onProgress: (progress: Git2Progress): void => {
          this.progressText = GitNativeService.progressLabel(progress);
        }
      };
      applyRemoteAuth(options, remote, this.authUsername.trim(), token);
      await GitNativeService.action(options);
      this.saveCredentialsAfterRemoteSuccess(token);
      this.missingGit = false;
      await this.refreshLocalStatus();
      this.statusMessage = '已重新关联远端；本地笔记未改动。';
      this.progressText = '重新关联完成';
    } catch (error) {
      this.showReattachFailure(error);
    } finally {
      this.finishBusy();
    }
  }

  private showReattachFailure(error: Error | Object): void {
    const message: string = (error as BusinessError).message ?? String(error);
    this.reattachError = '重新关联未完成：' + message +
      '。本地笔记未改动；修正地址或凭据后可重试。';
    this.progressText = '失败';
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
      this.retryAction = 'sync';
      this.requiresNewToken = false;
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
      await this.refreshLocalStatus();
    } catch (error) {
      this.showOperationFailure(error, 'Git 同步');
      await this.refreshLocalStatus();
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
    if (this.result === 'auth') {
      FocusRequest.safely(this.getUIContext(), 'git-sync-token-input');
    }
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
    this.retryAction = this.checkingRemoteOnly ? 'remoteStatus' : 'sync';
    this.requiresNewToken = this.result === 'auth';
    if (this.result === 'stale') {
      this.resultTitle = '远端已前进';
      this.resultBody = '本次未推送，本地提交已保留。可改推到其他分支，再在电脑上合并。';
    } else if (this.result === 'auth') {
      if (this.retryAction === 'remoteStatus') {
        this.resultTitle = '拉取远端状态时认证失败';
        this.resultBody = '令牌可能已失效或缺少读取权限；未读取到远端新状态，本地库内容未变。输入新令牌后验证并重试检查。';
      } else {
        this.resultTitle = '令牌无效或没有写权限';
        this.resultBody = '本次未推送，本地提交已保留。请更换具有仓库写权限的令牌后重试。';
      }
      this.credentialEditorOpen = true;
    } else if (this.result === 'network') {
      this.resultTitle = '网络连接失败';
        this.resultBody = this.retryAction === 'remoteStatus'
          ? '无法读取远端状态；本地库内容未变，检查网络后可重试检查。'
          : '本次未推送，本地提交已保留；检查网络后可以重试。';
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
    // v1.76：无 controller，改为回调通知 Index 退出全屏页。
    this.restoreFocus();
  }

  private restoreFocus(): void {
    if (this.hasDismissed) {
      return;
    }
    this.hasDismissed = true;
    this.tokenInput = '';
    this.tokenVisible = false;
    this.onDismiss();
  }

  private cancelCredentialEdit(): void {
    this.tokenInput = '';
    this.tokenVisible = false;
    this.credentialEditorOpen = false;
  }

  private retryActionLabel(): string {
    if (this.retryAction === 'remoteStatus') {
      return this.result === 'auth' ? '验证并重试检查' : '重试检查';
    }
    if (this.retryAction === 'pull') {
      return this.result === 'auth' ? '验证并重试拉取' : '重试拉取';
    }
    return this.result === 'auth' ? '验证并重试推送' : '重试';
  }

  private retryActionEnabled(): boolean {
    if (this.busy) {
      return false;
    }
    if (this.result !== 'auth') {
      return true;
    }
    if (this.requiresNewToken && this.tokenInput.trim().length === 0) {
      return false;
    }
    if (!this.hasStoredToken && this.tokenInput.trim().length === 0) {
      return false;
    }
    return this.isGitHubRemote() || this.authUsername.trim().length > 0;
  }

  private retryFailedOperation(): void {
    if (this.busy) {
      return;
    }
    const action: GitSyncRetryAction = this.retryAction;
    this.dismissResult();
    if (action === 'remoteStatus') {
      void this.refreshRemoteStatus();
      return;
    }
    if (action === 'pull') {
      void this.runPullAction();
      return;
    }
    void this.runPrimaryAction();
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
        .width(Space.s16)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
      Column({ space: Space.s1 }) {
        Text(value)
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
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
    // v1.87：状态行对齐原型 .sync-row——行高下限 calc(--s12 + --s1)，行内边距左 --s4 / 右 --s2。
    .constraintSize({ minHeight: Space.s12 + Space.s1 })
    .padding({ left: Space.s4, right: Space.s2, top: Space.s2, bottom: Space.s2 })
  }

  @Builder
  private ChangeRow(change: Git2FileChange) {
    Column() {
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
          .fontWeight(!this.singleScreen && this.expandedDiffPath === change.path
            ? Weight.semibold : FontWeight.Normal)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .accessibilityText((change.status === 'A' ? '新增：' :
            change.status === 'D' ? '删除：' : '修改：') + change.path)
        // 读 diffVersion 触发缓存回填后刷新统计（Map 本身不驱动 V1 @State）。
        Text(this.diffVersion >= 0 ? this.diffStatOf(change.path) : '')
          .fontSize(FontSize.caption)
          .fontFamily('monospace')
          .fontColor(!this.singleScreen && this.expandedDiffPath === change.path
            ? $r('app.color.brand') : $r('app.color.text_secondary'))
          .accessibilityText(this.diffStatOf(change.path))
        // v1.79 单屏简化版：无右栏 diff，不显示展开箭头。
        if (!this.singleScreen) {
          Text(this.expandedDiffPath === change.path ? '▾' : '▸')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s2, right: Space.s2 })
      .backgroundColor(!this.singleScreen && this.expandedDiffPath === change.path
        ? $r('app.color.brand_bg') : Color.Transparent)
      .borderRadius(Radius.control)
      // v1.87：选中左轨对齐原型 .sync-file-toggle 的 border-left（透明轨 + 选中换品牌色）。
      .border({ width: { left: Space.s1 },
        color: !this.singleScreen && this.expandedDiffPath === change.path
          ? $r('app.color.brand') : Color.Transparent })
      .onClick(() => { if (!this.singleScreen) { void this.toggleDiff(change.path); } })
      .accessibilityText(this.singleScreen
        ? (change.status === 'A' ? '新增：' : change.status === 'D' ? '删除：' : '修改：') + change.path + '，' + this.diffStatOf(change.path)
        : (this.expandedDiffPath === change.path ? '收起' : '查看') + ' ' + change.path + ' 的逐行差异（右侧显示）')
      .accessibilityDescription(this.diffStatOf(change.path))
    }
    .width('100%')
  }

  /** v1.76：右栏当前选中的改动文件（无选中返回 null）。 */
  private selectedChange(): Git2FileChange | null {
    for (const change of this.changes) {
      if (change.path === this.expandedDiffPath) {
        return change;
      }
    }
    return null;
  }

  /** v1.76：右栏逐行差异面板，未选中显示占位引导。 */
  @Builder
  private DiffPane() {
    Column({ space: Space.s2 }) {
      Column() {
        Text('逐行差异')
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
        Text('当前工作区 ↔ 上次提交 · 仅本次要提交的改动')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: Space.s1 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: Space.s5, right: Space.s5, top: Space.s4, bottom: Space.s4 })
      .border({ width: { bottom: 1 }, color: $r('app.color.line') })

      if (this.selectedChange() === null) {
        Column() {
          Icon('menu', Space.s16, $r('app.color.text_secondary'))
          Text(this.changes.length > 0
            ? '在左侧点选一个改动文件，这里会显示它的逐行差异。'
            : '本地没有未提交的改动，暂无逐行差异可看。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: Space.s3 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .border({ width: 1, color: $r('app.color.line'), style: BorderStyle.Dashed })
        .borderRadius(Radius.card)
        .padding(Space.s6)
      } else {
        this.DiffPanel(this.selectedChange() as Git2FileChange)
      }
    }
    .width('100%')
    .height('100%')
    // v1.78 右栏铺满 + v1.87 白底：右栏是 --paper 底的代码查看器（原型 .sync-detail）。
    .padding(0)
    .layoutWeight(this.singleScreen ? 0 : 1)
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  private DiffPanel(change: Git2FileChange) {
    Column() {
      if (this.diffLoading) {
        Text('正在读取逐行差异…')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .padding(Space.s3)
      } else if (this.activeFileDiff === null) {
        Text('无法读取逐行差异')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .padding(Space.s3)
      } else {
        Column({ space: Space.s1 }) {
          Row({ space: Space.s2 }) {
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
            Text(change.path)
              .layoutWeight(1)
              .fontSize(FontSize.body3)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.diffStatOf(change.path))
              .fontSize(FontSize.caption)
              .fontFamily('monospace')
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          Text(change.status === 'A' ? '新文件（本次新增）'
            : change.status === 'D' ? '本次删除' : '修改：上次提交 → 当前工作区')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        // v1.87：diff 卡头对齐原型 .sync-diff-head（padding --s3/--s5 + 底部分隔线）。
        .padding({ left: Space.s5, right: Space.s5, top: Space.s3, bottom: Space.s3 })
        .border({ width: { bottom: 1 }, color: $r('app.color.line') })
        if (this.activeFileDiff.truncated) {
          Text('此文件差异过大，仅显示前 ' + this.activeFileDiff.lines.length + ' 行')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.warning'))
            .width('100%')
            .padding({ left: Space.s3, bottom: Space.s2 })
        }
        Scroll() {
          Column() {
            ForEach(this.activeFileDiff.lines, (line: Git2DiffLine, index: number): void => {
              this.DiffLineRow(line, index)
            }, (line: Git2DiffLine, index: number): string => index.toString())
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .nestedScroll({
          scrollForward: NestedScrollMode.SELF_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    // v1.78 铺满式查看器 + v1.87 --paper 白底（原型 .sync-file-diff 落在 --paper 查看器上）。
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  private DiffLineRow(line: Git2DiffLine, index: number) {
    Row({ space: 0 }) {
      Text(line.oldLine > 0 ? line.oldLine.toString() : '')
        .width(Space.s8)
        .textAlign(TextAlign.End)
        .fontSize(FontSize.caption)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .border({ width: { right: 1 }, color: $r('app.color.line') })
      Text(line.newLine > 0 ? line.newLine.toString() : '')
        .width(Space.s8)
        .textAlign(TextAlign.End)
        .fontSize(FontSize.caption)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .border({ width: { right: 1 }, color: $r('app.color.line') })
      Text(line.origin)
        .width(Space.s5)
        .textAlign(TextAlign.Center)
        .fontSize(FontSize.caption)
        .fontFamily('monospace')
        .fontWeight(FontWeight.Bold)
        .fontColor(line.origin === '+' ? $r('app.color.success')
          : line.origin === '-' ? $r('app.color.danger') : $r('app.color.text_secondary'))
      Text(line.text)
        .layoutWeight(1)
        .fontSize(FontSize.caption)
        .fontFamily('monospace')
        .fontColor(line.origin === '+' ? $r('app.color.success')
          : line.origin === '-' ? $r('app.color.danger') : $r('app.color.text_primary'))
    }
    .width('100%')
    .padding({ left: Space.s2, right: Space.s2 })
    .backgroundColor(line.origin === '+' ? $r('app.color.success_bg')
      : line.origin === '-' ? $r('app.color.danger_bg') : Color.Transparent)
    .accessibilityText((line.origin === '+' ? '新增行 ' : line.origin === '-' ? '删除行 ' : '未改动 ') + line.text)
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
            // L-7/Z2：全局 @Builder 按值实参不随状态刷新，步进图标必须走 if 分支，不能写成三元实参
            if (index <= this.completedStep) {
              Icon('check', Space.s4, $r('app.color.success'))
            } else if (index === this.currentStep) {
              Icon('sync', Space.s4, $r('app.color.brand'))
            } else {
              Icon('doc', Space.s4, $r('app.color.text_tertiary'))
            }
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
        if (this.result === 'stale' && this.retryAction === 'sync') {
          Text('改推到其他分支')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.brand'))
            .padding({ top: Space.s1, bottom: Space.s1 })
            .onClick((): void => {
              this.branchDraft = this.pushBranch;
              this.branchEditing = true;
            })
        }
        if (this.result === 'auth' && !this.credentialEditorOpen) {
          Text('更新此仓库令牌')
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
        if (this.result === 'auth') {
          Text(this.hasStoredToken ? '更新此仓库的访问令牌' : '填写此仓库的访问令牌')
            .fontSize(FontSize.body3)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        if (!this.isGitHubRemote()) {
          TextInput({ placeholder: '用户名（Gitee / GitLab）', text: this.authUsername })
            .fontSize(FontSize.body3)
            .enabled(!this.busy)
            .onChange((value: string): void => { this.authUsername = value; })
            .accessibilityText('Git 用户名')
        }
        Column({ space: Space.s1 }) {
          Text('访问令牌')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
          Row({ space: Space.s1 }) {
            TextInput({ placeholder: this.hasStoredToken ? '输入新令牌以替换' : '访问令牌',
              text: this.tokenInput })
              .type(this.tokenVisible ? InputType.Normal : InputType.Password)
              .enabled(!this.busy)
              .focusable(true)
              .layoutWeight(1)
              .height(Size.buttonH)
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .padding({ left: Space.s3, right: Space.s2 })
              .backgroundColor(Color.Transparent)
              .id('git-sync-token-input')
              .onChange((value: string): void => { this.tokenInput = value; })
              .accessibilityText('Git 访问令牌')
            Text(this.tokenVisible ? '隐藏' : '显示')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.brand'))
              .height(Size.touch)
              .enabled(!this.busy)
              .padding({ left: Space.s3, right: Space.s3 })
              .textAlign(TextAlign.Center)
              .accessibilityText(this.tokenVisible ? '隐藏访问令牌' : '显示访问令牌')
              .onClick((): void => { this.tokenVisible = !this.tokenVisible; })
          }
          .width('100%')
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.bg_secondary'))
        }
        .width('100%')
        if (this.result === 'auth') {
          Text('仅在远端认证成功后替换本机安全存储中的当前库令牌。')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text('取消')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
            .padding({ top: Space.s1, bottom: Space.s1 })
            .enabled(!this.busy)
            .onClick((): void => { this.cancelCredentialEdit(); })
        }
      }
      .width('100%')
    } else {
      Text(this.hasStoredToken ? 'HTTPS · 令牌已保存在本机' : 'HTTPS · 需要访问令牌时可在此填写')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
  }

  /** v2.10：缺 .git 时的「重新关联远端」卡片，替代常规同步内容。 */
  @Builder
  private ReattachCard() {
    Column({ space: Space.s2 }) {
      Row() {
        Text('本地 Git 仓库缺失')
          .fontSize(FontSize.body2)
          .fontWeight(Weight.semibold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      Text('此知识库的笔记完好，但本地没有 .git 目录（应用备份不包含 Git 历史）。' +
        '填写远端地址重新关联后即可继续推送；本地笔记文件不会被修改。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Column({ space: Space.s1 }) {
        Text('远端仓库地址')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ placeholder: 'https://example.com/user/repo.git', text: this.reattachUrl })
          .fontSize(FontSize.body3)
          .enabled(!this.busy)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .padding({ left: Space.s3, right: Space.s3 })
          .backgroundColor($r('app.color.bg_secondary'))
          .borderRadius(Radius.control)
          .accessibilityText('远端仓库地址')
          .onChange((value: string): void => { this.reattachUrl = value; })
          .onSubmit((): void => { void this.runReattach(); })
      }
      .width('100%')
      Column({ space: Space.s2 }) {
        this.CredentialEditor()
      }
      .width('100%')
      if (this.reattachError.length > 0) {
        Text(this.reattachError)
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .accessibilityText(this.reattachError)
      }
      if (this.busy) {
        Text(this.progressText)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .accessibilityText('重新关联进度：' + this.progressText)
      }
      Row() {
        UtilityDialogAction(UIUtils.makeBinding<string>(() => '重新关联'), 'primary',
          this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.busy && this.reattachUrlIssue().length === 0),
          (): void => { void this.runReattach(); })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding({ left: Space.s4, right: Space.s4, top: Space.s3, bottom: Space.s3 })
    .borderRadius(Radius.card)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  /** v2.10：内容分流——缺 .git 只展示重新关联卡片，其余场景维持常规同步内容。 */
  @Builder
  private ContentBody() {
    if (this.missingGit) {
      this.ReattachCard()
    } else {
      this.DialogContent()
    }
  }

  @Builder
  private DialogContent() {
    // v1.87：卡片间距对齐原型 .sync-block 的 margin-bottom --s4。
    Column({ space: Space.s4 }) {
      // v1.77：概览与改动各自成卡，信息层级从「一堆灰条」变成两组明确区块。
      Column({ space: Space.s1 }) {
        Row() {
          Text('推送概览')
            .fontSize(FontSize.body2)
            .fontWeight(Weight.semibold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('上次推送：' + this.formatLastPush())
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        // v1.87：卡头对齐原型 .sync-block-head（min-height --s12 + 底部分隔线 + 标题 600）。
        .constraintSize({ minHeight: Space.s12 })
        .padding({ left: Space.s4, right: Space.s4, top: Space.s2, bottom: Space.s2 })
        .border({ width: { bottom: 1 }, color: $r('app.color.line') })
        // v1.87：状态行包进原型 .sync-block-body>.sync-card（--nav 底 + --small-r 圆角内卡）。
        Column() {
          Column() {
            this.StatusRow('远端', this.remoteLabel, this.transportLabel + ' · ' +
              (this.hasStoredToken ? '令牌已保存在本机' : '令牌未保存'))
            Divider().color($r('app.color.line'))
            this.StatusRow('推送分支', this.pushBranch,
              (this.pushBranch === 'xt2' ? '默认分支' : '自定义分支') + '；在电脑上合并到 ' +
              this.trackingTargetLabel())
            Divider().color($r('app.color.line'))
            this.StatusRow('待推送', this.waitingStatusText(),
              this.singleScreen ? '上报的本地改动' : '点文件在右侧核对正文')
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_navigation'))
          .borderRadius(Radius.control)
          Column() {
            this.CredentialEditor()
          }
          .width('100%')
          .padding({ top: Space.s2 })
        }
        .width('100%')
        // v1.87：卡体对齐原型 .sync-block-body（padding --s2/--s3/--s3）。
        .padding({ left: Space.s3, right: Space.s3, top: Space.s2, bottom: Space.s3 })
      }
      .width('100%')
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))

      if (this.branchEditing) {
        this.BranchEditor()
      }

      if (this.statusEntryCount > 0) {
        Column({ space: Space.s2 }) {
          Row() {
            Text('本地改动')
              .fontSize(FontSize.body2)
              .fontWeight(Weight.semibold)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(this.statusEntryCount.toString() + ' 个文件 · ' +
              (this.shouldCommitChanges() ? '推送时一并提交' : '本次不会提交'))
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          // v1.87：卡头对齐原型 .sync-block-head（min-height --s12 + 底部分隔线 + 标题 600）。
          .constraintSize({ minHeight: Space.s12 })
          .padding({ left: Space.s4, right: Space.s4, top: Space.s2, bottom: Space.s2 })
          .border({ width: { bottom: 1 }, color: $r('app.color.line') })
          Scroll() {
            Column({ space: Space.s1 }) {
              ForEach(this.changes, (change: Git2FileChange): void => {
                this.ChangeRow(change)
              }, (change: Git2FileChange): string => change.path)
            }
            .width('100%')
            .padding({ left: Space.s3, right: Space.s3 })
          }
          .width('100%')
          // v1.79 单屏：不展示 diff，清单自然展开、随整页滚动（不限高）。
          // 宽屏 / 双屏：差异在右栏独立显示，清单维持原限高，不因展开而放高。
          .height(this.singleScreen ? undefined
            : Math.min(Size.touch * 4 + Space.s6, Size.touch * this.changes.length))
          .scrollBar(this.singleScreen ? BarState.Off : BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          // 2026-11-16 键盘避让配套：宽屏内层清单 SELF_FIRST，滑到头把手势传给外层正文。
          // 单屏整页只用一个 Scroll，内层清单不滚动，无需嵌套滚动。
          .nestedScroll({
            scrollForward: this.singleScreen ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_FIRST,
            scrollBackward: this.singleScreen ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_FIRST
          })

          if (this.shouldCommitChanges()) {
            Column({ space: Space.s2 }) {
              Column({ space: Space.s1 }) {
                Text('提交说明')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({ placeholder: this.defaultCommitMessage(), text: this.commitMessage })
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_secondary'))
                  .borderRadius(Radius.control)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .onChange((value: string): void => { this.commitMessage = value; })
                  .accessibilityText('提交说明')
              }
              .width('100%')
              Column({ space: Space.s1 }) {
                Text('提交者名称 · 必填')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({ placeholder: '用于本次提交的署名', text: this.authorName })
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_secondary'))
                  .borderRadius(Radius.control)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .onChange((value: string): void => { this.authorName = value; })
                  .accessibilityText('提交者名称，必填')
              }
              .width('100%')
              Column({ space: Space.s1 }) {
                Text('提交者邮箱 · 必填')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                TextInput({ placeholder: '用于本次提交的署名', text: this.authorEmail })
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_secondary'))
                  .borderRadius(Radius.control)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .onChange((value: string): void => { this.authorEmail = value; })
                  .accessibilityText('提交者邮箱，必填')
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: Space.s3, right: Space.s3, bottom: Space.s4 })
          } else {
            Text('本次只推送已创建的本地提交；这些未提交改动会保留。')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: Space.s3, right: Space.s3, bottom: Space.s4 })
          }
        }
        .width('100%')
        .borderRadius(Radius.card)
        .border({ width: 1, color: $r('app.color.line') })
        .backgroundColor($r('app.color.bg_card'))
        .padding({ bottom: Space.s2 })
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
        Text('远端 ' + this.pushBranch + ' 已前进 ' + this.behindCount.toString() +
          ' 个提交；推送会被拒绝，请在电脑上处理。')
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
      if (!this.busy && this.result === 'none' && this.canPull()) {
        Text('拉取远端更新')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.brand'))
          .padding({ top: Space.s1, bottom: Space.s1 })
          .onClick((): void => { void this.runPullAction(); })
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
    Column({ space: Space.s2 }) {
      // v1.77：主按钮禁用必须给出原因，否则灰色按钮看起来像页面坏了。
      if (this.shouldCommitChanges() && !this.busy && this.result === 'none' &&
        (this.authorName.trim().length === 0 || this.authorEmail.trim().length === 0)) {
        Text('填写提交者名称与邮箱后可提交并推送')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      Row({ space: Space.s2 }) {
      UtilityDialogAction(UIUtils.makeBinding<string>(() => this.busy ? '取消' : '关闭'), 'secondary',
        this.singleScreen, UIUtils.makeBinding<boolean>(() => !this.busy), (): void => { this.dismiss(); })
      if (this.result === 'success') {
        UtilityDialogAction(UIUtils.makeBinding<string>(() => '完成'), 'primary', this.singleScreen, UIUtils.makeBinding<boolean>(() => true), (): void => {
          this.dismiss();
        })
      } else if (this.result !== 'none') {
        UtilityDialogAction(UIUtils.makeBinding<string>(() => this.retryActionLabel()), 'primary', this.singleScreen,
          UIUtils.makeBinding<boolean>(() => this.retryActionEnabled()), (): void => {
            this.retryFailedOperation();
          })
      } else {
        UtilityDialogAction(UIUtils.makeBinding<string>(() => this.primaryActionLabel()),
          'primary', this.singleScreen, UIUtils.makeBinding<boolean>(() => this.primaryActionEnabled()),
          (): void => { void this.runPrimaryAction(); })
      }
      }
      .width('100%')
      .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
    }
    .width('100%')
  }

  build() {
    // v1.76 全屏页：顶栏返回由 Index Appbar 统一提供（与设置页同范式）；
    // 组件负责副标题 + 主体（左状态/清单 + 右逐行差异）+ 底部操作栏。
    Column() {
      Text(this.vaultId + ' · 推送到 ' + this.pushBranch)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: Space.s4, right: Space.s4, top: Space.s2 })

      // 主体：单屏简化版（v1.79）——只有一个整页滚动的清单 + 提交流程，不展示逐行差异；
      // 宽屏 / 双屏保持左右分栏 + 右栏铺满 diff（v1.78）。
      if (this.singleScreen) {
        Scroll() { this.ContentBody() }
          .width('100%')
          .layoutWeight(1)
          // v1.87：单屏对齐原型 phone 下 .sync-side 的 padding --s4 画布内缩。
          .padding(Space.s4)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
      } else {
        Row() {
          Scroll() { this.ContentBody() }
            // v1.87：左栏固定宽对齐原型 .sync-side（calc(--nav-width * 1.65) = 396）。
            .width(Size.syncSideW)
            .height('100%')
            .padding(Space.s4)
            .border({ width: { right: 1 }, color: $r('app.color.line') })
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
          this.DiffPane()
        }
        .width('100%')
        .layoutWeight(1)
      }

      Column() {
        this.DialogFooter()
      }
      .width('100%')
      // v1.87：页脚对齐原型 .sync-page-foot（--paper 底 + 上细线 + padding --s3/--s5）。
      .padding({ left: Space.s5, right: Space.s5, top: Space.s3, bottom: Space.s3 })
      .border({ width: { top: 1 }, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
    // v1.87：画布对齐原型 .sync-page 的 --nav（bg_navigation），内容全部落在白卡上。
    .backgroundColor($r('app.color.bg_navigation'))
    .onKeyEvent((event: KeyEvent): void => {
      if (event.keyCode === KeyCode.KEYCODE_ESCAPE && event.type === KeyType.Down) {
        this.dismiss();
      }
    })
  }
}
