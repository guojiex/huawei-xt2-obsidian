/**
 * SettingsView.ets —— 设置与关于（原型「设置与关于」面板，v0.2 §4.x）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（与 VaultManagerView 同级）。
 * 顶栏返回由 Index 处理；单屏分类详情另提供返回分类入口。
 *
 * 内容（照原型「设置与关于」规格，2026-10-21 对齐设计稿改版）：
 *  - 关于卡：hero（应用名 + 版本号）+ 定位一行 + 开源信息一行小字；
 *    **包名行已删**（设计稿 2026-10-21 拍板：那是开发期对 hdc 日志/签名用的诊断值，用户不需要）；
 *    版本号**运行时从自身包信息读出，不在代码写死常量**（api_notes H-1/H-2：
 *    getBundleInfoForSelfSync 在 try/catch 内调用，失败兜底显示占位，读不到也不崩）；
 *  - 更新日志卡：数据驱动的最近记录，最新在上，内容由 changelog.json 生成；
 *  - 诊断卡：当前形态 / 断点 / 库目录（真机校准对照）；
 *  - 后续版本才有的设置项在底部灰显占位。
 * 视觉：token 化 + 内容页限宽 760vp 居中（需求 4.9）。
 */
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';
import { ResetDataDialog } from './ResetDataDialog';
import { AppDataResetService } from '../model/AppDataResetService';
import { RECENT_CHANGELOG } from '../model/ChangelogData';
import { ChangelogList } from './ChangelogList';
import { AgentConfigStore } from '../model/AgentConfigStore';
import { AgentMemoryStore } from '../model/AgentMemoryStore';
import { AgentRuntime } from '../model/AgentRuntime';
import { BUILTIN_AGENT_PROMPT } from '../model/AgentDefaults';
import { AgentSession, AgentSkillDefault } from '../model/AgentModels';
import { VaultEntry } from '../model/Vault';
import { Icon } from '../common/Icons';
import { DeleteAgentSessionDialog } from './AgentSessionDialogs';
import { FEEDBACK_EMAIL } from '../model/AppConfig';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

@Component
export struct SettingsView {
  /** 当前断点（从 Index @StorageProp 透传，诊断区显示） */
  @Prop breakpoint: string = '';
  @Prop singleScreenLayout: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  /** 当前库 id（诊断区显示库目录） */
  @Prop currentVaultId: string = '';
  @StorageProp('appTheme') appTheme: string = 'light';
  @Prop vaults: VaultEntry[] = [];
  @Prop @Watch('onSelectedCategoryChanged') selectedCategory: string = 'general';
  @Prop showCategoryList: boolean = false;
  @Prop showCategoryBack: boolean = false;
  onSelectCategory: (category: string) => void = (category: string) => {};
  onBackToCategories: () => void = () => {};
  onOpenHistory: () => void = () => {};
  onResetSplit: () => void = () => {};

  @State versionName: string = '—';
  @State versionCode: number = 0;
  @State resetting: boolean = false;
  @State resetError: string = '';
  @State selectedTab: string = 'general';
  @State systemPromptDraft: string = '';
  @State skillPrompts: string[] = [];
  @State toolEnabled: boolean[] = [];
  @State configRevision: number = 0;
  @State agentMessage: string = '';
  @State sessionFilter: string = 'archived';
  @State managedSessions: AgentSession[] = [];
  @State sessionMessage: string = '';
  @State feedbackError: string = '';
  @State diagnosticsExpanded: boolean = false;
  private resetDialog: CustomDialogController | null = null;
  private deleteSessionDialog: CustomDialogController | null = null;

  private normalizedCategory(category: string): string {
    return category === 'data' || category === 'feedback' || category === 'about' ? category : 'general';
  }

  private onCategoryKey(category: string, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    const categories: string[] = ['general', 'data', 'feedback', 'about'];
    let index: number = categories.indexOf(category);
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      index = (index + categories.length - 1) % categories.length;
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      index = (index + 1) % categories.length;
    } else if (event.keyCode === KeyCode.KEYCODE_MOVE_HOME) {
      index = 0;
    } else if (event.keyCode === KeyCode.KEYCODE_MOVE_END) {
      index = categories.length - 1;
    } else if (event.keyCode === KeyCode.KEYCODE_ENTER ||
      event.keyCode === KeyCode.KEYCODE_SPACE || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
      this.selectCategory(category);
      return true;
    } else {
      return false;
    }
    if (this.singleScreenLayout && this.showCategoryList) {
      this.focusCategoryRow(categories[index]);
    } else {
      this.selectCategory(categories[index]);
      if (!this.singleScreenLayout) {
        this.focusCategoryRow(categories[index]);
      }
    }
    return true;
  }

  private focusCategoryRow(category: string): void {
    this.getUIContext().getFocusController().requestFocus('settings-category-' + category);
  }

  private focusCategoryHeading(category: string): void {
    if (this.singleScreenLayout && !this.showCategoryList) {
      this.getUIContext().getFocusController().requestFocus('settings-heading-' + category);
    }
  }

  private async openFeedbackEmail(): Promise<void> {
    this.feedbackError = '';
    const subject: string = encodeURIComponent('曜石笔记 · 问题与建议');
    const want: Want = {
      action: 'ohos.want.action.sendToData',
      uri: 'mailto:' + FEEDBACK_EMAIL + '?subject=' + subject
    };
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility(want);
    } catch (error) {
      this.feedbackError = '未能打开邮件应用，请使用下方邮箱地址手动反馈';
    }
  }

  private onSelectedCategoryChanged(): void {
    this.selectedTab = this.normalizedCategory(this.selectedCategory);
    if (this.selectedTab === 'agent') {
      this.refreshManagedSessions();
    }
  }

  private selectCategory(category: string): void {
    this.selectedTab = category;
    this.onSelectCategory(category);
  }

  private confirmReset(): void {
    if (this.resetting) {
      return;
    }
    this.resetDialog = new CustomDialogController({
      builder: ResetDataDialog({ onConfirm: (): void => { void this.resetData(); } })
    });
    this.resetDialog.open();
  }

  private async resetData(): Promise<void> {
    if (this.resetting) {
      return;
    }
    this.resetting = true;
    this.resetError = '';
    try {
      await AppDataResetService.reset(getContext(this) as common.UIAbilityContext);
    } catch (error) {
      const err = error as Error;
      this.resetting = false;
      this.resetError = '重置未完成，部分访问令牌可能已清除。' + err.message;
    }
  }


  aboutToAppear(): void {
    this.selectedTab = this.normalizedCategory(this.selectedCategory);
    this.loadAgentSettings();
    this.refreshManagedSessions();
    try {
      // 读自身包信息：同步接口，flag 用 WITH_APPLICATION 即可拿到 version / name 等
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = info.versionName;
      this.versionCode = info.versionCode;
    } catch (error) {
      // 读不到（权限/接口差异）不崩：留占位，诊断区照常可用
      this.versionName = '（读取失败）';
    }
  }

  private loadAgentSettings(): void {
    const snapshot = AgentConfigStore.currentSettings();
    const skills = AgentConfigStore.skillDefaults();
    const names = AgentConfigStore.toolNames();
    this.systemPromptDraft = snapshot.systemPrompt;
    const prompts: string[] = [];
    for (let i = 0; i < skills.length; i++) {
      prompts.push(snapshot.skillPrompts.get(skills[i].id) ?? skills[i].prompt);
    }
    this.skillPrompts = prompts;
    const enabled: boolean[] = [];
    for (let i = 0; i < names.length; i++) {
      enabled.push(snapshot.enabledTools.get(names[i]) === true);
    }
    this.toolEnabled = enabled;
    this.configRevision = snapshot.revision;
  }

  private saveSystemPrompt(): void {
    try {
      AgentConfigStore.saveSystemPrompt(this.systemPromptDraft);
      this.configRevision++;
      this.agentMessage = '已保存；从下一轮开始生效，运行中的轮次继续使用原快照。';
    } catch (error) {
      const err = error as Error;
      this.agentMessage = err.message;
    }
  }

  private restoreSystemPrompt(): void {
    try {
      AgentConfigStore.restoreSystemPrompt();
      this.systemPromptDraft = BUILTIN_AGENT_PROMPT;
      this.configRevision++;
      this.agentMessage = '已恢复内置系统提示词；笔记、对话和工具开关未改变。';
    } catch (error) {
      const err = error as Error;
      this.agentMessage = err.message;
    }
  }

  private saveSkillPrompt(index: number): void {
    const skills = AgentConfigStore.skillDefaults();
    if (index < 0 || index >= skills.length) {
      return;
    }
    try {
      AgentConfigStore.saveSkillPrompt(skills[index].id, this.skillPrompts[index]);
      this.configRevision++;
      this.agentMessage = '已保存「' + skills[index].name + '」；从下一轮开始生效。';
    } catch (error) {
      const err = error as Error;
      this.agentMessage = err.message;
    }
  }

  private restoreSkillPrompt(index: number): void {
    const skills = AgentConfigStore.skillDefaults();
    if (index < 0 || index >= skills.length) {
      return;
    }
    try {
      AgentConfigStore.restoreSkillPrompt(skills[index].id);
      const prompts: string[] = this.skillPrompts.slice();
      prompts[index] = skills[index].prompt;
      this.skillPrompts = prompts;
      this.configRevision++;
      this.agentMessage = '已恢复「' + skills[index].name + '」的内置提示词；其他设置与笔记未改变。';
    } catch (error) {
      const err = error as Error;
      this.agentMessage = err.message;
    }
  }

  private setToolEnabled(index: number, enabled: boolean): void {
    const names = AgentConfigStore.toolNames();
    if (index < 0 || index >= names.length) {
      return;
    }
    try {
      AgentConfigStore.setToolEnabled(names[index], enabled);
      const values: boolean[] = this.toolEnabled.slice();
      values[index] = enabled;
      this.toolEnabled = values;
      this.configRevision++;
      this.agentMessage = '工具开关已更新；只影响新一轮，Skill 权限限制仍然生效。';
    } catch (error) {
      const err = error as Error;
      this.agentMessage = err.message;
    }
  }

  private refreshManagedSessions(): void {
    const visible: AgentSession[] = [];
    for (let i = 0; i < this.vaults.length; i++) {
      const sessions: AgentSession[] = AgentMemoryStore.list(this.vaults[i].id);
      for (let j = 0; j < sessions.length; j++) {
        if (this.sessionFilter === 'all' || sessions[j].archived === true) {
          visible.push(sessions[j]);
        }
      }
    }
    this.managedSessions = visible;
  }

  private setSessionFilter(filter: string): void {
    this.sessionFilter = filter;
    this.refreshManagedSessions();
  }

  private vaultName(vaultId: string): string {
    for (let i = 0; i < this.vaults.length; i++) {
      if (this.vaults[i].id === vaultId) {
        return this.vaults[i].id;
      }
    }
    return vaultId;
  }

  private openDeleteSessionDialog(session: AgentSession): void {
    this.deleteSessionDialog = new CustomDialogController({
      builder: DeleteAgentSessionDialog({
        title: session.title,
        vaultName: this.vaultName(session.vaultId),
        onConfirm: (): void => { void this.deleteSession(session); }
      })
    });
    this.deleteSessionDialog.open();
  }

  private async deleteSession(session: AgentSession): Promise<void> {
    if (AgentRuntime.isVaultBusy(session.vaultId)) {
      this.sessionMessage = '该库的 Agent 正在运行或删除；稍后再删除对话。';
      return;
    }
    try {
      if (!await AgentMemoryStore.remove(session.vaultId, session.id)) {
        this.sessionMessage = '这段对话已不存在。';
        this.refreshManagedSessions();
        return;
      }
      AgentRuntime.forgetConversation(session.vaultId, session.id);
      this.sessionMessage = '对话已删除；笔记与已完成的笔记操作未改变。';
      this.refreshManagedSessions();
    } catch (error) {
      this.sessionMessage = '对话删除失败；原记录已保留。';
    }
  }

  private async restoreSession(session: AgentSession): Promise<void> {
    try {
      if (await AgentMemoryStore.restore(session.vaultId, session.id)) {
        this.sessionMessage = '对话已恢复到“' + this.vaultName(session.vaultId) + '”。';
        this.refreshManagedSessions();
      }
    } catch (error) {
      this.sessionMessage = '对话恢复失败；原归档状态已保留。';
    }
  }

  /** hero 副行版本文案：读取失败时只显示占位，不拼出「版本 （读取失败）（0）」 */
  private versionText(): string {
    if (this.versionName === '—' || this.versionName === '（读取失败）') {
      return this.versionName;
    }
    return '版本 ' + this.versionName + '（' + this.versionCode.toString() + '）';
  }

  /** 断点 → 形态中文标签（照原型 FORMS） */
  private formLabel(): string {
    const label: string = this.singleScreenLayout && this.breakpoint === 'md' ? '单屏横向窗口' :
      this.breakpoint === 'sm' ? '窄窗口' : this.breakpoint === 'md' ? '中宽窗口' : '宽窗口';
    return label + ' (' + Math.round(this.windowWidthVp).toString() + '×' +
      Math.round(this.windowHeightVp).toString() + 'vp)';
  }

  /** 当前库绝对目录（从注册表取真实路径，不自己拼 filesDir） */
  private vaultDir(): string {
    if (this.currentVaultId.length === 0) {
      return '（无库）';
    }
    try {
      return VaultRegistry.get().vaultDirOf(this.currentVaultId);
    } catch (error) {
      return 'vaults/' + this.currentVaultId;
    }
  }

  /** 一行「标签 + 值」（诊断/定位行共用） */
  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width(96)
      Text(value)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: Space.s2 })
  }

  build() {
    Column() {
      if (this.singleScreenLayout && this.showCategoryList) {
        Scroll() {
          Column({ space: Space.s1 }) {
            this.CategoryRow('general', '通用', true)
            this.CategoryRow('data', '数据', true)
            this.CategoryRow('feedback', '问题与建议', true)
            this.CategoryRow('about', '关于与版本记录', true)
          }
          .width('100%')
          .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s3 })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .backgroundColor($r('app.color.bg_navigation'))
      } else if (this.singleScreenLayout) {
        this.CategoryContent()
      } else {
        Row() {
          Scroll() {
            Column({ space: Space.s1 }) {
              this.CategoryRow('general', '通用', true)
              this.CategoryRow('data', '数据', true)
              this.CategoryRow('feedback', '问题与建议', true)
              this.CategoryRow('about', '关于与版本记录', true)
            }
            .width('100%')
            .padding({ left: Space.s3, right: Space.s3, top: Space.s3, bottom: Space.s3 })
          }
          .width(Size.sidebarW)
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .backgroundColor($r('app.color.bg_navigation'))
          .border({ width: { right: 1 }, color: $r('app.color.line') })

          Column() {
            this.CategoryContent()
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  CategoryRow(category: string, label: string, showArrow: boolean) {
    Row() {
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor(this.selectedTab === category ? $r('app.color.brand') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (showArrow) {
        Icon('chevronRight', 16, $r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .backgroundColor(this.selectedTab === category
      ? $r('app.color.brand_bg') : Color.Transparent)
    .focusable(true)
    .id('settings-category-' + category)
    .onKeyEvent((event: KeyEvent): boolean => { return this.onCategoryKey(category, event); })
    .onClick(() => { this.selectCategory(category); })
    .onAppear((): void => {
      if ((!this.singleScreenLayout || this.showCategoryList) &&
        category === this.normalizedCategory(this.selectedCategory)) {
        this.focusCategoryRow(category);
      }
    })
  }

  @Builder
  CategoryContent() {
    Scroll() {
      Column({ space: Space.s4 }) {
        if (this.showCategoryBack) {
          Row() {
            Button('← 设置分类')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.brand'))
              .backgroundColor(Color.Transparent)
              .height(Size.touch)
              .padding({ left: 0, right: Space.s2 })
              .onClick(this.onBackToCategories)
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }
        if (this.selectedTab === 'general') {
          this.GeneralTab()
        } else if (this.selectedTab === 'data') {
          this.DataTab()
        } else if (this.selectedTab === 'feedback') {
          this.FeedbackTab()
        } else {
          this.AboutTab()
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: Size.contentMaxW })
      .padding({ left: Space.s5, right: Space.s5, top: Space.s4, bottom: Space.s8 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  GeneralTab() {
    Column({ space: Space.s3 }) {
      Text('通用')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .focusable(true)
        .id('settings-heading-general')
        .onAppear((): void => { this.focusCategoryHeading('general'); })
      Text('当前界面随窗口宽度切换布局；旋转后按新的窗口宽高重新排布。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Column({ space: Space.s2 }) {
        Text('外观')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
        this.InfoRow('显示主题', this.appTheme === 'dark' ? '深色（跟随系统）' : '浅色（跟随系统）')
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      Column({ space: Space.s2 }) {
        Text('阅读与编辑布局')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
        Text('拖动导航和正文分隔条调整栏宽；编辑与预览比例会自动保存。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Text('恢复等分栏宽')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .focusable(true)
          .onClick(() => { this.onResetSplit(); })
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      Column() {
        Row() {
          Text('诊断信息')
            .fontSize(FontSize.body3)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(this.diagnosticsExpanded ? '⌃' : '⌄')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .height(Size.touch)
        .focusable(true)
        .onClick((): void => { this.diagnosticsExpanded = !this.diagnosticsExpanded; })
        if (this.diagnosticsExpanded) {
          this.InfoRow('当前形态', this.formLabel())
          this.InfoRow('断点', this.breakpoint)
          this.InfoRow('库目录', this.vaultDir())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AgentTab() {
    Column({ space: Space.s4 }) {
      Text('Agent 配置')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('配置保存在本机；更改只影响下一轮，已经运行的轮次使用启动时快照。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text('系统提示词')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextArea({ text: this.systemPromptDraft, placeholder: '编辑系统提示词' })
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_card'))
        .padding(Space.s3)
        .height(180)
        .borderRadius(Radius.control)
        .border({ width: 1, color: $r('app.color.line') })
        .onChange((value: string): void => { this.systemPromptDraft = value; })
      Row({ space: Space.s2 }) {
        Button('保存系统提示词')
          .height(Size.buttonH)
          .fontSize(FontSize.body3)
          .onClick(() => { this.saveSystemPrompt(); })
        Button('恢复内置默认')
          .height(Size.buttonH)
          .fontSize(FontSize.body3)
          .onClick(() => { this.restoreSystemPrompt(); })
      }
      .width('100%')
      Text('内置 Skills')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      ForEach(AgentConfigStore.skillDefaults(), (skill: AgentSkillDefault, index: number) => {
        Column({ space: Space.s2 }) {
          Text(skill.name + ' · 内置版本 ' + skill.revision.toString())
            .fontSize(FontSize.body3)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          TextArea({ text: this.skillPrompts[index] ?? skill.prompt, placeholder: '编辑 Skill 提示词' })
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_card'))
            .padding(Space.s3)
            .height(128)
            .borderRadius(Radius.control)
            .border({ width: 1, color: $r('app.color.line') })
            .onChange((value: string): void => {
              const prompts: string[] = this.skillPrompts.slice();
              prompts[index] = value;
              this.skillPrompts = prompts;
            })
          Row({ space: Space.s2 }) {
            Button('保存 Skill')
              .height(Size.buttonH)
              .fontSize(FontSize.caption)
              .onClick(() => { this.saveSkillPrompt(index); })
            Button('恢复内置')
              .height(Size.buttonH)
              .fontSize(FontSize.caption)
              .onClick(() => { this.restoreSkillPrompt(index); })
          }
          .width('100%')
        }
        .width('100%')
        .padding(Space.s3)
        .borderRadius(Radius.card)
        .border({ width: 1, color: $r('app.color.line') })
        .backgroundColor($r('app.color.bg_card'))
      }, (skill: AgentSkillDefault) => skill.id)
      Text('本地工具')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      ForEach(AgentConfigStore.toolNames(), (name: string, index: number) => {
        Row() {
          Text(name)
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.toolEnabled[index] === true })
            .onChange((enabled: boolean): void => { this.setToolEnabled(index, enabled); })
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_card'))
      }, (name: string) => name)
      this.AgentSessionManagement()
      if (this.agentMessage.length > 0) {
        Text(this.agentMessage)
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      Text('小艺平台接入、后台执行和系统通知尚未启用。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AgentSessionManagement() {
    Column({ space: Space.s2 }) {
      Text('对话管理')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('对话、草稿、运行记录和撤销数据保存在本机。可切换查看全部对话，并按所属知识库恢复或删除已归档对话。')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s2 }) {
        Text('已归档')
          .fontSize(FontSize.body3)
          .fontColor(this.sessionFilter === 'archived' ? $r('app.color.brand') : $r('app.color.text_secondary'))
          .height(Size.touch)
          .padding({ left: Space.s3, right: Space.s3 })
          .borderRadius(Radius.control)
          .backgroundColor(this.sessionFilter === 'archived' ?
            $r('app.color.brand_bg') : $r('app.color.bg_card'))
          .onClick(() => { this.setSessionFilter('archived'); })
        Text('全部对话')
          .fontSize(FontSize.body3)
          .fontColor(this.sessionFilter === 'all' ? $r('app.color.brand') : $r('app.color.text_secondary'))
          .height(Size.touch)
          .padding({ left: Space.s3, right: Space.s3 })
          .borderRadius(Radius.control)
          .backgroundColor(this.sessionFilter === 'all' ?
            $r('app.color.brand_bg') : $r('app.color.bg_card'))
          .onClick(() => { this.setSessionFilter('all'); })
      }
      .width('100%')
      if (this.managedSessions.length === 0) {
        Text(this.sessionFilter === 'archived' ? '没有已归档对话。' : '没有对话。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: Space.s2, bottom: Space.s2 })
      }
      ForEach(this.managedSessions, (session: AgentSession) => {
        Row({ space: Space.s2 }) {
          Icon('message', 18, $r('app.color.text_tertiary'))
          Column({ space: Space.s1 }) {
            Text(session.title)
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.vaultName(session.vaultId) + ' · ' + session.messages.length.toString() + ' 条消息')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          if (session.archived === true) {
            Text('恢复')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.brand'))
              .height(Size.touch)
              .padding({ left: Space.s2, right: Space.s2 })
              .onClick(() => { void this.restoreSession(session); })
          }
          Text('删除')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .height(Size.touch)
            .padding({ left: Space.s2, right: Space.s2 })
            .onClick(() => { this.openDeleteSessionDialog(session); })
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s2, right: Space.s2 })
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_card'))
      }, (session: AgentSession) => session.vaultId + '/' + session.id)
      if (this.sessionMessage.length > 0) {
        Text(this.sessionMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(Space.s3)
    .borderRadius(Radius.card)
    .border({ width: 1, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_secondary'))
  }

  @Builder
  DataTab() {
    Column({ space: Space.s3 }) {
      Text('数据')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .focusable(true)
        .id('settings-heading-data')
        .onAppear((): void => { this.focusCategoryHeading('data'); })
      Column({ space: Space.s3 }) {
        Text('数据管理')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text('清除本地数据后，重新打开应用会恢复首次安装的样例笔记库。此操作无法撤销。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Text('远端 Git 仓库不会被修改；重置前请先确认已保存需要保留的本地内容。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Button(this.resetting ? '正在重置…' : '重置所有数据…')
          .width('100%')
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.danger_bg'))
          .borderRadius(Radius.button)
          .enabled(!this.resetting)
          .onClick(() => { this.confirmReset(); })
        if (this.resetError.length > 0) {
          Text(this.resetError)
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AboutTab() {
    Column({ space: Space.s4 }) {
      Text('关于与版本记录')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .focusable(true)
        .id('settings-heading-about')
        .onAppear((): void => { this.focusCategoryHeading('about'); })
      Column() {
        Row() {
          Text('曜')
            .fontSize(FontSize.s2)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_brand'))
            .width(Size.itemH)
            .height(Size.itemH)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.card)
            .linearGradient({
              angle: 180,
              colors: [[$r('app.color.brand'), 0], [$r('app.color.brand_press'), 1]]
            })
          Column() {
            Text('曜石笔记')
              .fontSize(FontSize.s3)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.versionText())
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: Space.s1 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: Space.s4 })
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        .margin({ bottom: Space.s3 })
        this.InfoRow('定位', '为 XT2 三折叠做的本地 Markdown 笔记')
        Text('开源 · MIT · github.com/guojiex/huawei-xt2-obsidian（含 isomorphic-git、CodeMirror 等 MIT 组件）')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: Space.s2 })
          .border({ width: { top: 1 }, color: $r('app.color.line') })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))

      Column() {
        Text('更新日志')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ bottom: Space.s2 })
        ChangelogList({ entries: RECENT_CHANGELOG })
        Text('查看完整版本记录 ›')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .width('100%')
          .onClick(() => { this.onOpenHistory(); })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FeedbackTab() {
    Column({ space: Space.s3 }) {
      Text('问题与建议')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .focusable(true)
        .id('settings-heading-feedback')
        .onAppear((): void => { this.focusCategoryHeading('feedback'); })
      Text('请通过邮件描述你遇到的问题或改进建议。邮件由你检查并确认发送，不会自动附带笔记、对话、日志或诊断信息。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Column({ space: Space.s3 }) {
        Text('问题与建议')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Button('发送反馈邮件')
          .width('100%')
          .height(Size.touch)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.on_brand'))
          .backgroundColor($r('app.color.brand'))
          .borderRadius(Radius.button)
          .onClick((): void => { void this.openFeedbackEmail(); })
        Text(FEEDBACK_EMAIL)
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .width('100%')
          .padding({ top: Space.s2, bottom: Space.s2 })
        if (this.feedbackError.length > 0) {
          Text(this.feedbackError)
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(Space.s4)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

}
