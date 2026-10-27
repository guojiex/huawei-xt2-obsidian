import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GitBridgeController, GitBridgeView } from '../git/GitBridgeView';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitProgress } from '../git/GitBridgeModels';
import { VaultRegistry } from '../model/VaultRegistry';
import { sanitizeVaultName, VaultEntry } from '../model/Vault';

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

  private context: common.UIAbilityContext | undefined = undefined;
  private bridgeCtrl: GitBridgeController = new GitBridgeController();
  /** 本次导入的临时 id（clone 失败时的清理目标） */
  private pendingTempId: string = '';
  /** 本次导入的正式 id（clone 成功后 rename + 登记） */
  private pendingFinalId: string = '';

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.cleanupLegacyToken();
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
    if (message.includes('401') || message.includes('Unauthorized')) {
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
    if (this.repoUrl.trim().length === 0) {
      promptAction.showToast({ message: '请先填写仓库地址' });
      return;
    }
    if (!this.bridgeCtrl.ready) {
      this.appendLog('桥接层尚未就绪，请稍候再试');
      return;
    }
    const reg: VaultRegistry = VaultRegistry.get();
    const finalId: string = this.previewVaultId();
    const tempId: string = reg.uniqueVaultId(finalId + IMPORTING_SUFFIX, '');
    this.pendingFinalId = finalId;
    this.pendingTempId = tempId;
    this.busy = true;
    this.progressText = '准备中…';
    this.appendLog('开始导入 ' + this.repoUrl.trim() + ' → vaults/' + finalId);
    try {
      reg.beginGitImport(finalId, tempId);
      // 临时目录即本次 clone 的 fs root；gitDir 标签与 root 一致（JS 侧只做前缀剥离）
      const tempDir: string = reg.vaultDirOf(tempId);
      await this.bridgeCtrl.init(tempDir, tempDir, this.token, this.username, true);
      await this.bridgeCtrl.clone(this.repoUrl.trim(), this.branch.trim(), this.token, this.username);
    } catch (error) {
      const err = error as BusinessError;
      this.onCloneDone(false, err.message ?? String(error));
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
        Text('导入 Git 仓库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('‹ 返回')
          .fontSize(16)
          .fontColor(Color.Transparent)
      }
      .width('100%')
      .margin({ bottom: 16 })

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

      // 承载 isomorphic-git 的隐形引擎
      GitBridgeView({
        vaultRoot: VaultRegistry.get().vaultsRootDir(),
        gitDir: VaultRegistry.get().vaultsRootDir(),
        token: '',
        username: '',
        bridgeController: this.bridgeCtrl,
        onProgress: (p: GitProgress) => {
          this.progressText = p.phase + ' ' + p.loaded + '/' + p.total;
        },
        onLog: (msg: string) => {
          this.appendLog(msg);
        },
        onCloneDone: (ok: boolean, message: string) => {
          this.onCloneDone(ok, message);
        }
      })
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
