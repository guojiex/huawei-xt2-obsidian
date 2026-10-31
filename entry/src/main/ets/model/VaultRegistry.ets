/**
 * VaultRegistry.ets —— 库注册表（单例）：CRUD + 当前库 + preferences 持久化
 *
 * 设计依据（plan.md R3 / R5 / R7）：
 * - 注册表存 preferences 单 key JSON（mvp_design.md §4.5「MVP 存 preferences，app.db 是 v2 的事」），
 *   自带落盘，本版本无需 AtomicFile；
 * - 删库先递归移除子项，最后对空目录调用 fileIo.rmdirSync；
 * - 改名/删除遵循「文件系统操作成功后才改注册表」——失败即回滚到未动状态，禁止半状态；
 * - 消毒与重名规则收口在 model 层（Vault.sanitizeVaultName + 本类 uniqueVaultId），
 *   新建/改名/对话框共用同一套逻辑，避免两处漂移。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DEFAULT_VAULT_ID, SAMPLE_VAULT_ID, sanitizeVaultName, VaultEntry } from './Vault';
import { VaultPathResolver } from './VaultPathResolver';
import { VaultAccess } from './VaultAccess';
import { createExternalVaultAccess, createSandboxVaultAccess } from './VaultAccessDevice';

const REG_DOMAIN: number = 0x0001;
const REG_TAG: string = 'VaultRegistry';

/** 注册表持久化结构（JSON 存 preferences 单 key，plan.md R3）。 */
interface VaultRegistryState {
  vaults: VaultEntry[];
  currentVaultId: string;
  initialNotePath?: string;
}

/** JSON.parse 的原始载体：解析结果先落此类型，经 typeof 校验后才拷入严格模型。 */
interface VaultRegistryRaw {
  vaults?: Object[];
  currentVaultId?: Object;
  initialNotePath?: Object;
}

/** 单个库条目的原始（未校验）形态。 */
interface VaultEntryRaw {
  id?: Object;
  vaultKey?: Object;
  type?: Object;
  createdAt?: Object;
  remote?: Object;
  branch?: Object;
  authUsername?: Object;
  lastSyncAt?: Object;
  rootKind?: Object;
  rootUri?: Object;
  grantedAt?: Object;
}

export class VaultRegistry {
  private static instance: VaultRegistry | null = null;
  private static readonly GIT_IMPORTING_SUFFIX: string = '__importing';

  /** preferences 实例名（单一真源，plan.md Data Model）。 */
  private readonly PREF_NAME: string = 'vault_registry';
  /** 注册表 JSON 所在 key（单一真源）。 */
  private readonly PREF_KEY: string = 'vault_registry_json';

  private context: common.UIAbilityContext;
  private resolver: VaultPathResolver;
  private store: preferences.Preferences | null = null;
  private state: VaultRegistryState = { vaults: [], currentVaultId: '' };
  private initialized: boolean = false;
  private sampleInstallPending: boolean = false;
  private vaultKeySerial: number = 0;
  /** vaultId → VaultAccess 的缓存（只缓存 accessor，不缓存 fd）。 */
  private accessCache: Map<string, VaultAccess> = new Map<string, VaultAccess>();

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.resolver = new VaultPathResolver(context);
  }

  /**
   * 创建单例并初始化（在 EntryAbility.onWindowStageCreate 中调用，先于 UI 加载）。
   * 幂等：重复调用不会重复初始化。
   */
  static initialize(context: common.UIAbilityContext): VaultRegistry {
    if (VaultRegistry.instance === null) {
      VaultRegistry.instance = new VaultRegistry(context);
    }
    VaultRegistry.instance.init();
    return VaultRegistry.instance;
  }

  /** 取已初始化的单例（UI 层使用；initialize 必须已调用过）。 */
  static get(): VaultRegistry {
    if (VaultRegistry.instance === null) {
      throw new Error('VaultRegistry 未初始化：请先在 EntryAbility 中调用 initialize');
    }
    return VaultRegistry.instance;
  }

  /** 加载/创建注册表；全新安装创建个人库与教程库，并首次进入教程库。 */
  private init(): void {
    if (this.initialized) {
      return;
    }
    try {
      this.store = preferences.getPreferencesSync(this.context, { name: this.PREF_NAME });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, 'getPreferencesSync 失败: %{public}s', JSON.stringify(err));
      this.store = null;
    }
    const rawJson: string = this.store !== null ? (this.store.getSync(this.PREF_KEY, '') as string) : '';
    const loaded: VaultRegistryState | null = this.parseState(rawJson);
    if (loaded !== null) {
      this.state = loaded;
      // 自愈：沙箱目录被清理等极端情况下按注册表补建目录，保证库模型完整
      this.ensureVaultDirs();
      this.ensureCurrentValid();
      this.persist();
    } else {
      // 无注册表且没有既有库目录才按全新安装处理；保留失去注册表时的已有内容。
      this.state = { vaults: [], currentVaultId: '' };
      const vaultsRoot: string = this.resolver.vaultsRoot();
      const hasExistingVaults: boolean = fileIo.accessSync(vaultsRoot) && fileIo.listFileSync(vaultsRoot).length > 0;
      this.sampleInstallPending = !hasExistingVaults;
      this.createInitialVaults();
    }
    this.recoverGitImportResidues();
    this.initialized = true;
  }

  /** One-shot first-install grant; existing directories and later launches are never seeded. */
  consumeSampleInstall(): boolean {
    const pending: boolean = this.sampleInstallPending;
    this.sampleInstallPending = false;
    return pending;
  }

  /** 首装教程笔记路径；已有安装不会自动获得该值。 */
  firstInstallNotePath(): string {
    return typeof this.state.initialNotePath === 'string' ? this.state.initialNotePath : '';
  }

  /** 教程笔记成功打开并保存工作区后清除首装标记。 */
  markFirstInstallNoteOpened(): boolean {
    if (this.state.initialNotePath === undefined) {
      return true;
    }
    const initialNotePath: string = this.state.initialNotePath;
    this.state.initialNotePath = undefined;
    if (this.persist()) {
      return true;
    }
    this.state.initialNotePath = initialNotePath;
    return false;
  }

  /** 库列表（返回拷贝，调用方改动不影响注册表内部状态）。 */
  list(): VaultEntry[] {
    const copy: VaultEntry[] = [];
    for (let i = 0; i < this.state.vaults.length; i++) {
      const v: VaultEntry = this.state.vaults[i];
      const item: VaultEntry = { id: v.id, vaultKey: v.vaultKey, type: v.type, createdAt: v.createdAt };
      if (v.remote !== undefined) {
        item.remote = v.remote;
      }
      if (v.branch !== undefined) {
        item.branch = v.branch;
      }
      if (v.authUsername !== undefined) {
        item.authUsername = v.authUsername;
      }
      if (v.lastSyncAt !== undefined) {
        item.lastSyncAt = v.lastSyncAt;
      }
      if (v.rootKind !== undefined) {
        item.rootKind = v.rootKind;
      }
      if (v.rootUri !== undefined) {
        item.rootUri = v.rootUri;
      }
      if (v.grantedAt !== undefined) {
        item.grantedAt = v.grantedAt;
      }
      copy.push(item);
    }
    return copy;
  }

  /** 当前库 id。 */
  currentId(): string {
    return this.state.currentVaultId;
  }

  /** UIAbilityContext 转发（给需要 preferences 的子系统用，避免各处重复取 context） */
  abilityContext(): common.UIAbilityContext {
    return this.context;
  }

  /** 当前库条目（不存在/列表空时返回 null）。 */
  currentEntry(): VaultEntry | null {
    return this.findEntry(this.state.currentVaultId);
  }

  /* ----------------------------------------------------------------------- */
  /* v1.5：库访问层（沙箱 / 外部授权目录的统一入口）                          */
  /* ----------------------------------------------------------------------- */

  /**
   * 取某个库的 VaultAccess —— **这是 15.3 之后所有文件读写的唯一入口**。
   *
   * 为什么上层不许再碰 `vaultDirOf` / `absoluteIn`：外部授权目录给不出绝对路径
   * （Picker 只给 `file://docs/...` 这种 URI，`listFileSync` 收 URI 直接报
   * 13900002，见 api_notes T3）。差异全部关在 VaultAccess 的两个实现里，上层
   * 拿到什么 kind 都照同一个接口用。
   *
   * 缓存的是「低值 accessor」而不是 fd：真正的目录 fd 每次调用现开现关
   * （DeviceExternalFdSource），避免跨应用重启后拿着失效 fd 报莫名其妙的 EBADF。
   */
  accessFor(id: string): VaultAccess {
    const cached: VaultAccess | undefined = this.accessCache.get(id);
    if (cached !== undefined) {
      return cached;
    }
    const entry: VaultEntry | null = this.findEntry(id);
    if (entry === null) {
      throw new Error('库不存在: ' + id);
    }
    const created: VaultAccess = this.isExternalEntry(entry) ?
      createExternalVaultAccess(entry.rootUri as string) :
      createSandboxVaultAccess(this.resolver, entry.id);
    this.accessCache.set(id, created);
    return created;
  }

  /** 当前库的 VaultAccess（currentVaultId 为空时抛错，调用方需保证已选库）。 */
  currentAccess(): VaultAccess {
    return this.accessFor(this.state.currentVaultId);
  }

  /** 扔掉缓存的 accessor：删库、改名、重新授权后必须调，否则会拿着旧的 URI 干活。 */
  forgetAccess(id: string): void {
    if (this.accessCache.has(id)) {
      this.accessCache.delete(id);
    }
  }

  /** 外部库的判定收口：三个字段必须齐活，缺一个就当沙箱处理（见 parseState 的同款守卫）。 */
  private isExternalEntry(entry: VaultEntry): boolean {
    return entry.rootKind === 'external' && typeof entry.rootUri === 'string' && entry.rootUri.length > 0;
  }

  /** 稳定的库身份，用于库改名后继续定位库外 Agent 私有数据。 */
  vaultKeyOf(id: string): string {
    const entry: VaultEntry | null = this.findEntry(id);
    if (entry === null) {
      throw new Error('库不存在: ' + id);
    }
    return entry.vaultKey;
  }

  /** 切换当前库（切库后上下文归零是允许的，spec.md FR-012）。 */
  setCurrent(id: string): void {
    if (this.findEntry(id) === null) {
      throw new Error('目标库不存在，无法切换: ' + id);
    }
    if (this.state.currentVaultId === id) {
      return;
    }
    this.state.currentVaultId = id;
    this.persist();
  }

  /**
   * 新建本地库：消毒 → 重名加 -2/-3 → mkdir → 入表 → 持久化。
   * 消毒结果为空 → 抛错（UI 层应提前禁用确认按钮，此处为兜底）。
   */
  createLocal(name: string): VaultEntry {
    const sanitized: string = sanitizeVaultName(name);
    if (sanitized.length === 0) {
      throw new Error('库名不能为空，也不能只由 / \\ : * ? " < > | 等字符组成');
    }
    const id: string = this.uniqueVaultId(sanitized, '');
    this.ensureVaultsRoot();
    const dirPath: string = this.resolver.vaultDir(id);
    if (!fileIo.accessSync(dirPath)) {
      // mkdir 失败会抛错 → 不入表，无半状态
      fileIo.mkdirSync(dirPath);
    }
    const entry: VaultEntry = { id: id, vaultKey: this.newVaultKey(), type: 'local', createdAt: Date.now() };
    this.state.vaults.push(entry);
    this.persist();
    return entry;
  }

  /**
   * 登记导入完成的 Git 库（v0.3 / M3.5）。
   * 前置：库目录已 clone 完成并 rename 到正式 id 位置（调用方保证，此处校验存在性）；
   * 本方法只做入表 + 持久化，不碰文件系统 —— 失败时注册表未动（禁半状态）。
   * remote / branch / authUsername 随注册表存 preferences（非敏感）；令牌只进 Asset Store Kit。
   */
  registerGit(id: string, remote: string, branch: string, authUsername: string): VaultEntry {
    const dirPath: string = this.resolver.vaultDir(id);
    if (this.findEntry(id) !== null) {
      throw new Error('库已登记，拒绝重复登记: ' + id);
    }
    if (!fileIo.accessSync(dirPath)) {
      throw new Error('库目录不存在，拒绝登记: ' + id);
    }
    const entry: VaultEntry = { id: id, vaultKey: this.newVaultKey(), type: 'git', createdAt: Date.now() };
    if (remote.length > 0) {
      entry.remote = remote;
    }
    if (branch.length > 0) {
      entry.branch = branch;
    }
    if (authUsername.length > 0) {
      entry.authUsername = authUsername;
    }
    this.state.vaults.push(entry);
    try {
      this.persist(true);
    } catch (error) {
      const err = error as BusinessError;
      this.state.vaults.pop();
      this.persist();
      throw new Error(err.message);
    }
    return entry;
  }

  /** 记录前台 Git 同步完成时间；不保存令牌或提交内容。 */
  recordGitSync(id: string, timestamp: number): void {
    const entry: VaultEntry | null = this.findEntry(id);
    if (entry === null || entry.type !== 'git') {
      throw new Error('目标不是已登记的 Git 库: ' + id);
    }
    const previous: number | undefined = entry.lastSyncAt;
    entry.lastSyncAt = timestamp;
    try {
      this.persist(true);
    } catch (error) {
      if (previous === undefined) {
        entry.lastSyncAt = undefined;
      } else {
        entry.lastSyncAt = previous;
      }
      this.persist();
      const err = error as BusinessError;
      throw new Error(err.message);
    }
  }

  /** 保存当前 Git 库的非敏感用户名；令牌仍只由 GitCredentialStore 管理。 */
  updateGitAuthUsername(id: string, username: string): void {
    const entry: VaultEntry | null = this.findEntry(id);
    if (entry === null || entry.type !== 'git') {
      throw new Error('目标不是已登记的 Git 库: ' + id);
    }
    const previous: string | undefined = entry.authUsername;
    const normalized: string = username.trim();
    if (previous === normalized || (previous === undefined && normalized.length === 0)) {
      return;
    }
    if (normalized.length === 0) {
      entry.authUsername = undefined;
    } else {
      entry.authUsername = normalized;
    }
    try {
      this.persist(true);
    } catch (error) {
      if (previous === undefined) {
        entry.authUsername = undefined;
      } else {
        entry.authUsername = previous;
      }
      this.persist();
      const err = error as BusinessError;
      throw new Error(err.message);
    }
  }

  /** 在 clone 开始前登记恢复意图；标记目录与库内容分离，不进入 Git 工作树。 */
  beginGitImport(finalId: string, importingId: string): void {
    this.recoverGitImportResidues();
    if (!importingId.startsWith(finalId + VaultRegistry.GIT_IMPORTING_SUFFIX)) {
      throw new Error('导入临时库 id 不匹配: ' + importingId);
    }
    if (this.idTaken(finalId, '') || this.idTaken(importingId, '')) {
      throw new Error('导入目标已存在，拒绝覆盖');
    }
    this.ensureVaultsRoot();
    const markerRoot: string = this.resolver.gitImportMarkersRoot();
    if (!fileIo.accessSync(markerRoot)) {
      fileIo.mkdirSync(markerRoot);
    }
    const markerDir: string = this.resolver.gitImportMarkerDir(finalId);
    if (fileIo.accessSync(markerDir)) {
      throw new Error('导入恢复标记已存在: ' + finalId);
    }
    fileIo.mkdirSync(markerDir);
    try {
      fileIo.mkdirSync(this.resolver.gitImportTempMarkerDir(finalId, importingId));
    } catch (error) {
      const err = error as BusinessError;
      fileIo.rmdirSync(markerDir);
      throw new Error(err.message);
    }
  }

  /** 失败时仅删除由本次导入标记拥有且尚未登记的目录。清理失败时保留标记供重启恢复。 */
  cleanupGitImport(finalId: string, importingId: string): void {
    const markerDir: string = this.resolver.gitImportMarkerDir(finalId);
    if (!fileIo.accessSync(markerDir)) {
      return;
    }
    if (!importingId.startsWith(finalId + VaultRegistry.GIT_IMPORTING_SUFFIX)) {
      throw new Error('导入临时库 id 不匹配，拒绝清理: ' + importingId);
    }
    if (this.findEntry(importingId) === null) {
      this.removePathTreeIfExists(this.resolver.vaultDir(importingId));
    }
    if (this.findEntry(finalId) === null) {
      this.removePathTreeIfExists(this.resolver.vaultDir(finalId));
    }
    this.removeImportMarker(finalId, importingId);
  }

  /** 登记成功后移除恢复标记；清理异常留给下一次启动重试，不撤销已持久化的库。 */
  finishGitImport(finalId: string, importingId: string): void {
    if (this.findEntry(finalId) === null) {
      throw new Error('Git 导入尚未登记: ' + finalId);
    }
    try {
      this.removeImportMarker(finalId, importingId);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(REG_DOMAIN, REG_TAG, 'Git 导入标记清理失败，将在下次启动重试: %{public}s', err.message);
    }
  }

  /**
   * 库改名 = 改目录名（显示名与目录名不分离，FR-010）。
   * 顺序：先 renameSync 目录，成功后才更新注册表——失败即抛错且注册表未动（禁半状态）。
   * 消毒后与现名相同则无操作直接返回。
   */
  rename(id: string, newName: string): VaultEntry {
    const target: VaultEntry | null = this.findEntry(id);
    if (target === null) {
      throw new Error('库不存在: ' + id);
    }
    const newId: string = this.previewRenameId(id, newName);
    if (newId === id) {
      return target;
    }
    // 外部库的目录是用户的，改名只改「本 App 里怎么称呼它」，一个字节都不往磁盘上动。
    if (!this.isExternalEntry(target)) {
      const oldDir: string = this.resolver.vaultDir(id);
      const newDir: string = this.resolver.vaultDir(newId);
      // 目标名经 uniqueVaultId 保证不存在，不覆盖已有目录（spec.md Edge Cases）
      fileIo.renameSync(oldDir, newDir);
    }
    target.id = newId;
    if (this.state.currentVaultId === id) {
      this.state.currentVaultId = newId;
    }
    this.forgetAccess(id);
    this.persist();
    return target;
  }

  /** 预览改名后实际库 id，供相关本地数据在库目录改名前迁移。 */
  previewRenameId(id: string, newName: string): string {
    if (this.findEntry(id) === null) {
      throw new Error('库不存在: ' + id);
    }
    const sanitized: string = sanitizeVaultName(newName);
    if (sanitized.length === 0) {
      throw new Error('库名不能为空，也不能只由 / \\ : * ? " < > | 等字符组成');
    }
    return this.uniqueVaultId(sanitized, id);
  }

  /**
   * v1.5：外部库的目录树归用户所有，删库**不许动用户文件**（需求 15.5）。
   * 沙箱库照旧递归删目录；外部库只把自己的记录从注册表里摘掉，磁盘上的笔记原封不动
   * ——用户在别的应用里还能照常看到，顶多是本 App 不再记得这个库。
   */
  remove(id: string): void {
    const target: VaultEntry | null = this.findEntry(id);
    if (target === null) {
      throw new Error('库不存在: ' + id);
    }
    if (!this.isExternalEntry(target)) {
      this.removeVaultTree(id, '');
    }
    this.removePrivateData(target);
    const kept: VaultEntry[] = [];
    for (let i = 0; i < this.state.vaults.length; i++) {
      if (this.state.vaults[i].id !== id) {
        kept.push(this.state.vaults[i]);
      }
    }
    this.state.vaults = kept;
    if (this.state.currentVaultId === id) {
      // 删除当前库 → 回落列表第一个；空列表为理论不可达，仍以空串兜底（spec.md Edge Cases）
      this.state.currentVaultId = this.state.vaults.length > 0 ? this.state.vaults[0].id : '';
    }
    this.forgetAccess(id);
    this.persist();
  }

  /**
   * 删库时一并清掉这个库的 App 私有数据：回收站 + 崩溃恢复草稿（v1.5 15.6，用户拍板）。
   *
   * 这两样现在都在沙箱里按 `vaultKey` 分目录（15.6），跟用户文件已经是两回事，
   * 所以**沙箱库和外部库一视同仁地清** —— 用户的笔记在 15.5 里原封不动留着，
   * 但 App 自己的回收站与草稿没有理由在「删库」之后还赖在磁盘上。
   * **刻意做成 best-effort**：这个阶段库目录（沙箱库）已经删掉了，如果回收站 / 草稿
   * 清理失败就往外抛，会留下「文件系统已删、注册表还在」的半状态 —— 那比留几个孤儿
   * 私有目录严重得多。孤儿草稿本来就有启动自愈（NoteDraftService.cleanupOrphans），
   * 回收站残留下次由同类清理带走；失败只记日志。
   * 必须在 `target` 还在注册表里时调用：出表后就查不到 vaultKey 了。
   */
  private removePrivateData(target: VaultEntry): void {
    const dirs: string[] = [
      this.resolver.trashDir(target.vaultKey),
      this.resolver.draftsVaultDir(target.vaultKey)
    ];
    for (let i = 0; i < dirs.length; i++) {
      try {
        this.removePathTreeIfExists(dirs[i]);
      } catch (error) {
        const err = error as BusinessError;
        hilog.warn(0x0000, 'VaultRegistry', '私有数据清理失败 %{public}s: %{public}s',
          dirs[i], err.message);
      }
    }
  }

  private removeVaultTree(vaultId: string, relativePath: string): void {
    const path: string = relativePath.length === 0
      ? this.resolver.vaultDir(vaultId)
      : this.resolver.resolve(vaultId, relativePath);
    this.removePathTree(path);
  }

  private removePathTreeIfExists(path: string): void {
    if (fileIo.accessSync(path)) {
      this.removePathTree(path);
    }
  }

  private removePathTree(path: string): void {
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (!stat.isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const names: string[] = fileIo.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      this.removePathTree(path + '/' + names[i]);
    }
    fileIo.rmdirSync(path);
  }

  /**
   * 重名处理（对外公开供对话框实时预览共用）：base 被占用则依次尝试 base-2、base-3…
   * 同时检查注册表与文件系统（沙箱里可能残留注册表之外的孤儿目录）。
   * excludeId 用于改名场景：改成自己的原名不算重名。
   */
  uniqueVaultId(base: string, excludeId: string): string {
    let candidate: string = base;
    let n: number = 2;
    while (this.idTaken(candidate, excludeId)) {
      candidate = base + '-' + n;
      n++;
    }
    return candidate;
  }

  /**
   * 库内相对路径 → 沙箱绝对路径（转发唯一解析器）。
   * 子系统（NoteService 等）要用绝对路径时走这里，不得自己拼 `filesDir + '/vaults/...'`
   * （硬约束 #14：路径拼接只允许出现在 VaultPathResolver）。
   */
  absoluteIn(vaultId: string, relativePath: string): string {
    return this.resolver.resolve(vaultId, relativePath);
  }

  draftsRoot(): string {
    return this.resolver.draftsRoot();
  }

  sharePath(relativePath: string): string {
    return this.resolver.resolveShare(relativePath);
  }

  draftsRootRecoveryFile(): string {
    return this.resolver.draftsRootRecoveryFile();
  }

  draftsVaultDirOf(vaultId: string): string {
    return this.resolver.draftsVaultDir(this.vaultKeyOf(vaultId));
  }

  draftDirectory(vaultId: string, relativeDirectory: string): string {
    return this.resolver.draftDirectory(this.vaultKeyOf(vaultId), relativeDirectory);
  }

  absoluteDraftIn(vaultId: string, relativePath: string): string {
    return this.resolver.resolveDraft(this.vaultKeyOf(vaultId), relativePath);
  }

  /**
   * 孤儿草稿整棵删掉：删的原因是「这个 vaultKey 在注册表里已经不存在了」，
   * 所以这里拿不到 vaultId，只能按 key 直接删目录（孤儿清理专用）。
   */
  removeDraftsTreeByKey(vaultKey: string): void {
    this.removePathTreeIfExists(this.resolver.draftsVaultDir(vaultKey));
  }

  /** 库目录绝对路径（转发唯一解析器，供 UI 展示路径但不自行拼接）。 */
  vaultDirOf(id: string): string {
    return this.resolver.vaultDir(id);
  }

  /**
   * 回收站目录绝对路径（转发唯一解析器，1.7；v1.5 起落在沙箱 filesDir/trash/<vaultKey>）。
   */
  trashDirOf(id: string): string {
    return this.resolver.trashDir(this.vaultKeyOf(id));
  }

  /** 回收站内相对路径 → 沙箱绝对路径（转发唯一解析器，1.7）。 */
  absoluteInTrash(vaultId: string, relativePath: string): string {
    return this.resolver.resolveInTrash(this.vaultKeyOf(vaultId), relativePath);
  }

  /** 注册表展示用相对路径：vaults/<id>（仅展示，不是文件系统绝对路径）。 */
  static displayPath(id: string): string {
    return 'vaults/' + id;
  }

  /** vaults 根目录绝对路径（转发唯一解析器；git 桥接的初始 fs root 用）。 */
  vaultsRootDir(): string {
    return this.resolver.vaultsRoot();
  }

  agentConversationsDirOf(vaultId: string): string {
    return this.resolver.agentConversationsDir(this.vaultKeyOf(vaultId));
  }

  agentConversationDirOf(vaultId: string, conversationId: string): string {
    return this.resolver.agentConversationDir(this.vaultKeyOf(vaultId), conversationId);
  }

  agentConversationFileOf(vaultId: string, conversationId: string): string {
    return this.resolver.agentConversationFile(this.vaultKeyOf(vaultId), conversationId);
  }

  agentVaultDirOf(vaultId: string): string {
    return this.resolver.agentVaultDir(this.vaultKeyOf(vaultId));
  }

  agentRunDirOf(vaultId: string, conversationId: string, runId: string): string {
    return this.resolver.agentRunDir(this.vaultKeyOf(vaultId), conversationId, runId);
  }

  agentRunsDirOf(vaultId: string, conversationId: string): string {
    return this.resolver.agentRunsDir(this.vaultKeyOf(vaultId), conversationId);
  }

  agentRunStateFileOf(vaultId: string, conversationId: string, runId: string): string {
    return this.resolver.agentRunStateFile(this.vaultKeyOf(vaultId), conversationId, runId);
  }

  agentRunOperationsDirOf(vaultId: string, conversationId: string, runId: string): string {
    return this.resolver.agentRunOperationsDir(this.vaultKeyOf(vaultId), conversationId, runId);
  }

  agentOperationFileOf(vaultId: string, conversationId: string, runId: string, operationId: string): string {
    return this.resolver.agentOperationFile(this.vaultKeyOf(vaultId), conversationId, runId, operationId);
  }

  private idTaken(id: string, excludeId: string): boolean {
    if (id.length > 0 && id === excludeId) {
      return false;
    }
    for (let i = 0; i < this.state.vaults.length; i++) {
      if (this.state.vaults[i].id === id) {
        return true;
      }
    }
    try {
      return fileIo.accessSync(this.resolver.vaultDir(id)) ||
        fileIo.accessSync(this.resolver.gitImportMarkerDir(id));
    } catch (error) {
      return false;
    }
  }

  private findEntry(id: string): VaultEntry | null {
    for (let i = 0; i < this.state.vaults.length; i++) {
      if (this.state.vaults[i].id === id) {
        return this.state.vaults[i];
      }
    }
    return null;
  }

  /** 解析并校验注册表 JSON；空串/损坏 → 返回 null（调用方走首启建库分支）。 */
  private parseState(rawJson: string): VaultRegistryState | null {
    if (rawJson.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(rawJson) as VaultRegistryRaw;
      if (typeof parsed !== 'object' || parsed === null) {
        return null;
      }
      const rawVaults = parsed.vaults;
      if (!Array.isArray(rawVaults)) {
        return null;
      }
      const vaults: VaultEntry[] = [];
      const usedVaultKeys: Map<string, boolean> = new Map<string, boolean>();
      for (let i = 0; i < rawVaults.length; i++) {
        const item = rawVaults[i] as VaultEntryRaw;
        if (typeof item !== 'object' || item === null) {
          continue;
        }
        if (typeof item.id !== 'string' || typeof item.type !== 'string' ||
          typeof item.createdAt !== 'number') {
          continue;
        }
        // 校验通过后拷入严格模型，不直接引用解析产物
        let vaultKey: string = typeof item.vaultKey === 'string' && this.isSafeVaultKey(item.vaultKey) ?
          item.vaultKey : '';
        if (vaultKey.length === 0 || usedVaultKeys.has(vaultKey)) {
          vaultKey = this.newVaultKey(usedVaultKeys);
        }
        usedVaultKeys.set(vaultKey, true);
        const entry: VaultEntry = { id: item.id, vaultKey: vaultKey, type: item.type, createdAt: item.createdAt };
        if (typeof item.remote === 'string') {
          entry.remote = item.remote;
        }
        if (typeof item.branch === 'string') {
          entry.branch = item.branch;
        }
        if (typeof item.authUsername === 'string') {
          entry.authUsername = item.authUsername;
        }
        if (typeof item.lastSyncAt === 'number') {
          entry.lastSyncAt = item.lastSyncAt;
        }
        // v1.5 外部库字段。rootUri 必须伴随 rootKind='external' 才作数，
        // 否则宁可退化成沙箱语义——带着半个外部标记会走到「既打不开、又不报错」的死区。
        if (typeof item.rootKind === 'string' && typeof item.rootUri === 'string' &&
          item.rootKind === 'external' && item.rootUri.length > 0) {
          entry.rootKind = item.rootKind;
          entry.rootUri = item.rootUri;
          if (typeof item.grantedAt === 'number') {
            entry.grantedAt = item.grantedAt;
          }
        }
        vaults.push(entry);
      }
      const rawCurrent = parsed.currentVaultId;
      const currentVaultId: string = typeof rawCurrent === 'string' ? rawCurrent : '';
      const state: VaultRegistryState = { vaults: vaults, currentVaultId: currentVaultId };
      if (typeof parsed.initialNotePath === 'string') {
        state.initialNotePath = parsed.initialNotePath;
      }
      return state;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(REG_DOMAIN, REG_TAG, '注册表 JSON 解析失败，按首启处理: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  /** 校验 currentVaultId 必须存在于 vaults，失配回落第一个（plan.md 校验规则）。 */
  private ensureCurrentValid(): void {
    if (this.findEntry(this.state.currentVaultId) !== null) {
      return;
    }
    this.state.currentVaultId = this.state.vaults.length > 0 ? this.state.vaults[0].id : '';
  }

  private ensureVaultsRoot(): void {
    const root: string = this.resolver.vaultsRoot();
    if (!fileIo.accessSync(root)) {
      fileIo.mkdirSync(root);
    }
  }

  /** 按注册表补建缺失的库目录（自愈，不视为错误）。 */
  private ensureVaultDirs(): void {
    try {
      this.ensureVaultsRoot();
      for (let i = 0; i < this.state.vaults.length; i++) {
        const dirPath: string = this.resolver.vaultDir(this.state.vaults[i].id);
        if (!fileIo.accessSync(dirPath)) {
          fileIo.mkdirSync(dirPath);
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, '补建库目录失败: %{public}s', JSON.stringify(err));
    }
  }

  private createInitialVaults(): void {
    try {
      this.ensureVaultsRoot();
      const dirPath: string = this.resolver.vaultDir(DEFAULT_VAULT_ID);
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath);
      }
      this.state.vaults.push({ id: DEFAULT_VAULT_ID, vaultKey: this.newVaultKey(), type: 'local', createdAt: Date.now() });
      if (this.sampleInstallPending) {
        const sampleDir: string = this.resolver.vaultDir(SAMPLE_VAULT_ID);
        try {
          if (!fileIo.accessSync(sampleDir)) {
            fileIo.mkdirSync(sampleDir);
          }
          this.state.vaults.push({
            id: SAMPLE_VAULT_ID,
            vaultKey: this.newVaultKey(),
            type: 'local',
            createdAt: Date.now()
          });
          this.state.currentVaultId = SAMPLE_VAULT_ID;
          this.state.initialNotePath = '00_开始/快速上手.md';
        } catch (error) {
          const err = error as BusinessError;
          this.sampleInstallPending = false;
          this.state.currentVaultId = DEFAULT_VAULT_ID;
          hilog.error(REG_DOMAIN, REG_TAG, '创建教程库失败，回退到个人库: %{public}s', JSON.stringify(err));
        }
      } else {
        this.state.currentVaultId = DEFAULT_VAULT_ID;
      }
      this.persist();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, '创建默认库失败: %{public}s', JSON.stringify(err));
    }
  }

  /** 注册表落盘（preferences putSync + flushSync，API 14+ 已于 T002 核对）。 */
  private persist(mustSucceed: boolean = false): boolean {
    if (this.store === null) {
      hilog.error(REG_DOMAIN, REG_TAG, 'preferences 实例不可用，注册表未持久化');
      if (mustSucceed) {
        throw new Error('preferences 实例不可用，注册表未持久化');
      }
      return false;
    }
    try {
      this.store.putSync(this.PREF_KEY, JSON.stringify(this.state));
      this.store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, '注册表持久化失败: %{public}s', JSON.stringify(err));
      if (mustSucceed) {
        throw new Error(err.message);
      }
      return false;
    }
  }

  recoverGitImportResidues(): void {
    const markerRoot: string = this.resolver.gitImportMarkersRoot();
    if (!fileIo.accessSync(markerRoot)) {
      return;
    }
    const finalIds: string[] = fileIo.listFileSync(markerRoot);
    for (let i = 0; i < finalIds.length; i++) {
      const finalId: string = finalIds[i];
      try {
        const markerDir: string = this.resolver.gitImportMarkerDir(finalId);
        const importingIds: string[] = fileIo.listFileSync(markerDir);
        let safeToFinish: boolean = true;
        for (let j = 0; j < importingIds.length; j++) {
          const importingId: string = importingIds[j];
          if (!importingId.startsWith(finalId + VaultRegistry.GIT_IMPORTING_SUFFIX)) {
            safeToFinish = false;
            continue;
          }
          if (this.findEntry(importingId) === null) {
            this.removePathTreeIfExists(this.resolver.vaultDir(importingId));
          }
          fileIo.rmdirSync(this.resolver.gitImportTempMarkerDir(finalId, importingId));
        }
        if (!safeToFinish) {
          continue;
        }
        if (this.findEntry(finalId) === null) {
          this.removePathTreeIfExists(this.resolver.vaultDir(finalId));
        }
        fileIo.rmdirSync(markerDir);
      } catch (error) {
        const err = error as BusinessError;
        hilog.warn(REG_DOMAIN, REG_TAG, 'Git 导入残留恢复失败，将保留标记供重试: %{public}s', err.message);
      }
    }
  }

  private removeImportMarker(finalId: string, importingId: string): void {
    const tempMarker: string = this.resolver.gitImportTempMarkerDir(finalId, importingId);
    if (fileIo.accessSync(tempMarker)) {
      fileIo.rmdirSync(tempMarker);
    }
    const markerDir: string = this.resolver.gitImportMarkerDir(finalId);
    if (fileIo.accessSync(markerDir) && fileIo.listFileSync(markerDir).length === 0) {
      fileIo.rmdirSync(markerDir);
    }
  }

  private newVaultKey(usedKeys?: Map<string, boolean>): string {
    let candidate: string = '';
    do {
      this.vaultKeySerial++;
      candidate = 'vault-' + Date.now().toString() + '-' + this.vaultKeySerial.toString();
    } while (this.vaultKeyTaken(candidate) || (usedKeys !== undefined && usedKeys.has(candidate)));
    return candidate;
  }

  private vaultKeyTaken(key: string): boolean {
    for (let i = 0; i < this.state.vaults.length; i++) {
      if (this.state.vaults[i].vaultKey === key) {
        return true;
      }
    }
    return false;
  }

  private isSafeVaultKey(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      const ch: string = value.charAt(i);
      const alphaNumeric: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
      if (!alphaNumeric && ch !== '-' && ch !== '_') {
        return false;
      }
    }
    return true;
  }
}
