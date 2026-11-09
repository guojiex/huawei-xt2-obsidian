/**
 * SearchStoreDevice.ets —— SearchStore 的设备侧实现：relationalStore + FTS5 自定义分词
 * （v1.40 · 40.1，设计说明 §2/§3；鸿蒙侧事实见 api_notes.md AC 组）。
 *
 * 关键决策：
 * - search.db 用系统 RDB：StoreConfig 开 encrypt + tokenizer=CUSTOM_TOKENIZER（API17+ 字段，
 *   API24 可用），FTS5 表以 `tokenize='customtokenizer cut_mode short_words'` 建表（AC2）。
 * - **没有分词回退链**（设计说明 §3）：isTokenizerSupported 为 false 或 FTS 建表失败时
 *   supportsTokenizer()=false，queryContent 抛错 → 上层报「正文搜索暂不可用」，
 *   不退化为单字/子串索引，也不伪造零结果。
 * - schema 版本与分词配置版本存 search_meta；任一不符 → 整库清空重建（AC2 官方口径）。
 * - 写操作经单条 Promise 链串行，配合同步 beginTransaction/commit/rollBack 保证
 *   「文档行 + FTS 行 + pending 行」要么全成要么全回滚（async Transaction 接口没有
 *   executeSql/querySql，做不了 FTS5 MATCH 与按 doc_id 的联动删除，故用同步事务）。
 * - 路径删除不走 SQL LIKE（SQLite LIKE 默认 ASCII 不区分大小写，会误删仅大小写不同的
 *   路径），而是「查出候选 → ArkTS 里精确/前缀匹配 → 按 doc_id 删」。
 * - 隐私：日志只打错误码与表级事件，绝不打查询词、路径、标题或正文（硬约束 16）。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  SearchCandidate,
  SearchDocRow,
  SearchDocWrite,
  SearchPendingRow,
  SearchStore,
  SearchVaultRow
} from './SearchStore';

const STORE_DOMAIN: number = 0x0000;
const STORE_TAG: string = 'SearchStoreDevice';

const DB_NAME: string = 'search.db';
const SCHEMA_VERSION: string = '1';
const TOKENIZER_ID: string = 'customtokenizer-cut_mode-short_words';
const META_UNAVAILABLE: string = 'unavailable';

const SQL_CREATE_META: string =
  'CREATE TABLE IF NOT EXISTS search_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)';
const SQL_CREATE_VAULTS: string =
  'CREATE TABLE IF NOT EXISTS search_vaults (vault_key TEXT PRIMARY KEY, ' +
  'initialized INTEGER NOT NULL DEFAULT 0, last_reconciled_at INTEGER NOT NULL DEFAULT 0, ' +
  'scan_generation INTEGER NOT NULL DEFAULT 0)';
const SQL_CREATE_DOCUMENTS: string =
  'CREATE TABLE IF NOT EXISTS search_documents (doc_id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
  'vault_key TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, ' +
  'mtime_sec INTEGER NOT NULL, content_hash TEXT NOT NULL, generation INTEGER NOT NULL, ' +
  'UNIQUE (vault_key, path))';
const SQL_CREATE_PENDING: string =
  'CREATE TABLE IF NOT EXISTS search_pending (vault_key TEXT NOT NULL, path TEXT NOT NULL, ' +
  'generation INTEGER NOT NULL, PRIMARY KEY (vault_key, path))';
const SQL_CREATE_FTS: string =
  "CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(title, body, " +
  "tokenize='customtokenizer cut_mode short_words')";

class RelationalSearchStore implements SearchStore {
  private context: common.UIAbilityContext;
  private db: relationalStore.RdbStore | null = null;
  private tokenizerUsable: boolean = false;
  private initPromise: Promise<void> | null = null;
  private writeChain: Promise<void> = Promise.resolve();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  init(): Promise<void> {
    if (this.initPromise === null) {
      this.initPromise = this.doInit();
      this.initPromise.catch((): void => {
        // 保留拒绝态：本进程内搜索一律报错，重启后重试。
      });
    }
    return this.initPromise;
  }

  supportsTokenizer(): boolean {
    return this.tokenizerUsable;
  }

  async getVaultState(vaultKey: string): Promise<SearchVaultRow | null> {
    const rs: relationalStore.ResultSet = await this.requireDb().querySql(
      'SELECT initialized, last_reconciled_at, scan_generation FROM search_vaults WHERE vault_key = ?',
      [vaultKey]);
    let row: SearchVaultRow | null = null;
    if (rs.goToNextRow()) {
      row = {
        initialized: rs.getLong(0) !== 0,
        lastReconciledAt: rs.getLong(1),
        scanGeneration: rs.getLong(2)
      };
    }
    rs.close();
    return row;
  }

  async listDocuments(vaultKey: string): Promise<SearchDocRow[]> {
    const rs: relationalStore.ResultSet = await this.requireDb().querySql(
      'SELECT path, size, mtime_sec, content_hash, generation FROM search_documents ' +
      'WHERE vault_key = ? ORDER BY path', [vaultKey]);
    const rows: SearchDocRow[] = [];
    while (rs.goToNextRow()) {
      rows.push({
        path: rs.getString(0),
        size: rs.getLong(1),
        mtimeSec: rs.getLong(2),
        contentHash: rs.getString(3),
        generation: rs.getLong(4)
      });
    }
    rs.close();
    return rows;
  }

  async queryContent(vaultKey: string, query: string, limit: number): Promise<SearchCandidate[]> {
    if (!this.tokenizerUsable || this.db === null) {
      throw new Error('SEARCH_STORE_UNAVAILABLE');
    }
    // 用户输入整体作为 FTS5 引号短语：杜绝把 AND/OR/NEAR/括号当查询语法解析。
    // 引号本身替换成空格（引号内不允许再出现引号）；全为空白时短语无 token，直接空结果。
    const sanitized: string = query.split('"').join(' ');
    if (sanitized.trim().length === 0) {
      return [];
    }
    const phrase: string = '"' + sanitized + '"';
    const rs: relationalStore.ResultSet = await this.db.querySql(
      'SELECT d.path, d.content_hash FROM search_fts JOIN search_documents d ' +
      'ON d.doc_id = search_fts.rowid WHERE search_fts MATCH ? AND d.vault_key = ? ' +
      'ORDER BY d.path LIMIT ?', [phrase, vaultKey, limit]);
    const candidates: SearchCandidate[] = [];
    while (rs.goToNextRow()) {
      candidates.push({ path: rs.getString(0), contentHash: rs.getString(1) });
    }
    rs.close();
    return candidates;
  }

  setPending(vaultKey: string, paths: string[]): Promise<void> {
    return this.enqueue((): Promise<void> => this.setPendingLocked(vaultKey, paths));
  }

  takePending(vaultKey: string): Promise<SearchPendingRow[]> {
    return this.requireDb().querySql(
      'SELECT path, generation FROM search_pending WHERE vault_key = ? ORDER BY generation, path',
      [vaultKey]).then((rs: relationalStore.ResultSet): SearchPendingRow[] => {
      const rows: SearchPendingRow[] = [];
      while (rs.goToNextRow()) {
        rows.push({ path: rs.getString(0), generation: rs.getLong(1) });
      }
      rs.close();
      return rows;
    });
  }

  dropPending(vaultKey: string, path: string, taskGeneration: number): Promise<void> {
    return this.enqueue((): Promise<void> => {
      return this.requireDb().executeSql(
        'DELETE FROM search_pending WHERE vault_key = ? AND path = ? AND generation <= ?',
        [vaultKey, path, taskGeneration]);
    });
  }

  upsertDocument(vaultKey: string, doc: SearchDocWrite, taskGeneration: number): Promise<void> {
    return this.enqueue((): Promise<void> => this.upsertDocumentLocked(vaultKey, doc, taskGeneration));
  }

  removeDocuments(vaultKey: string, path: string, isDirectory: boolean, taskGeneration: number): Promise<void> {
    return this.enqueue((): Promise<void> =>
      this.removeDocumentsLocked(vaultKey, path, isDirectory, taskGeneration));
  }

  markVaultInitialized(vaultKey: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.markVaultLocked(vaultKey, true));
  }

  markVaultReconciled(vaultKey: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.markVaultLocked(vaultKey, false));
  }

  clearVault(vaultKey: string): Promise<void> {
    return this.enqueue((): Promise<void> => this.clearVaultLocked(vaultKey));
  }

  async listVaultKeys(): Promise<string[]> {
    const rs: relationalStore.ResultSet = await this.requireDb().querySql(
      'SELECT vault_key FROM search_vaults');
    const keys: string[] = [];
    while (rs.goToNextRow()) {
      keys.push(rs.getString(0));
    }
    rs.close();
    return keys;
  }

  /* --------------------------------------------------------------------- */
  /* 初始化与 schema                                                        */
  /* --------------------------------------------------------------------- */

  private async doInit(): Promise<void> {
    if (!relationalStore.isTokenizerSupported(relationalStore.Tokenizer.CUSTOM_TOKENIZER)) {
      // 无回退链：分词不可用即整体不可用（名称搜索不经本存储，不受影响）。
      this.tokenizerUsable = false;
      return;
    }
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
      encrypt: true,
      tokenizer: relationalStore.Tokenizer.CUSTOM_TOKENIZER
    };
    const db: relationalStore.RdbStore = await relationalStore.getRdbStore(this.context, config);
    await this.ensureSchema(db);
    this.db = db;
  }

  private async ensureSchema(db: relationalStore.RdbStore): Promise<void> {
    const meta: Map<string, string> = await this.readMeta(db);
    const stale: boolean = meta.size > 0 &&
      (meta.get('schema_version') !== SCHEMA_VERSION || meta.get('tokenizer') !== TOKENIZER_ID);
    if (stale) {
      await db.executeSql('DROP TABLE IF EXISTS search_fts');
      await db.executeSql('DROP TABLE IF EXISTS search_documents');
      await db.executeSql('DROP TABLE IF EXISTS search_pending');
      await db.executeSql('DROP TABLE IF EXISTS search_vaults');
      await db.executeSql('DROP TABLE IF EXISTS search_meta');
      hilog.info(STORE_DOMAIN, STORE_TAG, '%{public}s', 'schema 或分词配置版本变化，搜索索引整库重建');
    }
    await db.executeSql(SQL_CREATE_META);
    await db.executeSql(SQL_CREATE_VAULTS);
    await db.executeSql(SQL_CREATE_DOCUMENTS);
    await db.executeSql(SQL_CREATE_PENDING);
    let ftsOk: boolean = false;
    try {
      await db.executeSql(SQL_CREATE_FTS);
      ftsOk = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(STORE_DOMAIN, STORE_TAG, 'FTS5 建表失败，正文搜索降级为不可用 code=%{public}d', err.code);
      ftsOk = false;
    }
    this.tokenizerUsable = ftsOk;
    await db.executeSql('INSERT OR REPLACE INTO search_meta (key, value) VALUES (?, ?)',
      ['schema_version', SCHEMA_VERSION]);
    await db.executeSql('INSERT OR REPLACE INTO search_meta (key, value) VALUES (?, ?)',
      ['tokenizer', ftsOk ? TOKENIZER_ID : META_UNAVAILABLE]);
  }

  private async readMeta(db: relationalStore.RdbStore): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    try {
      const rs: relationalStore.ResultSet = await db.querySql('SELECT key, value FROM search_meta');
      while (rs.goToNextRow()) {
        out.set(rs.getString(0), rs.getString(1));
      }
      rs.close();
    } catch (error) {
      // 首次建库：search_meta 尚不存在。
    }
    return out;
  }

  /* --------------------------------------------------------------------- */
  /* 串行写实现                                                             */
  /* --------------------------------------------------------------------- */

  private async setPendingLocked(vaultKey: string, paths: string[]): Promise<void> {
    if (paths.length === 0) {
      return;
    }
    const db: relationalStore.RdbStore = this.requireDb();
    db.beginTransaction();
    try {
      await db.executeSql(
        'INSERT OR IGNORE INTO search_vaults (vault_key, initialized, last_reconciled_at, scan_generation) ' +
        'VALUES (?, 0, 0, 0)', [vaultKey]);
      await db.executeSql(
        'UPDATE search_vaults SET scan_generation = scan_generation + 1 WHERE vault_key = ?', [vaultKey]);
      const rs: relationalStore.ResultSet = await db.querySql(
        'SELECT scan_generation FROM search_vaults WHERE vault_key = ?', [vaultKey]);
      let generation: number = 0;
      if (rs.goToNextRow()) {
        generation = rs.getLong(0);
      }
      rs.close();
      for (let i = 0; i < paths.length; i++) {
        await db.executeSql(
          'INSERT OR REPLACE INTO search_pending (vault_key, path, generation) VALUES (?, ?, ?)',
          [vaultKey, paths[i], generation]);
      }
      db.commit();
    } catch (error) {
      db.rollBack();
      throw error instanceof Error ? error : new Error('登记索引任务失败');
    }
  }

  private async upsertDocumentLocked(vaultKey: string, doc: SearchDocWrite,
    taskGeneration: number): Promise<void> {
    const db: relationalStore.RdbStore = this.requireDb();
    db.beginTransaction();
    try {
      const rs: relationalStore.ResultSet = await db.querySql(
        'SELECT generation FROM search_documents WHERE vault_key = ? AND path = ?',
        [vaultKey, doc.path]);
      let existingGeneration: number = -1;
      if (rs.goToNextRow()) {
        existingGeneration = rs.getLong(0);
      }
      rs.close();
      if (existingGeneration > taskGeneration) {
        // 40.4：旧任务不覆盖新结果；pending 只删不比任务新的行。
        db.commit();
        return;
      }
      await db.executeSql(
        'DELETE FROM search_fts WHERE rowid IN ' +
        '(SELECT doc_id FROM search_documents WHERE vault_key = ? AND path = ?)',
        [vaultKey, doc.path]);
      await db.executeSql('DELETE FROM search_documents WHERE vault_key = ? AND path = ?',
        [vaultKey, doc.path]);
      const bucket: relationalStore.ValuesBucket = {
        'vault_key': vaultKey,
        'path': doc.path,
        'size': doc.size,
        'mtime_sec': doc.mtimeSec,
        'content_hash': doc.contentHash,
        'generation': taskGeneration
      };
      const rowId: number = await db.insert('search_documents', bucket);
      if (rowId < 0) {
        throw new Error('写入索引文档行失败');
      }
      await db.executeSql('INSERT INTO search_fts (rowid, title, body) VALUES (?, ?, ?)',
        [rowId, doc.title, doc.content]);
      await db.executeSql(
        'DELETE FROM search_pending WHERE vault_key = ? AND path = ? AND generation <= ?',
        [vaultKey, doc.path, taskGeneration]);
      db.commit();
    } catch (error) {
      db.rollBack();
      throw error instanceof Error ? error : new Error('写入搜索索引失败');
    }
  }

  private async removeDocumentsLocked(vaultKey: string, path: string, isDirectory: boolean,
    taskGeneration: number): Promise<void> {
    const db: relationalStore.RdbStore = this.requireDb();
    db.beginTransaction();
    try {
      const rs: relationalStore.ResultSet = await db.querySql(
        'SELECT doc_id, path, generation FROM search_documents WHERE vault_key = ?', [vaultKey]);
      const docIds: number[] = [];
      while (rs.goToNextRow()) {
        const candidate: string = rs.getString(1);
        if (rs.getLong(2) <= taskGeneration &&
          RelationalSearchStore.pathMatches(candidate, path, isDirectory)) {
          docIds.push(rs.getLong(0));
        }
      }
      rs.close();
      for (let i = 0; i < docIds.length; i++) {
        await db.executeSql('DELETE FROM search_fts WHERE rowid = ?', [docIds[i]]);
        await db.executeSql('DELETE FROM search_documents WHERE doc_id = ?', [docIds[i]]);
      }
      const pending: relationalStore.ResultSet = await db.querySql(
        'SELECT path, generation FROM search_pending WHERE vault_key = ?', [vaultKey]);
      const pendingPaths: string[] = [];
      while (pending.goToNextRow()) {
        const candidate: string = pending.getString(0);
        if (pending.getLong(1) <= taskGeneration &&
          RelationalSearchStore.pathMatches(candidate, path, isDirectory)) {
          pendingPaths.push(candidate);
        }
      }
      pending.close();
      for (let i = 0; i < pendingPaths.length; i++) {
        await db.executeSql('DELETE FROM search_pending WHERE vault_key = ? AND path = ?',
          [vaultKey, pendingPaths[i]]);
      }
      db.commit();
    } catch (error) {
      db.rollBack();
      throw error instanceof Error ? error : new Error('清理搜索索引失败');
    }
  }

  private async markVaultLocked(vaultKey: string, initialized: boolean): Promise<void> {
    const db: relationalStore.RdbStore = this.requireDb();
    db.beginTransaction();
    try {
      await db.executeSql(
        'INSERT OR IGNORE INTO search_vaults (vault_key, initialized, last_reconciled_at, scan_generation) ' +
        'VALUES (?, 0, 0, 0)', [vaultKey]);
      if (initialized) {
        await db.executeSql('UPDATE search_vaults SET initialized = 1 WHERE vault_key = ?', [vaultKey]);
      } else {
        await db.executeSql('UPDATE search_vaults SET last_reconciled_at = ? WHERE vault_key = ?',
          [Date.now(), vaultKey]);
      }
      db.commit();
    } catch (error) {
      db.rollBack();
      throw error instanceof Error ? error : new Error('更新索引库状态失败');
    }
  }

  private async clearVaultLocked(vaultKey: string): Promise<void> {
    const db: relationalStore.RdbStore = this.requireDb();
    db.beginTransaction();
    try {
      await db.executeSql(
        'DELETE FROM search_fts WHERE rowid IN (SELECT doc_id FROM search_documents WHERE vault_key = ?)',
        [vaultKey]);
      await db.executeSql('DELETE FROM search_documents WHERE vault_key = ?', [vaultKey]);
      await db.executeSql('DELETE FROM search_pending WHERE vault_key = ?', [vaultKey]);
      await db.executeSql('DELETE FROM search_vaults WHERE vault_key = ?', [vaultKey]);
      db.commit();
    } catch (error) {
      db.rollBack();
      throw error instanceof Error ? error : new Error('清理库索引失败');
    }
  }

  /* --------------------------------------------------------------------- */
  /* 内部工具                                                               */
  /* --------------------------------------------------------------------- */

  private requireDb(): relationalStore.RdbStore {
    if (this.db === null) {
      throw new Error('SEARCH_STORE_UNAVAILABLE');
    }
    return this.db;
  }

  /** 写操作串行：同步事务期间穿插 await，必须保证同一时刻只有一条写链在跑。 */
  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.writeChain.then(operation);
    this.writeChain = result.then((): void => {}, (): void => {});
    return result;
  }

  /** 精确 / 目录前缀匹配（大小写敏感；与 LIKE 不同，不会误删仅大小写不同的路径）。 */
  private static pathMatches(candidate: string, target: string, isDirectory: boolean): boolean {
    if (candidate === target) {
      return true;
    }
    return isDirectory && candidate.startsWith(target + '/');
  }
}

/** 设备侧工厂：EntryAbility 里与 FullTextSearchService.configure 配对使用。 */
export function createSearchStore(context: common.UIAbilityContext): SearchStore {
  return new RelationalSearchStore(context);
}
