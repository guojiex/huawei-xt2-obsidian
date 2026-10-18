/**
 * Index.ets —— 三形态布局总装 + 库模型接线（v0.1 骨架 / v0.2 视觉基线）
 *
 * 为什么三栏自绘而不用 FoldSplitContainer（api_notes.md A2-bis）：
 * ① 它的「三分栏」不是三列横排，是「侧列贯穿 + 另两栏上下堆叠」，横排列只有 2 个；
 * ② 分栏比例只有预设枚举 LAYOUT_1V1 / LAYOUT_3V2 / LAYOUT_2V3，无 1:1:1；
 * ③ 它为双折叠悬停态设计，三折叠三屏态不在其模型内。
 * （2026-10-18 官方答复亦确认：布局适配优先基于响应式断点，精确对齐折痕非官方要求）
 *
 * 断点只用 windowSizeChange + px2vp（api_notes.md A3 ✅），不用 getFoldDisplayMode 做分支。
 * 布局矩阵：
 *   sm：单栏（编辑 / 预览二选一，顶部分段控件切换）+ 抽屉侧栏
 *   md：侧栏 | 编辑 各 50%；收起 → 编辑 | 预览 各 50%
 *   lg：侧栏 | 编辑 | 预览 各 1/3；收起 → 编辑 2/3（跨第一条折痕，红警示）| 预览 1/3
 *
 * v0.2 §3.5：本文件视觉全部走 token —— 颜色 `$r('app.color.*')`（深色自动切另一套）、
 * 数值 `Space/Radius/FontSize/Size/Motion`（common/Tokens.ets）、图标 `Icon()`（common/Icons.ets）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Breakpoint } from '../model/Breakpoint';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { NoteService } from '../model/NoteService';
import { FileTree } from '../model/FileTree';
import { VaultSidebar } from '../components/VaultSidebar';
import { VaultManagerView } from '../components/VaultManagerView';
import { SettingsView } from '../components/SettingsView';
import { CreateVaultDialog, DeleteVaultDialog, RenameVaultDialog } from '../components/VaultDialogs';
import { CreateNoteDialog, DeletePathDialog } from '../components/NoteDialogs';
import { EditorWebView, EditorBridge } from '../components/EditorWebView';
import { PreviewWebView, PreviewBridge } from '../components/PreviewWebView';
import { Icon } from '../common/Icons';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

const DOMAIN: number = 0x0000;
const TAG: string = 'Index';

/** PaneHead 的按引用传参载体（@Builder 按值传参不随状态刷新，实测标题停在初始值） */
interface PaneHeadParam {
  title: string;
}

/** 状态栏形态标签（与原型 FORMS 一致） */
function formLabelOf(bp: string): string {
  if (bp === Breakpoint.SM) {
    return '外屏合起';
  }
  if (bp === Breakpoint.MD) {
    return '展开双屏';
  }
  return '三屏展开';
}

/** 单屏态分段控件的单个按钮 */
@Extend(Text)
function segItem(active: boolean) {
  .fontSize(FontSize.body3)
  .fontColor(active ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
  .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
  .height(28)
  .padding({ left: Space.s3, right: Space.s3 })
  .textAlign(TextAlign.Center)
  .borderRadius(Radius.full)
  .backgroundColor(active ? $r('app.color.bg_card') : Color.Transparent)
}

@Entry
@Component
struct Index {
  /** 断点档位（EntryAbility 写入 AppStorage；@Watch 在档位变化时收敛抽屉态） */
  @StorageProp('breakpoint') @Watch('onBreakpointChanged') breakpoint: string = Breakpoint.SM;
  /** 窗口宽度 vp（状态栏显示用） */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0;
  /** display.getFoldStatus() 读数（调试用，-1 = 没取到；api_notes A1） */
  @StorageProp('foldStatus') foldStatus: number = -1;
  /**
   * 折痕中心 x（**px**，多条逗号分隔；'-' = 没取到。api_notes A2 采集通道，不参与布局）。
   * 存 px 而不是 vp：官方提醒 px2vp 应在 UI 上下文换算，故在页面侧 statusRightText() 里转。
   */
  @StorageProp('creasePx') creasePx: string = '-';
  /** 库列表（单一数据源 VaultRegistry；CRUD 后 refreshFromRegistry） */
  @State vaults: VaultEntry[] = [];
  /** 当前库 id */
  @State currentVaultId: string = '';
  /** sm 抽屉开关（瞬态 @State：UIAbility 折叠切换不重建则存活，api_notes A4 ✅） */
  @State drawerOpen: boolean = false;
  /** md/lg 侧栏收起态（瞬态 @State） */
  @State sidebarCollapsed: boolean = false;
  /** 次级视图（库管理 / 设置与关于）整体替换内容区；'note' = 笔记主视图（原型 setView 模型） */
  @State topView: string = 'note';
  /**
   * 当前打开文件的**库内相对路径**（如 `docs/架构.md`）。
   *
   * 为什么放在这里而不是放在文件树组件里（需求 1.4）：
   * 折叠父目录只改变「哪些行可见」，不应连带改变正在编辑的文件。
   * 若当前文件由树持有，折叠动作会导致它被清掉（或被迫写例外逻辑绕过清理）。
   * 放在总装页还有一个额外好处：侧栏选中态、编辑区标题、以后的预览来源共用同一份状态，
   * 不存在三处各记一份然后不同步的可能。
   */
  @State currentFilePath: string = '';
  /**
   * M0.5 spike：Web 编辑器（CodeMirror 6）的桥接句柄与「最近一次内容长度」。
   * bridge 由本页创建并传给 EditorWebView（对象引用共享，页面 ready 时内部 bind）。
   * editorLen 只用于观察击键是否过桥，-1 表示尚未有过编辑。
   */
  @State editorLen: number = -1;
  private editorBridge: EditorBridge = new EditorBridge();
  /**
   * 文件树重扫信号（每次 +1 触发一次 rescan）。
   * 为什么不用「更聪明」的方案：树组件自己不知道外部什么时候改了磁盘
   * （没有文件监听），用显式信号换确定性和简单性。
   */
  @State treeSeq: number = 0;
  /**
   * 需要树展开到可见的目标路径。建完笔记置位 → 树展开它的父目录 → 立刻看得见。
   */
  @State revealPath: string = '';
  /** 单屏态「编辑 / 预览」二选一（v0.2 §3.4-3.3）。
   * 只有一块屏放不下两栏；md/lg 两栏同时可见，这个状态不参与布局。
   */
  @State smMode: string = 'edit';

  /**
   * M2 自动保存（2.3）：编辑器 onChange → 防抖落盘。
   * - `saveTimer`：-1 表示无待触发计时器；切换/后台时清零并立刻 flush。
   * - `lastSavedText`：当前文件「已落盘或已加载」的内容镜像，用于跳过无变化的冗余写，
   *   也防止 Web 的 setContent 回灌 change 事件被误判成新编辑而重写一遍。
   * ⚠️ 切文件 / 新建 / 删除当前文件前必须先 flush 旧文件 —— 否则防抖触发时编辑器已是
   * 新文件内容，却写进旧路径，造成数据损坏（实现见 loadFile / doCreateNote / doDeletePath）。
   */
  private saveTimer: number = -1;
  private lastSavedText: string = '';

  /**
   * M3 预览（3.1/3.2）：marked 渲染器跑在 PreviewWebView 里，本页做「编辑 → 预览」联动。
   * - `previewBridge`：内容 / 笔记目录 / 主题下发句柄（就绪前进队列不丢）；
   * - `lastPreviewText`：已推给预览的内容镜像，跳过无变化的重复渲染；
   * - `previewTimer`：联动防抖 500ms —— 编辑器 change 事件（Web 侧已 300ms 防抖）
   *   到达后不立刻拉全量内容过桥，攒 500ms 再一次，避免连续击键反复渲染。
   */
  private previewBridge: PreviewBridge = new PreviewBridge();
  private lastPreviewText: string = '';
  private previewTimer: number = -1;

  /** 对话框控制器：每次拉起重建（传新鲜目标参数），不复用旧实例防参数过期 */
  private createDialogCtl: CustomDialogController | null = null;
  private renameDialogCtl: CustomDialogController | null = null;
  private deleteDialogCtl: CustomDialogController | null = null;
  private createNoteCtl: CustomDialogController | null = null;
  /** 删除确认（文件/目录）对话框 controller（2026-10-18 方案 A 配套） */
  private deletePathCtl: CustomDialogController | null = null;

  aboutToAppear(): void {
    this.refreshFromRegistry();
  }

  /** 从注册表刷新库列表与当前库（切库/新建/改名/删除后调用） */
  private refreshFromRegistry(): void {
    const reg: VaultRegistry = VaultRegistry.get();
    this.vaults = reg.list();
    this.currentVaultId = reg.currentId();
  }

  /** 档位变化：抽屉语义只在 sm；切到 md/lg 强制收抽屉，防止回 sm 时意外打开 */
  private onBreakpointChanged(): void {
    if (this.breakpoint !== Breakpoint.SM) {
      this.drawerOpen = false;
    }
  }

  /**
   * 系统返回键/侧滑返回拦截（需求 2.7b；api_notes I-1 / I3.1 已真机核实：侧滑同样触发）。
   * 按优先级依次消费：① sm 抽屉打开 → 关抽屉；② 库管理视图 → 回笔记视图；
   * ③ sm 预览态 → 回编辑态；④ 都不是 → 返 false 走系统默认（退出应用）。
   */
  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.topView !== 'note') {
      this.topView = 'note';
      return true;
    }
    if (this.breakpoint === Breakpoint.SM && this.smMode === 'preview') {
      this.smMode = 'edit';
      return true;
    }
    return false;
  }

  /** 页面隐藏（应用退到后台）：立刻落盘，兜底「杀进程重进内容还在」（2.3） */
  onPageHide(): void {
    void this.flushSave();
  }

  /** 当前库名（显示名 = 目录名 = id；注册表兜底） */
  private currentVaultName(): string {
    return this.currentVaultId.length > 0 ? this.currentVaultId : '（无库）';
  }

  /**
   * 选中文件。
   * 单屏态额外做两件事：关抽屉 + 回编辑态 —— 在只有一个栏位的地方点了文件，
   * 默认意图是「看/改它」，而不是开抽屉也不看 preview。
   */
  private onSelectFile(relPath: string): void {
    hilog.info(DOMAIN, TAG, '选中文件 %{public}s', relPath);
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = false;
      this.smMode = 'edit';
    }
    void this.loadFile(relPath);
  }

  /**
   * 读取笔记全文并下发给 Web 编辑器（M0.5 spike 的加载路径）。
   * 读文件在 ArkTS 侧做（组件不碰 IO，硬约束 14）；读失败给空串，不弹错不崩。
   * ⚠️ **先更新 `lastSavedText` 再下发给编辑器**：若 Web 的 setContent 回灌一个 change
   * 事件，guard 才能识别「内容没变」跳过冗余写（否则会被当成新编辑重写一遍）。
   */
  private async readAndPush(relPath: string): Promise<string> {
    let text: string = '';
    if (this.currentVaultId.length > 0 && relPath.length > 0) {
      text = NoteService.readNote(VaultRegistry.get(), this.currentVaultId, relPath);
    }
    this.lastSavedText = text;
    await this.editorBridge.setContent(text);
    // M3 联动：文件加载后预览同步本页内容 + 告知笔记目录（相对图片引用的解析基准）
    this.previewBridge.setNoteDir(relPath.indexOf('/') >= 0 ? relPath.substring(0, relPath.lastIndexOf('/')) : '');
    this.pushPreview(text);
    return text;
  }

  /**
   * 切换当前打开的文件（M2 协同 2.3）。
   *
   * ⚠️ **顺序（2026-10-18 修 bug 后定案）**：先把 `currentFilePath` 指向新文件，
   * 再去 flush 旧文件（用捕获的 `prev` 作写入目标），最后加载新内容。
   * 之前写成「先 await flushSave() 再赋值」有两个错：
   *  1. flush 是跨进程 Web 调用（getContent → runJavaScript），一抛错/卡住，
   *     `currentFilePath` 和 readAndPush 就永远不执行 —— 用户表现是「点了文件没反应、
   *     左下角文件名一直停在第一篇」（loadFile 是 void 调用，异常被静默吞掉）。
   *  2. UI（侧栏选中态 / 底部状态栏 / 编辑区标题）都被一次异步 IO 拖住才更新。
   * 改成先切指针后 flush，UI 立刻跟上；flush 用捕获的 prev 写旧内容，**不会串到新路径**。
   */
  private async loadFile(relPath: string): Promise<void> {
    const prev: string = this.currentFilePath;
    this.currentFilePath = relPath;
    // flush 失败不能挡住打开新文件：见 flushSave 的「永不抛错」约定
    await this.flushSave(prev);
    await this.readAndPush(relPath);
  }

  /**
   * 立刻把编辑器当前内容落盘（防抖到点 / 切文件前 / 后台时调用）。
   *
   * @param targetPath 写入目标，缺省为 `currentFilePath`。切文件时由 loadFile 传入**旧路径**：
   *   那时指针已经指向新文件，但编辑器里还是旧内容，必须写回旧路径。
   *
   * ⚠️ **本函数约定「永不抛错」**：它是尽力而为的保存，调用方（loadFile 切文件、
   *   doDeletePath 删除、onPageHide 后台兜底）都排在关键动作之前，一旦抛出就会
   *   连带把「打开文件 / 删除」整个动作吞掉（void 调用 + 静默 rejection）。
   *   所以 getContent 与 saveNote 两处 IO 都各自包 try/catch。
   */
  private async flushSave(targetPath: string = ''): Promise<void> {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    const path: string = targetPath.length > 0 ? targetPath : this.currentFilePath;
    if (this.currentVaultId.length === 0 || path.length === 0) {
      return;
    }
    // 编辑器未就绪时 getContent 返回 ''，此时落盘会把真实文件清空 —— 必须跳过
    if (!this.editorBridge.ready) {
      return;
    }
    let text: string = '';
    try {
      text = await this.editorBridge.getContent();
    } catch (error) {
      // 拉不到内容：放弃这次保存（拿空串落盘会清空文件），但绝不让异常外泄挡住调用方
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'flushSave 拉取编辑器内容失败，跳过保存: %{public}s', err.message);
      return;
    }
    if (text === this.lastSavedText) {
      return;
    }
    try {
      await NoteService.saveNote(VaultRegistry.get(), this.currentVaultId, path, text);
      this.lastSavedText = text;
    } catch (error) {
      this.toastRegistryError('保存失败', error);
    }
  }

  /** 编辑器有改动：防抖 800ms 后再落盘，避免每次击键都写盘 */
  private scheduleSave(): void {
    if (this.currentFilePath.length === 0) {
      return;
    }
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      void this.flushSave();
    }, 800);
  }

  // ===== M3 预览联动（3.2 编辑/预览实时联动） =====

  /** 把文本推给预览渲染（相同内容跳过；预览未就绪时进其内部队列不丢） */
  private pushPreview(text: string): void {
    if (text === this.lastPreviewText) {
      return;
    }
    this.lastPreviewText = text;
    this.previewBridge.setContent(text);
  }

  /** 编辑器有改动：防抖 500ms 后从编辑器拉全量内容渲染预览 */
  private schedulePreviewUpdate(): void {
    if (this.previewTimer !== -1) {
      clearTimeout(this.previewTimer);
    }
    this.previewTimer = setTimeout((): void => {
      this.previewTimer = -1;
      void this.updatePreviewFromEditor();
    }, 500);
  }

  /**
   * 从编辑器拉当前内容 → 推给预览。编辑器未就绪时退回 `lastSavedText`
   * （已加载内容的镜像），保证预览永远有东西可渲染而不是空白。
   */
  private async updatePreviewFromEditor(): Promise<void> {
    if (!this.editorBridge.ready) {
      this.pushPreview(this.lastSavedText);
      return;
    }
    let text: string = '';
    try {
      text = await this.editorBridge.getContent();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '预览拉取编辑器内容失败: %{public}s', err.message);
      return;
    }
    this.pushPreview(text);
  }

  /**
   * 读库内图片 → data URI（PreviewWebView 的 readAsset 桥回调，M3 预览「图片」项）。
   * 返回空串 = 图片不存在/不支持，Web 侧显示「图片不存在」。
   */
  private readVaultAsset(relPath: string): string {
    if (this.currentVaultId.length === 0 || relPath.length === 0) {
      return '';
    }
    try {
      return NoteService.readAssetDataUri(VaultRegistry.get(), this.currentVaultId, relPath);
    } catch (error) {
      return '';
    }
  }

  /** 状态栏右侧读数：形态 · vp · FS:N（有折痕时追加 · C:x,y，px 在此换算成 vp） */
  private statusRightText(): string {
    let s: string = formLabelOf(this.breakpoint) + ' · ' + Math.round(this.windowWidthVp) + 'vp' +
      ' · FS:' + this.foldStatus;
    if (this.creasePx !== '-') {
      s += ' · C:' + this.creaseVpText();
    }
    return s;
  }

  /** 折痕 px 串 → vp 串（页面侧换算，UI 上下文里 px2vp 才可靠） */
  private creaseVpText(): string {
    const parts: string[] = this.creasePx.split(',');
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      const px: number = parseInt(parts[i], 10);
      out += (i === 0 ? '' : ',') + (isNaN(px) ? '?' : Math.round(px2vp(px)).toString());
    }
    return out;
  }

  /** 顶栏汉堡：sm = 抽屉开关；md/lg = 收起/唤回切换（toggle） */
  private onHamburger(): void {
    if (this.breakpoint === Breakpoint.SM) {
      this.drawerOpen = !this.drawerOpen;
    } else {
      this.sidebarCollapsed = !this.sidebarCollapsed;
    }
  }

  // ===== 库操作（对话框确认后执行；失败 toast + 日志，注册表不落半状态） =====

  private doSwitchVault(id: string): void {
    try {
      VaultRegistry.get().setCurrent(id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('切换库失败', error);
    }
  }

  private doCreateVault(name: string): void {
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const entry: VaultEntry = reg.createLocal(name);
      // 原型行为：新建后自动切到新库（doCreate → switchVault）
      reg.setCurrent(entry.id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('新建库失败', error);
    }
  }

  private doRenameVault(id: string, name: string): void {
    try {
      VaultRegistry.get().rename(id, name);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('改名失败', error);
    }
  }

  private doDeleteVault(id: string): void {
    try {
      VaultRegistry.get().remove(id);
      this.refreshFromRegistry();
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /**
   * 新建笔记（顺序不能乱）：
   * 1. `normalizeRelPath` —— 消毒 + 补 `.md`（非法输入在这一步就抛错，不会落到磁盘）；
   * 2. `createNote` —— 逐级补建父目录 + 写空文件，重名自动加后缀；
   * 3. 置 currentFilePath / revealPath / treeSeq —— 让用户立刻看到刚建的那篇。
   * 失败一律 toast，且**不改动任何 UI 状态**（笔记没建成就不该「选中」它）。
   */
  private doCreateNote(rawName: string): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeRelPath(rawName);
      const actual: string = NoteService.createNote(reg, this.currentVaultId, rel);
      // 新笔记是空文件：先 flush 旧文件编辑，再指向新文件并加载空内容（loadFile 内部处理）
      void this.loadFile(actual);
      this.revealPath = actual;
      this.treeSeq++;
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
        this.smMode = 'edit';
      }
    } catch (error) {
      this.toastRegistryError('新建笔记失败', error);
    }
  }

  /**
   * 新建空文件夹（2026-10-18 方案 A：显式「新建文件夹」类型）。
   * 顺序：normalizeDirPath（消毒、不补 .md）→ createFolder（逐级补建父目录、
   * 重名加后缀）→ 记住新文件夹（下次新建默认进里面，与原型 lastDir 同策略）。
   * 不动 currentFilePath：建文件夹不该抢走用户正在编辑的笔记。
   */
  private doCreateFolder(rawName: string): void {
    if (this.currentVaultId.length === 0) {
      promptAction.showToast({ message: '还没有笔记本' });
      return;
    }
    try {
      const reg: VaultRegistry = VaultRegistry.get();
      const rel: string = NoteService.normalizeDirPath(rawName);
      const actual: string = NoteService.createFolder(reg, this.currentVaultId, rel);
      // （2026-10-18 用户拍板：头部「＋」= 根目录入口，不再记忆上次目录）
      this.revealPath = actual;
      this.treeSeq++;
      if (this.breakpoint === Breakpoint.SM) {
        this.drawerOpen = false;
      }
    } catch (error) {
      this.toastRegistryError('新建文件夹失败', error);
    }
  }

  /**
   * 删除文件或整棵目录（2026-10-18 方案 A 配套：目录行尾删除按钮）。
   * ⚠️ 不可恢复（回收站是需求池 B 组）—— 调用方（openDeletePathDialog）必须先过确认框。
   * 删的是正在编辑的文件（或其子孙）时清空编辑器：留着已不存在文件的标题比空着更坏。
   */
  private async doDeletePath(relPath: string): Promise<void> {
    if (this.currentVaultId.length === 0) {
      return;
    }
    try {
      // 删的是当前打开的文件（或其父目录）时：先落盘编辑，再删（删完文件就不复存在，
      // 且必须在 deletePath 之前 await 完，否则 flushSave 的 getContent 在文件已删后
      // 写回会 recreate 一个本该消失的文件）。
      const isCurrent: boolean = this.currentFilePath === relPath
        || this.currentFilePath.startsWith(relPath + '/');
      if (isCurrent) {
        await this.flushSave();
        this.currentFilePath = '';
      }
      NoteService.deletePath(VaultRegistry.get(), this.currentVaultId, relPath);
      this.revealPath = '';
      this.treeSeq++;
    } catch (error) {
      this.toastRegistryError('删除失败', error);
    }
  }

  /** 注册表操作失败：固定文案 toast + 详细原因进 hilog（不把异常原文弹给用户） */
  private toastRegistryError(prefix: string, error: Object): void {
    const err = error as Error;
    hilog.warn(DOMAIN, TAG, '%{public}s: %{public}s', prefix, err.message ?? JSON.stringify(error));
    promptAction.showToast({ message: prefix });
  }

  // ===== 对话框拉起（每次新建 controller 传新鲜参数） =====

  private openCreateDialog(): void {
    this.createDialogCtl = new CustomDialogController({
      builder: CreateVaultDialog({
        onConfirm: (name: string): void => {
          this.doCreateVault(name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createDialogCtl.open();
  }

  /**
   * 打开新建（笔记 / 文件夹）对话框。
   * @param initialDir 预选目录：目录行 + 按钮入口传点击的目录；空串 = 目录树头部「＋」入口，
   *        **固定为 vault 根目录**（2026-10-18 用户拍板：移除底部「新建笔记」按钮，头部「＋」
   *        作为根目录创建入口，与文件夹行尾「＋」（指定目录）两级入口一致，不再记忆上次目录）。
   */
  private openCreateNoteDialog(initialDir: string = ''): void {
    // 目录选择器的候选：全量目录（不受展开状态影响）
    let dirs: string[] = [];
    try {
      dirs = FileTree.allDirs(VaultRegistry.get().vaultDirOf(this.currentVaultId));
    } catch (error) {
      const err = error as Error;
      hilog.warn(0x0001, 'Index', '列目录失败：%{public}s', err.message);
      dirs = [];
    }
    this.createNoteCtl = new CustomDialogController({
      builder: CreateNoteDialog({
        vaultId: this.currentVaultId,
        dirs: dirs,
        initialDir: initialDir,
        onConfirm: (rawName: string, createType: string): void => {
          // 2026-10-18 方案 A：对话框内「笔记 / 文件夹」切换，落到不同的创建方法
          if (createType === 'folder') {
            this.doCreateFolder(rawName);
          } else {
            this.doCreateNote(rawName);
          }
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.createNoteCtl.open();
  }

  /**
   * 打开删除确认框（2026-10-18 方案 A 配套：目录行尾删除按钮）。
   * 目前只有目录行带删除入口（文件行的删除等 1.6 左滑三档一起做），
   * 所以 isDir 恒 true；DeletePathDialog 已支持文件形态，届时直接复用。
   */
  private openDeletePathDialog(relPath: string): void {
    this.deletePathCtl = new CustomDialogController({
      builder: DeletePathDialog({
        relPath: relPath,
        isDir: true,
        onConfirm: (): void => {
          this.doDeletePath(relPath);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deletePathCtl.open();
  }

  private openRenameDialog(id: string): void {
    this.renameDialogCtl = new CustomDialogController({
      builder: RenameVaultDialog({
        initialName: id,
        onConfirm: (name: string): void => {
          this.doRenameVault(id, name);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.renameDialogCtl.open();
  }

  private openDeleteDialog(id: string): void {
    this.deleteDialogCtl = new CustomDialogController({
      builder: DeleteVaultDialog({
        vaultId: id,
        onConfirm: (): void => {
          this.doDeleteVault(id);
        }
      }),
      autoCancel: true,
      customStyle: true
    });
    this.deleteDialogCtl.open();
  }

  // ===== 视觉构件 =====

  /** 顶栏图标按钮：视觉 22，热区 48（4.x 修正 v0.1 的 32×32 不足） */
  @Builder
  IconButton(name: string, color: ResourceColor, onTap: () => void) {
    Row() {
      Icon(name, 22, color)
    }
    .width(Size.touch)
    .height(Size.touch)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.icon)
    .onClick(onTap)
  }

  /** 单屏态「编辑 / 预览」分段控件（SegmentedButton 观感） */
  @Builder
  SegToggle() {
    Row({ space: 2 }) {
      Text('编辑')
        .segItem(this.smMode === 'edit')
        .onClick(() => {
          this.smMode = 'edit';
        })
      Text('预览')
        .segItem(this.smMode === 'preview')
        .onClick(() => {
          this.smMode = 'preview';
          // 切到预览立刻拉一次编辑器当前内容：Web 侧 change 事件有 300ms 防抖，
          // 点击前刚敲的字可能还没报上来，直接 getContent 才是最新
          void this.updatePreviewFromEditor();
        })
    }
    .padding(2)
    .borderRadius(Radius.full)
    .backgroundColor($r('app.color.bg_secondary'))
  }

  /** 栏头：标题 + （单屏态才有的）编辑/预览切换。⚠️ $$ 按引用传参：按值传参时
   *  @Builder 不随状态刷新（实测：编辑区标题永远停在「源模式」，currentFilePath 变了不动） */
  @Builder
  PaneHead($$: PaneHeadParam) {
    Row() {
      Text($$.title)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.breakpoint === Breakpoint.SM) {
        this.SegToggle()
      }
    }
    .width('100%')
    .height(Size.paneHeadH)
    .padding({ left: Space.s4, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  build() {
    Column() {
      this.Appbar()
      Stack() {
        if (this.topView === 'vaults') {
          this.ManagerView()
        } else if (this.topView === 'settings') {
          this.SettingsPane()
        } else if (this.breakpoint === Breakpoint.SM) {
          this.SmContent()
        } else {
          this.WideContent()
        }
      }
      .layoutWeight(1)
      .width('100%')
      this.Statusbar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /**
   * 顶栏（需求 2.7，贴合设计稿）：
   *  - 笔记视图 = 汉堡（sm 抽屉 / md+lg 收起唤回）+ 标题（当前库名）+ 右上「同步 + 设置」图标；
   *  - 次级视图（库管理 / 设置与关于）= 左上角换返回箭头 + 标题「笔记库」/「设置与关于」，
   *    右上图标收敛（设计稿：同步图标仅在笔记视图显示、设置图标在设置视图隐藏）；
   *  - 库管理入口不放在顶栏（侧栏下拉「管理库…」+ 底部「管理库」已覆盖，避免重复）。
   * v0.2 §3.5：高度 56vp、标题 20fp/700、图标热区 48、颜色走 token。
   */
  @Builder
  Appbar() {
    Row() {
      if (this.topView !== 'note') {
        // 次级视图顶栏返回是硬要求（api_notes I3），不依赖系统返回可否拦截
        this.IconButton('back', $r('app.color.text_primary'), (): void => {
          this.topView = 'note';
        })
      } else {
        this.IconButton('menu', $r('app.color.text_secondary'), (): void => {
          this.onHamburger();
        })
      }
      // 原型 VIEW_TITLE：次级视图标题固定为视图名，不显示当前库名
      Text(this.topView === 'note' ? this.currentVaultName()
        : (this.topView === 'vaults' ? '笔记库' : '设置与关于'))
        .fontSize(FontSize.s2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: Space.s2, right: Space.s2 })
      if (this.topView === 'note') {
        // 设计稿顶栏右上 = 同步 + 设置 两个图标（库管理在侧栏下拉进，顶栏不重复摆）
        this.IconButton('sync', $r('app.color.text_secondary'), (): void => {
          // 同步（Git 同步是 v0.3 能力）：跳独立「导入仓库」页
          router.pushUrl({ url: 'pages/SyncPage' });
        })
        this.IconButton('settings', $r('app.color.text_secondary'), (): void => {
          this.topView = 'settings';
        })
      }
    }
    .width('100%')
    .height(Size.appbarH)
    .padding({ left: Space.s1, right: Space.s2 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }

  /**
   * sm：单栏内容（编辑 / 预览二选一）+ 抽屉侧栏覆盖层（Stack，汉堡开关，点遮罩关闭）。
   * ⚠️ 编辑器**常驻**（Visibility 切换而非 if 卸载，同 git 容器的常驻铁律精神）：
   * 卸载会销毁 Web 实例 —— 800ms 防抖窗口内未落盘的编辑、光标、撤销栈全丢。
   * 预览是纯展示，可随用随挂（内容由 pushPreview 保证一致）。
   */
  @Builder
  SmContent() {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        this.EditorPane(false)
      }
      .width('100%')
      .height('100%')
      .visibility(this.smMode === 'edit' ? Visibility.Visible : Visibility.Hidden)
      if (this.smMode === 'preview') {
        this.PreviewPane()
      }
      if (this.drawerOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.mask'))
          .onClick(() => {
            this.drawerOpen = false;
          })
        VaultSidebar({
          asDrawer: true,
          vaults: this.vaults,
          currentVaultId: this.currentVaultId,
          currentFilePath: this.currentFilePath,
          refreshSeq: this.treeSeq,
          revealPath: this.revealPath,
          onSwitchVault: (id: string): void => {
            this.doSwitchVault(id);
          },
          onManageVaults: (): void => {
            this.drawerOpen = false;
            this.topView = 'vaults';
          },
          onCreateNote: (): void => {
            this.drawerOpen = false;
            this.openCreateNoteDialog();
          },
          onCreateInDir: (dirRelPath: string): void => {
            // 抽屉形态先关抽屉：对话框是窗口级弹层，但抽屉+遮罩叠着容易误触
            this.drawerOpen = false;
            this.openCreateNoteDialog(dirRelPath);
          },
          onDeleteDir: (dirRelPath: string): void => {
            this.drawerOpen = false;
            this.openDeletePathDialog(dirRelPath);
          },
          onSelectFile: (relPath: string): void => {
            this.onSelectFile(relPath);
          }
        })
          .width(Size.drawerW)
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** md/lg：Row 等分（layoutWeight 精确等分，栏边界压折痕） */
  @Builder
  WideContent() {
    Row() {
      if (!this.sidebarCollapsed) {
        // 侧栏（嵌入形态）
        Column() {
          VaultSidebar({
            asDrawer: false,
            vaults: this.vaults,
            currentVaultId: this.currentVaultId,
            currentFilePath: this.currentFilePath,
            refreshSeq: this.treeSeq,
            revealPath: this.revealPath,
            onCollapse: (): void => {
              this.sidebarCollapsed = true;
            },
            onSwitchVault: (id: string): void => {
              this.doSwitchVault(id);
            },
            onManageVaults: (): void => {
              this.topView = 'vaults';
            },
            onCreateNote: (): void => {
              this.openCreateNoteDialog();
            },
            onCreateInDir: (dirRelPath: string): void => {
              this.openCreateNoteDialog(dirRelPath);
            },
            onDeleteDir: (dirRelPath: string): void => {
              this.openDeletePathDialog(dirRelPath);
            },
            onSelectFile: (relPath: string): void => {
              this.onSelectFile(relPath);
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { right: 1 }, color: $r('app.color.line') })

        if (this.breakpoint === Breakpoint.MD) {
          // md 展开：侧栏 | 编辑 各 50%（预览隐藏，原型 applyForm）
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
        } else {
          // lg 展开：侧栏 | 编辑 | 预览 各 1/3
          Column() {
            this.EditorPane(false)
          }
          .layoutWeight(1)
          .height('100%')
          Column() {
            this.PreviewPane()
          }
          .layoutWeight(1)
          .height('100%')
          .border({ width: { left: 1 }, color: $r('app.color.line') })
        }
      } else if (this.breakpoint === Breakpoint.MD) {
        // md 收起：腾出的那一栏给预览 → 编辑 | 预览 各一整块屏
        Column() {
          this.EditorPane(false)
        }
        .layoutWeight(1)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      } else {
        // lg 收起：编辑扩 2/3 —— 会跨越第一条折痕，这是物理限制非 bug；
        // 编辑区内渲染红色虚线折痕警示 + 预览 1/3
        Column() {
          this.EditorPane(true)
        }
        .layoutWeight(2)
        .height('100%')
        Column() {
          this.PreviewPane()
        }
        .layoutWeight(1)
        .height('100%')
        .border({ width: { left: 1 }, color: $r('app.color.line') })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 编辑区占位（真实编辑器 v0.2 M2 接入）。
   * showHingeWarning：lg 收起态专用——编辑区扩到 2/3 会跨第一条折痕。
   * 警示线位置 = 编辑区宽的 50%：第一条折痕在整体 1/3 处，编辑区占 2/3，1/3 ÷ 2/3 = 50%。
   * 折痕实际坐标只做读数（api_notes A2：真机返回不可用 / 模拟器可用），**不进布局算式**。
   */
  @Builder
  EditorPane(showHingeWarning: boolean) {
    Column() {
      this.PaneHead({ title: this.currentFilePath.length > 0 ? this.currentFilePath : '源模式' })

      Stack() {
        // M0.5 spike：CodeMirror 6 跑在 Web 组件里（web/mdeditor → rawfile/mdeditor/index.html）。
        // 内容由本页在「选中文件 / 切库」时读好下发；组件本身不碰文件 IO（硬约束 14）。
        EditorWebView({
          bridge: this.editorBridge,
          onChange: (len: number): void => {
            // 编辑中：记长度（观察击键是否过桥正常）+ 触发防抖自动保存（M2 2.3）
            if (len !== this.editorLen) {
              this.editorLen = len;
            }
            this.scheduleSave();
            this.schedulePreviewUpdate();
          },
          onReady: (): void => {
            // 页面就绪后补一次内容加载：EditorWebView 的指令队列保证此前收到的
            // setContent 不丢，但首帧若在选中文件之前就绪，这里再同步一次更稳
            void this.loadFile(this.currentFilePath);
          },
          onError: (msg: string): void => {
            hilog.error(DOMAIN, TAG, '编辑器 Web: %{public}s', msg);
          }
        })

        if (showHingeWarning) {
          // 被内容横跨的折痕：红色虚线竖标（零宽 Column + 左边框）
          Column()
            .width(0)
            .height('100%')
            .border({ width: { left: 2 }, color: $r('app.color.danger'), style: BorderStyle.Dashed })
            .position({ x: '50%' })
          Text('被内容横跨')
            .fontSize(FontSize.caption)
            .fontColor($r('app.color.danger'))
            .position({ x: '50%', y: Space.s3 })
            .translate({ x: Space.s1 })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 预览区（M3 3.1/3.2）：marked 渲染器跑在 Web 组件里（web/mdpreview → rawfile）。
   * 内容由本页在「加载文件 / 编辑器变化（500ms 防抖）/ 切预览」时推送；
   * 本地图片经 readVaultAsset 桥换 data URI。组件不碰文件 IO（硬约束 14）。
   */
  @Builder
  PreviewPane() {
    Column() {
      this.PaneHead({ title: '预览' })
      PreviewWebView({
        bridge: this.previewBridge,
        onReadAsset: (relPath: string): string => {
          return this.readVaultAsset(relPath);
        },
        onError: (msg: string): void => {
          hilog.error(DOMAIN, TAG, '预览 Web: %{public}s', msg);
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 库管理视图：整体替换内容区；返回走顶栏 ‹ 与 onBackPress，组件不自带（2.7c） */
  @Builder
  ManagerView() {
    VaultManagerView({
      vaults: this.vaults,
      currentVaultId: this.currentVaultId,
      onSetCurrent: (id: string): void => {
        this.doSwitchVault(id);
      },
      onRename: (id: string): void => {
        this.openRenameDialog(id);
      },
      onDelete: (id: string): void => {
        this.openDeleteDialog(id);
      },
      onCreate: (): void => {
        this.openCreateDialog();
      }
    })
  }

  /** 设置与关于视图：整体替换内容区；返回走顶栏 ‹ 与 onBackPress（2.7c 同级） */
  @Builder
  SettingsPane() {
    SettingsView({
      breakpoint: this.breakpoint,
      currentVaultId: this.currentVaultId
    })
  }

  /** 状态栏：当前库 + 档位 + vp 宽度（spec FR：状态栏联动断点） */
  @Builder
  Statusbar() {
    Row() {
      // TEMP-MARKER：验证选中链路用，验证完删掉的第三行
      Text(this.currentVaultName() + ' | ' + this.currentFilePath)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
      Blank()
      Text(this.statusRightText())
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Size.statusbarH)
    .padding({ left: Space.s3, right: Space.s3 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: $r('app.color.line') })
    .backgroundColor($r('app.color.bg_card'))
  }
}
