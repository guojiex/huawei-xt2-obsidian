/** ImportVaultDialog.ets —— v1.5 统一知识库导入入口（原型 v2 importVaultDialog）。 */
import { GitImportDraft } from '../model/GitImportDraftStore';
import { Icon } from '../common/Icons';
import { FontSize, Radius, Size, Space } from '../common/Tokens';

/**
 * 目录选择结果由弹窗自己持有：CustomDialog 的 @Prop 不会随父组件状态刷新
 * （父在弹窗打开后置位的值传不进来，按钮会一直灰），因此父侧只通过回调返回
 * 结果，界面状态落在下面的 @State 上。参见 v1.5 需求文档 §6.1。
 */
@CustomDialog
export struct ImportVaultDialog {
  controller?: CustomDialogController;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @State pickedName: string = '';
  @State working: boolean = false;
  @State source: string = 'local';
  @State gitRemote: string = '';
  @State gitBranch: string = 'main';
  @State gitUsername: string = '';
  @State gitToken: string = '';
  @State showGitToken: boolean = false;
  @State gitAuthHint: string = '';
  /** 返回选中目录的展示名；取消或失败返回 null（失败原因由父侧提示）。 */
  onChooseDirectory: () => Promise<string | null> = async (): Promise<string | null> => null;
  /** 返回是否关联成功；失败时父侧提示，弹窗保持打开供重试。 */
  onAssociateDirectory: () => Promise<boolean> = async (): Promise<boolean> => false;
  onContinueGit: (draft: GitImportDraft) => void = (_draft: GitImportDraft) => {};
  onCancel: () => void = () => {};

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
    return this.pickedName.length > 0;
  }

  private async pickDirectory(): Promise<void> {
    if (this.working) {
      return;
    }
    this.working = true;
    try {
      const name: string | null = await this.onChooseDirectory();
      if (name !== null && name.length > 0) {
        this.pickedName = name;
      }
    } finally {
      this.working = false;
    }
  }

  private async associateDirectory(): Promise<void> {
    if (!this.hasPicked() || this.working) {
      return;
    }
    this.working = true;
    try {
      await this.onAssociateDirectory();
    } finally {
      this.working = false;
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

  build() {
    Column() {
      Row() {
        Text('导入库')
          .fontSize(FontSize.s3)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('×')
          .fontSize(FontSize.s2)
          .fontColor($r('app.color.text_secondary'))
          .width(Size.touch)
          .height(Size.touch)
          .textAlign(TextAlign.Center)
          .accessibilityText('关闭导入库')
          .onClick(() => { this.close(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('把已有的笔记，带进你的工作台。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2 })

      Row({ space: Space.s1 }) {
        this.SourceTab('本地目录', 'local')
        this.SourceTab('Git 仓库', 'git')
      }
      .width('100%')
      .padding(Space.s1)
      .borderRadius(Radius.full)
      .backgroundColor($r('app.color.bg_secondary'))
      .margin({ top: Space.s3 })

      Scroll() {
        Column({ space: Space.s3 }) {
          if (this.source === 'local') {
            Text('使用手机里的笔记目录')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text('选择已有 Markdown 目录，授权后直接作为笔记库使用。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Row({ space: Space.s3 }) {
              Icon('folder', Space.s6, $r('app.color.brand'))
              Column({ space: Space.s1 }) {
                Text(this.hasPicked() ? this.pickedName : '选择本地目录')
                  .fontSize(FontSize.body2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.hasPicked() ? '已选择文件夹，关联后直接读写' : '从系统目录选择器中选择文件夹')
                  .fontSize(FontSize.caption)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .layoutWeight(1)
              Text('↗')
                .fontSize(FontSize.body1)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding(Space.s4)
            .borderRadius(Radius.card)
            .border({ width: 1, color: this.hasPicked()
              ? $r('app.color.brand') : $r('app.color.line_strong'),
              style: this.hasPicked() ? BorderStyle.Solid : BorderStyle.Dashed })
            .backgroundColor(this.hasPicked()
              ? $r('app.color.brand_bg') : $r('app.color.bg_secondary'))
            .onClick(() => { void this.pickDirectory(); })
            Text('直接读写原目录，不复制文件。移除库只解除关联，原目录和文件保留。')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(Space.s3)
              .borderRadius(Radius.control)
              .backgroundColor($r('app.color.bg_secondary'))
          } else {
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
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(0, this.windowHeightVp - Space.s8 * 6) })
      .scrollBar(BarState.Off)
      .margin({ top: Space.s4 })

      Row({ space: Space.s2 }) {
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .height(Size.buttonH)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => { this.close(); })
        if (this.source === 'local') {
          Text(this.working ? '处理中…' : '关联此目录')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.on_brand'))
            .height(Size.buttonH)
            .padding({ left: Space.s4, right: Space.s4 })
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.brand'))
            .enabled(this.hasPicked() && !this.working)
            .opacity(this.hasPicked() && !this.working ? 1 : 0.4)
            .onClick(() => { void this.associateDirectory(); })
        } else {
          Text(this.working ? '处理中…' : '导入 Git 仓库')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.on_brand'))
            .height(Size.buttonH)
            .padding({ left: Space.s4, right: Space.s4 })
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.control)
            .backgroundColor($r('app.color.brand'))
            .enabled(this.gitRemote.trim().length > 0 && !this.working)
            .opacity(this.gitRemote.trim().length > 0 && !this.working ? 1 : 0.4)
            .onClick(() => { this.continueGit(); })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: Space.s3 })
    }
    .width(this.windowWidthVp > 0
      ? Math.max(0, Math.min(Size.drawerW, this.windowWidthVp - Space.s6))
      : Size.drawerW)
    .constraintSize({ maxHeight: this.windowHeightVp })
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}
