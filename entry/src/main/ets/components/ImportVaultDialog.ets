/** ImportVaultDialog.ets —— v1.5 统一知识库导入入口（原型 v2 importVaultDialog）。 */
import { GitImportDraft } from '../model/GitImportDraftStore';
import { Icon } from '../common/Icons';
import { ZipChooseOutcome, ZipImportOutcome } from '../model/ZipImportService';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

/**
 * 目录选择结果由弹窗自己持有：CustomDialog 的 @Prop 不会随父组件状态刷新
 * （父在弹窗打开后置位的值传不进来，按钮会一直灰），因此父侧只通过回调返回
 * 结果，界面状态落在下面的 @State 上。参见 v1.5 需求文档 §6.1。
 */
@CustomDialog
export struct ImportVaultDialog {
  controller?: CustomDialogController;
  @Prop singleScreen: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @State pickedName: string = '';
  @State directoryState: string = 'unselected';
  @State directoryStatus: string = '';
  @State working: boolean = false;
  @State associating: boolean = false;
  @State source: string = 'local';
  @State gitRemote: string = '';
  @State gitBranch: string = 'main';
  @State gitUsername: string = '';
  @State gitToken: string = '';
  @State showGitToken: boolean = false;
  @State gitAuthHint: string = '';
  @State zipState: string = 'unselected';
  @State zipFileName: string = '';
  @State zipSummary: string = '';
  @State zipVaultName: string = '';
  @State zipFailureText: string = '';
  @State zipProgressText: string = '';
  @State importingZip: boolean = false;
  /** 返回选中目录的展示名；取消或失败返回 null（失败原因由父侧提示）。 */
  onChooseDirectory: () => Promise<string | null> = async (): Promise<string | null> => null;
  /** 返回是否关联成功；失败时父侧提示，弹窗保持打开供重试。 */
  onAssociateDirectory: () => Promise<boolean> = async (): Promise<boolean> => false;
  /** 选择并解析 ZIP 的编排结果（36.1/36.2）：cancelled / failed / selected。 */
  onChooseZip: () => Promise<ZipChooseOutcome> = async (): Promise<ZipChooseOutcome> => {
    const cancelled: ZipChooseOutcome = {
      status: 'cancelled', kind: 'corrupt', fileName: '', summary: '', defaultVaultName: ''
    };
    return cancelled;
  };
  /** 确认导入的编排结果（36.6/36.7）：ok 时父侧已登记切库并提示。 */
  onImportZip: (name: string, onProgress: (done: number, total: number) => void) => Promise<ZipImportOutcome> =
    async (_name: string, _onProgress: (done: number, total: number) => void): Promise<ZipImportOutcome> => {
      const cancelled: ZipImportOutcome = { status: 'cancelled', kind: 'corrupt', result: null };
      return cancelled;
    };
  onBusyChange: (busy: boolean) => void = (_busy: boolean) => {};
  onContinueGit: (draft: GitImportDraft) => void = (_draft: GitImportDraft) => {};
  onCancel: () => void = () => {};

  private setWorking(working: boolean): void {
    this.working = working;
    this.onBusyChange(working);
  }

  private isGiteeRemote(): boolean {
    const scheme: number = this.gitRemote.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const slash: number = this.gitRemote.indexOf('/', authorityStart);
    const authority: string =
      this.gitRemote.substring(authorityStart, slash >= 0 ? slash : this.gitRemote.length);
    const host: string = authority.substring(authority.lastIndexOf('@') + 1).split(':')[0].toLowerCase();
    return host === 'gitee.com' || host.endsWith('.gitee.com');
  }

  private isGitHubRemote(): boolean {
    const scheme: number = this.gitRemote.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const slash: number = this.gitRemote.indexOf('/', authorityStart);
    const authority: string =
      this.gitRemote.substring(authorityStart, slash >= 0 ? slash : this.gitRemote.length);
    const host: string = authority.substring(authority.lastIndexOf('@') + 1).split(':')[0].toLowerCase();
    return host === 'github.com' || host === 'www.github.com';
  }

  private clearGitCredentials(): void {
    this.gitUsername = '';
    this.gitToken = '';
    this.showGitToken = false;
    this.gitAuthHint = '';
  }

  private toggleGitTokenVisibility(): void {
    this.showGitToken = !this.showGitToken;
  }

  private close(): void {
    if (this.working) {
      return;
    }
    this.clearGitCredentials();
    this.controller?.close();
    this.onCancel();
  }

  aboutToDisappear(): void {
    this.clearGitCredentials();
  }

  private chooseSource(source: string): void {
    if (!this.working) {
      this.source = source;
    }
  }

  /** 是否已选好目录：只认弹窗自己的状态，不看父组件回传。 */
  private hasPicked(): boolean {
    return this.directoryState === 'selected' && this.pickedName.length > 0;
  }

  private directoryTitle(): string {
    if (this.directoryState === 'selected') {
      return this.pickedName;
    }
    return this.directoryState === 'failed' ? '未获得目录授权' : '选择笔记目录';
  }

  private directoryDescription(): string {
    if (this.directoryState === 'selected') {
      return '系统授权目录 · 关联后直接读写';
    }
    if (this.directoryState === 'failed') {
      return this.pickedName.length > 0
        ? '「' + this.pickedName + '」未完成授权；没有登记知识库，可重新选择目录。'
        : '没有登记知识库，可重新选择目录。';
    }
    return '在系统选择器中选一个文件夹';
  }

  private directoryActionLabel(): string {
    if (this.directoryState === 'selected') {
      return '更换';
    }
    return this.directoryState === 'failed' ? '重试' : '选择';
  }

  private directoryCardAccessibilityText(): string {
    return this.directoryTitle() + '，' + this.directoryDescription();
  }

  private async pickDirectory(): Promise<void> {
    if (this.working || this.source !== 'local') {
      return;
    }
    this.setWorking(true);
    this.directoryStatus = '正在打开系统目录选择器…';
    try {
      const name: string | null = await this.onChooseDirectory();
      if (name === null) {
        this.directoryStatus = '已取消选择';
      } else if (name.length > 0) {
        this.pickedName = name;
        this.directoryState = 'selected';
        this.directoryStatus = '';
      } else {
        this.directoryState = 'failed';
        this.directoryStatus = '目录授权未完成；没有登记知识库，请重新选择目录。';
      }
    } catch (_error) {
      this.directoryState = 'failed';
      this.directoryStatus = '目录授权未完成；没有登记知识库，请重新选择目录。';
    } finally {
      this.setWorking(false);
    }
  }

  private async associateDirectory(): Promise<void> {
    if (!this.hasPicked() || this.working) {
      return;
    }
    this.setWorking(true);
    this.associating = true;
    this.directoryStatus = '正在关联目录…';
    try {
      const associated: boolean = await this.onAssociateDirectory();
      if (associated) {
        this.directoryStatus = '目录已关联';
      } else {
        this.directoryState = 'failed';
        this.directoryStatus = '关联未完成；没有登记知识库，原目录未改写。请重新选择目录后重试。';
      }
    } catch (_error) {
      this.directoryState = 'failed';
      this.directoryStatus = '关联未完成；没有登记知识库，原目录未改写。请重新选择目录后重试。';
    } finally {
      this.associating = false;
      this.setWorking(false);
    }
  }

  private continueGit(): void {
    if (this.gitRemote.trim().length === 0 || this.working) {
      return;
    }
    const username: string = this.gitUsername.trim();
    if (this.isGiteeRemote() && this.gitToken.length > 0 && username.length === 0) {
      this.gitAuthHint = '使用 Gitee 私人令牌时，请填写对应用户名。';
      return;
    }
    const draft: GitImportDraft = {
      remote: this.gitRemote.trim(),
      branch: this.gitBranch.trim(),
      username: username,
      token: this.gitToken
    };
    this.clearGitCredentials();
    this.controller?.close();
    this.onContinueGit(draft);
  }

  private zipCardTitle(): string {
    if (this.zipState === 'selected') {
      return this.zipFileName;
    }
    if (this.zipState === 'failed') {
      return this.zipFileName.length > 0 ? this.zipFileName : '无法读取这个 ZIP';
    }
    return '选择 ZIP 文件';
  }

  private zipCardDescription(): string {
    if (this.zipState === 'selected') {
      return this.zipSummary;
    }
    if (this.zipState === 'failed') {
      return this.zipFailureText;
    }
    return '在系统选择器中选一个 .zip 备份';
  }

  private zipCardActionLabel(): string {
    if (this.zipState === 'selected') {
      return '更换';
    }
    return this.zipState === 'failed' ? '重试' : '选择';
  }

  private zipCardAccessibilityText(): string {
    return this.zipCardTitle() + '，' + this.zipCardDescription();
  }

  /** 36.7 失败文案映射：只暴露分类结论，不携带底层错误与 ZIP 内文件名。 */
  private zipFailureMessage(kind: string): string {
    if (kind === 'not_vault') {
      return 'ZIP 里没有 Markdown 笔记，不是知识库备份；没有新建知识库。';
    }
    if (kind === 'over_limit') {
      return 'ZIP 内容超出导入上限；没有新建知识库。';
    }
    if (kind === 'no_space') {
      return '存储空间不足；没有新建知识库，可清理空间后重试。';
    }
    if (kind === 'encrypted') {
      return '暂不支持加密 ZIP；没有新建知识库。';
    }
    if (kind === 'unsafe') {
      return 'ZIP 内包含不安全的条目，已拒绝导入；没有新建知识库。';
    }
    if (kind === 'io') {
      return '读取 ZIP 失败；没有新建知识库，可重试。';
    }
    return '文件损坏，无法读取这个 ZIP；没有新建知识库。';
  }

  private async chooseZip(): Promise<void> {
    if (this.working || this.source !== 'zip') {
      return;
    }
    this.setWorking(true);
    this.zipProgressText = '正在读取 ZIP…';
    try {
      const outcome: ZipChooseOutcome = await this.onChooseZip();
      if (outcome.status === 'cancelled') {
        // 取消选择回到原状态（36.1）：已有选择保持不变。
        this.zipProgressText = '';
      } else if (outcome.status === 'selected') {
        this.zipState = 'selected';
        this.zipFileName = outcome.fileName;
        this.zipSummary = outcome.summary;
        this.zipVaultName = outcome.defaultVaultName;
        this.zipFailureText = '';
        this.zipProgressText = '';
      } else {
        this.zipState = 'failed';
        this.zipFileName = outcome.fileName;
        this.zipFailureText = this.zipFailureMessage(outcome.kind);
        this.zipProgressText = '';
      }
    } catch (_error) {
      this.zipState = 'failed';
      this.zipFailureText = this.zipFailureMessage('io');
      this.zipProgressText = '';
    } finally {
      this.setWorking(false);
    }
  }

  private async importZip(): Promise<void> {
    if (this.zipState !== 'selected' || this.working || this.zipVaultName.trim().length === 0) {
      return;
    }
    this.setWorking(true);
    this.importingZip = true;
    this.zipProgressText = '准备导入…';
    try {
      const outcome: ZipImportOutcome = await this.onImportZip(this.zipVaultName.trim(),
        (done: number, total: number): void => {
          this.zipProgressText = '已处理 ' + done + '/' + total + ' 项';
        });
      if (outcome.status === 'ok') {
        // 父侧已完成登记、切库与「已导入 N 篇笔记」提示（36.7）。
        this.zipProgressText = '';
        this.controller?.close();
      } else if (outcome.status === 'failed') {
        this.zipState = 'failed';
        this.zipFailureText = this.zipFailureMessage(outcome.kind);
        this.zipProgressText = '';
      } else {
        this.zipProgressText = '';
      }
    } catch (_error) {
      this.zipState = 'failed';
      this.zipFailureText = this.zipFailureMessage('io');
      this.zipProgressText = '';
    } finally {
      this.importingZip = false;
      this.setWorking(false);
    }
  }

  @Builder
  SourceTab(label: string, value: string) {
    Text(label)
      .fontSize(FontSize.body3)
      .fontColor(this.source === value ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .fontWeight(this.source === value ? FontWeight.Medium : FontWeight.Normal)
      .height(Size.buttonH)
      .layoutWeight(1)
      .padding({ left: Space.s2, right: Space.s2 })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.full)
      .backgroundColor(this.source === value ? $r('app.color.bg_card') : Color.Transparent)
      .onClick(() => { this.chooseSource(value); })
  }

  @Builder
  DialogContent() {
    Column() {
      Row({ space: Space.s1 }) {
        this.SourceTab('本地目录', 'local')
        this.SourceTab('Git 仓库', 'git')
        this.SourceTab('ZIP 文件', 'zip')
      }
      .width('100%')
      .padding(Space.s1)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_secondary'))
      .margin({ top: Space.s3 })

      Scroll() {
        Column({ space: Space.s3 }) {
          if (this.source === 'local') {
            Row({ space: Space.s3 }) {
              Stack({ alignContent: Alignment.Center }) {
                Icon('folder', Space.s6, this.directoryState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.brand'))
                if (this.directoryState === 'selected') {
                  Row() {
                    Icon('check', Space.s3, $r('app.color.on_brand'))
                  }
                  .width(Space.s5)
                  .height(Space.s5)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .borderRadius(Radius.full)
                  .backgroundColor($r('app.color.brand'))
                  .align(Alignment.BottomEnd)
                } else if (this.directoryState === 'failed') {
                  Text('!')
                    .fontSize(FontSize.caption)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.on_brand'))
                    .width(Space.s5)
                    .height(Space.s5)
                    .textAlign(TextAlign.Center)
                    .borderRadius(Radius.full)
                    .backgroundColor($r('app.color.danger'))
                    .align(Alignment.BottomEnd)
                }
              }
              .width(Space.s12)
              .height(Space.s12)
              .borderRadius(Radius.control)
              .backgroundColor(this.directoryState === 'selected'
                ? $r('app.color.brand') : this.directoryState === 'failed'
                  ? $r('app.color.danger_bg') : $r('app.color.bg_card'))
              Column({ space: Space.s1 }) {
                Text(this.directoryTitle())
                  .fontSize(FontSize.body2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.directoryState === 'failed'
                    ? $r('app.color.danger') : $r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.directoryDescription())
                  .fontSize(FontSize.caption)
                  .fontColor(this.directoryState === 'failed'
                    ? $r('app.color.danger') : $r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              Text(this.directoryActionLabel())
                .fontSize(FontSize.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.directoryState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.brand'))
                .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s1 })
                .borderRadius(Radius.full)
                .backgroundColor(this.directoryState === 'failed'
                  ? $r('app.color.danger_bg') : $r('app.color.brand_bg'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding(Space.s4)
            .borderRadius(Radius.menu)
            .border({ width: 1, color: this.directoryState === 'failed'
              ? $r('app.color.danger') : this.directoryState === 'selected'
                ? $r('app.color.brand') : $r('app.color.brand'),
              style: this.directoryState === 'unselected' ? BorderStyle.Dashed : BorderStyle.Solid })
            .backgroundColor(this.directoryState === 'failed'
              ? $r('app.color.danger_bg') : this.directoryState === 'selected'
                ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
            .focusable(!this.working)
            .id('import-directory-card')
            .accessibilityText(this.directoryCardAccessibilityText())
            .accessibilityTextHint(this.directoryState === 'selected'
              ? '更换系统授权目录'
              : this.directoryState === 'failed' ? '重新选择目录' : '打开系统目录选择器')
            .onAppear((): void => {
              setTimeout((): void => {
                this.getUIContext().getFocusController().requestFocus('import-directory-card');
              }, 0);
            })
            .onClick(() => { void this.pickDirectory(); })
            if (this.directoryStatus.length > 0) {
              Text(this.directoryStatus)
                .fontSize(FontSize.caption)
                .fontColor(this.directoryState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.text_secondary'))
                .width('100%')
                .accessibilityText(this.directoryStatus)
            }
            this.DirectoryFact('link', '直接使用原目录', '不复制文件，笔记改动直接写回该目录')
            this.DirectoryFact('check', '移除只解除关联', '原目录和其中的文件都会保留')
          } else if (this.source === 'git') {
            Text('连接远端 Git 仓库')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text('克隆到应用内，作为独立笔记库使用。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Column({ space: Space.s1 }) {
              Text('仓库地址')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
              TextInput({
                placeholder: 'https://github.com/用户名/仓库.git',
                text: this.gitRemote
              })
                .height(Size.buttonH)
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .padding({ left: Space.s3, right: Space.s3 })
                .backgroundColor($r('app.color.bg_secondary'))
                .borderRadius(Radius.control)
                .onChange((value: string) => { this.gitRemote = value; })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            Column({ space: Space.s1 }) {
              Text('分支')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
              TextInput({ placeholder: 'main', text: this.gitBranch })
                .height(Size.buttonH)
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .padding({ left: Space.s3, right: Space.s3 })
                .backgroundColor($r('app.color.bg_secondary'))
                .borderRadius(Radius.control)
                .onChange((value: string) => { this.gitBranch = value; })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            if (this.isGiteeRemote()) {
              Column({ space: Space.s1 }) {
                Text('用户名')
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                TextInput({ placeholder: 'Gitee 用户名', text: this.gitUsername })
                  .height(Size.buttonH)
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_tertiary'))
                  .padding({ left: Space.s3, right: Space.s3 })
                  .backgroundColor($r('app.color.bg_secondary'))
                  .borderRadius(Radius.control)
                  .onChange((value: string) => {
                    this.gitUsername = value;
                    this.gitAuthHint = '';
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            Column({ space: Space.s1 }) {
              Text('访问令牌')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
              Row() {
                TextInput({ placeholder: '私有仓库访问令牌', text: this.gitToken })
                  .type(this.showGitToken ? InputType.Normal : InputType.Password)
                  .layoutWeight(1)
                  .height(Size.buttonH)
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_tertiary'))
                  .padding({ left: Space.s3, right: Space.s2 })
                  .backgroundColor(Color.Transparent)
                  .onChange((value: string) => {
                    this.gitToken = value;
                    this.gitAuthHint = '';
                  })
                Text(this.showGitToken ? '隐藏' : '显示')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.brand'))
                  .height(Size.touch)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .textAlign(TextAlign.Center)
                  .accessibilityText(this.showGitToken ? '隐藏访问令牌' : '显示访问令牌')
                  .onClick(() => { this.toggleGitTokenVisibility(); })
              }
              .width('100%')
              .borderRadius(Radius.control)
              .backgroundColor($r('app.color.bg_secondary'))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            Text(this.gitAuthHint.length > 0
              ? this.gitAuthHint
              : (this.isGitHubRemote()
                ? 'GitHub 使用 Bearer 认证；私有仓库需要令牌，公开仓库可留空。'
                : '私有仓库需要令牌，公开仓库可留空。'))
              .fontSize(FontSize.caption)
              .fontColor(this.gitAuthHint.length > 0
                ? $r('app.color.brand')
                : $r('app.color.text_secondary'))
              .width('100%')
            Text('令牌用于本次克隆；成功后存入本机安全存储，关闭弹窗会清空输入。不会写入地址、日志或普通设置，可在同步页更换。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(Space.s3)
              .borderRadius(Radius.control)
              .backgroundColor($r('app.color.bg_secondary'))
            Text('GitHub 使用 Bearer；Gitee 使用用户名和令牌。移除库只删除手机副本，远端仓库保留。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(Space.s3)
              .borderRadius(Radius.control)
              .backgroundColor($r('app.color.bg_secondary'))
          } else {
            Text('从 ZIP 备份新建知识库')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: Space.s3 }) {
              Stack({ alignContent: Alignment.Center }) {
                Icon('archive', Space.s6, this.zipState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.brand'))
                if (this.zipState === 'selected') {
                  Row() {
                    Icon('check', Space.s3, $r('app.color.on_brand'))
                  }
                  .width(Space.s5)
                  .height(Space.s5)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .borderRadius(Radius.full)
                  .backgroundColor($r('app.color.brand'))
                  .align(Alignment.BottomEnd)
                } else if (this.zipState === 'failed') {
                  Text('!')
                    .fontSize(FontSize.caption)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.on_brand'))
                    .width(Space.s5)
                    .height(Space.s5)
                    .textAlign(TextAlign.Center)
                    .borderRadius(Radius.full)
                    .backgroundColor($r('app.color.danger'))
                    .align(Alignment.BottomEnd)
                }
              }
              .width(Space.s12)
              .height(Space.s12)
              .borderRadius(Radius.control)
              .backgroundColor(this.zipState === 'selected'
                ? $r('app.color.brand') : this.zipState === 'failed'
                  ? $r('app.color.danger_bg') : $r('app.color.bg_card'))
              Column({ space: Space.s1 }) {
                Text(this.zipCardTitle())
                  .fontSize(FontSize.body2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.zipState === 'failed'
                    ? $r('app.color.danger') : $r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.zipCardDescription())
                  .fontSize(FontSize.caption)
                  .fontColor(this.zipState === 'failed'
                    ? $r('app.color.danger') : $r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              Text(this.zipCardActionLabel())
                .fontSize(FontSize.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.zipState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.brand'))
                .padding({ left: Space.s3, right: Space.s3, top: Space.s1, bottom: Space.s1 })
                .borderRadius(Radius.full)
                .backgroundColor(this.zipState === 'failed'
                  ? $r('app.color.danger_bg') : $r('app.color.brand_bg'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding(Space.s4)
            .borderRadius(Radius.menu)
            .border({ width: 1, color: this.zipState === 'failed'
              ? $r('app.color.danger') : $r('app.color.brand'),
              style: this.zipState === 'unselected' ? BorderStyle.Dashed : BorderStyle.Solid })
            .backgroundColor(this.zipState === 'failed'
              ? $r('app.color.danger_bg') : this.zipState === 'selected'
                ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
            .focusable(!this.working)
            .id('import-zip-card')
            .accessibilityText(this.zipCardAccessibilityText())
            .accessibilityTextHint(this.zipState === 'selected'
              ? '更换 ZIP 文件'
              : this.zipState === 'failed' ? '重新选择 ZIP 文件' : '打开系统文件选择器')
            .onAppear((): void => {
              setTimeout((): void => {
                this.getUIContext().getFocusController().requestFocus('import-zip-card');
              }, 0);
            })
            .onClick(() => { void this.chooseZip(); })
            if (this.zipProgressText.length > 0) {
              Text(this.zipProgressText)
                .fontSize(FontSize.caption)
                .fontColor(this.zipState === 'failed'
                  ? $r('app.color.danger') : $r('app.color.text_secondary'))
                .width('100%')
                .accessibilityText(this.zipProgressText)
            }
            if (this.zipState === 'selected') {
              Column({ space: Space.s1 }) {
                Text('新知识库名称')
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                TextInput({ placeholder: '新知识库名称', text: this.zipVaultName })
                  .height(Size.buttonH)
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_tertiary'))
                  .maxLength(40)
                  .padding({ left: Space.s3, right: Space.s3 })
                  .backgroundColor($r('app.color.bg_secondary'))
                  .borderRadius(Radius.control)
                  .onChange((value: string) => { this.zipVaultName = value; })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            this.DirectoryFact('plus', '只新建、不覆盖', '总是新建一个知识库，已有库和其中的文件保持不变')
            this.DirectoryFact('archive', '只导入笔记与图片', '其他文件、隐藏项、.git 与回收站会跳过，完成后告知数量')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(0, this.windowHeightVp - Space.s8 * 6) })
      .scrollBar(BarState.Off)
      .margin({ top: Space.s4 })

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DirectoryFact(icon: string, title: string, description: string) {
    Row({ space: Space.s3 }) {
      Icon(icon, Space.s5, $r('app.color.brand'))
      Column({ space: Space.s1 }) {
        Text(title)
          .fontSize(FontSize.body3)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(description)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s2 }) {
      UtilityDialogAction('取消', 'secondary', this.singleScreen, !this.working, (): void => {
        this.close();
      }, true)
      if (this.source === 'local') {
        UtilityDialogAction(this.associating ? '正在关联…' : '关联此目录', 'primary',
          this.singleScreen, this.hasPicked() && !this.working, (): void => {
            void this.associateDirectory();
          }, true)
      } else if (this.source === 'zip') {
        UtilityDialogAction(this.importingZip ? '正在导入…' : '导入为新知识库', 'primary',
          this.singleScreen, this.zipState === 'selected' && this.zipVaultName.trim().length > 0 && !this.working,
          (): void => {
            void this.importZip();
          }, true)
      } else {
        UtilityDialogAction(this.working ? '处理中…' : '导入 Git 仓库', 'primary',
          this.singleScreen, this.gitRemote.trim().length > 0 && !this.working, (): void => {
            this.continueGit();
          }, true)
      }
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '导入库',
      subtitle: this.source === 'zip' ? '从 ZIP 备份新建一个知识库'
        : this.source === 'git' ? '克隆远端 Git 仓库为独立笔记库'
        : '关联已有的 Markdown 笔记目录',
      headerIcon: 'folder',
      closeLabel: '关闭导入库',
      singleScreen: this.singleScreen,
      preferredWidthVp: Size.importDialogW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      scrollContent: false,
      onClose: (): void => { this.close(); },
      content: (): void => { this.DialogContent(); },
      footer: (): void => { this.DialogFooter(); }
    })
  }
}
