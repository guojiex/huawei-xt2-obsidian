/**
 * SettingsView.ets —— 设置与关于（原型「设置与关于」面板，v0.2 §4.x）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（与 VaultManagerView 同级）。
 * 顶栏返回由 Index 统一处理；单屏分类详情由顶栏返回至分类列表。
 *
 * 内容（照 v2 原型「设置与关于」规格，2026-10-30 对齐 v2 关于卡与通用/数据/问题与建议分类）：
 *  - 关于卡：hero（64vp 图标 + 应用名 + 版本号）+ 定位段落 + 反馈邮箱 + 开源许可小字；
 *    **包名行已删**（设计稿 2026-10-21 拍板：那是开发期对 hdc 日志/签名用的诊断值，用户不需要）；
 *    版本号**运行时从自身包信息读出，不在代码写死常量**（api_notes H-1/H-2：
 *    getBundleInfoForSelfSync 在 try/catch 内调用，失败兜底显示占位，读不到也不崩）；
 *  - 更新日志卡：数据驱动的最近记录，最新在上，内容由 changelog.json 生成；
 *  - 诊断卡：当前形态 / 断点 / 库目录（真机校准对照）；
 *  - 后续版本才有的设置项在底部灰显占位。
 * 视觉：token 化 + 内容页限宽 760vp 居中（需求 4.9）。
 */
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { buildCommitCopyPayload, buildCommitLabel, isBuildCommitKnown } from '../common/BuildCommitInfo';
import BuildProfile from 'BuildProfile';
import { PrivacyPolicyView } from './PrivacyPolicyView';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';
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
import { EditorExperienceMode } from '../model/EditorExperiencePolicy';

@Component
export struct SettingsView {
  /** 当前断点（从 Index @StorageProp 透传，诊断区显示） */
  @Prop breakpoint: string = '';
  @Prop singleScreenLayout: boolean = false;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop paneWidthSummary: string = '—';
  /** 当前库 id（诊断区显示库目录） */
  @Prop currentVaultId: string = '';
  @Prop showLineNumbers: boolean = false;
  @Prop experienceMode: EditorExperienceMode = 'simple';
  @StorageProp('appTheme') appTheme: string = 'light';
  @Prop vaults: VaultEntry[] = [];
  @Prop @Watch('onSelectedCategoryChanged') selectedCategory: string = 'general';
  @Prop showCategoryList: boolean = false;
  @Prop showPrivacyPolicy: boolean = false;
  onSelectCategory: (category: string) => void = (category: string) => {};
  onOpenPrivacyPolicy: () => void = () => {};
  onClosePrivacyPolicy: () => void = () => {};
  onOpenHistory: () => void = () => {};
  onResetSplit: () => void = () => {};
  onShowLineNumbersChange: (show: boolean) => void = (_show: boolean) => {};
  onExperienceModeChange: (mode: EditorExperienceMode) => void = (_mode: EditorExperienceMode) => {};

  @State versionName: string = '—';
  @State versionCode: number = 0;
  @State resetting: boolean = false;
  @State resetError: string = '';
  @State resetConfirmOpen: boolean = false;
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
  @State feedbackSteps: string = '';
  @State feedbackActual: string = '';
  @State feedbackExpected: string = '';
  @State feedbackPreview: string = '';
  @State diagnosticsExpanded: boolean = false;
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

  private focusExperienceMode(mode: EditorExperienceMode): void {
    this.getUIContext().getFocusController().requestFocus('settings-editor-mode-' + mode);
  }

  private onExperienceModeKey(mode: EditorExperienceMode, event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP || event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      this.focusExperienceMode(mode === 'simple' ? 'professional' : 'simple');
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE ||
      event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
      this.onExperienceModeChange(mode);
      return true;
    }
    return false;
  }

  private onExperienceModeHeadingKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN || event.keyCode === KeyCode.KEYCODE_ENTER ||
      event.keyCode === KeyCode.KEYCODE_SPACE || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER) {
      this.focusExperienceMode(this.experienceMode);
      return true;
    }
    return false;
  }

  @Builder
  ExperienceModeRow(mode: EditorExperienceMode, title: string, description: string, icon: string) {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: Space.s3 }) {
        Icon(icon, Space.s5, this.experienceMode === mode
          ? $r('app.color.brand') : $r('app.color.text_secondary'))
        Column({ space: Space.s1 }) {
          Text(title)
            .fontSize(FontSize.body2)
            .fontWeight(this.experienceMode === mode ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.experienceMode === mode ? $r('app.color.brand') : $r('app.color.text_primary'))
          Text(description)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.experienceMode === mode) {
          Text('✓')
            .fontSize(FontSize.body1)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.brand'))
        }
      }
    }
    .width('100%')
    .height(Size.touch + Space.s6)
    .padding({ left: Space.s3, right: Space.s3, top: 0, bottom: 0 })
    .borderRadius(Radius.control)
    .backgroundColor(this.experienceMode === mode
      ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
    .tabStop(true)
    .accessibilityText(title + '。' + description + (this.experienceMode === mode ? '，已选中' : ''))
    .id('settings-editor-mode-' + mode)
    .onKeyEvent((event: KeyEvent): boolean => { return this.onExperienceModeKey(mode, event); })
    .onClick((): void => { this.onExperienceModeChange(mode); })
  }

  private composeFeedbackBody(): string {
    const parts: string[] = [];
    const steps: string = this.feedbackSteps.trim();
    const actual: string = this.feedbackActual.trim();
    const expected: string = this.feedbackExpected.trim();
    if (steps.length > 0) {
      parts.push('操作步骤：\n' + steps);
    }
    if (actual.length > 0) {
      parts.push('实际结果：\n' + actual);
    }
    if (expected.length > 0) {
      parts.push('期望结果：\n' + expected);
    }
    return parts.join('\n\n');
  }

  private async openFeedbackEmail(): Promise<void> {
    this.feedbackError = '';
    const composed: string = this.composeFeedbackBody();
    const bodyText: string = composed.length > 0
      ? composed
      : '操作步骤：\n\n实际结果：\n\n期望结果：';
    const want: Want = {
      action: 'ohos.want.action.sendToData',
      uri: 'mailto:' + FEEDBACK_EMAIL + '?subject=' + encodeURIComponent('曜石笔记 · 问题与建议')
        + '&body=' + encodeURIComponent(bodyText)
    };
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility(want);
    } catch (error) {
      this.feedbackError = '未能打开邮件应用，请使用上方反馈邮箱手动发送';
    }
  }

  private previewFeedback(): void {
    const composed: string = this.composeFeedbackBody();
    this.feedbackPreview = composed.length > 0 ? composed : '请先填写反馈内容';
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

  /** 危险行展开组内确认；防误触靠「点行 → 点确认」两步，与弹窗一致。 */
  private openResetConfirm(): void {
    if (this.resetting) {
      return;
    }
    this.resetConfirmOpen = true;
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

  /**
   * 分组标题（v1.13，照 v2 .hs-group-title）：12 号、muted、500，位于分组卡片之外。
   * 原型 `margin: --s5 --s4 --s2`，这里左右对齐交给外层容器，不重复加内缩。
   */
  @Builder
  GroupTitle(text: string) {
    Text(text)
      .fontSize(FontSize.caption)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .margin({ top: Space.s5, bottom: Space.s2 })
  }

  /** 一行「标签 + 值」（v2 settings-facts / setting-row：14 号、值右对齐、可选行分隔线） */
  @Builder
  InfoRow(label: string, value: string, showDivider: boolean) {
    Row() {
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
      Text(value)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: showDivider ? Space.s3 : Space.s2, bottom: showDivider ? Space.s3 : Space.s2 })
    .border(showDivider ? { width: { bottom: 1 }, color: $r('app.color.line') } : { width: 0 })
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

  /**
   * 单屏「只显示分类列表」态：右侧没有并列详情，行本身表示「进入」，
   * 此时既不该有选中高亮（v1.13 的单屏错误选中态），箭头也属多余。
   */
  private isCategoryListOnly(): boolean {
    return this.singleScreenLayout && this.showCategoryList;
  }

  private isCategoryHighlighted(category: string): boolean {
    return this.selectedTab === category && !this.isCategoryListOnly();
  }

  @Builder
  CategoryRow(category: string, label: string, showArrow: boolean) {
    Row() {
      Text(label)
        .fontSize(FontSize.body2)
        .fontColor(this.isCategoryHighlighted(category)
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (showArrow && !this.isCategoryListOnly()) {
        Icon('chevronRight', 16, $r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s3, right: Space.s3 })
    .borderRadius(Radius.control)
    .backgroundColor(this.isCategoryHighlighted(category)
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
    if (this.showPrivacyPolicy) {
      PrivacyPolicyView({ onClose: this.onClosePrivacyPolicy })
        .width('100%')
        .height('100%')
    } else {
      Scroll() {
        Column() {
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
  }

  @Builder
  GeneralTab() {
    Column() {
      Text('通用')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s5 })
        .focusable(true)
        .id('settings-heading-general')
        .onAppear((): void => { this.focusCategoryHeading('general'); })
      Text('当前界面随窗口宽度切换布局；旋转后按新的窗口宽高重新排布。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: Space.s4 })
      this.GroupTitle('外观')
      Column() {
        this.InfoRow('显示主题', this.appTheme === 'dark' ? '深色（跟随系统）' : '浅色（跟随系统）', false)
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
      // 编辑模式标题保留键盘焦点进入（v0.7 7.x 的焦点恢复），样式与其余分组标题一致
      Text('编辑模式')
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: Space.s5, bottom: Space.s2 })
        .focusable(true)
        .tabStop(true)
        .onKeyEvent((event: KeyEvent): boolean => { return this.onExperienceModeHeadingKey(event); })
      Column() {
        this.ExperienceModeRow('simple', '简单模式', '在排版正文中直接输入和设置基础格式。', 'simpleMode')
        this.ExperienceModeRow('professional', '专业模式', '使用 Markdown 源码、预览和双栏布局。', 'professionalMode')
        Text('切换时保留当前笔记的修改，也可以从右上角「…」菜单切换。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: Space.s3 })
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
      this.GroupTitle('编辑器')
      Column() {
        Row() {
          Column({ space: Space.s1 }) {
            Text('显示行号')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_primary'))
            Text('编辑 Markdown 时显示，预览不显示')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.showLineNumbers })
            .accessibilityText('显示行号')
            .onChange((show: boolean): void => { this.onShowLineNumbersChange(show); })
        }
        .width('100%')
        .height(Size.touch)
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
      this.GroupTitle('阅读与编辑布局')
      Column() {
        this.InfoRow('当前栏宽', this.paneWidthSummary, false)
        Text('拖动导航和正文分隔条调整栏宽；编辑与预览比例会自动保存。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        Text('恢复等分栏宽')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .focusable(true)
          .onClick(() => { this.onResetSplit(); })
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
      this.GroupTitle('高级')
      Column() {
        Row() {
          Column({ space: Space.s1 }) {
            Text('诊断信息')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('用于设备验收')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(this.diagnosticsExpanded ? '⌃' : '⌄')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .height(Size.touch)
        .focusable(true)
        .onClick((): void => { this.diagnosticsExpanded = !this.diagnosticsExpanded; })
        if (this.diagnosticsExpanded) {
          this.InfoRow('当前形态', this.formLabel(), true)
          this.InfoRow('断点', this.breakpoint, true)
          this.BuildCommitRow()
          this.InfoRow('库目录', this.vaultDir(), true)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 「构建提交」一行（v1.15）：显示构建期注入的标识，并提供复制。
   * 复制内容只有标识本身；未知状态不伪造标识也不复制。
   */
  @Builder
  BuildCommitRow() {
    Row() {
      Text('构建提交')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
      Text(buildCommitLabel(this.buildCommitState(), this.buildCommitLabelText()))
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      Text('复制')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.brand'))
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s2 })
        .focusable(true)
        .accessibilityText('复制构建提交号')
        .enabled(isBuildCommitKnown(this.buildCommitState()))
        .opacity(isBuildCommitKnown(this.buildCommitState()) ? 1 : 0.4)
        .onClick((): void => { void this.copyBuildCommit(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: Space.s3, bottom: Space.s3 })
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
  }

  /** BuildProfile 由 hvigor 在构建时生成；字段缺失一律按未知处理，不沿用旧值。 */
  private buildCommitState(): string {
    return typeof BuildProfile.buildCommitState === 'string' ? BuildProfile.buildCommitState : 'unknown';
  }

  private buildCommitLabelText(): string {
    return typeof BuildProfile.buildCommitLabel === 'string' ? BuildProfile.buildCommitLabel : '';
  }

  private async copyBuildCommit(): Promise<void> {
    const payload: string = buildCommitCopyPayload(this.buildCommitState(), this.buildCommitLabelText());
    if (payload.length === 0) {
      promptAction.showToast({ message: '构建提交未知，不复制' });
      return;
    }
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, payload));
      promptAction.showToast({ message: '已复制构建提交号' });
    } catch (error) {
      promptAction.showToast({ message: '复制失败，请手动记录' });
    }
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
    Column() {
      Text('数据')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s5 })
        .focusable(true)
        .id('settings-heading-data')
        .onAppear((): void => { this.focusCategoryHeading('data'); })
      this.GroupTitle('本地数据')
      Column() {
        // 危险行（v2 .hs-row.hs-danger：透明底、标题用 danger 色），确认在组内展开
        Row() {
          Text(this.resetting ? '正在重置…' : '重置所有数据…')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.danger'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .height(Size.touch)
        .focusable(true)
        .enabled(!this.resetting)
        .opacity(this.resetting ? 0.4 : 1)
        .onClick((): void => { this.openResetConfirm(); })
        if (this.resetConfirmOpen) {
          Column() {
            Text('确定重置所有数据？')
              .fontSize(FontSize.body2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text('本页编辑、插入图片、文件操作和回收站将恢复为初始样例，栏宽偏好也会清除，无法撤销。')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: Space.s2 })
            Row({ space: Space.s2 }) {
              Text('取消')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
                .height(Size.buttonH)
                .padding({ left: Space.s4, right: Space.s4 })
                .textAlign(TextAlign.Center)
                .borderRadius(Radius.full)
                .backgroundColor($r('app.color.bg_secondary'))
                .onClick((): void => { this.resetConfirmOpen = false; })
              Text('重置并恢复样例')
                .fontSize(FontSize.body3)
                .fontColor(Color.White)
                .height(Size.buttonH)
                .padding({ left: Space.s4, right: Space.s4 })
                .textAlign(TextAlign.Center)
                .borderRadius(Radius.full)
                .backgroundColor($r('app.color.danger'))
                .enabled(!this.resetting)
                .opacity(this.resetting ? 0.4 : 1)
                .onClick((): void => { void this.resetData(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: Space.s3 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.s4)
          .borderRadius(Radius.control)
          .backgroundColor($r('app.color.danger_bg'))
        }
        if (this.resetError.length > 0) {
          Text(this.resetError)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .margin({ top: Space.s3 })
        }
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
      Column() {
        Text('会清除本地笔记库、草稿、回收站、最近打开、同步配置和访问令牌，重新打开后恢复初始样例库，无法撤销。远端仓库不受影响。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .padding({ left: Space.s4, right: Space.s4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  AboutTab() {
    Column() {
      Text('关于与版本记录')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s5 })
        .focusable(true)
        .id('settings-heading-about')
        .onAppear((): void => { this.focusCategoryHeading('about'); })
      Text('在这里查看应用版本与更新记录。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ bottom: Space.s4 })
      // hero（v2 .hs-hero：图标 / 名称 / 版本 / 标语居中，不再与分组卡片同列左对齐）
      Column() {
        Image($r('app.media.app_icon_1024'))
          .width(Space.s16)
          .height(Space.s16)
          .objectFit(ImageFit.Contain)
          .borderRadius(Radius.menu)
        Text('曜石笔记')
          .fontSize(FontSize.s3)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: Space.s3 })
        Text(this.versionText())
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: Space.s1 })
        Text('为 XT2 三折叠做的本地 Markdown 笔记')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: Space.s2 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: Space.s4, bottom: Space.s6 })
      Column() {
        Text() {
          Span('反馈邮箱 ')
          Span(FEEDBACK_EMAIL)
            .fontColor($r('app.color.brand'))
        }
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ bottom: Space.s3 })
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Row() {
            Text('隐私政策')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.brand'))
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            Icon('chevronRight', 16, $r('app.color.text_tertiary'))
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: 0, right: 0 })
        .backgroundColor(Color.Transparent)
        .accessibilityText('查看隐私政策')
        .onClick((): void => { this.onOpenPrivacyPolicy(); })
        Text('开源 · MIT。含 isomorphic-git、CodeMirror 等 MIT 组件。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })

      this.GroupTitle('更新日志')
      Column() {
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
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FeedbackTab() {
    Column() {
      Text('问题与建议')
        .fontSize(FontSize.s3)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Space.s5 })
        .focusable(true)
        .id('settings-heading-feedback')
        .onAppear((): void => { this.focusCategoryHeading('feedback'); })
      Text('遇到问题或有建议，欢迎告诉我们。')
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: Space.s4 })
      // v1.13：卡片内不再重复「问题与建议」标题，页标题 + 说明已表达同一层含义
      Column() {
        Text('请描述操作步骤、实际结果和期望结果，帮助我们了解问题。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        Text('操作步骤')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        TextArea({ text: this.feedbackSteps })
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .padding(Space.s3)
          .constraintSize({ minHeight: Space.s16 })
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .margin({ bottom: Space.s3 })
          .onChange((value: string): void => { this.feedbackSteps = value; })
        Text('实际结果')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        TextArea({ text: this.feedbackActual })
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .padding(Space.s3)
          .constraintSize({ minHeight: Space.s16 })
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .margin({ bottom: Space.s3 })
          .onChange((value: string): void => { this.feedbackActual = value; })
        Text('期望结果')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        TextArea({ text: this.feedbackExpected })
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_secondary'))
          .padding(Space.s3)
          .constraintSize({ minHeight: Space.s16 })
          .borderRadius(Radius.control)
          .border({ width: 1, color: $r('app.color.line') })
          .margin({ bottom: Space.s3 })
          .onChange((value: string): void => { this.feedbackExpected = value; })
        Text('预览反馈内容')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .textAlign(TextAlign.Start)
          .onClick((): void => { this.previewFeedback(); })
        if (this.feedbackPreview.length > 0) {
          Text(this.feedbackPreview)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: Space.s3 })
        }
        Row({ space: Space.s3 }) {
          Text('反馈邮箱')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_secondary'))
          Text(FEEDBACK_EMAIL)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.brand'))
        }
        .width('100%')
        .padding({ top: Space.s4, bottom: Space.s4 })
        Text('发送反馈邮件 ›')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .textAlign(TextAlign.Start)
          .onClick((): void => { void this.openFeedbackEmail(); })
        Text('将在邮件应用中创建邮件，由你编辑并确认发送。若未打开，可使用上方邮箱地址手动发送。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s3 })
        Text('不会自动附带笔记、对话或日志；添加截图前请检查私人信息。')
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        if (this.feedbackError.length > 0) {
          Text(this.feedbackError)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(Space.s5)
      .borderRadius(Radius.card)
      .border({ width: 1, color: $r('app.color.line') })
      .backgroundColor($r('app.color.bg_card'))
      .margin({ bottom: Space.s4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

}
