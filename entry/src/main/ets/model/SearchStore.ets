/**
 * SearchStore.ets —— v1.40 持久搜索索引的「存储适配器」契约 + 纯工具（40.1 / 设计说明 §3）。
 *
 * 定位与 VaultAccess 同套路：**纯逻辑 + 依赖注入**，零系统依赖，可在 Node 单测里裸跑。
 * 真正的 RDB 实现（relationalStore + FTS5 自定义分词）在 SearchStoreDevice.ets；
 * 编排（何时建库、何时对账、如何消化 pending）在 FullTextSearchService.ets。
 *
 * 关键语义（设计说明 §2 / §5，40.4）：
 * - 五张逻辑表：search_meta（schema 与分词配置版本）/ search_vaults（每库初始化与对账状态、
 *   扫描代次）/ search_documents（路径、大小、mtime、正文 hash、索引代次）/
 *   search_fts（FTS5 标题 + 正文）/ search_pending（待增量任务，不存旧正文）。
 * - **代次由存储方持有**（search_vaults.scan_generation 持久化）：setPending 推进代次，
 *   upsertDocument / removeDocuments 拒绝「现有行的代次 > 任务代次」的写入 ——
 *   这是 40.4「旧任务不得覆盖新结果、不得吞掉更新的 pending」的落点。
 * - 正文 hash 是「实际提交到索引的原文」的指纹，不以 mtime 代替版本（设计说明 §2）。
 */

import { VaultAccess } from './VaultAccess';
import { VaultEntry } from './Vault';
import { noteDisplayName, noteDisplayNameOfPath } from '../common/NoteDisplayName';

/** 单条正文命中（v1.1 起的既有形状；v1.40 起从本文件导出，SearchIndex.ets 已删除）。 */
export interface FullTextSearchResult {
  path: string;
  excerpt: string;
}

/**
 * 索引状态（40.8，调用方据此区分 complete / cached / building / failed）：
 * - 'building'：该库首次初始化（全量建库）进行中；
 * - 'checking'：该库本进程首次使用时的完整 hash 对账进行中；
 * - 'ready'：查询已按当前索引执行；
 * - 'error'：存储或库访问失败 —— **不编造零结果**（40.4）。
 */
export type SearchIndexState = 'building' | 'checking' | 'ready' | 'error';

/** 查询产出：结果 + 索引状态；indexComplete 表示结果来自「已对账且无未消化任务」的索引。 */
export interface SearchOutcome {
  results: FullTextSearchResult[];
  indexState: SearchIndexState;
  indexComplete: boolean;
  reconciledAt: number;
}

/** 查询候选：路径 + 索引时正文 hash（供调用方做新鲜度校验）。 */
export interface SearchCandidate {
  path: string;
  contentHash: string;
}

/** search_documents 单行（对账用）。 */
export interface SearchDocRow {
  path: string;
  size: number;
  mtimeSec: number;
  contentHash: string;
  generation: number;
}

/** 一次索引写入的载荷（title/body 由存储方拆进 FTS 表）。 */
export interface SearchDocWrite {
  path: string;
  title: string;
  content: string;
  size: number;
  mtimeSec: number;
  contentHash: string;
}

/** search_vaults 单行。 */
export interface SearchVaultRow {
  initialized: boolean;
  lastReconciledAt: number;
  scanGeneration: number;
}

/** search_pending 单行。 */
export interface SearchPendingRow {
  path: string;
  generation: number;
}

/**
 * 搜索存储接口。vaultKey 是库的稳定身份（改名不变），与注册表内部一致。
 */
export interface SearchStore {
  /** 打开/建库/校验 schema 与分词版本；版本不符时清空重建。失败 reject（此后查询应报 error）。 */
  init(): Promise<void>;

  /** FTS 自定义分词是否可用；false 时 queryContent 必须抛错而不是返回空结果。 */
  supportsTokenizer(): boolean;

  getVaultState(vaultKey: string): Promise<SearchVaultRow | null>;

  listDocuments(vaultKey: string): Promise<SearchDocRow[]>;

  /** 正文查询：返回按路径排序的候选（截断到 limit）。分词不可用/查询失败时抛错。 */
  queryContent(vaultKey: string, query: string, limit: number): Promise<SearchCandidate[]>;

  /** 登记待增量任务并推进扫描代次；已有同路径任务被新代次覆盖（代次单调增，不会降级）。 */
  setPending(vaultKey: string, paths: string[]): Promise<void>;

  takePending(vaultKey: string): Promise<SearchPendingRow[]>;

  /** 放弃一条任务（连续失败兜底），只删 generation ≤ taskGeneration 的行。 */
  dropPending(vaultKey: string, path: string, taskGeneration: number): Promise<void>;

  /**
   * 写入/覆盖一篇文档；拒绝「现有行 generation > taskGeneration」的旧任务写入，
   * 并删除该路径 generation ≤ taskGeneration 的 pending 行。
   */
  upsertDocument(vaultKey: string, doc: SearchDocWrite, taskGeneration: number): Promise<void>;

  /** 删除一篇或一整棵子树（isDirectory 时含 path 前缀），同样受代次守卫约束。 */
  removeDocuments(vaultKey: string, path: string, isDirectory: boolean, taskGeneration: number): Promise<void>;

  markVaultInitialized(vaultKey: string): Promise<void>;

  markVaultReconciled(vaultKey: string): Promise<void>;

  /** 删除某库全部索引数据（40.9 删库/清理）。 */
  clearVault(vaultKey: string): Promise<void>;

  /** 现存全部 vaultKey（启动孤儿清理用）。 */
  listVaultKeys(): Promise<string[]>;
}

/**
 * FullTextSearchService 对注册表的最小依赖。收窄成接口而不是直接收 VaultRegistry：
 * 服务可以在 Node 单测里配 fake；ArkTS 不认结构化类型（api_notes T9），
 * 所以 VaultRegistry 必须 `implements SearchVaultRegistry`。
 */
export interface SearchVaultRegistry {
  vaultKeyOf(id: string): string;
  accessFor(id: string): VaultAccess;
  list(): VaultEntry[];
}

/**
 * 正文 hash：x31 滚动 hash（32 位）+ 长度，十六进制拼接。
 * 用途仅是「对账时判断是否需要重读重索引」，非密码学；碰撞概率 2^-32 量级，
 * 且叠加长度与真实内容比对兜底（对账差异最终都会重读文件）。
 */
export function contentHashOf(content: string): string {
  let hash: number = 0;
  for (let i = 0; i < content.length; i++) {
    hash = (((hash << 5) - hash) + content.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(16) + ':' + content.length.toString(16);
}

/** 摘录（与 v1.1 行为一致：命中点前 36 后 64，空白折叠，越界加省略号）。 */
export function excerptOf(content: string, matchAt: number, matchLength: number): string {
  const start: number = Math.max(0, matchAt - 36);
  const end: number = Math.min(content.length, matchAt + matchLength + 64);
  const prefix: string = start > 0 ? '…' : '';
  const suffix: string = end < content.length ? '…' : '';
  return prefix + content.substring(start, end).replace(/\s+/g, ' ').trim() + suffix;
}

/** 索引标题：前 20 行内首个 `# ` 一级标题；否则去后缀文件名。 */
export function searchTitleOf(path: string, content: string): string {
  const lines: string[] = content.split('\n');
  const limit: number = lines.length < 20 ? lines.length : 20;
  for (let i = 0; i < limit; i++) {
    const line: string = lines[i].trim();
    if (line.startsWith('# ')) {
      const title: string = line.substring(2).trim();
      if (title.length > 0) {
        return title;
      }
    }
  }
  const slash: number = path.lastIndexOf('/');
  const name: string = slash >= 0 ? path.substring(slash + 1) : path;
  return noteDisplayName(name);
}
