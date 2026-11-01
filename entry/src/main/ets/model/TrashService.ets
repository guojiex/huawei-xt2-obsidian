/**
 * TrashService.ets —— 回收站（v0.2 需求 1.7 / 1.8）
 *
 * 位置与结构（**v1.5 15.6 已搬家**）：沙箱 `filesDir/trash/<vaultKey>/` 下**镜像原库内
 * 相对路径**（删 `工程/a.md` → `trash/<vaultKey>/工程/a.md`）。
 *
 * 早先是 `<vaultDir>/.trash/`，v1.5 挪到库外的理由：
 *  - 外部授权库的「库目录」是**用户的目录**，在里面建 `.trash` 会被 Obsidian / Git /
 *    云盘当成普通内容，也和 15.5「移除库只解除关联、不清磁盘」打架（那个目录算谁的？）；
 *  - 按 `<vaultKey>` 而不是 `<vaultId>` 分段，库改名后回收站仍能定位；
 *  - 顺带不用再给 Git 同步写 `.gitignore` —— 它已经不在仓库里了。
 * 仍在的约定：恢复目标 = 它在回收站里的相对路径本身（不需要第二份「原路径」元数据）。
 * 代价：删库时要**显式**清掉 `trash/<vaultKey>`（VaultRegistry.remove 已做）；
 *       以前这活是递归删库根顺带完成的。
 *
 * 与 NoteService 的分工：那边管「库里的笔记」，这边管「已删出库但还能救回的笔记」。
 * 删除语义（原型 deleteWithUndo）：文件 → 移入回收站 + 5 秒撤销条；
 * 目录 → 永久删除（确认框），不进回收站 —— 误删一棵子树的代价不该被「撤销」轻描淡写。
 *
 * 路径铁律（硬约束 #14）：绝对路径一律经 `VaultRegistry.absoluteInTrash()`，
 * `trash/<vaultKey>` 段的拼接收口在 VaultPathResolver（本文件不拼沙箱路径）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { VaultRegistry } from './VaultRegistry';
import { VaultAccess, VaultDirChild, isVaultNoteName } from './VaultAccess';
import { FullTextSearchService } from './FullTextSearchService';
import { WikiLinkService } from './WikiLinkService';

const TRASH_DOMAIN: number = 0x0005;
const TRASH_TAG: string = 'TrashService';

/** 回收站条目（回收站视图一行） */
export interface TrashItem {
  /** 原库内相对路径 = 恢复目标路径（回收站内的镜像路径，含重名后缀时的实际名） */
  relPath: string;
  /** 显示名（最后一段） */
  name: string;
  /** 删除时间（文件 mtime 秒，排序用 —— 进回收站时 renameSync 会刷新它） */
  deletedAt: number;
}

/** 撤销条快照（1.7）：移入回收站那一刻的现场，5 秒内「撤销」用（Index 持有） */
export interface UndoSnap {
  /** 删除时所在的库（撤销时可能已切库，恢复要指回原库） */
  vaultId: string;
  /** 回收站内的相对路径（= 恢复目标，含重名后缀时的实际名） */
  relPath: string;
  /** 删的是否是当时正在编辑的文件（撤销后重新加载它，原型 snap.wasCurrent） */
  wasCurrent: boolean;
  /** 文件是否也在右栏打开；右栏独有笔记撤销后恢复到原栏。 */
  wasRight: boolean;
}

export class TrashService {
  private static mutationChain: Promise<void> = Promise.resolve();
  private static legacyMigrationCompleted: Set<string> = new Set<string>();

  /**
   * 把文件移入回收站（1.7 主路径：左滑滑到底 / 删除确认框的「确认删除」）。
   * - 逐级补建回收站里的父目录（镜像结构）；
   * - 回收站里已有同路径文件（同一路径删两次且未恢复）→ 扩展名前加 -2/-3（不覆盖，
   *   与 NoteService.uniqueRelPath 同策略：覆盖等于静默丢掉一次已删内容）；
   * - renameSync 原子移动（同分区），中途失败不留半状态（最多留下空目录）。
   * 只收文件；目录删除走 NoteService.deletePath（永久，配确认框）。
   * 返回**回收站内的实际相对路径**（同路径二次删除会被加 -2 后缀，
   * 调用方拿它做恢复快照 —— 撤销/恢复都以它为准，不能拿入参当恢复目标）。
   */
  static moveToTrash(registry: VaultRegistry, vaultId: string, relPath: string): Promise<string> {
    return TrashService.enqueue<string>(async (): Promise<string> => {
      const access = registry.accessFor(vaultId);
      const content: string = access.readText(relPath);
      return TrashService.moveTextToPrivateTrash(registry, vaultId, relPath, content, access);
    });
  }

  private static async moveTextToPrivateTrash(registry: VaultRegistry, vaultId: string,
    relPath: string, content: string, access: VaultAccess): Promise<string> {
    let target: string = relPath;
    if (TrashService.existsInTrash(registry, vaultId, relPath)) {
      const dot: number = relPath.lastIndexOf('.');
      const stem: string = dot > 0 ? relPath.substring(0, dot) : relPath;
      const ext: string = dot > 0 ? relPath.substring(dot) : '';
      let n: number = 2;
      target = stem + '-' + n + ext;
      while (TrashService.existsInTrash(registry, vaultId, target)) {
        n++;
        target = stem + '-' + n + ext;
      }
    }
    // 回收站根必须先建：顶层文件没有父段可补建（ensureTrashParents 循环不跑）。
    const trashRoot: string = registry.trashDirOf(vaultId);
    if (!fileIo.accessSync(trashRoot)) {
      fileIo.mkdirSync(trashRoot);
    }
    TrashService.ensureTrashParents(registry, vaultId, target);
    const dst: string = registry.absoluteInTrash(vaultId, target);
    await TrashService.writePrivateAtomic(dst, content);
    if (fileIo.readTextSync(dst) !== content) {
      TrashService.removePrivateCopy(dst);
      throw new Error('回收站副本校验失败，原笔记未删除');
    }
    if (access.readText(relPath) !== content) {
      TrashService.removePrivateCopy(dst);
      throw new Error('笔记在删除过程中已变化，已保留原文件');
    }
    try {
      access.remove(relPath);
    } catch (error) {
      // If the source is still readable and unchanged, discard the redundant backup.
      // If access was lost or the source changed, retain the private copy as a recovery path.
      try {
        if (access.readText(relPath) === content) {
          TrashService.removePrivateCopy(dst);
        }
      } catch (readError) {
        // Keep the verified private copy when source state cannot be established.
      }
      const err = error as Error;
      throw new Error(err.message);
    }
    FullTextSearchService.noteRemoved(vaultId, relPath, false);
    WikiLinkService.pathRemoved(vaultId);
    hilog.info(TRASH_DOMAIN, TRASH_TAG, '移入回收站 %{public}s → %{public}s', relPath, target);
    return target;
  }

  /**
   * Import legacy in-vault `.trash` notes into the private trash on first access.
   * The original directory is intentionally retained. Copy is atomic and read-back
   * verified; identical destination content makes retries idempotent, while collisions
   * receive a numbered name instead of overwriting an existing recovery copy.
   */
  static migrateLegacyTrash(registry: VaultRegistry, vaultId: string): Promise<void> {
    return TrashService.enqueue<void>(async (): Promise<void> => {
      if (TrashService.legacyMigrationCompleted.has(vaultId)) {
        return;
      }
      const access: VaultAccess = registry.accessFor(vaultId);
      const legacyRoot = access.stat('.trash');
      if (legacyRoot === null) {
        TrashService.legacyMigrationCompleted.add(vaultId);
        return;
      }
      if (!legacyRoot.isDir || legacyRoot.isSymbolicLink) {
        throw new Error('旧回收站不是安全目录，原目录已保留');
      }

      let visited: number = 0;
      const copyDirectory = async (sourceDir: string, targetDir: string, depth: number): Promise<void> => {
        if (depth > 64) {
          throw new Error('旧回收站目录层级超限，已保留原目录；可稍后重试');
        }
        const children: VaultDirChild[] = access.listAll(sourceDir, true);
        for (let i = 0; i < children.length; i++) {
          visited++;
          if (visited > 20000) {
            throw new Error('旧回收站条目超限，已保留原目录；可稍后重试');
          }
          const child: VaultDirChild = children[i];
          const sourcePath: string = sourceDir + '/' + child.name;
          const targetPath: string = targetDir.length === 0 ? child.name : targetDir + '/' + child.name;
          const sourceStat = access.stat(sourcePath);
          if (sourceStat === null || sourceStat.isSymbolicLink) {
            throw new Error('旧回收站条目无法安全读取，已保留原目录');
          }
          if (child.isDir) {
            if (!sourceStat.isDir) {
              throw new Error('旧回收站目录状态发生变化，已保留原目录');
            }
            await copyDirectory(sourcePath, targetPath, depth + 1);
            continue;
          }
          // The legacy trash only accepted Markdown notes. Leave any foreign files in place.
          if (!isVaultNoteName(child.name)) {
            continue;
          }
          if (sourceStat.isDir) {
            throw new Error('旧回收站文件状态发生变化，已保留原目录');
          }
          const content: string = access.readText(sourcePath);
          let destination: string = TrashService.findLegacyTrashDestination(registry, vaultId, targetPath,
            content);
          if (destination.length === 0) {
            continue;
          }
          const trashRoot: string = registry.trashDirOf(vaultId);
          if (!fileIo.accessSync(trashRoot)) {
            fileIo.mkdirSync(trashRoot);
          }
          TrashService.ensureTrashParents(registry, vaultId, destination);
          const destinationAbs: string = registry.absoluteInTrash(vaultId, destination);
          await TrashService.writePrivateAtomic(destinationAbs, content);
          if (fileIo.readTextSync(destinationAbs) !== content) {
            TrashService.removePrivateCopy(destinationAbs);
            throw new Error('旧回收站副本校验失败，原目录已保留');
          }
        }
      };

      await copyDirectory('.trash', '', 0);
      TrashService.legacyMigrationCompleted.add(vaultId);
      hilog.info(TRASH_DOMAIN, TRASH_TAG, '旧回收站已复制并校验，源目录保留');
    });
  }

  private static findLegacyTrashDestination(registry: VaultRegistry, vaultId: string,
    relPath: string, content: string): string {
    const slash: number = relPath.lastIndexOf('/');
    const parent: string = slash >= 0 ? relPath.substring(0, slash + 1) : '';
    const name: string = slash >= 0 ? relPath.substring(slash + 1) : relPath;
    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const extension: string = dot > 0 ? name.substring(dot) : '';
    let candidate: string = relPath;
    let suffix: number = 2;
    while (true) {
      const abs: string = registry.absoluteInTrash(vaultId, candidate);
      let existing: fileIo.Stat;
      try {
        existing = fileIo.lstatSync(abs);
      } catch (error) {
        const err = error as BusinessError;
        const code: number = typeof err.code === 'number' ? err.code : -1;
        if (code === 2 || code === 13900002) {
          return candidate;
        }
        throw new Error(err.message);
      }
      try {
        if (!existing.isDirectory() && !existing.isSymbolicLink() && fileIo.readTextSync(abs) === content) {
          return '';
        }
      } catch (error) {
        // A directory or unreadable existing path is a collision; keep searching.
      }
      candidate = parent + stem + '-' + suffix.toString() + extension;
      suffix++;
    }
  }

  /**
   * 列出回收站全部文件（1.8 回收站视图）。递归镜像结构收文件，按删除时间倒序
   * （最近删的排最前，与原型 TRASH.unshift 一致）。目录本身不列 —— 恢复按文件逐个来。
   */
  static list(registry: VaultRegistry, vaultId: string): TrashItem[] {
    const out: TrashItem[] = [];
    const root: string = registry.trashDirOf(vaultId);
    if (!fileIo.accessSync(root)) {
      return out;
    }
    TrashService.walk(registry, vaultId, '', out);
    out.sort((a: TrashItem, b: TrashItem): number => b.deletedAt - a.deletedAt);
    return out;
  }

  /**
   * 恢复到原位置（1.8「恢复」按钮 / 1.7 撤销条共用）。
   * 原位置已有同名文件 → 抛错（文案即 toast 内容），**不自动改名也不覆盖**：
   * 原型语义（restoreTrashItem 的「原位置已有同名文件，请先处理重名」）。
   * 成功返回恢复后的库内相对路径（= trashRel 本身）。
   */
  static restore(registry: VaultRegistry, vaultId: string, trashRel: string): Promise<string> {
    return TrashService.enqueue<string>(async (): Promise<string> => {
      if (TrashService.existsAtOrigin(registry, vaultId, trashRel)) {
        throw new Error('原位置已有同名文件，请先处理重名');
      }
      const content: string = fileIo.readTextSync(registry.absoluteInTrash(vaultId, trashRel));
      const access = registry.accessFor(vaultId);
      access.ensureDir(TrashService.parentDirectory(trashRel));
      // Recheck just before the write; the private recovery source remains untouched until
      // the formal target has been written and read back exactly.
      if (TrashService.existsAtOrigin(registry, vaultId, trashRel)) {
        throw new Error('原位置已有同名文件，请先处理重名');
      }
      await access.writeAtomic(trashRel, content);
      let restored: string;
      try {
        restored = access.readText(trashRel);
      } catch (error) {
        throw new Error('恢复副本校验失败，回收站原件仍保留');
      }
      if (restored !== content) {
        throw new Error('恢复副本校验失败，回收站原件仍保留');
      }
      fileIo.unlinkSync(registry.absoluteInTrash(vaultId, trashRel));
      FullTextSearchService.noteRestored(registry, vaultId, trashRel);
      WikiLinkService.pathAdded(vaultId);
      hilog.info(TRASH_DOMAIN, TRASH_TAG, '恢复 %{public}s', trashRel);
      return trashRel;
    });
  }

  private static existsInTrash(registry: VaultRegistry, vaultId: string, relPath: string): boolean {
    try {
      return fileIo.accessSync(registry.absoluteInTrash(vaultId, relPath));
    } catch (error) {
      return false;
    }
  }

  /** 原位置（库内，不在回收站）是否已有同名文件（restore 拒绝覆盖的判定） */
  private static existsAtOrigin(registry: VaultRegistry, vaultId: string, relPath: string): boolean {
    try {
      return registry.accessFor(vaultId).exists(relPath);
    } catch (error) {
      return false;
    }
  }

  /** 补建回收站内 target 的所有父目录（镜像结构逐级 mkdir） */
  private static ensureTrashParents(registry: VaultRegistry, vaultId: string, target: string): void {
    const segs: string[] = target.split('/');
    for (let i = 1; i < segs.length; i++) {
      const dirRel: string = segs.slice(0, i).join('/');
      const dirAbs: string = registry.absoluteInTrash(vaultId, dirRel);
      if (!fileIo.accessSync(dirAbs)) {
        fileIo.mkdirSync(dirAbs);
      }
    }
  }

  private static parentDirectory(relPath: string): string {
    const slash: number = relPath.lastIndexOf('/');
    return slash > 0 ? relPath.substring(0, slash) : '';
  }

  private static removePrivateCopy(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
      // Best effort: a verified recovery copy is safer to retain than to lose.
    }
  }

  private static enqueue<T>(action: () => Promise<T>): Promise<T> {
    const job: Promise<T> = TrashService.mutationChain.then(action);
    TrashService.mutationChain = job.then((): void => {
    }, (): void => {
    });
    return job;
  }

  /** Write a private copy with AtomicFile; the source note remains untouched until verification. */
  private static writePrivateAtomic(path: string, content: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (rollbackError) {
          // Preserve the initial write error.
        }
        reject(error);
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
          fail(new Error(err.message));
          return;
        }
        settled = true;
        resolve();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        if (content.length === 0) {
          finish();
          return;
        }
        timerId = setTimeout((): void => {
          fail(new Error('回收站写入回调 3s 未触发'));
        }, 3000);
        stream.write(content, 'utf-8', (error?: BusinessError): void => {
          if (error !== undefined && error !== null) {
            fail(new Error(error.message));
          } else {
            finish();
          }
        });
      } catch (error) {
        const err = error as BusinessError;
        fail(new Error(err.message));
      }
    });
  }

  /** 递归收集回收站文件；relDir 为镜像的库内相对目录（'' = 回收站根） */
  private static walk(registry: VaultRegistry, vaultId: string, relDir: string, out: TrashItem[]): void {
    const absDir: string = relDir.length === 0
      ? registry.trashDirOf(vaultId)
      : registry.absoluteInTrash(vaultId, relDir);
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(absDir);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(TRASH_DOMAIN, TRASH_TAG, '列回收站目录失败 %{public}s: %{public}s', relDir, err.message);
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const nm: string = names[i];
      const rel: string = relDir.length === 0 ? nm : relDir + '/' + nm;
      const abs: string = registry.absoluteInTrash(vaultId, rel);
      let stat: fileIo.Stat;
      try {
        stat = fileIo.statSync(abs);
      } catch (error) {
        continue;
      }
      if (stat.isDirectory()) {
        TrashService.walk(registry, vaultId, rel, out);
      } else {
        out.push({ relPath: rel, name: nm, deletedAt: stat.mtime });
      }
    }
  }
}
