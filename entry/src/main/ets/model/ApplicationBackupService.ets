/**
 * ApplicationBackupService.ets — v1.66 app-wide backup and transactional restore.
 * The archive contains only explicitly selected sandbox data and inventoried Preferences stores.
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import fileIo from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { atomicWriteText } from '../common/AtomicWrite';
import { VaultEntry } from './Vault';
import { VaultRegistry } from './VaultRegistry';
import { VaultPathResolver } from './VaultPathResolver';
import { AgentMemoryStore } from './AgentMemoryStore';
import { AgentRuntime } from './AgentRuntime';
import { FullTextSearchService } from './FullTextSearchService';
import { GitCredentialStore } from '../git/GitCredentialStore';
import {
  InflatePort, ZipImportError, ZipParsed, ZipParsedEntry, ZipPickResult, ZipWriterPort, ZipImportService
} from './ZipImportService';
import { DeviceZipPicker, StagingZipReader, ZlibRawInflate, copyPickerZipToStaging, freeBytesUnder } from './ZipImportDevice';

const APP_BACKUP_FORMAT: string = 'yaoshi-application-backup';
const APP_BACKUP_SCHEMA_VERSION: number = 1;
const BACKUP_MANIFEST_FILE: string = 'manifest.json';
const BACKUP_PREFERENCES_DIR: string = 'preferences';
const LEGACY_GIT_PREFERENCES: string = 'git_sync';
const APPLICATION_PREFERENCE_STORES: string[] = [
  'vault_registry',
  'editor_preferences',
  'pane_layout',
  'file_tree_state',
  'recent_open_state',
  'workspace_session',
  'screensaver_preferences',
  'share_image_preferences',
  'vault_stats_preferences',
  'xiaoyi_entry_preferences',
  'agent_settings',
  'recent_error_diagnostics',
  'app_update_check'
];
// The obsolete git_sync store may contain a plaintext token. Never serialize it into the
// transaction journal; clear it only after the restore commit succeeds.
const TRANSACTION_PREFERENCE_STORES: string[] = APPLICATION_PREFERENCE_STORES.slice();
const APP_BACKUP_ROOTS: string[] = ['vaults', 'trash', 'drafts', 'agent'];
const APP_BACKUP_LIMITS = ZipImportService.DEFAULT_LIMITS;
const NO_SPACE_ERROR_CODE: number = 13900025;

export interface ApplicationBackupVaultPreview {
  id: string;
  type: string;
  rootKind: string;
}

export interface ApplicationBackupPreview {
  fileName: string;
  createdAt: number;
  archiveBytes: number;
  expandedBytes: number;
  fileCount: number;
  vaults: ApplicationBackupVaultPreview[];
}

export interface ApplicationBackupOutcome {
  status: string;
  detail: string;
  preview: ApplicationBackupPreview | null;
}

interface ApplicationBackupManifest {
  format: string;
  schemaVersion: number;
  createdAt: number;
  appVersion: string;
  vaults: ApplicationBackupVaultPreview[];
  preferenceStores: string[];
  includes: string[];
}

interface BackupJournal {
  schemaVersion: number;
  state: string;
  hadOriginal: Record<string, boolean>;
  credentialVaultIds: string[];
  preferences: Record<string, Record<string, Object>>;
}

interface TreeSize {
  entries: number;
  bytes: number;
}

/** 备份 payload 中首个超限文件（相对 payload 根的路径 + 字节数），供错误提示点名。 */
interface OversizedFile {
  relativePath: string;
  bytes: number;
}

/** Writes extracted files only under the unregistered staging root. */
class ApplicationBackupStageWriter implements ZipWriterPort {
  private rootDir: string;

  constructor(rootDir: string) {
    this.rootDir = rootDir;
  }

  async writeFile(relativePath: string, data: Uint8Array): Promise<void> {
    const target: string = this.resolve(relativePath);
    const slash: number = target.lastIndexOf('/');
    if (slash > this.rootDir.length) {
      const parent: string = target.substring(0, slash);
      if (!fileIo.accessSync(parent)) {
        fileIo.mkdirSync(parent, true);
      }
    }
    const file: fileIo.File = fileIo.openSync(target,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, ApplicationBackupStageWriter.exactBuffer(data));
    } finally {
      fileIo.closeSync(file);
    }
  }

  setModifiedTime(relativePath: string, modifiedAtMs: number): void {
    fileIo.utimes(this.resolve(relativePath), modifiedAtMs);
  }

  private resolve(relativePath: string): string {
    const segments: string[] = relativePath.split('/');
    if (relativePath.length === 0 || relativePath.startsWith('/')) {
      throw new Error('备份文件包含不安全路径');
    }
    for (let i: number = 0; i < segments.length; i++) {
      if (segments[i].length === 0 || segments[i] === '.' || segments[i] === '..' ||
        segments[i].indexOf('\\') >= 0) {
        throw new Error('备份文件包含不安全路径');
      }
    }
    return this.rootDir + '/' + segments.join('/');
  }

  private static exactBuffer(data: Uint8Array): ArrayBuffer {
    if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
      return data.buffer;
    }
    const copy: Uint8Array = new Uint8Array(data.byteLength);
    copy.set(data);
    return copy.buffer;
  }
}

/** Owns the prepared archive path between the picker preview and the user's restore confirmation. */
export class ApplicationBackupService {
  private context: common.UIAbilityContext;
  private registry: VaultRegistry;
  private pendingWorkspace: string = '';
  private pendingArchivePath: string = '';
  private pendingParsed: ZipParsed | null = null;
  private pendingPreview: ApplicationBackupPreview | null = null;

  constructor(context: common.UIAbilityContext, registry: VaultRegistry) {
    this.context = context;
    this.registry = registry;
  }

  static preferenceStoreNames(): string[] {
    return APPLICATION_PREFERENCE_STORES.slice();
  }

  /** Create one complete archive, then copy it to the user-selected document URI. */
  async exportToSystemSave(): Promise<ApplicationBackupOutcome> {
    const resolver: VaultPathResolver = new VaultPathResolver(this.context);
    const exportId: string = 'backup-' + Date.now().toString();
    const exportDir: string = resolver.appBackupExportDir(exportId);
    const payloadDir: string = exportDir + '/payload';
    const archivePath: string = exportDir + '/yaoshi-application-backup.zip';
    try {
      const entries: VaultEntry[] = this.registry.list();
      for (let i: number = 0; i < entries.length; i++) {
        if (AgentRuntime.isVaultBusy(entries[i].id)) {
          return { status: 'failed', detail: 'Agent 操作正在运行，完成后再导出应用备份。', preview: null };
        }
      }
      await AgentMemoryStore.flushPending();
      fileIo.mkdirSync(payloadDir, true);
      fileIo.mkdirSync(payloadDir + '/vaults', true);
      fileIo.mkdirSync(payloadDir + '/trash', true);
      fileIo.mkdirSync(payloadDir + '/drafts', true);
      fileIo.mkdirSync(payloadDir + '/agent', true);
      fileIo.mkdirSync(payloadDir + '/' + BACKUP_PREFERENCES_DIR, true);

      const previewVaults: ApplicationBackupVaultPreview[] = [];
      for (let i: number = 0; i < entries.length; i++) {
        const entry: VaultEntry = entries[i];
        const rootKind: string = entry.rootKind === 'external' ? 'external' : 'sandbox';
        previewVaults.push({ id: entry.id, type: entry.type, rootKind: rootKind });
        if (rootKind === 'sandbox') {
          const source: string = this.registry.vaultDirOf(entry.id);
          const target: string = payloadDir + '/vaults/' + entry.id;
          if (!fileIo.accessSync(source)) {
            throw new Error('有知识库目录不可读取，请检查后重试');
          }
          await ApplicationBackupService.copyTree(source, target);
        }
      }

      await ApplicationBackupService.copyTreeIfPresent(resolver.trashRoot(), payloadDir + '/trash');
      await ApplicationBackupService.copyTreeIfPresent(resolver.draftsRoot(), payloadDir + '/drafts');
      await ApplicationBackupService.copyTreeIfPresent(resolver.agentRoot(), payloadDir + '/agent');

      const stores: Record<string, Record<string, Object>> =
        ApplicationBackupService.readPreferenceSnapshot(this.context, APPLICATION_PREFERENCE_STORES);
      ApplicationBackupService.sanitizeRegistryRemote(stores);
      for (let i: number = 0; i < APPLICATION_PREFERENCE_STORES.length; i++) {
        const storeName: string = APPLICATION_PREFERENCE_STORES[i];
        ApplicationBackupService.writeNewTextFile(payloadDir + '/' + BACKUP_PREFERENCES_DIR + '/' + storeName + '.json',
          JSON.stringify(stores[storeName]));
      }

      const createdAt: number = Date.now();
      const manifest: ApplicationBackupManifest = {
        format: APP_BACKUP_FORMAT,
        schemaVersion: APP_BACKUP_SCHEMA_VERSION,
        createdAt: createdAt,
        appVersion: ApplicationBackupService.readAppVersion(),
        vaults: previewVaults,
        preferenceStores: APPLICATION_PREFERENCE_STORES.slice(),
        includes: ['vaults', 'trash', 'drafts', 'agent', BACKUP_PREFERENCES_DIR]
      };
      ApplicationBackupService.writeNewTextFile(payloadDir + '/' + BACKUP_MANIFEST_FILE, JSON.stringify(manifest));

      const treeSize: TreeSize = ApplicationBackupService.measureTree(payloadDir);
      if (treeSize.entries > APP_BACKUP_LIMITS.maxEntries || treeSize.bytes > APP_BACKUP_LIMITS.maxTotalUncompressed) {
        throw new ZipImportError('over_limit',
          '备份数据共 ' + treeSize.entries.toString() + ' 个文件、约 ' +
          ZipImportService.formatBytes(treeSize.bytes) + '，超过备份安全上限（' +
          APP_BACKUP_LIMITS.maxEntries.toString() + ' 个文件 / ' +
          ZipImportService.formatBytes(APP_BACKUP_LIMITS.maxTotalUncompressed) +
          '）。请移出部分文件后重试。');
      }
      const oversized: OversizedFile | null =
        ApplicationBackupService.findOversizedFile(payloadDir, '', APP_BACKUP_LIMITS.maxSingleUncompressed);
      if (oversized !== null) {
        throw new ZipImportError('over_limit',
          '「' + oversized.relativePath + '」（约 ' +
          ZipImportService.formatBytes(oversized.bytes) + '）超过单个文件 ' +
          ZipImportService.formatBytes(APP_BACKUP_LIMITS.maxSingleUncompressed) +
          ' 的备份上限，请移出或删除该文件后重试。');
      }
      await zlib.compressFile(payloadDir, archivePath, {});

      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      const savedUris: string[] = await savePicker.save({
        newFileNames: ['曜石笔记_应用备份.zip'],
        fileSuffixChoices: ['应用备份|.zip']
      });
      if (savedUris.length === 0) {
        return { status: 'cancelled', detail: '', preview: null };
      }
      await ApplicationBackupService.copyFileToPickerUri(archivePath, savedUris[0]);
      return { status: 'ok', detail: '', preview: null };
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      if (err.code === NO_SPACE_ERROR_CODE) {
        return { status: 'failed', detail: '设备空间不足，备份未保存。请清理空间后重试。', preview: null };
      }
      if (error instanceof ZipImportError && error.kind === 'over_limit') {
        return { status: 'failed', detail: error.message, preview: null };
      }
      return { status: 'failed', detail: '应用备份未完成，当前数据未更改。请检查可用空间后重试。', preview: null };
    } finally {
      try {
        ApplicationBackupService.removeTree(exportDir);
      } catch (cleanupError) {
        // The cache workspace is private and will be cleared by the next backup attempt.
      }
    }
  }

  /** Select, fully validate and stage a backup without changing the current application data. */
  async chooseBackup(): Promise<ApplicationBackupOutcome> {
    const resolver: VaultPathResolver = new VaultPathResolver(this.context);
    this.cancelPending();
    const pickerDevice: DeviceZipPicker = new DeviceZipPicker(this.context, '曜石笔记应用备份');
    let picked: ZipPickResult | null = null;
    try {
      picked = await pickerDevice.pick();
    } catch (error) {
      picked = null;
    }
    if (picked === null) {
      return { status: 'cancelled', detail: '', preview: null };
    }

    const importId: string = 'restore-' + Date.now().toString();
    const cacheRoot: string = resolver.appBackupImportCacheRoot();
    const zipPath: string = cacheRoot + '/' + importId + '.zip';
    const workspace: string = resolver.appBackupRestoreRoot();
    const newRoot: string = workspace + '/new';
    try {
      if (!fileIo.accessSync(cacheRoot)) {
        fileIo.mkdirSync(cacheRoot, true);
      }
      await copyPickerZipToStaging(picked.uri, zipPath);
      const reader: StagingZipReader = new StagingZipReader(zipPath);
      let parsed: ZipParsed;
      try {
        parsed = await ZipImportService.parse(reader, APP_BACKUP_LIMITS, {
          allowHiddenEntries: true,
          acceptAllFiles: true,
          requireMarkdown: false
        });
        ApplicationBackupService.validateEntryNames(parsed.entries);
        if (freeBytesUnder(this.context.filesDir) < parsed.totalUncompressed) {
          throw new ZipImportError('no_space', '设备存储空间不足，无法安全暂存备份');
        }
        if (fileIo.accessSync(workspace)) {
          ApplicationBackupService.removeTree(workspace);
        }
        fileIo.mkdirSync(newRoot, true);
        for (let i: number = 0; i < APP_BACKUP_ROOTS.length; i++) {
          fileIo.mkdirSync(newRoot + '/' + APP_BACKUP_ROOTS[i], true);
        }
        fileIo.mkdirSync(newRoot + '/' + BACKUP_PREFERENCES_DIR, true);
        const writer: ApplicationBackupStageWriter = new ApplicationBackupStageWriter(newRoot);
        const inflate: InflatePort = new ZlibRawInflate();
        await ZipImportService.extract(reader, writer, inflate, parsed, { preserveMtime: true });
      } finally {
        reader.close();
      }

      const manifest: ApplicationBackupManifest = ApplicationBackupService.readAndValidateManifest(newRoot);
      ApplicationBackupService.ensureSandboxVaultDirs(newRoot, manifest);
      const storeSnapshots: Record<string, Record<string, Object>> =
        ApplicationBackupService.readAndValidateBackupPreferences(newRoot);
      ApplicationBackupService.validateRegistryAgainstManifest(storeSnapshots, manifest, newRoot);
      const preview: ApplicationBackupPreview = {
        fileName: picked.fileName,
        createdAt: manifest.createdAt,
        archiveBytes: fileIo.statSync(zipPath).size,
        expandedBytes: parsed.totalUncompressed,
        fileCount: parsed.entries.length,
        vaults: manifest.vaults
      };
      this.pendingWorkspace = workspace;
      this.pendingArchivePath = zipPath;
      this.pendingParsed = parsed;
      this.pendingPreview = preview;
      return { status: 'selected', detail: '', preview: preview };
    } catch (error) {
      try {
        ApplicationBackupService.removeTree(workspace);
      } catch (cleanupError) {
        // Failed staging is not registered and is retried on the next selection.
      }
      try {
        fileIo.unlinkSync(zipPath);
      } catch (cleanupError) {
        // Cache cleanup is best effort.
      }
      const err: BusinessError = error as BusinessError;
      if (error instanceof ZipImportError && error.kind === 'over_limit') {
        const status: string = error.message.indexOf('较新') >= 0 ? 'newer' : 'failed';
        return { status: status, detail: error.message, preview: null };
      }
      if (error instanceof ZipImportError && error.kind === 'no_space') {
        return { status: 'failed', detail: '设备存储空间不足，备份校验未完成。当前数据未更改。', preview: null };
      }
      if (err.code === NO_SPACE_ERROR_CODE) {
        return { status: 'failed', detail: '设备空间不足，备份校验未完成。当前数据未更改。', preview: null };
      }
      if (error instanceof ZipImportError && error.kind === 'corrupt') {
        return {
          status: 'failed',
          detail: '备份文件损坏或格式不完整（' + error.message + '）。请选择其他文件后重试。',
          preview: null
        };
      }
      const reason: string = typeof err.message === 'string' ? err.message : '';
      return {
        status: 'failed',
        detail: reason.length > 0
          ? '无法读取该应用备份（' + reason + '）。请选择有效的曜石笔记备份文件后重试。'
          : '无法读取该应用备份。请选择有效的曜石笔记备份文件后重试。',
        preview: null
      };
    }
  }

  /** Replace current roots and Preferences after explicit user confirmation. */
  async restoreBackup(): Promise<ApplicationBackupOutcome> {
    if (this.pendingWorkspace.length === 0 || this.pendingPreview === null || this.pendingParsed === null) {
      return { status: 'failed', detail: '备份预览已失效，请重新选择文件。', preview: null };
    }
    const workspace: string = this.pendingWorkspace;
    const resolver: VaultPathResolver = new VaultPathResolver(this.context);
    let searchPaused: boolean = false;
    let committed: boolean = false;
    try {
      const currentEntries: VaultEntry[] = this.registry.list();
      for (let i: number = 0; i < currentEntries.length; i++) {
        if (AgentRuntime.isVaultBusy(currentEntries[i].id)) {
          throw new Error('Agent 操作仍在进行，请完成后再恢复备份');
        }
      }
      const livePreferences: Record<string, Record<string, Object>> =
        ApplicationBackupService.readPreferenceSnapshot(this.context, TRANSACTION_PREFERENCE_STORES);
      const nextPreferences: Record<string, Record<string, Object>> =
        ApplicationBackupService.readAndValidateBackupPreferences(workspace + '/new');
      await AgentMemoryStore.prepareForBackupRestore();
      await FullTextSearchService.prepareForBackupRestore();
      searchPaused = true;
      const hadOriginal: Record<string, boolean> = {};
      for (let i: number = 0; i < APP_BACKUP_ROOTS.length; i++) {
        const rootName: string = APP_BACKUP_ROOTS[i];
        hadOriginal[rootName] = fileIo.accessSync(ApplicationBackupService.liveRoot(resolver, rootName));
      }
      const journal: BackupJournal = {
        schemaVersion: 1,
        state: 'committing',
        hadOriginal: hadOriginal,
        credentialVaultIds: ApplicationBackupService.gitVaultIdsFromEntries(currentEntries)
          .concat(ApplicationBackupService.gitVaultIdsFromPreview(this.pendingPreview.vaults)),
        preferences: livePreferences
      };
      const oldRoot: string = workspace + '/old';
      fileIo.mkdirSync(oldRoot, true);
      await atomicWriteText(resolver.appBackupRestoreJournal(), JSON.stringify(journal), {
        timeoutMessage: '应用备份恢复记录写入超时'
      });
      try {
        for (let i: number = 0; i < APP_BACKUP_ROOTS.length; i++) {
          const rootName: string = APP_BACKUP_ROOTS[i];
          const target: string = ApplicationBackupService.liveRoot(resolver, rootName);
          const oldPath: string = oldRoot + '/' + rootName;
          const nextPath: string = workspace + '/new/' + rootName;
          const slash: number = target.lastIndexOf('/');
          if (slash > 0 && !fileIo.accessSync(target.substring(0, slash))) {
            fileIo.mkdirSync(target.substring(0, slash), true);
          }
          if (hadOriginal[rootName]) {
            fileIo.renameSync(target, oldPath);
          }
          fileIo.renameSync(nextPath, target);
        }
        ApplicationBackupService.replacePreferences(this.context, nextPreferences, TRANSACTION_PREFERENCE_STORES);
        journal.state = 'committed';
        await atomicWriteText(resolver.appBackupRestoreJournal(), JSON.stringify(journal), {
          timeoutMessage: '应用备份恢复提交记录写入超时'
        });
        committed = true;
      } catch (error) {
        try {
          ApplicationBackupService.rollbackJournal(this.context, resolver, journal, workspace);
          ApplicationBackupService.removeIfPresent(workspace + '/old');
          ApplicationBackupService.removeIfPresent(resolver.appBackupRestoreJournal());
        } catch (rollbackError) {
          throw new Error('恢复未完成，旧数据回滚状态尚未确认；请关闭并重新打开应用以自动恢复。');
        }
        if (error instanceof Error) {
          throw error;
        }
        throw new Error('应用备份恢复失败');
      }
      const postCommitClean: boolean =
        ApplicationBackupService.finishCommittedRestore(this.context, journal.credentialVaultIds);
      if (postCommitClean) {
        try {
          ApplicationBackupService.removeTree(workspace);
        } catch (cleanupError) {
          // The committed journal makes this cleanup retryable at the next launch.
        }
      } else {
        if (this.pendingArchivePath.length > 0) {
          try {
            fileIo.unlinkSync(this.pendingArchivePath);
          } catch (cleanupError) {
            // The cache archive is expendable; the journal and old roots remain for startup recovery.
          }
        }
        this.clearPendingFields();
        return {
          status: 'recovery_required',
          detail: '数据已恢复，但旧 Git 凭据清理未完成。请结束并重新打开应用；启动时会重试清理。',
          preview: null
        };
      }
      if (this.pendingArchivePath.length > 0) {
        try {
          fileIo.unlinkSync(this.pendingArchivePath);
        } catch (cleanupError) {
          // The selected archive is a private staging copy and can be cleared on the next selection.
        }
      }
      this.clearPendingFields();
      return { status: 'ok', detail: postCommitClean ? '' : '数据已恢复；旧凭据清理将在下次启动重试。', preview: null };
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '';
      const err: BusinessError = error as BusinessError;
      if (committed) {
        return {
          status: 'recovery_required',
          detail: '数据已提交，但恢复收尾未完成。请结束并重新打开应用；启动时会继续处理恢复记录。',
          preview: null
        };
      }
      if (searchPaused && !committed && message.indexOf('重新打开应用') < 0) {
        FullTextSearchService.resumeAfterBackupRestoreFailure();
      }
      if (err.code === NO_SPACE_ERROR_CODE || message.indexOf('设备空间不足') >= 0) {
        return { status: 'failed', detail: '设备存储空间不足，恢复未完成。当前数据已回滚；请清理空间后重试。', preview: null };
      }
      if (message.indexOf('尚未确认') >= 0 || message.indexOf('重新打开应用') >= 0) {
        return { status: 'recovery_required', detail: message, preview: null };
      }
      return { status: 'failed', detail: message.length > 0
        ? message : '恢复未完成，当前数据已回滚。请检查存储空间后重试。', preview: null };
    }
  }

  cancelPending(): void {
    if (this.pendingWorkspace.length > 0) {
      try {
        const resolver: VaultPathResolver = new VaultPathResolver(this.context);
        if (!fileIo.accessSync(resolver.appBackupRestoreJournal())) {
          ApplicationBackupService.removeTree(this.pendingWorkspace);
        }
      } catch (error) {
        // Staging remains private and unregistered; next choose attempt cleans it.
      }
    }
    if (this.pendingArchivePath.length > 0) {
      try {
        fileIo.unlinkSync(this.pendingArchivePath);
      } catch (error) {
        // Cache cleanup is best effort.
      }
    }
    this.clearPendingFields();
  }

  /** Called before VaultRegistry is initialized. An interrupted commit always rolls back. */
  static recoverInterrupted(context: common.UIAbilityContext): void {
    const resolver: VaultPathResolver = new VaultPathResolver(context);
    const journalPath: string = resolver.appBackupRestoreJournal();
    if (!fileIo.accessSync(journalPath)) {
      return;
    }
    const workspace: string = resolver.appBackupRestoreRoot();
    let journal: BackupJournal;
    try {
      journal = JSON.parse(fileIo.readTextSync(journalPath)) as BackupJournal;
    } catch (error) {
      throw new Error('应用备份恢复记录损坏，已阻止打开数据以避免覆盖；请重启应用重试恢复。');
    }
    if (journal.schemaVersion !== 1 || typeof journal.state !== 'string' ||
      typeof journal.hadOriginal !== 'object' || journal.hadOriginal === null ||
      typeof journal.preferences !== 'object' || journal.preferences === null ||
      !Array.isArray(journal.credentialVaultIds) ||
      (journal.state !== 'committing' && journal.state !== 'committed')) {
      throw new Error('应用备份恢复记录不完整，已阻止打开数据以避免覆盖。');
    }
    for (let i: number = 0; i < journal.credentialVaultIds.length; i++) {
      if (typeof journal.credentialVaultIds[i] !== 'string' ||
        !ApplicationBackupService.isSafeVaultId(journal.credentialVaultIds[i])) {
        throw new Error('应用备份恢复记录包含无效库标识，已阻止打开数据。');
      }
    }
    for (let i: number = 0; i < APP_BACKUP_ROOTS.length; i++) {
      if (typeof journal.hadOriginal[APP_BACKUP_ROOTS[i]] !== 'boolean') {
        throw new Error('应用备份恢复记录不完整，已阻止打开数据以避免覆盖。');
      }
    }
    for (let i: number = 0; i < TRANSACTION_PREFERENCE_STORES.length; i++) {
      const storeName: string = TRANSACTION_PREFERENCE_STORES[i];
      const values: Object = journal.preferences[storeName] as Object;
      if (typeof values !== 'object' || values === null || Array.isArray(values)) {
        throw new Error('应用备份恢复记录不完整，已阻止打开数据以避免覆盖。');
      }
      const map: Record<string, Object> = values as Record<string, Object>;
      const keys: string[] = Object.keys(map);
      for (let j: number = 0; j < keys.length; j++) {
        if (keys[j].length === 0 || !ApplicationBackupService.isJsonPreferenceValue(map[keys[j]], 0)) {
          throw new Error('应用备份恢复记录中的偏好数据无效，已阻止打开数据。');
        }
      }
    }
    if (journal.state === 'committed') {
      if (ApplicationBackupService.finishCommittedRestore(context, journal.credentialVaultIds)) {
        ApplicationBackupService.removeTree(workspace);
        return;
      }
      throw new Error('应用备份数据已提交，但旧 Git 凭据清理未完成；已阻止打开数据，请重启应用重试。');
    }
    ApplicationBackupService.rollbackJournal(context, resolver, journal, workspace);
    ApplicationBackupService.removeTree(workspace);
  }

  private clearPendingFields(): void {
    this.pendingWorkspace = '';
    this.pendingArchivePath = '';
    this.pendingParsed = null;
    this.pendingPreview = null;
  }

  private static readPreferenceSnapshot(context: common.UIAbilityContext,
    storeNames: string[]): Record<string, Record<string, Object>> {
    const result: Record<string, Record<string, Object>> = {};
    for (let i: number = 0; i < storeNames.length; i++) {
      const name: string = storeNames[i];
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: name });
      const values: Record<string, preferences.ValueType> =
        store.getAllSync() as Record<string, preferences.ValueType>;
      const copy: Record<string, Object> = {};
      const keys: string[] = Object.keys(values);
      for (let j: number = 0; j < keys.length; j++) {
        const value: preferences.ValueType = values[keys[j]];
        if (!ApplicationBackupService.isJsonPreferenceValue(value, 0)) {
          throw new Error('偏好数据包含无法安全迁移的类型');
        }
        copy[keys[j]] = value as Object;
      }
      result[name] = copy;
    }
    return result;
  }

  private static isJsonPreferenceValue(value: Object, depth: number): boolean {
    if (depth > 24) {
      return false;
    }
    if (typeof value === 'string' || typeof value === 'boolean') {
      return true;
    }
    if (typeof value === 'number') {
      return Number.isFinite(value as number);
    }
    if (Array.isArray(value)) {
      const list: Object[] = value as Object[];
      if (list.length === 0) {
        return true;
      }
      const first: Object = list[0];
      if (typeof first !== 'string' && typeof first !== 'number' && typeof first !== 'boolean') {
        return false;
      }
      const itemType: string = typeof first;
      for (let i: number = 0; i < list.length; i++) {
        if (typeof list[i] !== itemType ||
          (typeof list[i] === 'number' && !Number.isFinite(list[i] as number))) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  private static sanitizeRegistryRemote(stores: Record<string, Record<string, Object>>): void {
    const registryValues: Record<string, Object> = stores['vault_registry'];
    const raw: Object = registryValues['vault_registry_json'];
    if (typeof raw !== 'string') {
      return;
    }
    try {
      const parsed: Object = JSON.parse(raw as string);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error('invalid registry root');
      }
      const root: Record<string, Object> = parsed as Record<string, Object>;
      const rawVaults: Object = root['vaults'];
      if (!Array.isArray(rawVaults)) {
        throw new Error('invalid registry vaults');
      }
      const vaults: Object[] = rawVaults as Object[];
      for (let i: number = 0; i < vaults.length; i++) {
        if (typeof vaults[i] !== 'object' || vaults[i] === null || Array.isArray(vaults[i])) {
          throw new Error('invalid registry entry');
        }
        const entry: Record<string, Object> = vaults[i] as Record<string, Object>;
        if (typeof entry['remote'] === 'string') {
          entry['remote'] = ApplicationBackupService.sanitizeRemoteUrl(entry['remote'] as string);
        }
      }
      registryValues['vault_registry_json'] = JSON.stringify(root);
    } catch (error) {
      throw new Error('知识库注册信息损坏，无法安全导出');
    }
  }

  private static sanitizeRemoteUrl(remote: string): string {
    let output: string = remote.replace(/([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^/@\s]+@)/g, '$1');
    output = output.replace(/([?&](?:access_)?token|[?&]password|[?&]secret|[?&]key)=([^&#\s]*)/gi, '$1=');
    return output;
  }

  private static readAndValidateBackupPreferences(rootDir: string): Record<string, Record<string, Object>> {
    const stores: Record<string, Record<string, Object>> = {};
    for (let i: number = 0; i < APPLICATION_PREFERENCE_STORES.length; i++) {
      const name: string = APPLICATION_PREFERENCE_STORES[i];
      const path: string = rootDir + '/' + BACKUP_PREFERENCES_DIR + '/' + name + '.json';
      if (!fileIo.accessSync(path) || !fileIo.statSync(path).isFile()) {
        throw new ZipImportError('corrupt', '应用备份缺少必要的偏好数据');
      }
      try {
        const parsed: Object = JSON.parse(fileIo.readTextSync(path));
        if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
          throw new Error('invalid preference map');
        }
        const map: Record<string, Object> = parsed as Record<string, Object>;
        const keys: string[] = Object.keys(map);
        for (let j: number = 0; j < keys.length; j++) {
          if (keys[j].length === 0 || !ApplicationBackupService.isJsonPreferenceValue(map[keys[j]], 0)) {
            throw new Error('invalid preference value');
          }
        }
        stores[name] = map;
      } catch (error) {
        throw new ZipImportError('corrupt', '应用备份中的偏好数据损坏');
      }
    }
    const preferenceDir: string = rootDir + '/' + BACKUP_PREFERENCES_DIR;
    const names: string[] = fileIo.listFileSync(preferenceDir);
    if (names.length !== APPLICATION_PREFERENCE_STORES.length) {
      throw new ZipImportError('corrupt', '应用备份包含未知或缺失的偏好文件');
    }
    for (let i: number = 0; i < names.length; i++) {
      if (APPLICATION_PREFERENCE_STORES.indexOf(names[i].replace(/\.json$/i, '')) < 0 ||
        !names[i].toLowerCase().endsWith('.json')) {
        throw new ZipImportError('unsafe', '应用备份包含未知的偏好文件');
      }
    }
    return stores;
  }

  private static readAndValidateManifest(rootDir: string): ApplicationBackupManifest {
    const path: string = rootDir + '/' + BACKUP_MANIFEST_FILE;
    if (!fileIo.accessSync(path) || !fileIo.statSync(path).isFile()) {
      throw new ZipImportError('corrupt', '文件不是完整的曜石笔记应用备份');
    }
    let raw: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(fileIo.readTextSync(path));
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error('invalid manifest root');
      }
      raw = parsed as Record<string, Object>;
    } catch (error) {
      throw new ZipImportError('corrupt', '应用备份清单损坏');
    }
    if (raw['format'] !== APP_BACKUP_FORMAT) {
      throw new ZipImportError('corrupt', '文件不是曜石笔记应用备份');
    }
    const schema: Object = raw['schemaVersion'];
    if (typeof schema !== 'number' || !Number.isFinite(schema as number) ||
      Math.floor(schema as number) !== (schema as number) || (schema as number) < 1) {
      throw new ZipImportError('corrupt', '应用备份清单版本号无效');
    }
    if ((schema as number) > APP_BACKUP_SCHEMA_VERSION) {
      throw new ZipImportError('over_limit', '备份格式较新，请升级曜石笔记后再恢复');
    }
    if ((schema as number) !== APP_BACKUP_SCHEMA_VERSION || typeof raw['createdAt'] !== 'number' ||
      !Number.isFinite(raw['createdAt'] as number) || (raw['createdAt'] as number) <= 0 ||
      !Array.isArray(raw['vaults']) ||
      typeof raw['appVersion'] !== 'string' || !Array.isArray(raw['preferenceStores']) ||
      !Array.isArray(raw['includes'])) {
      throw new ZipImportError('corrupt', '应用备份清单不完整');
    }
    const storeNames: Object[] = raw['preferenceStores'] as Object[];
    if (storeNames.length !== APPLICATION_PREFERENCE_STORES.length) {
      throw new ZipImportError('corrupt', '应用备份偏好清单不完整');
    }
    const seenStores: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < APPLICATION_PREFERENCE_STORES.length; i++) {
      const storeName: Object = storeNames[i];
      if (typeof storeName !== 'string' || APPLICATION_PREFERENCE_STORES.indexOf(storeName as string) < 0 ||
        seenStores.has(storeName as string)) {
        throw new ZipImportError('corrupt', '应用备份偏好清单不完整');
      }
      seenStores.set(storeName as string, true);
    }
    const includes: Object[] = raw['includes'] as Object[];
    const expectedIncludes: string[] = ['vaults', 'trash', 'drafts', 'agent', BACKUP_PREFERENCES_DIR];
    if (includes.length !== expectedIncludes.length) {
      throw new ZipImportError('corrupt', '应用备份内容清单不完整');
    }
    const seenIncludes: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < includes.length; i++) {
      const include: Object = includes[i];
      if (typeof include !== 'string' || expectedIncludes.indexOf(include as string) < 0 ||
        seenIncludes.has(include as string)) {
        throw new ZipImportError('corrupt', '应用备份内容清单不完整');
      }
      seenIncludes.set(include as string, true);
    }
    const vaultsRaw: Object[] = raw['vaults'] as Object[];
    const vaults: ApplicationBackupVaultPreview[] = [];
    const seen: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < vaultsRaw.length; i++) {
      if (typeof vaultsRaw[i] !== 'object' || vaultsRaw[i] === null || Array.isArray(vaultsRaw[i])) {
        throw new ZipImportError('corrupt', '应用备份库清单无效');
      }
      const entry: Record<string, Object> = vaultsRaw[i] as Record<string, Object>;
      const id: Object = entry['id'];
      const type: Object = entry['type'];
      const rootKind: Object = entry['rootKind'];
      if (typeof id !== 'string' || !ApplicationBackupService.isSafeVaultId(id as string) ||
        (type !== 'local' && type !== 'git') || (rootKind !== 'sandbox' && rootKind !== 'external') ||
        seen.has(id as string)) {
        throw new ZipImportError('corrupt', '应用备份库清单无效');
      }
      seen.set(id as string, true);
      vaults.push({ id: id as string, type: type as string, rootKind: rootKind as string });
    }
    return {
      format: APP_BACKUP_FORMAT,
      schemaVersion: APP_BACKUP_SCHEMA_VERSION,
      createdAt: raw['createdAt'] as number,
      appVersion: typeof raw['appVersion'] === 'string' ? raw['appVersion'] as string : '',
      vaults: vaults,
      preferenceStores: APPLICATION_PREFERENCE_STORES.slice(),
      includes: ['vaults', 'trash', 'drafts', 'agent', BACKUP_PREFERENCES_DIR]
    };
  }

  /**
   * 空知识库目录补齐（2026-11-18）：备份 zip 里空库只有目录条目（compressFile 记录
   * vaults/<id>/ 目录，没有任何文件条目），而 ZipImportService.parse 按设计跳过
   * 目录条目，解压后空库目录缺失，注册校验报「应用备份缺少知识库目录」。
   * manifest 中的沙箱库在恢复校验前按清单补建（已存在时 no-op）；外部库不占沙箱目录，跳过。
   */
  private static ensureSandboxVaultDirs(rootDir: string, manifest: ApplicationBackupManifest): void {
    for (let i: number = 0; i < manifest.vaults.length; i++) {
      const vault: ApplicationBackupVaultPreview = manifest.vaults[i];
      if (vault.rootKind !== 'sandbox') {
        continue;
      }
      const dir: string = rootDir + '/vaults/' + vault.id;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    }
  }

  private static validateRegistryAgainstManifest(stores: Record<string, Record<string, Object>>,
    manifest: ApplicationBackupManifest, rootDir: string): void {
    const rawRegistry: Object = stores['vault_registry']['vault_registry_json'];
    if (typeof rawRegistry !== 'string') {
      throw new ZipImportError('corrupt', '应用备份缺少知识库注册清单');
    }
    let registryState: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(rawRegistry as string);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        throw new Error('invalid registry root');
      }
      registryState = parsed as Record<string, Object>;
    } catch (error) {
      throw new ZipImportError('corrupt', '知识库注册清单损坏');
    }
    const rawVaults: Object[] = registryState['vaults'] as Object[];
    if (!Array.isArray(rawVaults) || rawVaults.length !== manifest.vaults.length) {
      throw new ZipImportError('corrupt', '备份库列表与注册清单不一致');
    }
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const seenVaultKeys: Map<string, boolean> = new Map<string, boolean>();
    const expectedSandboxIds: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < rawVaults.length; i++) {
      if (typeof rawVaults[i] !== 'object' || rawVaults[i] === null || Array.isArray(rawVaults[i])) {
        throw new ZipImportError('corrupt', '备份库注册信息无效');
      }
      const item: Record<string, Object> = rawVaults[i] as Record<string, Object>;
      if (typeof item['id'] !== 'string' || (item['type'] !== 'local' && item['type'] !== 'git') ||
        typeof item['createdAt'] !== 'number' || !Number.isFinite(item['createdAt'] as number) ||
        typeof item['vaultKey'] !== 'string' || !ApplicationBackupService.isSafeVaultKey(item['vaultKey'] as string)) {
        throw new ZipImportError('corrupt', '备份库注册信息无效');
      }
      const id: string = item['id'] as string;
      if (!ApplicationBackupService.isSafeVaultId(id) || seen.has(id)) {
        throw new ZipImportError('unsafe', '备份库注册信息包含不安全名称');
      }
      seen.set(id, true);
      const vaultKey: string = item['vaultKey'] as string;
      if (seenVaultKeys.has(vaultKey)) {
        throw new ZipImportError('corrupt', '备份库私有标识重复');
      }
      seenVaultKeys.set(vaultKey, true);
      let expected: ApplicationBackupVaultPreview | null = null;
      for (let j: number = 0; j < manifest.vaults.length; j++) {
        if (manifest.vaults[j].id === id) {
          expected = manifest.vaults[j];
          break;
        }
      }
      if (expected === null || expected.type !== item['type']) {
        throw new ZipImportError('corrupt', '备份库列表与注册清单不一致');
      }
      const rootKind: Object = item['rootKind'];
      const rootUri: Object = item['rootUri'];
      if (rootKind !== undefined && rootKind !== 'external') {
        throw new ZipImportError('corrupt', '备份库位置类型无效');
      }
      const external: boolean = rootKind === 'external' &&
        typeof rootUri === 'string' && (rootUri as string).length > 0;
      if ((expected.rootKind === 'external') !== external) {
        throw new ZipImportError('corrupt', '备份库授权信息与清单不一致');
      }
      if (!external) {
        expectedSandboxIds.set(id, true);
        const dir: string = rootDir + '/vaults/' + id;
        if (!fileIo.accessSync(dir)) {
          throw new ZipImportError('corrupt', '应用备份缺少知识库目录');
        } else if (!fileIo.statSync(dir).isDirectory()) {
          throw new ZipImportError('corrupt', '应用备份库目录结构无效');
        }
      }
    }
    const currentId: Object = registryState['currentVaultId'];
    if (typeof currentId !== 'string' ||
      (manifest.vaults.length > 0 && !seen.has(currentId as string)) ||
      (manifest.vaults.length === 0 && currentId.length > 0)) {
      throw new ZipImportError('corrupt', '备份当前库信息无效');
    }
    const vaultRoot: string = rootDir + '/vaults';
    const vaultFolders: string[] = fileIo.listFileSync(vaultRoot);
    if (vaultFolders.length !== expectedSandboxIds.size) {
      throw new ZipImportError('corrupt', '应用备份包含未登记或缺失的知识库目录');
    }
    for (let i: number = 0; i < vaultFolders.length; i++) {
      if (!expectedSandboxIds.has(vaultFolders[i]) ||
        !fileIo.statSync(vaultRoot + '/' + vaultFolders[i]).isDirectory()) {
        throw new ZipImportError('corrupt', '应用备份知识库目录与注册清单不一致');
      }
    }
    const topLevel: string[] = fileIo.listFileSync(rootDir);
    const allowed: string[] = [BACKUP_MANIFEST_FILE, BACKUP_PREFERENCES_DIR, 'vaults', 'trash', 'drafts', 'agent'];
    for (let i: number = 0; i < topLevel.length; i++) {
      if (allowed.indexOf(topLevel[i]) < 0) {
        throw new ZipImportError('unsafe', '应用备份包含不支持的数据目录');
      }
    }
  }

  private static validateEntryNames(entries: ZipParsedEntry[]): void {
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const allowed: string[] = [BACKUP_MANIFEST_FILE, BACKUP_PREFERENCES_DIR, 'vaults', 'trash', 'drafts', 'agent'];
    for (let i: number = 0; i < entries.length; i++) {
      const name: string = entries[i].name;
      if (seen.has(name)) {
        throw new ZipImportError('corrupt', '应用备份包含重复文件');
      }
      seen.set(name, true);
      const slash: number = name.indexOf('/');
      const first: string = slash >= 0 ? name.substring(0, slash) : name;
      if (allowed.indexOf(first) < 0 || (first === BACKUP_MANIFEST_FILE && name !== BACKUP_MANIFEST_FILE)) {
        throw new ZipImportError('unsafe', '应用备份包含不支持的数据目录');
      }
      if (first === BACKUP_PREFERENCES_DIR) {
        const relative: string = slash >= 0 ? name.substring(slash + 1) : '';
        const validName: boolean = APPLICATION_PREFERENCE_STORES.indexOf(relative.replace(/\.json$/i, '')) >= 0 &&
          relative.toLowerCase().endsWith('.json') && relative.indexOf('/') < 0;
        if (!validName) {
          throw new ZipImportError('unsafe', '应用备份包含未知的偏好文件');
        }
      }
    }
  }

  private static replacePreferences(context: common.UIAbilityContext,
    source: Record<string, Record<string, Object>>, storeNames: string[]): void {
    for (let i: number = 0; i < storeNames.length; i++) {
      const name: string = storeNames[i];
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: name });
      store.clearSync();
      const values: Record<string, Object> = source[name] ?? {};
      const keys: string[] = Object.keys(values);
      for (let j: number = 0; j < keys.length; j++) {
        store.putSync(keys[j], values[keys[j]] as preferences.ValueType);
      }
      store.flushSync();
    }
  }

  private static finishCommittedRestore(context: common.UIAbilityContext, credentialVaultIds: string[]): boolean {
    const seen: Map<string, boolean> = new Map<string, boolean>();
    for (let i: number = 0; i < credentialVaultIds.length; i++) {
      const vaultId: string = credentialVaultIds[i];
      if (ApplicationBackupService.isSafeSegment(vaultId) && !seen.has(vaultId)) {
        seen.set(vaultId, true);
        if (!GitCredentialStore.removeToken(vaultId)) {
          return false;
        }
      }
    }
    try {
      const legacy: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LEGACY_GIT_PREFERENCES
      });
      legacy.clearSync();
      legacy.flushSync();
      return true;
    } catch (error) {
      // The current backup never imports this deprecated store; retry on committed-journal recovery.
      return false;
    }
  }

  private static gitVaultIdsFromEntries(entries: VaultEntry[]): string[] {
    const ids: string[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].type === 'git') {
        ids.push(entries[i].id);
      }
    }
    return ids;
  }

  private static gitVaultIdsFromPreview(vaults: ApplicationBackupVaultPreview[]): string[] {
    const ids: string[] = [];
    for (let i: number = 0; i < vaults.length; i++) {
      if (vaults[i].type === 'git') {
        ids.push(vaults[i].id);
      }
    }
    return ids;
  }

  private static readAppVersion(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return info.versionName;
    } catch (error) {
      return '';
    }
  }

  private static rollbackJournal(context: common.UIAbilityContext, resolver: VaultPathResolver,
    journal: BackupJournal, workspace: string): void {
    const oldRoot: string = workspace + '/old';
    for (let i: number = APP_BACKUP_ROOTS.length - 1; i >= 0; i--) {
      const rootName: string = APP_BACKUP_ROOTS[i];
      const target: string = ApplicationBackupService.liveRoot(resolver, rootName);
      const oldPath: string = oldRoot + '/' + rootName;
      const hadOriginal: boolean = journal.hadOriginal[rootName] === true;
      if (!hadOriginal) {
        ApplicationBackupService.removeIfPresent(target);
      } else if (fileIo.accessSync(oldPath)) {
        ApplicationBackupService.removeIfPresent(target);
        const slash: number = target.lastIndexOf('/');
        if (slash > 0 && !fileIo.accessSync(target.substring(0, slash))) {
          fileIo.mkdirSync(target.substring(0, slash), true);
        }
        fileIo.renameSync(oldPath, target);
      }
    }
    ApplicationBackupService.replacePreferences(context, journal.preferences, TRANSACTION_PREFERENCE_STORES);
  }

  private static liveRoot(resolver: VaultPathResolver, rootName: string): string {
    if (rootName === 'vaults') {
      return resolver.vaultsRoot();
    }
    if (rootName === 'trash') {
      return resolver.trashRoot();
    }
    if (rootName === 'drafts') {
      return resolver.draftsRoot();
    }
    if (rootName === 'agent') {
      return resolver.agentRoot();
    }
    throw new Error('未知的应用备份数据目录');
  }

  private static async copyTreeIfPresent(source: string, target: string): Promise<void> {
    if (fileIo.accessSync(source)) {
      await ApplicationBackupService.copyTree(source, target);
    }
  }

  private static async copyTree(source: string, target: string): Promise<void> {
    const sourceStat: fileIo.Stat = fileIo.lstatSync(source);
    if (sourceStat.isSymbolicLink()) {
      throw new Error('应用数据包含不支持的链接文件，备份未生成');
    }
    if (!sourceStat.isDirectory()) {
      throw new Error('应用备份数据结构无效');
    }
    if (!fileIo.accessSync(target)) {
      fileIo.mkdirSync(target, true);
    }
    const names: string[] = fileIo.listFileSync(source);
    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i];
      // v2.10：备份无条件排除 .git（目录或同名文件，任意层级）——Git 历史由远端重新关联承接。
      if (name === '.git') {
        continue;
      }
      const sourcePath: string = source + '/' + name;
      const targetPath: string = target + '/' + name;
      const stat: fileIo.Stat = fileIo.lstatSync(sourcePath);
      if (stat.isSymbolicLink()) {
        throw new Error('应用数据包含不支持的链接文件，备份未生成');
      }
      if (stat.isDirectory()) {
        await ApplicationBackupService.copyTree(sourcePath, targetPath);
        fileIo.utimes(targetPath, stat.mtime * 1000);
        continue;
      }
      if (!stat.isFile()) {
        throw new Error('应用数据包含不支持的文件类型，备份未生成');
      }
      await fileIo.copyFile(sourcePath, targetPath);
      fileIo.utimes(targetPath, stat.mtime * 1000);
    }
  }

  private static measureTree(root: string): TreeSize {
    const result: TreeSize = { entries: 0, bytes: 0 };
    ApplicationBackupService.addTreeSize(root, result);
    return result;
  }

  private static addTreeSize(path: string, result: TreeSize): void {
    const names: string[] = fileIo.listFileSync(path);
    for (let i: number = 0; i < names.length; i++) {
      const child: string = path + '/' + names[i];
      const stat: fileIo.Stat = fileIo.lstatSync(child);
      if (stat.isDirectory()) {
        ApplicationBackupService.addTreeSize(child, result);
      } else if (stat.isFile()) {
        result.entries++;
        result.bytes += stat.size;
      }
    }
  }

  private static findOversizedFile(root: string, relativeRoot: string, maxBytes: number): OversizedFile | null {
    const names: string[] = fileIo.listFileSync(root);
    for (let i: number = 0; i < names.length; i++) {
      const child: string = root + '/' + names[i];
      const childRelative: string = relativeRoot.length === 0 ? names[i] : relativeRoot + '/' + names[i];
      const stat: fileIo.Stat = fileIo.lstatSync(child);
      if (stat.isDirectory()) {
        const found: OversizedFile | null =
          ApplicationBackupService.findOversizedFile(child, childRelative, maxBytes);
        if (found !== null) {
          return found;
        }
      } else if (stat.size > maxBytes) {
        return { relativePath: childRelative, bytes: stat.size };
      }
    }
    return null;
  }

  private static writeNewTextFile(path: string, content: string): void {
    const slash: number = path.lastIndexOf('/');
    if (slash > 0) {
      const parent: string = path.substring(0, slash);
      if (!fileIo.accessSync(parent)) {
        fileIo.mkdirSync(parent, true);
      }
    }
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content, { encoding: 'utf-8' });
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static async copyFileToPickerUri(sourcePath: string, targetUri: string): Promise<void> {
    const source: fileIo.File = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
    let target: fileIo.File | null = null;
    try {
      target = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(source.fd, target.fd);
    } catch (error) {
      try {
        fileIo.unlinkSync(targetUri);
      } catch (cleanupError) {
        // The save-panel destination may already be gone or its URI grant may have expired.
      }
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('备份文件复制失败');
    } finally {
      fileIo.closeSync(source);
      if (target !== null) {
        fileIo.closeSync(target);
      }
    }
  }

  private static isSafeSegment(value: string): boolean {
    return value.length > 0 && value !== '.' && value !== '..' &&
      value.indexOf('/') < 0 && value.indexOf('\\') < 0 && !value.startsWith('/');
  }

  private static isSafeVaultId(value: string): boolean {
    return ApplicationBackupService.isSafeSegment(value) && !value.startsWith('.');
  }

  private static isSafeVaultKey(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let i: number = 0; i < value.length; i++) {
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

  private static removeIfPresent(path: string): void {
    if (fileIo.accessSync(path)) {
      ApplicationBackupService.removeTree(path);
    }
  }

  private static removeTree(path: string): void {
    if (!fileIo.accessSync(path)) {
      return;
    }
    const stat: fileIo.Stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const names: string[] = fileIo.listFileSync(path);
    for (let i: number = 0; i < names.length; i++) {
      ApplicationBackupService.removeTree(path + '/' + names[i]);
    }
    fileIo.rmdirSync(path);
  }
}
