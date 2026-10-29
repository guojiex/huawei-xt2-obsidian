/**
 * TrashService.ets —— 回收站（v0.2 需求 1.7 / 1.8）
 *
 * 位置与结构：`vaults/<库>/.trash/` 下**镜像原库内相对路径**（删 `工程/a.md`
 * → `.trash/工程/a.md`）。为什么放库目录里而不是全局回收站：
 *  - 库改名 / 删除时回收站自动跟着走（rename/rmdir 作用在库根，`.trash` 是其子树）；
 *  - FileTree 天然过滤点开头目录，文件树里看不见它，不用加过滤规则；
 *  - 恢复目标就是它在 `.trash` 里的相对路径本身，不需要第二份「原路径」元数据。
 *  ⚠️ v0.3 Git 同步接入时要给 `.trash` 配 .gitignore（不能把已删笔记推上远端）。
 *
 * 与 NoteService 的分工：那边管「库里的笔记」，这边管「已删出库但还能救回的笔记」。
 * 删除语义（原型 deleteWithUndo）：文件 → 移入回收站 + 5 秒撤销条；
 * 目录 → 永久删除（确认框），不进回收站 —— 误删一棵子树的代价不该被「撤销」轻描淡写。
 *
 * 路径铁律（硬约束 #14）：绝对路径一律经 `VaultRegistry.absoluteInTrash()`，
 * `.trash` 段的拼接收口在 VaultPathResolver（本文件不拼沙箱路径）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { VaultRegistry } from './VaultRegistry';
import { FullTextSearchService } from './FullTextSearchService';
import { WikiLinkService } from './WikiLinkService';

const TRASH_DOMAIN: number = 0x0005;
const TRASH_TAG: string = 'TrashService';

/** 回收站条目（回收站视图一行） */
export interface TrashItem {
  /** 原库内相对路径 = 恢复目标路径（`.trash` 内的镜像路径，含重名后缀时的实际名） */
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
  /**
   * 把文件移入回收站（1.7 主路径：左滑滑到底 / 删除确认框的「确认删除」）。
   * - 逐级补建 `.trash` 里的父目录（镜像结构）；
   * - 回收站里已有同路径文件（同一路径删两次且未恢复）→ 扩展名前加 -2/-3（不覆盖，
   *   与 NoteService.uniqueRelPath 同策略：覆盖等于静默丢掉一次已删内容）；
   * - renameSync 原子移动（同分区），中途失败不留半状态（最多留下空目录）。
   * 只收文件；目录删除走 NoteService.deletePath（永久，配确认框）。
   * 返回**回收站内的实际相对路径**（同路径二次删除会被加 -2 后缀，
   * 调用方拿它做恢复快照 —— 撤销/恢复都以它为准，不能拿入参当恢复目标）。
   */
  static moveToTrash(registry: VaultRegistry, vaultId: string, relPath: string): string {
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
    // `.trash` 根必须先建：顶层文件没有父段可补建（ensureTrashParents 循环不跑），
    // 嵌套文件的第一级 mkdir 也因 `.trash` 缺失而 ENOENT —— renameSync 必失败。
    const trashRoot: string = registry.trashDirOf(vaultId);
    if (!fileIo.accessSync(trashRoot)) {
      fileIo.mkdirSync(trashRoot);
    }
    TrashService.ensureTrashParents(registry, vaultId, target);
    const src: string = registry.absoluteIn(vaultId, relPath);
    const dst: string = registry.absoluteInTrash(vaultId, target);
    fileIo.renameSync(src, dst);
    FullTextSearchService.noteRemoved(vaultId, relPath, false);
    WikiLinkService.pathRemoved(vaultId);
    hilog.info(TRASH_DOMAIN, TRASH_TAG, '移入回收站 %{public}s → %{public}s', relPath, target);
    return target;
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
  static restore(registry: VaultRegistry, vaultId: string, trashRel: string): string {
    if (TrashService.existsAtOrigin(registry, vaultId, trashRel)) {
      throw new Error('原位置已有同名文件，请先处理重名');
    }
    // 恢复目标可能建在（已被删掉的）多层子目录里，逐级补建
    const segs: string[] = trashRel.split('/');
    for (let i = 1; i < segs.length; i++) {
      const dirRel: string = segs.slice(0, i).join('/');
      const dirAbs: string = registry.absoluteIn(vaultId, dirRel);
      if (!fileIo.accessSync(dirAbs)) {
        fileIo.mkdirSync(dirAbs);
      }
    }
    const src: string = registry.absoluteInTrash(vaultId, trashRel);
    const dst: string = registry.absoluteIn(vaultId, trashRel);
    fileIo.renameSync(src, dst);
    FullTextSearchService.noteRestored(registry, vaultId, trashRel);
    WikiLinkService.pathAdded(vaultId);
    hilog.info(TRASH_DOMAIN, TRASH_TAG, '恢复 %{public}s', trashRel);
    return trashRel;
  }

  private static existsInTrash(registry: VaultRegistry, vaultId: string, relPath: string): boolean {
    try {
      return fileIo.accessSync(registry.absoluteInTrash(vaultId, relPath));
    } catch (error) {
      return false;
    }
  }

  /** 原位置（库内，不在 `.trash`）是否已有同名文件（restore 拒绝覆盖的判定） */
  private static existsAtOrigin(registry: VaultRegistry, vaultId: string, relPath: string): boolean {
    try {
      return fileIo.accessSync(registry.absoluteIn(vaultId, relPath));
    } catch (error) {
      return false;
    }
  }

  /** 补建 `.trash` 内 target 的所有父目录（镜像结构逐级 mkdir） */
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

  /** 递归收集回收站文件；relDir 为镜像的库内相对目录（'' = `.trash` 根） */
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
