/**
 * NoteDraftService.ets —— 自动保存完成前的崩溃恢复草稿（v0.2 §3.3-2.5）。
 *
 * 草稿位于 filesDir/drafts/<vaultId>/<note-relative-path>.draft，和正式 vault 隔离。
 * 每条草稿保留正式内容基线；只有正式文件仍与该基线逐字相同才允许恢复，
 * 避免较旧草稿覆盖已经更新的正式笔记。
 */
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VaultRegistry } from './VaultRegistry';

interface NoteDraftRecord {
  version: number;
  baseText: string;
  content: string;
}

interface DraftCopyItem {
  sourceVaultId: string;
  sourcePath: string;
  targetVaultId: string;
  targetPath: string;
}

export interface NoteDraftRecovery {
  recovered: boolean;
  conflict: boolean;
  content: string;
}

export class NoteDraftService {
  private static writeChain: Promise<void> = Promise.resolve();
  private static readonly SUFFIX: string = '.draft';

  /** 正式保存前持久化编辑快照；回到基线时只清理同基线草稿。 */
  static persist(registry: VaultRegistry, vaultId: string, relPath: string,
    baseText: string, content: string): Promise<boolean> {
    return NoteDraftService.enqueue<boolean>(async (): Promise<boolean> => {
      const existing: NoteDraftRecord | null = NoteDraftService.readRecord(registry, vaultId, relPath);
      if (content === baseText) {
        if (existing !== null) {
          NoteDraftService.removeDraftFile(registry, vaultId, relPath);
        }
        return true;
      }
      // 旧草稿内容已成为当前正式基线时可更新；其他基线冲突不静默覆盖。
      if (existing !== null && existing.baseText !== baseText && existing.content !== baseText) {
        return false;
      }
      if (existing !== null && existing.baseText === baseText && existing.content === content) {
        return true;
      }
      const record: NoteDraftRecord = { version: 1, baseText: baseText, content: content };
      await NoteDraftService.writeAtomic(registry, vaultId, relPath, JSON.stringify(record));
      hilog.info(0x0000, 'NoteDraftService', '草稿 AtomicFile 写入完成');
      return true;
    });
  }

  /** 仅正式内容仍等于草稿基线时恢复；相同内容的残留草稿会被清理。 */
  static async recover(registry: VaultRegistry, vaultId: string, relPath: string,
    formalText: string): Promise<NoteDraftRecovery> {
    await NoteDraftService.writeChain;
    const record: NoteDraftRecord | null = NoteDraftService.readRecord(registry, vaultId, relPath);
    if (record === null) {
      NoteDraftService.removeDraftFile(registry, vaultId, relPath);
      return { recovered: false, conflict: false, content: formalText };
    }
    if (record.content === formalText) {
      NoteDraftService.removeDraftFile(registry, vaultId, relPath);
      return { recovered: false, conflict: false, content: formalText };
    }
    if (record.baseText === formalText) {
      return { recovered: true, conflict: false, content: record.content };
    }
    // 没有手动冲突处理界面；丢弃基线已过期的草稿，避免下次打开重复提示或误恢复。
    NoteDraftService.removeDraftFile(registry, vaultId, relPath);
    return { recovered: false, conflict: true, content: formalText };
  }

  /** 正式保存成功后只删除与已保存快照相同的草稿。 */
  static clearIfMatches(registry: VaultRegistry, vaultId: string, relPath: string,
    savedText: string): Promise<void> {
    return NoteDraftService.enqueue<void>(async (): Promise<void> => {
      const record: NoteDraftRecord | null = NoteDraftService.readRecord(registry, vaultId, relPath);
      if (record !== null && record.content === savedText) {
        NoteDraftService.removeDraftFile(registry, vaultId, relPath);
      }
    });
  }

  /** 删除笔记草稿和同路径镜像目录，供删除及移入回收站使用。 */
  static discardPath(registry: VaultRegistry, vaultId: string, relPath: string): Promise<void> {
    return NoteDraftService.enqueue<void>(async (): Promise<void> => {
      NoteDraftService.removeDraftFile(registry, vaultId, relPath);
      NoteDraftService.removeDraftDirectory(registry, vaultId, relPath);
    });
  }

  /** 删除整库草稿，避免同库名重建后恢复旧笔记。 */
  static discardVault(registry: VaultRegistry, vaultId: string): Promise<void> {
    return NoteDraftService.enqueue<void>(async (): Promise<void> => {
      NoteDraftService.removeDraftDirectory(registry, vaultId, '');
    });
  }

  /**
   * 在正式 rename/move 前将匹配草稿复制到新路径；目标冲突时拒绝覆盖。
   * 正式文件改名成功后调用方再清理源草稿。若进程中断，启动扫描会删除无正式文件的一侧。
   */
  static copySubtree(registry: VaultRegistry, sourceVaultId: string, sourcePath: string,
    targetVaultId: string, targetPath: string, isDirectory: boolean): Promise<boolean> {
    return NoteDraftService.enqueue<boolean>(async (): Promise<boolean> => {
      const items: DraftCopyItem[] = [];
      if (sourceVaultId !== targetVaultId || sourcePath !== targetPath) {
        // 正式目标路径已由调用方确认不存在；清掉可能遗留的目标草稿，避免绑定到新文件。
        if (targetPath.length > 0) {
          NoteDraftService.removeDraftFile(registry, targetVaultId, targetPath);
        }
        NoteDraftService.removeDraftDirectory(registry, targetVaultId, targetPath);
      }
      if (isDirectory) {
        NoteDraftService.collectDirectoryCopies(registry, sourceVaultId, sourcePath,
          targetVaultId, targetPath, items);
      } else if (fileIo.accessSync(registry.absoluteDraftIn(sourceVaultId, sourcePath))) {
        items.push({
          sourceVaultId: sourceVaultId,
          sourcePath: sourcePath,
          targetVaultId: targetVaultId,
          targetPath: targetPath
        });
      }
      if (items.length === 0) {
        return false;
      }
      for (let i = 0; i < items.length; i++) {
        if (fileIo.accessSync(registry.absoluteDraftIn(items[i].targetVaultId, items[i].targetPath))) {
          throw new Error('目标位置已有草稿，拒绝覆盖');
        }
      }
      const copied: DraftCopyItem[] = [];
      try {
        for (let i = 0; i < items.length; i++) {
          const item: DraftCopyItem = items[i];
          const content: string = fileIo.readTextSync(
            registry.absoluteDraftIn(item.sourceVaultId, item.sourcePath));
          await NoteDraftService.writeAtomic(registry, item.targetVaultId, item.targetPath, content);
          copied.push(item);
        }
      } catch (error) {
        for (let i = 0; i < copied.length; i++) {
          NoteDraftService.removeDraftFile(registry, copied[i].targetVaultId, copied[i].targetPath);
        }
        const err = error as Error;
        throw new Error(err.message);
      }
      return true;
    });
  }

  /** Ability 启动时清理已删除/移动文件对应的孤儿草稿。 */
  static cleanupOrphans(registry: VaultRegistry): void {
    const root: string = registry.draftsRoot();
    let draftKeys: string[] = [];
    let knownVaults = registry.list();
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
      if (!fileIo.statSync(root).isDirectory()) {
        const recoveryFile: string = registry.draftsRootRecoveryFile();
        if (fileIo.accessSync(recoveryFile)) {
          hilog.error(0x0000, 'NoteDraftService', '草稿根不是目录，且保留文件已存在；跳过清理');
          return;
        }
        fileIo.renameSync(root, recoveryFile);
        fileIo.mkdirSync(root);
        hilog.error(0x0000, 'NoteDraftService', '草稿根不是目录，原文件已保留并重建草稿目录');
      }
      draftKeys = fileIo.listFileSync(root);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, 'NoteDraftService', '扫描草稿目录失败: %{public}s', err.message);
      return;
    }
    // v1.5 15.6：草稿目录按 **vaultKey** 分（不是 vaultId），与回收站口径一致。
    // 好处是库改名后旧草稿仍找得到；代价是这里要按 key 反查 id。
    for (let i = 0; i < draftKeys.length; i++) {
      const draftKey: string = draftKeys[i];
      let ownerId: string = '';
      for (let j = 0; j < knownVaults.length; j++) {
        if (knownVaults[j].vaultKey === draftKey) {
          ownerId = knownVaults[j].id;
          break;
        }
      }
      try {
        if (ownerId.length > 0) {
          NoteDraftService.cleanupDirectory(registry, ownerId, '');
        } else {
          // 孤儿目录（库已删/注册表重建）：整个按 key 删掉。
          registry.removeDraftsTreeByKey(draftKey);
        }
      } catch (error) {
        // 清理失败不阻止启动；恢复仍会逐字比较正式内容基线。
      }
    }
  }

  private static enqueue<T>(action: () => Promise<T>): Promise<T> {
    const job: Promise<T> = NoteDraftService.writeChain.then(action);
    NoteDraftService.writeChain = job.then((): void => {
    }, (): void => {
    });
    return job;
  }

  private static readRecord(registry: VaultRegistry, vaultId: string,
    relPath: string): NoteDraftRecord | null {
    const draftPath: string = registry.absoluteDraftIn(vaultId, relPath);
    try {
      if (!fileIo.accessSync(draftPath)) {
        return null;
      }
      const record: NoteDraftRecord = JSON.parse(fileIo.readTextSync(draftPath)) as NoteDraftRecord;
      if (record.version !== 1 || typeof record.baseText !== 'string' || typeof record.content !== 'string') {
        return null;
      }
      return record;
    } catch (error) {
      return null;
    }
  }

  private static removeDraftFile(registry: VaultRegistry, vaultId: string, relPath: string): void {
    try {
      const draftPath: string = registry.absoluteDraftIn(vaultId, relPath);
      if (fileIo.accessSync(draftPath)) {
        fileIo.unlinkSync(draftPath);
      }
    } catch (error) {
      // 清理失败不应阻止正式笔记打开；后续启动再清理。
    }
  }

  private static removeDraftDirectory(registry: VaultRegistry, vaultId: string,
    relativeDirectory: string): void {
    const dirPath: string = registry.draftDirectory(vaultId, relativeDirectory);
    if (!fileIo.accessSync(dirPath)) {
      return;
    }
    if (!fileIo.statSync(dirPath).isDirectory()) {
      fileIo.unlinkSync(dirPath);
      return;
    }
    const names: string[] = fileIo.listFileSync(dirPath);
    for (let i = 0; i < names.length; i++) {
      const childRel: string = relativeDirectory.length > 0
        ? relativeDirectory + '/' + names[i] : names[i];
      const childPath: string = registry.draftDirectory(vaultId, childRel);
      if (fileIo.statSync(childPath).isDirectory()) {
        NoteDraftService.removeDraftDirectory(registry, vaultId, childRel);
      } else if (names[i].endsWith(NoteDraftService.SUFFIX)) {
        const notePath: string = childRel.substring(0, childRel.length - NoteDraftService.SUFFIX.length);
        NoteDraftService.removeDraftFile(registry, vaultId, notePath);
      } else {
        fileIo.unlinkSync(childPath);
      }
    }
    fileIo.rmdirSync(dirPath);
  }

  private static collectDirectoryCopies(registry: VaultRegistry, sourceVaultId: string,
    sourceDirectory: string, targetVaultId: string, targetDirectory: string,
    items: DraftCopyItem[]): void {
    const sourceAbs: string = registry.draftDirectory(sourceVaultId, sourceDirectory);
    if (!fileIo.accessSync(sourceAbs)) {
      return;
    }
    const names: string[] = fileIo.listFileSync(sourceAbs);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const sourceChild: string = sourceDirectory.length > 0 ? sourceDirectory + '/' + name : name;
      const childAbs: string = registry.draftDirectory(sourceVaultId, sourceChild);
      if (fileIo.statSync(childAbs).isDirectory()) {
        const targetChild: string = targetDirectory.length > 0 ? targetDirectory + '/' + name : name;
        NoteDraftService.collectDirectoryCopies(registry, sourceVaultId, sourceChild,
          targetVaultId, targetChild, items);
      } else if (name.endsWith(NoteDraftService.SUFFIX)) {
        const sourceNotePath: string = sourceChild.substring(0,
          sourceChild.length - NoteDraftService.SUFFIX.length);
        const suffix: string = sourceDirectory.length > 0
          ? sourceNotePath.substring(sourceDirectory.length) : sourceNotePath;
        items.push({
          sourceVaultId: sourceVaultId,
          sourcePath: sourceNotePath,
          targetVaultId: targetVaultId,
          targetPath: targetDirectory + suffix
        });
      }
    }
  }

  private static cleanupDirectory(registry: VaultRegistry, vaultId: string,
    relativeDirectory: string): void {
    const dirPath: string = registry.draftDirectory(vaultId, relativeDirectory);
    const names: string[] = fileIo.listFileSync(dirPath);
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const childRel: string = relativeDirectory.length > 0 ? relativeDirectory + '/' + name : name;
      const childPath: string = registry.draftDirectory(vaultId, childRel);
      if (fileIo.statSync(childPath).isDirectory()) {
        NoteDraftService.cleanupDirectory(registry, vaultId, childRel);
        if (fileIo.listFileSync(childPath).length === 0) {
          fileIo.rmdirSync(childPath);
        }
      } else if (name.endsWith(NoteDraftService.SUFFIX)) {
        const notePath: string = childRel.substring(0, childRel.length - NoteDraftService.SUFFIX.length);
        if (!fileIo.accessSync(registry.absoluteIn(vaultId, notePath))) {
          fileIo.unlinkSync(childPath);
        }
      }
    }
  }

  private static async writeAtomic(registry: VaultRegistry, vaultId: string, relPath: string,
    content: string): Promise<void> {
    NoteDraftService.ensureParents(registry, vaultId, relPath);
    const path: string = registry.absoluteDraftIn(vaultId, relPath);
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (message: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (error) {
          // Preserve the original write failure.
        }
        reject(new Error(message));
      };
      const finish = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
        } catch (error) {
          const err = error as BusinessError;
          fail(err.message);
          return;
        }
        settled = true;
        resolve();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        timerId = setTimeout((): void => {
          fail('草稿写入回调超时');
        }, 3000);
        stream.write(content, 'utf-8', (err?: BusinessError): void => {
          if (err !== undefined && err !== null) {
            fail(err.message);
            return;
          }
          finish();
        });
      } catch (error) {
        const err = error as BusinessError;
        fail(err.message);
      }
    });
  }

  private static ensureParents(registry: VaultRegistry, vaultId: string, relPath: string): void {
    const root: string = registry.draftsRoot();
    if (!fileIo.accessSync(root)) {
      fileIo.mkdirSync(root);
    }
    const vaultDir: string = registry.draftsVaultDirOf(vaultId);
    if (!fileIo.accessSync(vaultDir)) {
      fileIo.mkdirSync(vaultDir);
    }
    const segments: string[] = relPath.split('/');
    for (let i = 1; i < segments.length; i++) {
      const relativeDirectory: string = segments.slice(0, i).join('/');
      const dirPath: string = registry.draftDirectory(vaultId, relativeDirectory);
      if (!fileIo.accessSync(dirPath)) {
        fileIo.mkdirSync(dirPath);
      }
    }
  }
}
