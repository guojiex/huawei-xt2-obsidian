import { unifiedDataChannel } from '@kit.ArkData';
import { AgentConfigStore } from '../model/AgentConfigStore';
import { AgentMemoryStore } from '../model/AgentMemoryStore';
import { AgentRuntime } from '../model/AgentRuntime';
import { AgentMessage, AgentMessagePart, AgentNoteSnapshot, AgentRunConfig, AgentSession, AgentSkillDefault, AgentToolEvent, AgentToolStep, AgentWriteResult } from '../model/AgentModels';
import { AgentRules } from '../model/AgentRules';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { VaultSidebar } from './VaultSidebar';
import { RenameAgentSessionDialog } from './AgentSessionDialogs';
import { Icon } from '../common/Icons';
import { FontSize, Motion, Radius, Size, Space } from '../common/Tokens';
import { SplitHandle } from './SplitHandle';

const NOTE_REF_MIME: string = 'application/x-yaoshi-note-ref';

@Component
export struct AgentWorkspace {
  @Prop @Watch('onVaultChanged') vaultId: string = '';
  @Prop vaults: VaultEntry[] = [];
  @Prop noteCount: number = 0;
  @Prop @Watch('onLayoutChanged') breakpoint: string = 'sm';
  @Prop @Watch('onLayoutChanged') singleLandscape: boolean = false;
  @Prop @Watch('onNavToggle') navToggleSeq: number = 0;
  @Prop @Watch('onRenameCurrentRequested') renameCurrentSeq: number = 0;
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop navigationWidthVp: number = Size.paneMinW;
  @Prop splitDragging: boolean = false;
  @Prop refreshSeq: number = 0;
  onOpenNote: (path: string) => void = (path: string) => {};
  onTitleChanged: (title: string) => void = (title: string) => {};
  onNotesChanged: () => void = () => {};
  onSwitchVault: (id: string) => void = (id: string) => {};
  onManageVaults: () => void = () => {};
  onImportGit: () => void = () => {};
  onNavigationDragStart: () => void = () => {};
  onNavigationDrag: (offsetX: number) => void = (offsetX: number) => {};
  onSplitDragEnd: () => void = () => {};
  onSplitReset: () => void = () => {};
  isUnsaved: (path: string) => boolean = (path: string) => false;

  @State sessions: AgentSession[] = [];
  @State sessionId: string = '';
  @State messages: AgentMessage[] = [];
  @State draft: string = '';
  @State skillId: string = 'reading';
  @State panelMode: string = 'none';
  @State activeList: string = 'sessions';
  @State lastVisiblePanelMode: string = 'both';
  @State drawerOpen: boolean = false;
  @State drawerProgress: number = 0;
  @State navProgress: number = 1;
  @State running: boolean = false;
  @State dropActive: boolean = false;
  @State statusText: string = '';

  private inputController: TextAreaController = new TextAreaController();
  private selectionStart: number = 0;
  private selectionEnd: number = 0;
  private lastSingleLandscape: boolean = false;
  private renameDialog: CustomDialogController | null = null;

  aboutToAppear(): void {
    const active: AgentSession = AgentMemoryStore.active(this.vaultId);
    this.sessions = AgentMemoryStore.recent(this.vaultId);
    this.loadSession(active);
    this.panelMode = AgentMemoryStore.panelState(this.vaultId);
    if (this.panelMode !== 'none') {
      this.lastVisiblePanelMode = this.panelMode;
    }
    this.navProgress = this.panelMode === 'none' ? 0 : 1;
    if (this.panelMode === 'sessions' || this.panelMode === 'files') {
      this.activeList = this.panelMode;
    }
    if (this.breakpoint === 'sm') {
      this.drawerOpen = false;
      this.drawerProgress = 0;
    }
    if (this.singleLandscape) {
      if (this.panelMode === 'none') {
        this.panelMode = 'sessions';
        this.lastVisiblePanelMode = 'sessions';
      }
      this.drawerOpen = true;
      this.drawerProgress = 1;
    }
    this.lastSingleLandscape = this.singleLandscape;
  }

  private onLayoutChanged(): void {
    if (this.singleLandscape !== this.lastSingleLandscape) {
      this.lastSingleLandscape = this.singleLandscape;
      if (this.singleLandscape) {
        if (this.panelMode === 'none') {
          this.panelMode = 'sessions';
          this.lastVisiblePanelMode = 'sessions';
        }
        if (this.panelMode === 'sessions' || this.panelMode === 'files') {
          this.activeList = this.panelMode;
        }
        this.drawerOpen = true;
        this.drawerProgress = 1;
      } else {
        this.drawerOpen = false;
        this.drawerProgress = 0;
      }
    }
    if (this.breakpoint === 'sm') {
      this.drawerOpen = false;
      this.drawerProgress = 0;
    }
  }

  private onVaultChanged(): void {
    const active: AgentSession = AgentMemoryStore.active(this.vaultId);
    this.sessions = AgentMemoryStore.recent(this.vaultId);
    this.loadSession(active);
    this.panelMode = AgentMemoryStore.panelState(this.vaultId);
    if (this.panelMode !== 'none') {
      this.lastVisiblePanelMode = this.panelMode;
    }
    this.navProgress = this.panelMode === 'none' ? 0 : 1;
    this.drawerOpen = false;
    this.drawerProgress = 0;
    if (this.panelMode === 'sessions' || this.panelMode === 'files') {
      this.activeList = this.panelMode;
    }
  }

  private session(): AgentSession {
    const value: AgentSession | null = AgentMemoryStore.get(this.vaultId, this.sessionId);
    return value === null ? AgentMemoryStore.active(this.vaultId) : value;
  }

  private loadSession(session: AgentSession): void {
    this.sessionId = session.id;
    this.messages = session.messages.slice();
    this.draft = session.draft;
    this.skillId = session.skillId;
    this.onTitleChanged(session.title);
  }

  private onNavToggle(): void {
    if (this.breakpoint === 'sm' || this.singleLandscape) {
      this.drawerOpen = !this.drawerOpen;
      this.drawerProgress = this.drawerOpen ? 1 : 0;
      return;
    }
    if (this.panelMode === 'none') {
      this.panelMode = this.lastVisiblePanelMode;
    } else {
      this.lastVisiblePanelMode = this.panelMode;
      this.panelMode = 'none';
    }
    this.navProgress = this.panelMode === 'none' ? 0 : 1;
    this.savePanelMode();
  }

  private onRenameCurrentRequested(): void {
    this.openRenameSessionDialog(this.session());
  }

  private openRenameSessionDialog(session: AgentSession): void {
    this.renameDialog = new CustomDialogController({
      builder: RenameAgentSessionDialog({
        initialTitle: session.title,
        onConfirm: (title: string): void => { void this.renameSession(session.id, title); }
      })
    });
    this.renameDialog.open();
  }

  private async renameSession(sessionId: string, title: string): Promise<void> {
    try {
      if (!await AgentMemoryStore.rename(this.vaultId, sessionId, title)) {
        this.statusText = '对话名称不能为空。';
        return;
      }
      this.sessions = AgentMemoryStore.recent(this.vaultId);
      const session: AgentSession | null = AgentMemoryStore.get(this.vaultId, sessionId);
      if (session !== null && session.id === this.sessionId) {
        this.onTitleChanged(session.title);
      }
      this.statusText = '对话已重命名。';
    } catch (error) {
      this.statusText = '对话名称保存失败；原名称已恢复。';
    }
  }

  private async archiveSession(sessionId: string): Promise<void> {
    if (sessionId === this.sessionId) {
      AgentMemoryStore.setDraft(this.vaultId, sessionId, this.draft);
    }
    try {
      if (!await AgentMemoryStore.archive(this.vaultId, sessionId)) {
        return;
      }
      this.sessions = AgentMemoryStore.recent(this.vaultId);
      if (sessionId === this.sessionId) {
        this.loadSession(AgentMemoryStore.active(this.vaultId));
      }
      this.statusText = '对话已归档；笔记内容未改变。';
    } catch (error) {
      this.statusText = '对话归档保存失败；原状态已恢复。';
    }
  }

  private savePanelMode(): void {
    AgentMemoryStore.setPanelState(this.vaultId, this.panelMode);
    this.navProgress = this.panelMode === 'none' ? 0 : 1;
  }

  private isCompact(): boolean {
    return this.windowHeightVp > 0 && this.windowHeightVp < 480;
  }

  private togglePanel(panel: string): void {
    if (this.singleLandscape) {
      this.drawerOpen = false;
      this.drawerProgress = 0;
      return;
    }
    if (this.breakpoint === 'lg') {
      if (panel === 'sessions') {
        this.panelMode = this.panelMode === 'both' || this.panelMode === 'sessions' ?
          (this.panelMode === 'both' ? 'files' : 'none') :
          (this.panelMode === 'files' ? 'both' : 'sessions');
      } else {
        this.panelMode = this.panelMode === 'both' || this.panelMode === 'files' ?
          (this.panelMode === 'both' ? 'sessions' : 'none') :
          (this.panelMode === 'sessions' ? 'both' : 'files');
      }
      if (this.panelMode !== 'none') {
        this.lastVisiblePanelMode = this.panelMode;
      }
      this.savePanelMode();
      return;
    }
    if (this.breakpoint === 'md') {
      if (this.panelMode === panel) {
        this.panelMode = 'none';
      } else {
        this.panelMode = panel;
        this.activeList = panel;
      }
      if (this.panelMode !== 'none') {
        this.lastVisiblePanelMode = this.panelMode;
      }
      this.savePanelMode();
      return;
    }
    if (!this.drawerOpen) {
      this.activeList = panel;
      this.drawerOpen = true;
      this.drawerProgress = 1;
    } else if (this.activeList === panel) {
      this.drawerOpen = false;
      this.drawerProgress = 0;
    } else {
      this.activeList = panel;
    }
  }

  private openPanel(panel: string): void {
    this.activeList = panel;
    if (this.breakpoint === 'sm' || this.singleLandscape) {
      this.drawerOpen = true;
      this.drawerProgress = 1;
    } else if (this.breakpoint === 'lg') {
      if (this.panelMode === 'none') {
        this.panelMode = this.lastVisiblePanelMode;
      }
      if (this.panelMode !== 'both' && this.panelMode !== panel) {
        this.panelMode = 'both';
      }
      if (this.panelMode === 'none') {
        this.panelMode = panel;
      }
      this.lastVisiblePanelMode = this.panelMode;
      this.savePanelMode();
    } else {
      this.panelMode = panel;
      this.lastVisiblePanelMode = this.panelMode;
      this.savePanelMode();
    }
  }

  private addReference(path: string, sourceVaultId: string): void {
    if (sourceVaultId !== this.vaultId) {
      this.statusText = '只能引用当前对话所属知识库中的笔记。';
      return;
    }
    if (path.indexOf(']]') >= 0 || path.indexOf('\n') >= 0 || path.indexOf('\r') >= 0) {
      this.statusText = '该路径无法用行内引用表示，请重命名笔记后再引用。';
      return;
    }
    const session: AgentSession = this.session();
    const text: string = this.draft;
    let start: number = this.selectionStart;
    let end: number = this.selectionEnd;
    if (start === end) {
      const caret: CaretOffset = this.inputController.getCaretOffset();
      start = caret.index;
      end = caret.index;
    }
    const inserted: string = AgentRules.insertReference(text, start, end, path);
    this.draft = inserted;
    AgentMemoryStore.setDraft(this.vaultId, session.id, inserted);
    const nextCaret: number = start + path.length + 4;
    this.selectionStart = nextCaret;
    this.selectionEnd = nextCaret;
    this.inputController.caretPosition(nextCaret);
    this.statusText = '已在光标处插入 ' + path + '；可继续编辑或重复引用。';
    if (this.breakpoint === 'sm' || this.singleLandscape) {
      this.drawerOpen = false;
      this.drawerProgress = 0;
    }
  }

  private onDropReference(event: DragEvent): void {
    this.dropActive = false;
    try {
      const records: unifiedDataChannel.UnifiedRecord[] = event.getData().getRecords();
      for (let i = 0; i < records.length; i++) {
        if (records[i].getType() !== NOTE_REF_MIME) {
          continue;
        }
        const raw: string = records[i].getValue() as string;
        const payload: Record<string, string> = JSON.parse(raw) as Record<string, string>;
        this.addReference(payload['path'], payload['vaultId']);
        return;
      }
      this.statusText = '只接受从当前知识库文件树拖入的笔记引用。';
    } catch (error) {
      this.statusText = '读取拖入笔记失败；可点击文件行插入引用。';
    }
  }

  private startNewSession(): void {
    const session: AgentSession = AgentMemoryStore.create(this.vaultId);
    this.sessions = AgentMemoryStore.recent(this.vaultId);
    this.loadSession(session);
    this.statusText = '新对话已保存在当前知识库的本机空间。';
    this.drawerOpen = false;
    this.drawerProgress = 0;
  }

  private switchSession(sessionId: string): void {
    const current: AgentSession = this.session();
    AgentMemoryStore.setDraft(this.vaultId, current.id, this.draft);
    const selected: AgentSession | null = AgentMemoryStore.activate(this.vaultId, sessionId);
    if (selected !== null) {
      this.loadSession(selected);
      this.statusText = '';
    }
  }

  private async send(): Promise<void> {
    if (this.running) {
      return;
    }
    const rawText: string = this.draft;
    if (rawText.trim().length === 0) {
      this.statusText = '先写下问题，或选择固定问法。';
      return;
    }
    const session: AgentSession = this.session();
    let parts: AgentMessagePart[] = [];
    try {
      parts = AgentRules.parseParts(rawText, this.vaultId);
      const references: AgentNoteSnapshot[] = AgentRuntime.captureReferences(
        this.vaultId, parts, VaultRegistry.get(), this.isUnsaved);
      const config: AgentRunConfig = AgentConfigStore.snapshot(session.skillId);
      AgentMemoryStore.setDraft(this.vaultId, session.id, rawText);
      await AgentMemoryStore.persist(this.vaultId, session);
      this.running = true;
      this.statusText = '正在执行本地固定场景…';
      const assistant: AgentMessage = await AgentRuntime.run(this.vaultId, session, AgentRuntime.newRunId(), rawText,
        parts, references, config, VaultRegistry.get(), this.isUnsaved);
      await AgentMemoryStore.persist(this.vaultId, session);
      this.messages = session.messages.slice();
      this.sessions = AgentMemoryStore.recent(this.vaultId);
      const failed: boolean = assistant.toolEvents.some((event) => event.status === 'failed');
      if (!failed) {
        AgentMemoryStore.setDraft(this.vaultId, session.id, '');
        this.draft = '';
        this.selectionStart = 0;
        this.selectionEnd = 0;
      } else {
        AgentMemoryStore.setDraft(this.vaultId, session.id, rawText);
        this.draft = rawText;
      }
      this.statusText = failed ? '本地工具未全部完成；输入仍保留，可检查结果后处理。' :
        '固定 mock 已结束；工具结果来自当前知识库的实际文件操作。';
      if (assistant.writeResult !== null) {
        this.onNotesChanged();
      }
    } catch (error) {
      const err = error as Error;
      this.statusText = err.message;
    } finally {
      this.running = false;
    }
  }

  private async undo(message: AgentMessage): Promise<void> {
    const session: AgentSession = this.session();
    const config: AgentRunConfig = AgentConfigStore.snapshot(session.skillId);
    try {
      const step: AgentToolStep = { name: 'UndoLastEdit' };
      const result: AgentWriteResult = await AgentRuntime.executeManualStep(
        this.vaultId, session, message, step, config, VaultRegistry.get(), this.isUnsaved);
      await AgentMemoryStore.persist(this.vaultId, session);
      this.messages = session.messages.slice();
      this.statusText = '已撤销 ' + result.path + '；对话和历史结果保留。';
      this.onNotesChanged();
    } catch (error) {
      const err = error as Error;
      this.statusText = err.message;
    }
  }

  private chooseSkill(skillId: string): void {
    const session: AgentSession = this.session();
    AgentMemoryStore.setSkill(this.vaultId, session.id, skillId);
    this.skillId = skillId;
    this.statusText = '本段对话下一轮使用该 Skill；当前运行继续使用已冻结的配置快照。';
  }

  @Builder
  ListRail() {
    Column() {
      if (this.breakpoint === 'lg') {
        if (this.panelMode === 'both' || this.panelMode === 'sessions') {
          this.SessionPanel(true)
        }
        if (this.panelMode === 'both' || this.panelMode === 'files') {
          this.FilePanel(true)
        }
      } else if (this.breakpoint === 'sm' || this.singleLandscape) {
        if (this.activeList === 'sessions') {
          this.SessionPanel(false)
        } else {
          this.FilePanel(false)
        }
      } else if (this.panelMode === 'sessions' ||
        (this.breakpoint === 'md' && this.panelMode === 'both' && this.activeList === 'sessions')) {
        this.SessionPanel(false)
      } else if (this.panelMode === 'files' ||
        (this.breakpoint === 'md' && this.panelMode === 'both' && this.activeList === 'files')) {
        this.FilePanel(false)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    if (this.breakpoint === 'lg') {
      Row() {
        Column() {
          this.ListRail()
        }
          .width(this.navigationWidthVp)
          .margin({ left: -this.navigationWidthVp * (1 - this.navProgress) })
          .enabled(this.panelMode !== 'none')
          .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        SplitHandle({
          dragStarted: (): void => { this.onNavigationDragStart(); },
          dragUpdated: (offsetX: number): void => { this.onNavigationDrag(offsetX); },
          dragEnded: (): void => { this.onSplitDragEnd(); },
          resetRequested: (): void => { this.onSplitReset(); }
        })
          .width(Space.s4 * this.navProgress)
          .enabled(this.panelMode !== 'none')
          .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        Column() {
          this.ChatPane(true)
        }
        .width(Math.max(0, this.windowWidthVp - this.navigationWidthVp * this.navProgress -
          Space.s4 * this.navProgress))
        .height('100%')
        .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
    } else if (this.singleLandscape) {
      Row() {
        Column() {
          this.ListRail()
        }
          .width(this.navigationWidthVp)
          .margin({ left: -this.navigationWidthVp * (1 - this.drawerProgress) })
          .enabled(this.drawerOpen)
          .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        SplitHandle({
          dragStarted: (): void => { this.onNavigationDragStart(); },
          dragUpdated: (offsetX: number): void => { this.onNavigationDrag(offsetX); },
          dragEnded: (): void => { this.onSplitDragEnd(); },
          resetRequested: (): void => { this.onSplitReset(); }
        })
          .width(Space.s4 * this.drawerProgress)
          .enabled(this.drawerOpen)
          .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        Column() {
          this.ChatPane(true)
        }
        .width(Math.max(0, this.windowWidthVp - this.navigationWidthVp * this.drawerProgress -
          Space.s4 * this.drawerProgress))
        .height('100%')
        .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
    } else if (this.breakpoint === 'md') {
      Row() {
        Column() {
          this.ListRail()
        }
          .width('40%')
          .margin({ left: -this.windowWidthVp * 0.4 * (1 - this.navProgress) })
          .enabled(this.panelMode !== 'none')
          .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        Column() {
          this.ChatPane(true)
        }
        .width(this.windowWidthVp - this.windowWidthVp * 0.4 * this.navProgress)
        .height('100%')
        .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
    } else {
      Row() {
        Column() {
          this.ListRail()
        }
        .width(Size.drawerW)
        .height('100%')
        .margin({ left: -Size.drawerW * (1 - this.drawerProgress) })
        .enabled(this.drawerOpen)
        .backgroundColor($r('app.color.bg_page'))
        .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })

        Column() {
          this.ChatPane(true)
        }
        .width('100%')
        .height('100%')
        .translate({ x: Size.drawerW * this.drawerProgress })
        .animation({ duration: this.splitDragging ? 0 : Motion.durBase, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
  }

  @Builder
  SkillButton(skill: AgentSkillDefault) {
    Text(skill.name)
      .fontSize(FontSize.body3)
      .fontColor(this.skillId === skill.id ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(Size.buttonH)
      .padding({ left: Space.s3, right: Space.s3 })
      .borderRadius(Radius.button)
      .backgroundColor(this.skillId === skill.id ? $r('app.color.brand_bg') : $r('app.color.bg_card'))
      .onClick(() => { this.chooseSkill(skill.id); })
  }

  @Builder
  SessionPanel(showAll: boolean) {
    Column() {
      Row() {
        Text('对话')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.breakpoint !== 'lg' || this.panelMode !== 'both') {
          Text('笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .height(Size.touch)
            .padding({ left: Space.s2, right: Space.s2 })
            .onClick(() => { this.openPanel('files'); })
        }
        Text('新对话')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
          .height(Size.touch)
          .padding({ left: Space.s2, right: Space.s2 })
          .onClick(() => { this.startNewSession(); })
        Text('收起')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .onClick(() => { this.togglePanel('sessions'); })
      }
      .height(Size.paneHeadH)
      .padding({ left: Space.s3, right: Space.s3 })
      List() {
        ForEach(this.sessions, (session: AgentSession) => {
          ListItem() {
            Row() {
              Row() {
                Icon('message', 18, session.id === this.sessionId ?
                  $r('app.color.brand') : $r('app.color.text_tertiary'))
                Text(session.title)
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width(0)
              .layoutWeight(1)
              .height(Size.itemH)
              .padding({ left: Space.s3, right: Space.s2 })
              .borderRadius(Radius.control)
              .backgroundColor(session.id === this.sessionId ?
                $r('app.color.brand_bg') : Color.Transparent)
              .onClick(() => { this.switchSession(session.id); })
              .gesture(TapGesture({ count: 2 }).onAction((): void => {
                this.openRenameSessionDialog(session);
              }))
              .focusable(true)
              .onKeyEvent((event: KeyEvent): void => {
                if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_F2) {
                  this.openRenameSessionDialog(session);
                }
              })
              Row() {
                Icon('archive', 18, $r('app.color.text_tertiary'))
              }
              .width(Size.touch)
              .height(Size.touch)
              .justifyContent(FlexAlign.Center)
              .borderRadius(Radius.icon)
              .onClick(() => { void this.archiveSession(session.id); })
            }
            .width('100%')
            .height(Size.touch)
            .padding({ left: Space.s2, right: Space.s2 })
          }
        }, (session: AgentSession) => session.id + ':' + session.title)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .layoutWeight(showAll ? 1 : 1)
    .width('100%')
    .border({ width: { bottom: showAll ? 1 : 0 }, color: $r('app.color.line') })
  }

  @Builder
  FilePanel(showAll: boolean) {
    Column() {
      Row() {
        Text('笔记')
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.breakpoint !== 'lg' || this.panelMode !== 'both') {
          Text('对话')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .height(Size.touch)
            .padding({ left: Space.s2, right: Space.s2 })
            .onClick(() => { this.openPanel('sessions'); })
        }
        Text('收起')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .onClick(() => { this.togglePanel('files'); })
      }
      .height(Size.paneHeadH)
      .padding({ left: Space.s3, right: Space.s3 })
      VaultSidebar({
        asDrawer: false,
        compact: this.singleLandscape,
        vaults: this.vaults,
        referenceOnly: true,
        currentVaultId: this.vaultId,
        noteCount: this.noteCount,
        currentFilePath: '',
        refreshSeq: this.refreshSeq,
        onSwitchVault: (id: string): void => { this.onSwitchVault(id); },
        onManageVaults: (): void => { this.onManageVaults(); },
        onImportGit: (): void => { this.onImportGit(); },
        onReferenceNote: (path: string, sourceVaultId: string): void => {
          this.addReference(path, sourceVaultId);
        }
      })
    }
    .layoutWeight(1)
    .width('100%')
    .border({ width: { bottom: showAll ? 0 : 0 }, color: $r('app.color.line') })
  }

  @Builder
  ChatPane(fillWidth: boolean) {
    if (fillWidth) {
      Column() {
        this.ChatPaneContent()
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        this.ChatPaneContent()
      }
      .layoutWeight(1)
      .height('100%')
    }
  }

  @Builder
  ChatPaneContent() {
    Column() {
      Scroll() {
        Column({ space: Space.s3 }) {
          if (this.messages.length === 0) {
            Column({ space: Space.s2 }) {
              Text('从一个问题开始')
                .fontSize(FontSize.s3)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('输入固定问法体验本地 mock；笔记通过文件树点击或拖入，引用会插在光标位置。')
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .width('100%')
            .padding(Space.s4)
          }
          ForEach(this.messages, (message: AgentMessage) => {
            this.MessageBlock(message)
          }, (message: AgentMessage) => message.id +
            (message.writeResult !== null && (message.writeResult as AgentWriteResult).undone ? '|undone' : '|active'))
        }
        .width('100%')
        .padding({ left: Space.s4, right: Space.s4, top: Space.s4, bottom: Space.s2 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)

      Column({ space: Space.s1 }) {
        Scroll() {
          Row({ space: Space.s2 }) {
            ForEach(AgentRuntime.fixedQuestions(), (question: string, index: number) => {
              Text(question)
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .padding({ left: Space.s2, right: Space.s2 })
                .height(Size.buttonH)
                .borderRadius(Radius.button)
                .backgroundColor($r('app.color.bg_card'))
                .onClick(() => {
                  this.draft = question;
                  AgentMemoryStore.setDraft(this.vaultId, this.sessionId, question);
                  this.statusText = '已填入固定问法；确认后点击发送。';
                })
            }, (question: string, index: number) => index.toString())
          }
          .padding({ left: Space.s3, right: Space.s3 })
        }
        .width('100%')
        .height(Size.buttonH)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        Row({ space: Space.s2 }) {
          ForEach(AgentConfigStore.skillDefaults(), (skill: AgentSkillDefault) => {
            this.SkillButton(skill)
          }, (skill: AgentSkillDefault) => skill.id)
          Blank()
          Text('+ 引用笔记')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.brand'))
            .onClick(() => { this.openPanel('files'); })
        }
        .width('100%')
        .padding({ left: Space.s3, right: Space.s3 })
        TextArea({
          text: this.draft,
          placeholder: '输入消息；按发送按钮提交，回车仅换行。',
          controller: this.inputController
        })
          .fontSize(FontSize.body2)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_card'))
          .padding(Space.s3)
          .height(this.isCompact() ? Size.buttonH + Space.s2 : 104)
          .borderRadius(Radius.control)
          .border({ width: 1, color: this.dropActive ? $r('app.color.brand') : $r('app.color.line') })
          .onChange((value: string): void => {
            this.draft = value;
            AgentMemoryStore.setDraft(this.vaultId, this.sessionId, value);
            const caret: CaretOffset = this.inputController.getCaretOffset();
            this.selectionStart = caret.index;
            this.selectionEnd = caret.index;
          })
          .onTextSelectionChange((start: number, end: number): void => {
            this.selectionStart = start;
            this.selectionEnd = end;
          })
          .allowDrop([NOTE_REF_MIME])
          .onDragEnter((event: DragEvent): void => { this.dropActive = true; })
          .onDragLeave((event: DragEvent): void => { this.dropActive = false; })
          .onDrop((event: DragEvent): void => { this.onDropReference(event); })
        Row() {
          Text(this.statusText)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(2)
          Button(this.running ? '执行中…' : '发送')
            .height(Size.buttonH)
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.on_brand'))
            .backgroundColor($r('app.color.brand'))
            .borderRadius(Radius.button)
            .enabled(!this.running && this.draft.trim().length > 0)
            .onClick(() => { void this.send(); })
        }
        .width('100%')
        .padding({ left: Space.s2, right: Space.s2, bottom: Space.s2 })
        Text('本地固定 mock · 会话、草稿、配置和笔记操作记录保存在本机。输入法候选期间不会自动发送。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: Space.s3, right: Space.s3, bottom: Space.s2 })
      }
      .width('100%')
      .padding({ left: Space.s2, right: Space.s2, top: Space.s2 })
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MessageBlock(message: AgentMessage) {
    Column({ space: Space.s2 }) {
      Text(message.role === 'user' ? '你' : 'Agent · 固定回复')
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(message.role === 'user' ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .width('100%')
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
        ForEach(message.parts, (part: AgentMessagePart) => {
          if (part.kind === 'text') {
            Text(part.text)
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.text_primary'))
          } else {
            Text('〔' + part.path + '〕')
              .fontSize(FontSize.body2)
              .fontColor($r('app.color.brand'))
              .onClick(() => { this.openMessageReference(message, part.path); })
          }
        }, (part: AgentMessagePart, index: number) => index.toString())
      }
      .width('100%')
      Text('配置 v' + message.configRevision.toString() + ' · Skill ' + message.skillId)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      ForEach(message.toolEvents, (event: AgentToolEvent, index: number) => {
        Column({ space: Space.s1 }) {
          Text(event.name + ' · ' + (event.status === 'completed' ? '完成' : '失败'))
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(event.status === 'completed' ? $r('app.color.text_secondary') : $r('app.color.danger'))
            .width('100%')
          Text(event.result)
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding(Space.s3)
        .borderRadius(Radius.control)
        .backgroundColor($r('app.color.bg_card'))
      }, (event: AgentToolEvent, index: number) => message.id + '-tool-' + index.toString())
      if (message.writeResult !== null) {
        this.WriteResultCard(message, message.writeResult as AgentWriteResult)
      }
    }
    .width('100%')
    .padding(Space.s3)
    .borderRadius(Radius.control)
    .backgroundColor(message.role === 'user' ? $r('app.color.brand_bg') : Color.Transparent)
  }

  @Builder
  WriteResultCard(message: AgentMessage, result: AgentWriteResult) {
    Column({ space: Space.s2 }) {
      Text((result.undone ? '已撤销 · ' : '实际写入 · ') + result.path)
        .fontSize(FontSize.body3)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text('修改前')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Text(result.before.length === 0 ? '（新建文件）' : result.before)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text('修改后')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Text(result.after)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Row({ space: Space.s2 }) {
        Button('查看笔记')
          .height(Size.buttonH)
          .fontSize(FontSize.caption)
          .onClick(() => { this.onOpenNote(result.path); })
        Button(result.undone ? '已撤销' : '撤销这次操作')
          .height(Size.buttonH)
          .fontSize(FontSize.caption)
          .enabled(!result.undone)
          .onClick(() => { void this.undo(message); })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Space.s3)
    .borderRadius(Radius.control)
    .backgroundColor($r('app.color.bg_card'))
  }

  private openMessageReference(message: AgentMessage, path: string): void {
    for (let i = 0; i < message.references.length; i++) {
      if (message.references[i].path === path && message.references[i].vaultId === this.vaultId) {
        if (!AgentRuntime.referenceStillValid(this.vaultId, message.references[i], VaultRegistry.get())) {
          this.statusText = '这条历史引用已失效或内容已变化；请从当前文件树重新引用。';
          return;
        }
        this.onOpenNote(path);
        return;
      }
    }
    this.statusText = '引用笔记不属于当前知识库。';
  }
}
