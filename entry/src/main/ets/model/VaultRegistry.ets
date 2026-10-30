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
import { DEFAULT_VAULT_ID, sanitizeVaultName, VaultEntry } from './Vault';
import { VaultPathResolver } from './VaultPathResolver';

const REG_DOMAIN: number = 0x0001;
const REG_TAG: string = 'VaultRegistry';

/** 注册表持久化结构（JSON 存 preferences 单 key，plan.md R3）。 */
interface VaultRegistryState {
  vaults: VaultEntry[];
  currentVaultId: string;
}

/** JSON.parse 的原始载体：解析结果先落此类型，经 typeof 校验后才拷入严格模型。 */
interface VaultRegistryRaw {
  vaults?: Object[];
  currentVaultId?: Object;
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

  /** 加载/创建注册表；首启（无注册表）自动建 vaults/local 并设为当前库（FR-007）。 */
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
      // 首启：无注册表 → 建默认库 vaults/local
      this.state = { vaults: [], currentVaultId: '' };
      this.sampleInstallPending = !fileIo.accessSync(this.resolver.vaultDir(DEFAULT_VAULT_ID));
      this.createDefaultVault();
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
    const oldDir: string = this.resolver.vaultDir(id);
    const newDir: string = this.resolver.vaultDir(newId);
    // 目标名经 uniqueVaultId 保证不存在，不覆盖已有目录（spec.md Edge Cases）
    fileIo.renameSync(oldDir, newDir);
    target.id = newId;
    if (this.state.currentVaultId === id) {
      this.state.currentVaultId = newId;
    }
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
   * 删除本地库（不可逆，FR-011）：先递归删除目录内容，再出表 → 当前库回落列表第一个。
   * 顺序：先删目录，成功后才改注册表——失败即抛错且注册表未动（禁半状态）。
   */
  remove(id: string): void {
    const target: VaultEntry | null = this.findEntry(id);
    if (target === null) {
      throw new Error('库不存在: ' + id);
    }
    const dirPath: string = this.resolver.vaultDir(id);
    this.removeVaultTree(id, '');
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
    this.persist();
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
    return this.resolver.draftsVaultDir(vaultId);
  }

  draftDirectory(vaultId: string, relativeDirectory: string): string {
    return this.resolver.draftDirectory(vaultId, relativeDirectory);
  }

  absoluteDraftIn(vaultId: string, relativePath: string): string {
    return this.resolver.resolveDraft(vaultId, relativePath);
  }

  /** 库目录绝对路径（转发唯一解析器，供 UI 展示路径但不自行拼接）。 */
  vaultDirOf(id: string): string {
    return this.resolver.vaultDir(id);
  }

  /** 回收站目录绝对路径（转发唯一解析器，1.7）。 */
  trashDirOf(id: string): string {
    return this.resolver.trashDir(id);
  }

  /** 回收站内相对路径 → 沙箱绝对路径（转发唯一解析器，1.7）。 */
  absoluteInTrash(vaultId: string, relativePath: string): string {
    return this.resolver.resolveInTrash(vaultId, relativePath);
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
        vaults.push(entry);
      }
      const rawCurrent = parsed.currentVaultId;
      const currentVaultId: string = typeof rawCurrent === 'string' ? rawCurrent : '';
      return { vaults: vaults, currentVaultId: currentVaultId };
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

  private createDefaultVault(): void {
    try {
      this.ensureVaultsRoot();
      const dirPath: string = this.resolver.vaultDir(DEFAULT_VAULT_ID);
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath);
      }
      this.state.vaults.push({ id: DEFAULT_VAULT_ID, vaultKey: this.newVaultKey(), type: 'local', createdAt: Date.now() });
      this.state.currentVaultId = DEFAULT_VAULT_ID;
      this.persist();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, '创建默认库失败: %{public}s', JSON.stringify(err));
    }
  }

  /** 注册表落盘（preferences putSync + flushSync，API 14+ 已于 T002 核对）。 */
  private persist(mustSucceed: boolean = false): void {
    if (this.store === null) {
      hilog.error(REG_DOMAIN, REG_TAG, 'preferences 实例不可用，注册表未持久化');
      if (mustSucceed) {
        throw new Error('preferences 实例不可用，注册表未持久化');
      }
      return;
    }
    try {
      this.store.putSync(this.PREF_KEY, JSON.stringify(this.state));
      this.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(REG_DOMAIN, REG_TAG, '注册表持久化失败: %{public}s', JSON.stringify(err));
      if (mustSucceed) {
        throw new Error(err.message);
      }
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
