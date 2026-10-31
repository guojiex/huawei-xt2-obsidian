import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitNativeService } from '../git/GitNativeService';
import { Git2ActionOptions, Git2CloneOptions, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';
import { VaultRegistry } from '../model/VaultRegistry';
import { sanitizeVaultName, VaultEntry } from '../model/Vault';
import { FontSize, Space } from '../common/Tokens';

/** 旧版把令牌明文存在这个 preferences store（v0.3 起令牌只进 Asset Store Kit，进页一次性清除） */
const LEGACY_STORE_NAME: string = 'git_sync';
/** 导入中临时目录的后缀：先 clone 到 vaults/<id>__importing，成功后 rename 到正式 id（mvp_design §9 导入失败残留） */
const IMPORTING_SUFFIX: string = '__importing';

/**
 * 从仓库地址推导库名：取最后一段路径，去掉 .git 后缀，再走库名消毒。
 * 推不出来（空 / 全非法字符）时回落到固定名，由 uniqueVaultId 保证不重名。
 */
function repoNameFromUrl(url: string): string {
  let u: string = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  if (u.endsWith('.git')) {
    u = u.substring(0, u.length - 4);
  }
  const idx: number = u.lastIndexOf('/');
  const raw: string = idx >= 0 ? u.substring(idx + 1) : u;
  const sanitized: string = sanitizeVaultName(raw);
  return sanitized.length > 0 ? sanitized : 'Git 笔记库';
}

/**
 * 导入 Git 仓库页（F6 / v0.3 M3.5）。
 *
 * 流程（对应 mvp_design §4.5 生命周期「导入仓库」）：
 * 1. 从地址推导库名 → uniqueVaultId 定正式 id；
 * 2. 先写入恢复标记，再 clone 到 `vaults/<正式id>__importing` 临时目录；
 * 3. 成功 → rename 到正式 id → 登记 VaultRegistry（type='git'）→ 令牌入 Asset Store Kit →
 *    自动切为当前库 → 返回主页（Index.onPageShow 检测到外部切库后重置上下文）。
 */
@Entry
@Component
struct SyncPage {
  @State repoUrl: string = '';
  @State branch: string = 'main';
  @State token: string = '';
  @State username: string = '';
  @State busy: boolean = false;
  @State progressText: string = '';
  @State logText: string = '';
  @State syncMode: boolean = false;
  @State syncVaultId: string = '';
  @State syncRemote: string = '';
  @State syncStatusText: string = '';
  @State syncToken: string = '';
  @State syncUsername: string = '';
  @State commitMessage: string = '从曜石笔记同步';
  @State authorName: string = '';
  @State authorEmail: string = '';

  private context: common.UIAbilityContext | undefined = undefined;
  /** 本次导入的临时 id（clone 失败时的清理目标） */
  private pendingTempId: string = '';
  /** 本次导入的正式 id（clone 成功后 rename + 登记） */
  private pendingFinalId: string = '';

  onBackPress(): boolean {
    return this.busy;
  }

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.cleanupLegacyToken();
    const current: VaultEntry | null = VaultRegistry.get().currentEntry();
    if (current !== null && current.type === 'git') {
      this.syncMode = true;
      this.syncVaultId = current.id;
      this.syncRemote = current.remote ?? '';
      this.syncUsername = current.authUsername ?? '';
      try {
        this.syncToken = GitCredentialStore.getToken(current.id) ?? '';
      } catch {
        this.syncToken = '';
      }
      this.refreshSyncStatus();
    }
  }

  /** 旧版曾把令牌明文存 preferences（git_sync/token）—— 一次性清除，此后令牌只进 Asset Store Kit。 */
  private cleanupLegacyToken(): void {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: LEGACY_STORE_NAME });
      if (store.hasSync('token')) {
        store.delete('token');
        store.flushSync();
      }
    } catch (error) {
      // 清理失败不阻塞导入页本身
      const err = error as BusinessError;
      this.appendLog('旧令牌清理失败（可忽略）：' + err.message);
    }
  }

  private appendLog(line: string): void {
    this.logText = this.logText + line + '\n';
  }

  /** 把 git 的裸错误翻译成人话，省得在手机上对着 401 发呆 */
  private explainError(message: string): string {
    if (message.includes('401') || message.includes('Unauthorized') ||
      message.toLowerCase().includes('authentication')) {
      // Gitee 对「仓库不存在」和「私有库未认证」都回 401，最容易误判
      return '认证失败。Gitee 对"仓库不存在 / 私有库未授权"都返回 401，请确认地址、用户名与令牌';
    }
    if (message.includes('404') || message.includes('NotFound')) {
      return '仓库或分支不存在，请检查地址与分支名';
    }
    if (message.includes('ENOTFOUND') || message.includes('ECONNREFUSED') || message.includes('timed out')) {
      return '网络不可达，请检查网络或 VPN';
    }
    return message;
  }

  /** 将导入到的库 id（随地址输入实时推导，UI 预览用） */
  private previewVaultId(): string {
    return VaultRegistry.get().uniqueVaultId(repoNameFromUrl(this.repoUrl), '');
  }

  private async doClone(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.repoUrl.trim().length === 0) {
      promptAction.showToast({ message: '请先填写仓库地址' });
      return;
    }
    const url: string = this.repoUrl.trim();
    if (this.urlHasInlineCredentials(url)) {
      promptAction.showToast({ message: '请移除地址中的认证信息，改在令牌字段填写' });
      return;
    }
    const username: string = this.username.trim();
    const token: string = this.token;
    const isGitHub: boolean = this.isGitHubRemote(url);
    if (token.length > 0 && !isGitHub && username.length === 0) {
      promptAction.showToast({ message: '此 Git 服务需要填写用户名' });
      return;
    }
    const reg: VaultRegistry = VaultRegistry.get();
    const finalId: string = this.previewVaultId();
    const tempId: string = reg.uniqueVaultId(finalId + IMPORTING_SUFFIX, '');
    this.pendingFinalId = finalId;
    this.pendingTempId = tempId;
    this.busy = true;
    this.progressText = '准备中…';
    this.appendLog('开始导入 → vaults/' + finalId);
    try {
      reg.beginGitImport(finalId, tempId);
      // Native clone 只写本次标记拥有的全新导入目录；失败时由恢复标记清理。
      const tempDir: string = reg.vaultDirOf(tempId);
      const options: Git2CloneOptions = {
        url: url,
        targetPath: tempDir,
        branch: this.branch.trim().length > 0 ? this.branch.trim() : undefined,
        onProgress: (progress: Git2Progress): void => {
          this.progressText = GitNativeService.progressLabel(progress);
        },
      };
      if (token.length > 0) {
        if (isGitHub) {
          options.bearerToken = token;
        } else {
          options.username = username;
          options.password = token;
        }
      }
      const clonedPath: string = await GitNativeService.clone(options);
      if (clonedPath !== tempDir) {
        throw new Error('Native clone 返回的目录与隔离目标不一致');
      }
      const state: Git2RepositoryState = GitNativeService.repositoryState(tempDir);
      if (!state.clean || (this.branch.trim().length > 0 && state.branch !== this.branch.trim())) {
        throw new Error('clone 后的仓库分支或工作区状态校验失败');
      }
      this.onCloneDone(true, 'Native clone 与磁盘状态校验完成');
    } catch (error) {
      const err = error as BusinessError;
      this.onCloneDone(false, err.message ?? String(error));
    }
  }

  private isGitHubRemote(url: string): boolean {
    const scheme: number = url.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const slash: number = url.indexOf('/', authorityStart);
    const authority: string = url.substring(authorityStart, slash >= 0 ? slash : url.length);
    const host: string = authority.split(':')[0].toLowerCase();
    return host === 'github.com' || host === 'www.github.com';
  }

  private urlHasInlineCredentials(url: string): boolean {
    const scheme: number = url.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const authorityEnd: number = url.indexOf('/', authorityStart);
    const authority: string = url.substring(authorityStart, authorityEnd >= 0 ? authorityEnd : url.length);
    if (authority.indexOf('@') >= 0) {
      return true;
    }
    const queryStart: number = url.indexOf('?');
    if (queryStart < 0) {
      return false;
    }
    const fragmentStart: number = url.indexOf('#', queryStart);
    const query: string = url.substring(queryStart + 1, fragmentStart >= 0 ? fragmentStart : url.length);
    const credentialKeys: string[] = [
      'token', 'access_token', 'private_token', 'personal_access_token', 'password', 'passwd',
      'secret', 'authorization', 'auth', 'bearer', 'pat'
    ];
    const parts: string[] = query.split('&');
    for (let i: number = 0; i < parts.length; i++) {
      const equals: number = parts[i].indexOf('=');
      const key: string = (equals >= 0 ? parts[i].substring(0, equals) : parts[i]).toLowerCase();
      if (credentialKeys.indexOf(key) >= 0) {
        return true;
      }
    }
    return false;
  }

  private refreshSyncStatus(): void {
    if (!this.syncMode || this.syncVaultId.length === 0) {
      return;
    }
    const reg: VaultRegistry = VaultRegistry.get();
    if (reg.currentId() !== this.syncVaultId) {
      this.syncStatusText = '当前库已切换，请返回主页后重新打开同步页';
      return;
    }
    try {
      const state: Git2RepositoryState = GitNativeService.repositoryState(reg.vaultDirOf(this.syncVaultId));
      const lines: string[] = ['当前分支：' + state.branch, '推送目标：xt2'];
      if (state.statusEntryCount > 0) {
        lines.push('有 ' + state.statusEntryCount.toString() + ' 项未提交更改');
      } else {
        lines.push('工作区干净');
      }
      if (state.aheadCount > 0) {
        lines.push('有 ' + state.aheadCount.toString() + ' 个本地提交待推送');
      }
      if (state.behindCount > 0) {
        lines.push('远端 xt2 已前进 ' + state.behindCount.toString() + ' 个提交；手机端不合并');
      }
      if (state.head.length > 0) {
        lines.push('HEAD ' + state.head.substring(0, 10));
      }
      this.syncStatusText = lines.join('\n');
    } catch (error) {
      const err = error as BusinessError;
      this.syncStatusText = '无法读取 Git 状态：' + this.explainError(err.message ?? String(error));
    }
  }

  private async performGitAction(operation: 'stage' | 'commit' | 'fetch' | 'push'): Promise<void> {
    if (this.busy) {
      return;
    }
    const reg: VaultRegistry = VaultRegistry.get();
    const entry: VaultEntry | null = reg.currentEntry();
    if (!this.syncMode || entry === null || entry.type !== 'git' || entry.id !== this.syncVaultId) {
      promptAction.showToast({ message: '当前 Git 库已变化，请返回主页重新打开同步页' });
      return;
    }
    if (this.syncToken.length > 0 && !this.isGitHubRemote(this.syncRemote) && this.syncUsername.trim().length === 0) {
      promptAction.showToast({ message: '此 Git 服务需要填写用户名' });
      return;
    }
    if (operation === 'commit' &&
      (this.commitMessage.trim().length === 0 || this.authorName.trim().length === 0 ||
        this.authorEmail.trim().length === 0)) {
      promptAction.showToast({ message: '提交需要填写说明、作者名和邮箱' });
      return;
    }

    this.busy = true;
    this.progressText = operation === 'push' || operation === 'fetch' ? '连接远端…' : '处理中…';
    try {
      const options: Git2ActionOptions = {
        operation: operation,
        repositoryPath: reg.vaultDirOf(this.syncVaultId),
        onProgress: (progress: Git2Progress): void => {
          this.progressText = GitNativeService.progressLabel(progress);
        },
      };
      if (this.syncToken.length > 0) {
        if (this.isGitHubRemote(this.syncRemote)) {
          options.bearerToken = this.syncToken;
        } else {
          options.username = this.syncUsername.trim();
          options.password = this.syncToken;
        }
      }
      if (operation === 'commit') {
        options.message = this.commitMessage.trim();
        options.authorName = this.authorName.trim();
        options.authorEmail = this.authorEmail.trim();
      }
      const result: string = await GitNativeService.action(options);
      if (operation === 'fetch' || operation === 'push') {
        try {
          const authUsername: string = this.isGitHubRemote(this.syncRemote) ? '' : this.syncUsername.trim();
          reg.updateGitAuthUsername(this.syncVaultId, authUsername);
        } catch {
          this.appendLog('远端操作已完成，但用户名设置未能保存');
        }
        if (this.syncToken.length > 0) {
          try {
            GitCredentialStore.saveToken(this.syncVaultId, this.syncToken);
          } catch {
            this.appendLog('令牌未能安全保存；下次同步时需要重新填写');
          }
        }
      }
      if (operation === 'fetch') {
        this.appendLog(result === 'missing' ? '远端尚无 xt2 分支' : '已获取 xt2 远端状态');
      } else if (operation === 'commit') {
        this.appendLog('本地提交完成：' + result.substring(0, 10));
      } else if (operation === 'push') {
        try {
          reg.recordGitSync(this.syncVaultId, Date.now());
        } catch {
          this.appendLog('推送成功，但上次同步时间未能保存');
        }
        this.appendLog('已推送到 xt2：' + result.substring(0, 10));
      } else {
        this.appendLog('已暂存工作区更改（.trash 已排除）');
      }
      this.progressText = operation === 'push' ? '推送完成' : '完成';
      this.refreshSyncStatus();
    } catch (error) {
      const err = error as BusinessError;
      this.progressText = '失败';
      this.appendLog(this.explainError(err.message ?? String(error)));
    } finally {
      this.busy = false;
    }
  }

  /** clone 结果（成功/失败共用）：验证成功后 rename → 登记 → 存令牌 → 切库；失败清本次标记目录。 */
  private onCloneDone(ok: boolean, message: string): void {
    this.busy = false;
    if (!ok) {
      this.progressText = '失败';
      this.appendLog('导入失败：' + this.explainError(message));
      this.cleanupTempDir();
      return;
    }
    const reg: VaultRegistry = VaultRegistry.get();
    const tempDir: string = reg.vaultDirOf(this.pendingTempId);
    const finalDir: string = reg.vaultDirOf(this.pendingFinalId);
    try {
      // 目标 id 在导入开始时已确认空闲；此 rename 仅发布本次新目录，不承担既有文件的原子替换保证。
      if (fileIo.accessSync(finalDir)) {
        throw new Error('正式库目录已存在，拒绝覆盖: ' + this.pendingFinalId);
      }
      fileIo.renameSync(tempDir, finalDir);
      const entry: VaultEntry = reg.registerGit(this.pendingFinalId, this.repoUrl.trim(), this.branch.trim(), this.username.trim());
      reg.finishGitImport(this.pendingFinalId, this.pendingTempId);
      // 令牌只进 Asset Store Kit；存失败不判导入失败（下次同步重填即可）
      if (this.token.length > 0) {
        try {
          GitCredentialStore.saveToken(entry.id, this.token);
        } catch (credError) {
          const ce = credError as BusinessError;
          this.appendLog('警告：令牌安全存储失败（code=' + ce.code + '），下次同步需重新填写');
        }
      }
      reg.setCurrent(entry.id);
      this.progressText = '完成';
      this.appendLog('导入完成：vaults/' + entry.id + '（已切换为当前库）');
      this.pendingTempId = '';
      this.pendingFinalId = '';
      promptAction.showToast({ message: '已导入 ' + entry.id });
      router.back();
    } catch (error) {
      const err = error as BusinessError;
      this.progressText = '失败';
      this.appendLog('登记库失败：' + err.message);
      this.cleanupTempDir();
    }
  }

  /** 删除本次导入拥有的临时/未登记正式目录；清理失败时保留恢复标记供下次启动重试。 */
  private cleanupTempDir(): void {
    if (this.pendingTempId.length === 0 || this.pendingFinalId.length === 0) {
      return;
    }
    try {
      VaultRegistry.get().cleanupGitImport(this.pendingFinalId, this.pendingTempId);
      this.appendLog('已清理本次导入目录');
    } catch (error) {
      const err = error as BusinessError;
      this.appendLog('导入目录清理失败（恢复标记保留供下次启动重试）：' + err.message);
    }
    this.pendingTempId = '';
    this.pendingFinalId = '';
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .onClick(() => {
            if (!this.busy) {
              router.back();
            }
          })
        Blank()
        Text(this.syncMode ? 'Git 同步' : '导入 Git 仓库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('‹ 返回')
          .fontSize(16)
          .fontColor(Color.Transparent)
      }
      .width('100%')
      .margin({ bottom: 16 })

      // v1.5 前置核实的临时入口（2026-10-31）：真机上跑一遍「选目录 → 持久化 →
      // 递归列出 → 读写」，把 api_notes T1–T4 的 ❓ 换成实测值。正式实现落地后移除。
      Button('外部目录能力核实（v1.5 临时）')
        .width('100%')
        .enabled(!this.busy)
        .margin({ bottom: Space.s2 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ExternalDirProbePage' });
        })

      if (this.syncMode) {
        Text('当前 Git 库：' + this.syncVaultId)
          .fontSize(FontSize.body1)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: Space.s2 })
        Text(this.syncStatusText)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s2 })

        TextInput({ placeholder: '提交说明', text: this.commitMessage })
          .onChange((value: string) => { this.commitMessage = value; })
          .margin({ bottom: Space.s2 })
        TextInput({ placeholder: '提交作者名', text: this.authorName })
          .onChange((value: string) => { this.authorName = value; })
          .margin({ bottom: Space.s2 })
        TextInput({ placeholder: '提交作者邮箱', text: this.authorEmail })
          .onChange((value: string) => { this.authorEmail = value; })
          .margin({ bottom: Space.s2 })
        TextInput({ placeholder: '当前库令牌（安全保存）', text: this.syncToken })
          .type(InputType.Password)
          .onChange((value: string) => { this.syncToken = value; })
          .margin({ bottom: Space.s2 })
        TextInput({ placeholder: '当前库用户名（Gitee / GitLab）', text: this.syncUsername })
          .onChange((value: string) => { this.syncUsername = value; })
          .margin({ bottom: Space.s2 })

        Row({ space: Space.s2 }) {
          Button('刷新状态')
            .enabled(!this.busy)
            .onClick(() => { this.refreshSyncStatus(); })
          Button('暂存')
            .enabled(!this.busy)
            .onClick(() => { void this.performGitAction('stage'); })
          Button('提交')
            .enabled(!this.busy)
            .onClick(() => { void this.performGitAction('commit'); })
          Button('获取远端')
            .enabled(!this.busy)
            .onClick(() => { void this.performGitAction('fetch'); })
          Button(this.busy ? '同步中…' : '推送 xt2')
            .enabled(!this.busy)
            .onClick(() => { void this.performGitAction('push'); })
        }
        .width('100%')
        .margin({ bottom: Space.s2 })

        Text('手机端不执行 pull / checkout。远端分支前进时会拒绝推送，请在 PC 端解决后再同步。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .margin({ bottom: Space.s3 })
      }

      Text(this.syncMode ? '导入另一个 Git 仓库' : '导入 Git 仓库')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 8 })

      TextInput({ placeholder: 'https://github.com/owner/repo.git', text: this.repoUrl })
        .onChange((value: string) => {
          this.repoUrl = value;
        })
        .margin({ bottom: 8 })

      Text('将导入为：vaults/' + (this.repoUrl.trim().length > 0 ? this.previewVaultId() : '（填写地址后推导）'))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8 })

      TextInput({ placeholder: '分支（main / master）', text: this.branch })
        .onChange((value: string) => {
          this.branch = value;
        })
        .margin({ bottom: 8 })

      TextInput({ placeholder: '私有库填 Access Token（GitHub / Gitee 通用）', text: this.token })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.token = value;
        })
        .margin({ bottom: 8 })

      TextInput({ placeholder: '用户名（仅 Gitee / 自建 GitLab 私有库需要）', text: this.username })
        .onChange((value: string) => {
          this.username = value;
        })
        .margin({ bottom: 12 })

      Row() {
        Button(this.busy ? '导入中…' : '导入为本机笔记库')
          .enabled(!this.busy)
          .onClick(() => {
            this.doClone();
          })
      }
      .margin({ bottom: 12 })

      Text(this.progressText)
        .fontSize(12)
        .margin({ bottom: 8 })

      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)

    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
