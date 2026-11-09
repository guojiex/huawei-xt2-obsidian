import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium';
import { FullTextSearchService } from '../main/ets/model/FullTextSearchService';
import {
  SearchCandidate,
  SearchDocRow,
  SearchDocWrite,
  SearchOutcome,
  SearchPendingRow,
  SearchStore,
  SearchVaultRegistry,
  SearchVaultRow
} from '../main/ets/model/SearchStore';
import {
  VaultAccess,
  VaultAccessKind,
  VaultBinaryImportSource,
  VaultDirChild,
  VaultFileStat,
  VaultSnapshotReport
} from '../main/ets/model/VaultAccess';
import { VaultEntry } from '../main/ets/model/Vault';

/** 内存版存储：语义对齐 SearchStoreDevice（代次守卫、INSERT OR REPLACE pending、前缀删除）。 */
interface StoredDoc {
  size: number;
  mtimeSec: number;
  contentHash: string;
  generation: number;
  title: string;
  content: string;
}

class MemorySearchStore implements SearchStore {
  private vaults: Map<string, SearchVaultRow> = new Map<string, SearchVaultRow>();
  private docs: Map<string, Map<string, StoredDoc>> = new Map<string, Map<string, StoredDoc>>();
  private pending: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();

  async init(): Promise<void> {
  }

  supportsTokenizer(): boolean {
    return true;
  }

  async getVaultState(vaultKey: string): Promise<SearchVaultRow | null> {
    return this.vaults.get(vaultKey) ?? null;
  }

  async listDocuments(vaultKey: string): Promise<SearchDocRow[]> {
    const byPath: Map<string, StoredDoc> | undefined = this.docs.get(vaultKey);
    const rows: SearchDocRow[] = [];
    if (byPath !== undefined) {
      for (const path of Array.from(byPath.keys()).sort()) {
        const doc: StoredDoc = byPath.get(path) as StoredDoc;
        rows.push({
          path: path,
          size: doc.size,
          mtimeSec: doc.mtimeSec,
          contentHash: doc.contentHash,
          generation: doc.generation
        });
      }
    }
    return rows;
  }

  async queryContent(vaultKey: string, query: string, limit: number): Promise<SearchCandidate[]> {
    const byPath: Map<string, StoredDoc> | undefined = this.docs.get(vaultKey);
    const out: SearchCandidate[] = [];
    if (byPath === undefined) {
      return out;
    }
    const normalized: string = query.toLowerCase();
    for (const path of Array.from(byPath.keys()).sort()) {
      if (out.length >= limit) {
        break;
      }
      const doc: StoredDoc = byPath.get(path) as StoredDoc;
      if (doc.content.toLowerCase().indexOf(normalized) >= 0) {
        out.push({ path: path, contentHash: doc.contentHash });
      }
    }
    return out;
  }

  async setPending(vaultKey: string, paths: string[]): Promise<void> {
    if (paths.length === 0) {
      return;
    }
    this.ensureVaultRow(vaultKey);
    const row: SearchVaultRow = this.vaults.get(vaultKey) as SearchVaultRow;
    row.scanGeneration++;
    let byPath: Map<string, number> | undefined = this.pending.get(vaultKey);
    if (byPath === undefined) {
      byPath = new Map<string, number>();
      this.pending.set(vaultKey, byPath);
    }
    for (let i = 0; i < paths.length; i++) {
      byPath.set(paths[i], row.scanGeneration);
    }
  }

  async takePending(vaultKey: string): Promise<SearchPendingRow[]> {
    const byPath: Map<string, number> | undefined = this.pending.get(vaultKey);
    const rows: SearchPendingRow[] = [];
    if (byPath === undefined) {
      return rows;
    }
    const paths: string[] = Array.from(byPath.keys()).sort((a: string, b: string): number =>
      (byPath.get(a) as number) - (byPath.get(b) as number));
    for (let i = 0; i < paths.length; i++) {
      rows.push({ path: paths[i], generation: byPath.get(paths[i]) as number });
    }
    return rows;
  }

  async dropPending(vaultKey: string, path: string, taskGeneration: number): Promise<void> {
    const byPath: Map<string, number> | undefined = this.pending.get(vaultKey);
    if (byPath === undefined) {
      return;
    }
    const generation: number | undefined = byPath.get(path);
    if (generation !== undefined && generation <= taskGeneration) {
      byPath.delete(path);
    }
  }

  async upsertDocument(vaultKey: string, doc: SearchDocWrite, taskGeneration: number): Promise<void> {
    let byPath: Map<string, StoredDoc> | undefined = this.docs.get(vaultKey);
    if (byPath === undefined) {
      byPath = new Map<string, StoredDoc>();
      this.docs.set(vaultKey, byPath);
    }
    const existing: StoredDoc | undefined = byPath.get(doc.path);
    if (existing !== undefined && existing.generation > taskGeneration) {
      return;
    }
    byPath.set(doc.path, {
      size: doc.size,
      mtimeSec: doc.mtimeSec,
      contentHash: doc.contentHash,
      generation: taskGeneration,
      title: doc.title,
      content: doc.content
    });
    const pendingPaths: Map<string, number> | undefined = this.pending.get(vaultKey);
    const pendingGeneration: number | undefined = pendingPaths?.get(doc.path);
    if (pendingGeneration !== undefined && pendingGeneration <= taskGeneration) {
      pendingPaths?.delete(doc.path);
    }
  }

  async removeDocuments(vaultKey: string, path: string, isDirectory: boolean,
    taskGeneration: number): Promise<void> {
    const byPath: Map<string, StoredDoc> | undefined = this.docs.get(vaultKey);
    if (byPath !== undefined) {
      for (const candidate of Array.from(byPath.keys())) {
        const doc: StoredDoc = byPath.get(candidate) as StoredDoc;
        if (doc.generation <= taskGeneration && MemorySearchStore.pathMatches(candidate, path, isDirectory)) {
          byPath.delete(candidate);
        }
      }
    }
    const pendingPaths: Map<string, number> | undefined = this.pending.get(vaultKey);
    if (pendingPaths !== undefined) {
      for (const candidate of Array.from(pendingPaths.keys())) {
        const generation: number = pendingPaths.get(candidate) as number;
        if (generation <= taskGeneration && MemorySearchStore.pathMatches(candidate, path, isDirectory)) {
          pendingPaths.delete(candidate);
        }
      }
    }
  }

  async markVaultInitialized(vaultKey: string): Promise<void> {
    this.ensureVaultRow(vaultKey);
    (this.vaults.get(vaultKey) as SearchVaultRow).initialized = true;
  }

  async markVaultReconciled(vaultKey: string): Promise<void> {
    this.ensureVaultRow(vaultKey);
    (this.vaults.get(vaultKey) as SearchVaultRow).lastReconciledAt = Date.now();
  }

  async clearVault(vaultKey: string): Promise<void> {
    this.vaults.delete(vaultKey);
    this.docs.delete(vaultKey);
    this.pending.delete(vaultKey);
  }

  async listVaultKeys(): Promise<string[]> {
    const keys: Set<string> = new Set<string>();
    for (const key of Array.from(this.vaults.keys())) {
      keys.add(key);
    }
    for (const key of Array.from(this.docs.keys())) {
      keys.add(key);
    }
    for (const key of Array.from(this.pending.keys())) {
      keys.add(key);
    }
    return Array.from(keys);
  }

  private ensureVaultRow(vaultKey: string): void {
    if (!this.vaults.has(vaultKey)) {
      this.vaults.set(vaultKey, { initialized: false, lastReconciledAt: 0, scanGeneration: 0 });
    }
  }

  private static pathMatches(candidate: string, target: string, isDirectory: boolean): boolean {
    if (candidate === target) {
      return true;
    }
    return isDirectory && candidate.startsWith(target + '/');
  }
}

/** 文件真源替身：relPath → 正文。 */
class SearchTestAccess implements VaultAccess {
  readonly kind: VaultAccessKind = 'sandbox';
  private files: Map<string, string>;

  constructor(files: Map<string, string>) {
    this.files = files;
  }

  snapshot(): VaultDirChild[] {
    return this.snapshotReport().entries;
  }

  snapshotReport(): VaultSnapshotReport {
    const entries: VaultDirChild[] = [];
    for (const path of Array.from(this.files.keys()).sort()) {
      entries.push({ name: path, isDir: false });
    }
    return { entries: entries, truncated: false, failed: false };
  }

  listAll(relDir: string, includeHidden?: boolean): VaultDirChild[] {
    throw new Error('listAll 不在搜索服务测试范围');
  }

  listDir(relDir: string): VaultDirChild[] {
    throw new Error('listDir 不在搜索服务测试范围');
  }

  allDirs(): string[] {
    throw new Error('allDirs 不在搜索服务测试范围');
  }

  allNotes(): string[] {
    throw new Error('allNotes 不在搜索服务测试范围');
  }

  exists(relPath: string): boolean {
    return this.stat(relPath) !== null;
  }

  stat(relPath: string): VaultFileStat | null {
    const content: string | undefined = this.files.get(relPath);
    if (content === undefined) {
      return null;
    }
    return { size: content.length, mtimeSec: 1, isDir: false, isSymbolicLink: false };
  }

  readText(relPath: string): string {
    const content: string | undefined = this.files.get(relPath);
    if (content === undefined) {
      throw new Error('测试文件不存在');
    }
    return content;
  }

  readBytes(relPath: string): Uint8Array {
    throw new Error('readBytes 不在搜索服务测试范围');
  }

  writeNewBinary(relPath: string, source: VaultBinaryImportSource): Promise<void> {
    throw new Error('writeNewBinary 不在搜索服务测试范围');
  }

  createEmptyNote(relPath: string): void {
    throw new Error('createEmptyNote 不在搜索服务测试范围');
  }

  ensureDir(relDir: string): void {
    throw new Error('ensureDir 不在搜索服务测试范围');
  }

  writeAtomic(relPath: string, content: string): Promise<void> {
    throw new Error('writeAtomic 不在搜索服务测试范围');
  }

  remove(relPath: string): void {
    throw new Error('remove 不在搜索服务测试范围');
  }

  removeDir(relPath: string): void {
    throw new Error('removeDir 不在搜索服务测试范围');
  }

  rename(from: string, to: string): void {
    throw new Error('rename 不在搜索服务测试范围');
  }
}

class SearchTestRegistry implements SearchVaultRegistry {
  private vaults: VaultEntry[];
  private vaultKeys: Map<string, string>;
  private filesByVault: Map<string, Map<string, string>>;

  constructor() {
    this.vaults = [];
    this.vaultKeys = new Map<string, string>();
    this.filesByVault = new Map<string, Map<string, string>>();
  }

  /** 每个测试用唯一 vaultKey，避免进程级静态状态跨用例串扰。 */
  addVault(vaultId: string, vaultKey: string): Map<string, string> {
    this.vaultKeys.set(vaultId, vaultKey);
    const files: Map<string, string> = new Map<string, string>();
    this.filesByVault.set(vaultId, files);
    this.vaults.push({
      id: vaultId,
      vaultKey: vaultKey,
      type: 'local',
      createdAt: Date.now()
    });
    return files;
  }

  vaultKeyOf(id: string): string {
    const key: string | undefined = this.vaultKeys.get(id);
    if (key === undefined) {
      throw new Error('未注册的库');
    }
    return key;
  }

  accessFor(id: string): VaultAccess {
    const files: Map<string, string> | undefined = this.filesByVault.get(id);
    if (files === undefined) {
      throw new Error('未注册的库');
    }
    return new SearchTestAccess(files);
  }

  list(): VaultEntry[] {
    return this.vaults;
  }
}

export default function fullTextSearchServiceTest(): void {
  describe('FullTextSearchService persistent-index lifecycle', () => {
    let registry: SearchTestRegistry;

    beforeAll((): void => {
      registry = new SearchTestRegistry();
      FullTextSearchService.configure(new MemorySearchStore(), registry);
    });

    afterEach((): void => {
      const entries: VaultEntry[] = registry.list();
      for (let i = 0; i < entries.length; i++) {
        FullTextSearchService.discardVaultKey(entries[i].vaultKey);
      }
    });

    it('keeps save, rename, delete, and vault switching aligned with source files', 0,
      async (): Promise<void> => {
        const filesA: Map<string, string> = registry.addVault('库一', 'key-lifecycle-a');
        filesA.set('same.md', '原始内容');
        let outcome: SearchOutcome = await FullTextSearchService.searchDetailed(
          registry, '库一', '原始内容', (_completed: number, _total: number): void => {});
        expect(outcome.indexState).assertEqual('ready');
        expect(outcome.results.length).assertEqual(1);
        expect(outcome.results[0].path).assertEqual('same.md');

        filesA.set('same.md', '保存后的内容');
        FullTextSearchService.noteSaved('库一', 'same.md', '保存后的内容');
        outcome = await FullTextSearchService.searchDetailed(registry, '库一', '原始内容',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);
        outcome = await FullTextSearchService.searchDetailed(registry, '库一', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(1);

        filesA.delete('same.md');
        filesA.set('改名.md', '保存后的内容');
        FullTextSearchService.pathRetargeted('库一', 'same.md', '改名.md', false);
        outcome = await FullTextSearchService.searchDetailed(registry, '库一', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(1);
        expect(outcome.results[0].path).assertEqual('改名.md');

        filesA.delete('改名.md');
        FullTextSearchService.noteRemoved('库一', '改名.md', false);
        outcome = await FullTextSearchService.searchDetailed(registry, '库一', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);

        const filesB: Map<string, string> = registry.addVault('库二', 'key-lifecycle-b');
        filesB.set('same.md', '另一个库的隔离词');
        outcome = await FullTextSearchService.searchDetailed(registry, '库二', '隔离词',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(1);
        outcome = await FullTextSearchService.searchDetailed(registry, '库二', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);
        outcome = await FullTextSearchService.searchDetailed(registry, '库一', '隔离词',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);
      });

    it('removes a trashed note from the index and restores it from the source file', 0,
      async (): Promise<void> => {
        const files: Map<string, string> = registry.addVault('恢复库', 'key-restore');
        const path: string = '恢复/文件.md';
        files.set(path, '回收站恢复标记');

        let outcome: SearchOutcome = await FullTextSearchService.searchDetailed(
          registry, '恢复库', '恢复标记', (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(1);

        FullTextSearchService.noteRemoved('恢复库', path, false);
        outcome = await FullTextSearchService.searchDetailed(registry, '恢复库', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);

        files.set(path, '回收站恢复标记');
        FullTextSearchService.noteRestored('恢复库', path);
        outcome = await FullTextSearchService.searchDetailed(registry, '恢复库', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(1);
        expect(outcome.results[0].path).assertEqual(path);

        FullTextSearchService.noteRemoved('恢复库', path, false);
        outcome = await FullTextSearchService.searchDetailed(registry, '恢复库', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(outcome.results.length).assertEqual(0);
      });
  });
}
