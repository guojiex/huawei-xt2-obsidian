import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';
import { GitBridgeController, GitBridgeView } from '../git/GitBridgeView';
import { GitFsBackend } from '../git/GitFsBackend';
import { GitProgress } from '../git/GitBridgeModels';

const STORE_NAME = 'git_sync';

/**
 * GitHub 仓库接入页（F6）。
 * MVP 阶段只做 clone：把远端笔记库拉进沙箱 vault，让后面的浏览/编辑有内容可用。
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
  @State fileCount: number = 0;

  private context: common.UIAbilityContext | undefined = undefined;
  private vaultRoot: string = '';
  private bridgeCtrl: GitBridgeController = new GitBridgeController();

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.vaultRoot = this.context.filesDir + '/vault';
    this.loadConfig();
  }

  private store(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: STORE_NAME });
  }

  private loadConfig(): void {
    const s = this.store();
    this.repoUrl = s.getSync('repoUrl', '') as string;
    this.branch = s.getSync('branch', 'main') as string;
    // TODO(安全): MVP 暂存在 preferences，正式版必须迁移到关键资产存储服务（Asset Store Kit）
    this.token = s.getSync('token', '') as string;
    this.username = s.getSync('username', '') as string;
    this.refreshFiles();
  }

  private saveConfig(): void {
    const s = this.store();
    s.putSync('repoUrl', this.repoUrl);
    s.putSync('branch', this.branch);
    s.putSync('token', this.token);
    s.putSync('username', this.username);
    s.flushSync();
  }

  private refreshFiles(): void {
    try {
      const backend = new GitFsBackend(this.vaultRoot);
      this.fileCount = backend.listMarkdown('').length;
    } catch (e) {
      this.fileCount = 0;
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
    if (message.includes('AlreadyExists') || message.includes('EEXIST')) {
      return 'vault 非空，git 拒绝克隆到非空目录（清理后再试）';
    }
    if (message.includes('ENOTFOUND') || message.includes('ECONNREFUSED') || message.includes('timed out')) {
      return '网络不可达，请检查网络或 VPN';
    }
    return message;
  }

  private async doClone(): Promise<void> {
    if (this.repoUrl.length === 0) {
      promptAction.showToast({ message: '请先填写仓库地址' });
      return;
    }
    if (!this.bridgeCtrl.ready) {
      this.appendLog('桥接层尚未就绪，请稍候再试');
      return;
    }
    this.saveConfig();
    this.busy = true;
    this.progressText = '准备中…';
    this.appendLog('开始拉取 ' + this.repoUrl);
    await this.bridgeCtrl.clone(this.repoUrl, this.branch, this.token, this.username);
  }

  build() {
    Column() {
      Text('接入 GitHub 笔记库')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 12 })

      TextInput({ placeholder: 'https://github.com/owner/repo.git', text: this.repoUrl })
        .onChange((value: string) => {
          this.repoUrl = value;
        })
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
        Button(this.busy ? '拉取中…' : '拉取到本机')
          .enabled(!this.busy)
          .onClick(() => {
            this.doClone();
          })
        Text('已导入 ' + this.fileCount + ' 篇笔记')
          .fontSize(12)
          .fontColor('#666666')
          .margin({ left: 12 })
      }
      .margin({ bottom: 12 })

      Text(this.progressText)
        .fontSize(12)
        .margin({ bottom: 8 })

      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .fontColor('#444444')
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)

      // 承载 isomorphic-git 的隐形引擎
      GitBridgeView({
        vaultRoot: this.vaultRoot,
        gitDir: '/vault',
        token: this.token,
        username: this.username,
        bridgeController: this.bridgeCtrl,
        onProgress: (p: GitProgress) => {
          this.progressText = p.phase + ' ' + p.loaded + '/' + p.total;
        },
        onLog: (msg: string) => {
          this.appendLog(msg);
        },
        onCloneDone: (ok: boolean, message: string) => {
          this.busy = false;
          this.progressText = ok ? '完成' : '失败';
          this.appendLog(ok ? '拉取完成' : '拉取失败：' + this.explainError(message));
          if (ok) {
            this.refreshFiles();
          }
        }
      })
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
