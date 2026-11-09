/**
 * FullTextSearchService.ets —— v1.40 持久搜索索引的编排层（40.1–40.5 / 设计说明 §4–§5）。
 *
 * 职责分工：
 * - SearchStore（注入）：五张逻辑表怎么存（设备侧 = relationalStore + FTS5，见 SearchStoreDevice）；
 * - 本类：**何时**建库、何时对账、如何把文件事件转成 pending 增量任务并消化；
 * - Markdown 文件永远是真源：索引只是缓存，任何任务都以「重读当前文件」为准（40.4）。
 *
 * 流程（设计说明 §5）：
 * 1. 文件事件（保存/删除/恢复/改名）统一登记 pending（推进存储方扫描代次），随后异步消化；
 * 2. 每库首次使用时若未初始化 → 全量建库（分批读文件、上报进度）；
 * 3. 每库每进程首次使用 → 完整正文 hash 对账（新增文件补索引、内容变化重索引、
 *    消失文件删索引——仅当快照列举完整时才下「消失」结论，40.8）；
 * 4. 查询：FTS 候选 → 重读当前文件核对命中并生成摘录（与 v1.1 同口径），
 *    读不到或不再命中的候选跳过，不编造结果。
 *
 * 40.4 铁律的落点：
 * - 文件保存结果不受索引影响：mutation 只登记 pending，登记失败不回传给保存方；
 * - 旧任务不覆盖新结果 / 不吞新 pending：由 SearchStore 的代次守卫保证；
 * - 索引不可用时报错而不是返回假空结果：searchDetailed 以 indexState='error' 表达，
 *   兼容包装 search() 直接抛错（小艺 SearchNotes 的 INDEX_UNAVAILABLE 通路不变）。
 *
 * 隐私（硬约束 16）：本类不打任何日志；查询词、路径、标题、正文一律不进日志或埋点。
 */
import {
  isVaultNoteName,
  VaultAccess,
  VaultDirChild,
  VaultFileStat,
  VaultSnapshotReport
} from './VaultAccess';
import { VaultEntry } from './Vault';
import {
  contentHashOf,
  excerptOf,
  FullTextSearchResult,
  SearchCandidate,
  SearchDocWrite,
  SearchOutcome,
  SearchDocRow,
  SearchPendingRow,
  SearchStore,
  SearchVaultRegistry,
  SearchVaultRow,
  searchTitleOf
} from './SearchStore';

type ProgressListener = (completed: number, total: number) => void;

interface ProgressSnapshot {
  completed: number;
  total: number;
}

export class FullTextSearchService {
  /** 建库/对账的分批大小：读 24 个文件让出一次主线程（与 v1.1 同口径）。 */
  private static readonly FILES_PER_BATCH: number = 24;
  /** 单次查询返回的候选上限（FTS 查询 LIMIT，按路径排序取前 N）。 */
  private static readonly QUERY_LIMIT: number = 200;
  /** 同一条 pending 连续消化失败次数达到该值即放弃该任务（防毒丸）。 */
  private static readonly MAX_PENDING_FAILURES: number = 3;
  /** runDrain 一次调用里最多做几轮「取任务→消化」循环（防活锁）。 */
  private static readonly MAX_DRAIN_PASSES: number = 4;

  private static store: SearchStore | null = null;
  private static registry: SearchVaultRegistry | null = null;
  private static storeReady: Promise<void> | null = null;
  /** 已删除（或正在删除）的库：索引行清理中，相关任务一律取消。 */
  private static readonly discardedKeys: Set<string> = new Set<string>();
  /** 本进程内已完成对账的库（对账每库每进程一次）。 */
  private static readonly reconciledKeys: Set<string> = new Set<string>();
  /** 有未消化/未确认任务的库（indexComplete 的 advisory 标记）。 */
  private static readonly pendingDirty: Set<string> = new Set<string>();
  private static readonly buildInFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static readonly reconcileInFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static readonly drainInFlight: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  private static readonly progressListeners: Map<string, ProgressListener[]> =
    new Map<string, ProgressListener[]>();
  private static readonly progressState: Map<string, ProgressSnapshot> = new Map<string, ProgressSnapshot>();
  /** pending 连续失败计数（vaultKey + '\u0000' + path）。 */
  private static readonly failureCounts: Map<string, number> = new Map<string, number>();

  /**
   * 注入存储与注册表（EntryAbility 启动时调用一次）。
   * store.init() 失败保留拒绝态：本进程内搜索一律报 error，重启后重试。
   */
  static configure(store: SearchStore, registry: SearchVaultRegistry): void {
    FullTextSearchService.store = store;
    FullTextSearchService.registry = registry;
    const ready: Promise<void> = store.init();
    FullTextSearchService.storeReady = ready;
    ready.catch((): void => {
      // searchDetailed 会 await storeReady 并捕获；这里只吞未处理的拒绝告警。
    });
  }

  /** 启动孤儿清理：索引里存在但注册表已没有的 vaultKey → 整库清索引（40.9）。 */
  static async cleanupOrphans(): Promise<void> {
    const store: SearchStore | null = FullTextSearchService.store;
    const registry: SearchVaultRegistry | null = FullTextSearchService.registry;
    if (store === null || registry === null || FullTextSearchService.storeReady === null) {
      return;
    }
    try {
      await FullTextSearchService.storeReady;
      const keys: string[] = await store.listVaultKeys();
      const entries: VaultEntry[] = registry.list();
      const registered: Set<string> = new Set<string>();
      for (let i = 0; i < entries.length; i++) {
        registered.add(entries[i].vaultKey);
      }
      for (let i = 0; i < keys.length; i++) {
        if (!registered.has(keys[i])) {
          FullTextSearchService.discardedKeys.add(keys[i]);
          await store.clearVault(keys[i]);
        }
      }
    } catch (error) {
      // 清理失败不阻塞启动：孤儿行留待下次清理。
    }
  }

  /**
   * 兼容包装（小艺 SearchNotes / CrossVaultSearchService 用）：
   * 索引不可用直接抛错，保持调用方「报错而不编造结果」的既有语义。
   */
  static async search(registry: SearchVaultRegistry, vaultId: string, query: string,
    onProgress: ProgressListener): Promise<FullTextSearchResult[]> {
    const outcome: SearchOutcome =
      await FullTextSearchService.searchDetailed(registry, vaultId, query, onProgress);
    if (outcome.indexState === 'error') {
      throw new Error('INDEX_UNAVAILABLE：全文索引暂不可用。');
    }
    return outcome.results;
  }

  /** 正文搜索（40.2）：消化 pending → 确保建库/对账 → FTS 查询 → 现文件核对。 */
  static async searchDetailed(registry: SearchVaultRegistry, vaultId: string, query: string,
    onProgress: ProgressListener): Promise<SearchOutcome> {
    const store: SearchStore | null = FullTextSearchService.store;
    if (store === null || FullTextSearchService.storeReady === null) {
      return { results: [], indexState: 'error', indexComplete: false, reconciledAt: 0 };
    }
    let vaultKey: string = '';
    try {
      vaultKey = registry.vaultKeyOf(vaultId);
    } catch (error) {
      vaultKey = '';
    }
    if (vaultKey === '' || FullTextSearchService.discardedKeys.has(vaultKey)) {
      return { results: [], indexState: 'error', indexComplete: false, reconciledAt: 0 };
    }
    try {
      await FullTextSearchService.storeReady;
      await FullTextSearchService.drainPending(vaultKey);
      const state: SearchVaultRow | null = await store.getVaultState(vaultKey);
      if (state === null || !state.initialized) {
        await FullTextSearchService.ensureBuilt(store, registry, vaultKey, vaultId, onProgress);
      } else if (!FullTextSearchService.reconciledKeys.has(vaultKey)) {
        await FullTextSearchService.ensureReconciled(store, registry, vaultKey, vaultId, onProgress);
      }
      if (query.trim().length === 0) {
        return FullTextSearchService.outcomeReady(state, vaultKey, []);
      }
      if (!store.supportsTokenizer()) {
        return { results: [], indexState: 'error', indexComplete: false, reconciledAt: 0 };
      }
      const candidates: SearchCandidate[] = await store.queryContent(vaultKey, query,
        FullTextSearchService.QUERY_LIMIT);
      const results: FullTextSearchResult[] =
        FullTextSearchService.buildResults(registry, vaultId, query, candidates);
      return FullTextSearchService.outcomeReady(state, vaultKey, results);
    } catch (error) {
      // 取消（删库）也走这里：调用方按请求号/跳过逻辑丢弃结果。
      return { results: [], indexState: 'error', indexComplete: false, reconciledAt: 0 };
    }
  }

  /* --------------------------------------------------------------------- */
  /* 文件事件 → pending 增量（40.3 / 40.4）                                 */
  /* --------------------------------------------------------------------- */

  /** 保存/新建后调用。content 仅保持旧签名兼容，任务一律重读当前文件（设计说明 §5）。 */
  static noteSaved(vaultId: string, path: string, content: string): void {
    FullTextSearchService.registerPending(vaultId, [path]);
  }

  /** 永久删除或移入回收站后调用。 */
  static noteRemoved(vaultId: string, path: string, isDirectory: boolean): void {
    void isDirectory;
    FullTextSearchService.registerPending(vaultId, [path]);
  }

  /** 从回收站恢复后调用（文件已回到库内，任务重读即入索引）。 */
  static noteRestored(vaultId: string, path: string): void {
    FullTextSearchService.registerPending(vaultId, [path]);
  }

  /** 改名/移动成功后调用：新旧路径都登记，消化时旧前缀清理、新前缀补齐。 */
  static pathRetargeted(vaultId: string, oldPath: string, newPath: string,
    isDirectory: boolean): void {
    void isDirectory;
    FullTextSearchService.registerPending(vaultId, [oldPath, newPath]);
  }

  /** 删库后按稳定 vaultKey 清索引（40.9）；此时注册表已无该库，id 查不到 key，必须直接给 key。 */
  static discardVaultKey(vaultKey: string): void {
    if (vaultKey.length === 0) {
      return;
    }
    FullTextSearchService.discardedKeys.add(vaultKey);
    FullTextSearchService.reconciledKeys.delete(vaultKey);
    FullTextSearchService.pendingDirty.delete(vaultKey);
    const store: SearchStore | null = FullTextSearchService.store;
    if (store === null) {
      return;
    }
    store.clearVault(vaultKey).catch((): void => {
      // 清理失败：该 key 已在 discardedKeys，重启后由 cleanupOrphans 兜底。
    });
  }

  /* --------------------------------------------------------------------- */
  /* pending 消化                                                           */
  /* --------------------------------------------------------------------- */

  private static registerPending(vaultId: string, paths: string[]): void {
    const store: SearchStore | null = FullTextSearchService.store;
    const registry: SearchVaultRegistry | null = FullTextSearchService.registry;
    if (store === null || registry === null) {
      return;
    }
    let vaultKey: string = '';
    try {
      vaultKey = registry.vaultKeyOf(vaultId);
    } catch (error) {
      vaultKey = '';
    }
    if (vaultKey === '' || FullTextSearchService.discardedKeys.has(vaultKey)) {
      return;
    }
    FullTextSearchService.pendingDirty.add(vaultKey);
    store.setPending(vaultKey, paths).then((): void => {
      void FullTextSearchService.drainPending(vaultKey);
    }).catch((): void => {
      // 登记失败不影响保存结果（40.4）；文件真源在，下次对账兜底。
    });
  }

  private static drainPending(vaultKey: string): Promise<void> {
    const inflight: Promise<void> | undefined = FullTextSearchService.drainInFlight.get(vaultKey);
    if (inflight !== undefined) {
      return inflight;
    }
    const task: Promise<void> = FullTextSearchService.runDrain(vaultKey);
    FullTextSearchService.drainInFlight.set(vaultKey, task);
    const release = (): void => {
      FullTextSearchService.drainInFlight.delete(vaultKey);
    };
    task.then(release, release);
    return task;
  }

  private static async runDrain(vaultKey: string): Promise<void> {
    const store: SearchStore | null = FullTextSearchService.store;
    const registry: SearchVaultRegistry | null = FullTextSearchService.registry;
    if (store === null || registry === null || FullTextSearchService.storeReady === null) {
      return;
    }
    await FullTextSearchService.storeReady;
    if (FullTextSearchService.discardedKeys.has(vaultKey)) {
      return;
    }
    const vaultId: string = FullTextSearchService.vaultIdOfKey(registry, vaultKey);
    if (vaultId === '') {
      // 注册表已无此库：整库清索引（可能与 discardVaultKey 重复，clearVault 幂等）。
      await store.clearVault(vaultKey);
      return;
    }
    const access: VaultAccess = registry.accessFor(vaultId);
    for (let pass = 0; pass < FullTextSearchService.MAX_DRAIN_PASSES; pass++) {
      const rows: SearchPendingRow[] = await store.takePending(vaultKey);
      if (rows.length === 0) {
        FullTextSearchService.pendingDirty.delete(vaultKey);
        return;
      }
      let failures: number = 0;
      for (let i = 0; i < rows.length; i++) {
        if (FullTextSearchService.discardedKeys.has(vaultKey)) {
          return;
        }
        const row: SearchPendingRow = rows[i];
        const failKey: string = vaultKey + ' ' + row.path;
        try {
          await FullTextSearchService.processPendingPath(store, access, vaultKey, row.path,
            row.generation);
          FullTextSearchService.failureCounts.delete(failKey);
        } catch (error) {
          failures++;
          const count: number = (FullTextSearchService.failureCounts.get(failKey) ?? 0) + 1;
          if (count >= FullTextSearchService.MAX_PENDING_FAILURES) {
            FullTextSearchService.failureCounts.delete(failKey);
            store.dropPending(vaultKey, row.path, row.generation).catch((): void => {});
          } else {
            FullTextSearchService.failureCounts.set(failKey, count);
          }
        }
      }
      if (failures > 0 || FullTextSearchService.discardedKeys.has(vaultKey)) {
        return;
      }
    }
    // 连续数轮干净消化后仍有新任务（高频编辑）：留待下一次触发，避免活锁。
  }

  /** 消化一条 pending：以当前文件系统为准（stat → 读 → 写索引 / 清索引）。 */
  private static async processPendingPath(store: SearchStore, access: VaultAccess,
    vaultKey: string, path: string, generation: number): Promise<void> {
    const stat: VaultFileStat | null = access.stat(path);
    if (stat === null) {
      // 文件/目录已不存在：前缀删除（同时覆盖「目录被整体移走」）。
      await store.removeDocuments(vaultKey, path, true, generation);
      return;
    }
    if (stat.isDir) {
      // 目录事件：先清旧前缀，再按当前快照把目录下的笔记补回索引。
      await store.removeDocuments(vaultKey, path, true, generation);
      const report: VaultSnapshotReport = access.snapshotReport();
      if (report.failed) {
        throw new Error('扫描库失败');
      }
      const prefix: string = path + '/';
      for (let i = 0; i < report.entries.length; i++) {
        const entry: VaultDirChild = report.entries[i];
        if (!entry.isDir && isVaultNoteName(entry.name) && entry.name.startsWith(prefix)) {
          await FullTextSearchService.upsertByRead(store, access, vaultKey, entry.name, generation);
        }
      }
      return;
    }
    if (!isVaultNoteName(FullTextSearchService.lastSegmentOf(path))) {
      await store.removeDocuments(vaultKey, path, false, generation);
      return;
    }
    await FullTextSearchService.upsertByRead(store, access, vaultKey, path, generation);
  }

  private static async upsertByRead(store: SearchStore, access: VaultAccess,
    vaultKey: string, path: string, generation: number): Promise<void> {
    const doc: SearchDocWrite | null = FullTextSearchService.readDocWrite(access, path);
    if (doc === null) {
      await store.removeDocuments(vaultKey, path, false, generation);
      return;
    }
    await store.upsertDocument(vaultKey, doc, generation);
  }

  /** 读当前文件生成索引载荷；文件消失/是目录/是符号链接/读失败 → null。 */
  private static readDocWrite(access: VaultAccess, path: string): SearchDocWrite | null {
    const stat: VaultFileStat | null = access.stat(path);
    if (stat === null || stat.isDir || stat.isSymbolicLink) {
      return null;
    }
    const content: string = access.readText(path);
    return {
      path: path,
      title: searchTitleOf(path, content),
      content: content,
      size: stat.size,
      mtimeSec: stat.mtimeSec,
      contentHash: contentHashOf(content)
    };
  }

  /* --------------------------------------------------------------------- */
  /* 建库与对账（40.1 / 设计说明 §5）                                       */
  /* --------------------------------------------------------------------- */

  private static ensureBuilt(store: SearchStore, registry: SearchVaultRegistry,
    vaultKey: string, vaultId: string, onProgress: ProgressListener): Promise<void> {
    const inflight: Promise<void> | undefined = FullTextSearchService.buildInFlight.get(vaultKey);
    FullTextSearchService.addProgressListener(vaultKey, onProgress);
    if (inflight !== undefined) {
      return inflight;
    }
    const task: Promise<void> = FullTextSearchService.runBuild(store, registry, vaultKey, vaultId);
    FullTextSearchService.buildInFlight.set(vaultKey, task);
    const release = (): void => {
      FullTextSearchService.buildInFlight.delete(vaultKey);
      FullTextSearchService.progressListeners.delete(vaultKey);
      FullTextSearchService.progressState.delete(vaultKey);
    };
    task.then(release, release);
    return task;
  }

  private static async runBuild(store: SearchStore, registry: SearchVaultRegistry,
    vaultKey: string, vaultId: string): Promise<void> {
    const access: VaultAccess = registry.accessFor(vaultId);
    const report: VaultSnapshotReport = access.snapshotReport();
    if (report.failed) {
      throw new Error('扫描库失败');
    }
    const state: SearchVaultRow | null = await store.getVaultState(vaultKey);
    const startGeneration: number = state === null ? 0 : state.scanGeneration;
    const notes: string[] = [];
    for (let i = 0; i < report.entries.length; i++) {
      const entry: VaultDirChild = report.entries[i];
      if (!entry.isDir && isVaultNoteName(entry.name)) {
        notes.push(entry.name);
      }
    }
    FullTextSearchService.notifyProgress(vaultKey, 0, notes.length);
    let completed: number = 0;
    for (let i = 0; i < notes.length; i++) {
      if (FullTextSearchService.discardedKeys.has(vaultKey)) {
        throw new Error('索引初始化已取消');
      }
      const notePath: string = notes[i];
      let doc: SearchDocWrite | null = null;
      try {
        doc = FullTextSearchService.readDocWrite(access, notePath);
      } catch (error) {
        doc = null; // 单文件不可读：跳过（设计说明 §5），其余照常。
      }
      if (doc !== null) {
        await store.upsertDocument(vaultKey, doc, startGeneration);
      }
      completed++;
      FullTextSearchService.notifyProgress(vaultKey, completed, notes.length);
      if (completed % FullTextSearchService.FILES_PER_BATCH === 0) {
        await FullTextSearchService.yieldToMainThread();
      }
    }
    await store.markVaultInitialized(vaultKey);
    // 建库即对账：本轮逐文件读过正文，直接记对账时间，避免紧接着再全量读一遍。
    await store.markVaultReconciled(vaultKey);
    FullTextSearchService.reconciledKeys.add(vaultKey);
  }

  private static ensureReconciled(store: SearchStore, registry: SearchVaultRegistry,
    vaultKey: string, vaultId: string, onProgress: ProgressListener): Promise<void> {
    const inflight: Promise<void> | undefined = FullTextSearchService.reconcileInFlight.get(vaultKey);
    FullTextSearchService.addProgressListener(vaultKey, onProgress);
    if (inflight !== undefined) {
      return inflight;
    }
    const task: Promise<void> = FullTextSearchService.runReconcile(store, registry, vaultKey, vaultId);
    FullTextSearchService.reconcileInFlight.set(vaultKey, task);
    const release = (): void => {
      FullTextSearchService.reconcileInFlight.delete(vaultKey);
      FullTextSearchService.progressListeners.delete(vaultKey);
      FullTextSearchService.progressState.delete(vaultKey);
    };
    task.then(release, release);
    return task;
  }

  /**
   * 完整 hash 对账（每库每进程首次使用，设计说明 §5）：
   * - 索引行 ↔ 当前文件逐条比对：内容变了重索引；
   * - 文件消失且快照列举完整 → 删索引行；列举被截断时不下「消失」结论（40.8）；
   * - 快照里有而索引没有的笔记（外部新增）→ 补索引。
   */
  private static async runReconcile(store: SearchStore, registry: SearchVaultRegistry,
    vaultKey: string, vaultId: string): Promise<void> {
    const access: VaultAccess = registry.accessFor(vaultId);
    const report: VaultSnapshotReport = access.snapshotReport();
    if (report.failed) {
      throw new Error('扫描库失败');
    }
    const state: SearchVaultRow | null = await store.getVaultState(vaultKey);
    const startGeneration: number = state === null ? 0 : state.scanGeneration;
    const docs: SearchDocRow[] = await store.listDocuments(vaultKey);
    const indexedPaths: Set<string> = new Set<string>();
    for (let i = 0; i < docs.length; i++) {
      indexedPaths.add(docs[i].path);
    }
    const newNotes: string[] = [];
    for (let i = 0; i < report.entries.length; i++) {
      const entry: VaultDirChild = report.entries[i];
      if (!entry.isDir && isVaultNoteName(entry.name) && !indexedPaths.has(entry.name)) {
        newNotes.push(entry.name);
      }
    }
    const total: number = docs.length + newNotes.length;
    FullTextSearchService.notifyProgress(vaultKey, 0, total);
    let completed: number = 0;
    for (let i = 0; i < docs.length; i++) {
      if (FullTextSearchService.discardedKeys.has(vaultKey)) {
        throw new Error('索引对账已取消');
      }
      const doc: SearchDocRow = docs[i];
      let current: SearchDocWrite | null = null;
      let readFailed: boolean = false;
      try {
        current = FullTextSearchService.readDocWrite(access, doc.path);
      } catch (error) {
        readFailed = true; // 读失败的文件保持原索引行，等待下次对账。
      }
      if (current !== null) {
        if (current.contentHash !== doc.contentHash) {
          await store.upsertDocument(vaultKey, current, startGeneration);
        }
      } else if (!readFailed && !report.truncated) {
        await store.removeDocuments(vaultKey, doc.path, false, startGeneration);
      }
      completed++;
      FullTextSearchService.notifyProgress(vaultKey, completed, total);
      if (completed % FullTextSearchService.FILES_PER_BATCH === 0) {
        await FullTextSearchService.yieldToMainThread();
      }
    }
    for (let i = 0; i < newNotes.length; i++) {
      if (FullTextSearchService.discardedKeys.has(vaultKey)) {
        throw new Error('索引对账已取消');
      }
      const doc: SearchDocWrite | null = FullTextSearchService.readDocWrite(access, newNotes[i]);
      if (doc !== null) {
        await store.upsertDocument(vaultKey, doc, startGeneration);
      }
      completed++;
      FullTextSearchService.notifyProgress(vaultKey, completed, total);
      if (completed % FullTextSearchService.FILES_PER_BATCH === 0) {
        await FullTextSearchService.yieldToMainThread();
      }
    }
    await store.markVaultReconciled(vaultKey);
    FullTextSearchService.reconciledKeys.add(vaultKey);
  }

  /* --------------------------------------------------------------------- */
  /* 查询与结果                                                             */
  /* --------------------------------------------------------------------- */

  /** FTS 候选 → 重读当前文件核对并生成摘录（与 v1.1 同口径；滞后候选跳过）。 */
  private static buildResults(registry: SearchVaultRegistry, vaultId: string, query: string,
    candidates: SearchCandidate[]): FullTextSearchResult[] {
    const results: FullTextSearchResult[] = [];
    const normalized: string = query.trim().toLowerCase();
    if (normalized.length === 0) {
      return results;
    }
    let access: VaultAccess | null = null;
    try {
      access = registry.accessFor(vaultId);
    } catch (error) {
      access = null;
    }
    if (access === null) {
      return results;
    }
    for (let i = 0; i < candidates.length; i++) {
      const candidate: SearchCandidate = candidates[i];
      let content: string | null = null;
      try {
        content = access.readText(candidate.path);
      } catch (error) {
        content = null;
      }
      if (content === null) {
        continue;
      }
      const matchAt: number = content.toLowerCase().indexOf(normalized);
      if (matchAt < 0) {
        continue;
      }
      results.push({ path: candidate.path, excerpt: excerptOf(content, matchAt, normalized.length) });
    }
    return results;
  }

  private static outcomeReady(state: SearchVaultRow | null, vaultKey: string,
    results: FullTextSearchResult[]): SearchOutcome {
    const reconciled: boolean = FullTextSearchService.reconciledKeys.has(vaultKey);
    return {
      results: results,
      indexState: 'ready',
      indexComplete: reconciled && !FullTextSearchService.pendingDirty.has(vaultKey),
      reconciledAt: state === null ? 0 : state.lastReconciledAt
    };
  }

  /* --------------------------------------------------------------------- */
  /* 内部工具                                                               */
  /* --------------------------------------------------------------------- */

  private static vaultIdOfKey(registry: SearchVaultRegistry, vaultKey: string): string {
    const entries: VaultEntry[] = registry.list();
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].vaultKey === vaultKey) {
        return entries[i].id;
      }
    }
    return '';
  }

  private static lastSegmentOf(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private static notifyProgress(vaultKey: string, completed: number, total: number): void {
    const snapshot: ProgressSnapshot = { completed: completed, total: total };
    FullTextSearchService.progressState.set(vaultKey, snapshot);
    const listeners: ProgressListener[] | undefined =
      FullTextSearchService.progressListeners.get(vaultKey);
    if (listeners === undefined) {
      return;
    }
    for (let i = 0; i < listeners.length; i++) {
      listeners[i](completed, total);
    }
  }

  private static addProgressListener(vaultKey: string, listener: ProgressListener): void {
    let listeners: ProgressListener[] | undefined =
      FullTextSearchService.progressListeners.get(vaultKey);
    if (listeners === undefined) {
      listeners = [];
      FullTextSearchService.progressListeners.set(vaultKey, listeners);
    }
    listeners.push(listener);
    const snapshot: ProgressSnapshot | undefined = FullTextSearchService.progressState.get(vaultKey);
    if (snapshot !== undefined) {
      listener(snapshot.completed, snapshot.total);
    } else {
      listener(0, 0);
    }
  }

  private static yieldToMainThread(): Promise<void> {
    return new Promise<void>((resolve: (value: void) => void): void => {
      setTimeout((): void => {
        resolve(undefined);
      }, 0);
    });
  }
}
