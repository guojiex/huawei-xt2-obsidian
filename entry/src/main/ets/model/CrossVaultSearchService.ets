/**
 * CrossVaultSearchService.ets —— v1.35 跨库搜索（35.2 / 35.6；v1.40 改用持久索引）。
 *
 * 显式「全部库」范围的逐库搜索与合并：
 * - 不建全局合并索引、不后台预扫（需求「明确不做」）；每次查询逐库执行；
 * - 排序：当前库结果在前，其余按库在库管理（注册表数组）中的顺序（35.2）；
 * - 不可读的库（外部授权失效、目录被移走等）逐库 try/catch 跳过并记名，不弹授权、
 *   不让单个库失败拖垮整个搜索（35.6）；失败路径即 v1.5 统一访问层抛错的
 *   VaultAccessError（errno 分类见 VaultAccess.describe，api_notes T3/T5）；
 * - v1.40（40.2）：正文搜索逐库走 FullTextSearchService 的持久 RDB 索引，
 *   不再为非当前库临时建内存索引；索引不可用的库沿既有「跳过并记名」语义处理；
 * - 可取消：新一次 run 推进 generation，旧 run 在库边界自行终止；cancel() 供
 *   面板关闭时显式终止（技术约束「关闭面板或修改查询即取消未完成的库」）。
 * 查询词与笔记内容不进日志或埋点。
 */
import { FileTree } from './FileTree';
import { VaultRegistry } from './VaultRegistry';
import { VaultEntry } from './Vault';
import { VaultAccess } from './VaultAccess';
import { FullTextSearchResult } from './SearchStore';
import { FullTextSearchService } from './FullTextSearchService';

/** 单条跨库命中：vaultId 即库名（FR-010 显示名与目录名不分离）。 */
export interface CrossVaultHit {
  vaultId: string;
  path: string;
  /** 正文命中时的摘录；文件名/路径命中为空串。 */
  excerpt: string;
}

/** 按库分组的结果：组标题 = 库名 + 命中数（35.3）。 */
export interface CrossVaultSearchGroup {
  vaultId: string;
  isCurrentVault: boolean;
  hits: CrossVaultHit[];
}

/** 一次「全部库」搜索的产出：命中的分组 + 被跳过的库名（35.6）。 */
export interface CrossVaultSearchOutcome {
  groups: CrossVaultSearchGroup[];
  skippedVaultNames: string[];
}

export class CrossVaultSearchService {
  /** 取消代：新 run / cancel() 推进，旧 run 在库边界检测失配后放弃剩余工作。 */
  private static generation: number = 0;

  /** 面板关闭时终止未完成的逐库搜索；结果即使返回也会被组件侧请求号丢弃。 */
  static cancel(): void {
    CrossVaultSearchService.generation++;
  }

  /**
   * 逐库执行并合并结果。
   * mode：'name' 搜文件名与路径，'content' 搜正文（v1.40 起逐库查询持久索引）。
   * onVaultStart：每开始搜一个库回调库名，供 UI 显示「正在搜索 {库名}…」。
   */
  static async run(registry: VaultRegistry, vaults: VaultEntry[], currentVaultId: string,
    query: string, mode: string, onVaultStart: (vaultName: string) => void): Promise<CrossVaultSearchOutcome> {
    CrossVaultSearchService.generation++;
    const generation: number = CrossVaultSearchService.generation;
    const outcome: CrossVaultSearchOutcome = { groups: [], skippedVaultNames: [] };
    const trimmed: string = query.trim();
    const normalized: string = trimmed.toLowerCase();
    if (normalized.length === 0) {
      return outcome;
    }
    const ordered: VaultEntry[] = CrossVaultSearchService.orderVaults(vaults, currentVaultId);
    for (let i = 0; i < ordered.length; i++) {
      if (generation !== CrossVaultSearchService.generation) {
        return outcome;
      }
      const entry: VaultEntry = ordered[i];
      onVaultStart(entry.id);
      try {
        let hits: CrossVaultHit[] = [];
        if (mode === 'content') {
          const results: FullTextSearchResult[] = await FullTextSearchService.search(registry, entry.id,
            trimmed, (_completed: number, _total: number): void => {});
          hits = CrossVaultSearchService.toHits(entry.id, results);
        } else {
          const access: VaultAccess = registry.accessFor(entry.id);
          hits = CrossVaultSearchService.searchNames(entry.id, FileTree.allNotesOf(access), normalized);
        }
        if (hits.length > 0) {
          outcome.groups.push({
            vaultId: entry.id,
            isCurrentVault: entry.id === currentVaultId,
            hits: hits
          });
        }
      } catch (error) {
        // 35.6：授权失效/目录被移走/索引不可用等只跳过并记名，不中断其余库。
        outcome.skippedVaultNames.push(entry.id);
      }
    }
    return outcome;
  }

  /** 当前库在前，其余按注册表数组顺序（= 库管理顺序，35.2）。 */
  private static orderVaults(vaults: VaultEntry[], currentVaultId: string): VaultEntry[] {
    const ordered: VaultEntry[] = [];
    for (let i = 0; i < vaults.length; i++) {
      if (vaults[i].id === currentVaultId) {
        ordered.push(vaults[i]);
      }
    }
    for (let i = 0; i < vaults.length; i++) {
      if (vaults[i].id !== currentVaultId) {
        ordered.push(vaults[i]);
      }
    }
    return ordered;
  }

  /** 文件名/路径包含匹配（与快切当前库口径一致：文件名或相对路径、忽略大小写）。 */
  private static searchNames(vaultId: string, paths: string[], normalized: string): CrossVaultHit[] {
    const hits: CrossVaultHit[] = [];
    for (let i = 0; i < paths.length; i++) {
      const path: string = paths[i];
      const slash: number = path.lastIndexOf('/');
      const name: string = slash >= 0 ? path.substring(slash + 1) : path;
      if (name.toLowerCase().indexOf(normalized) >= 0 || path.toLowerCase().indexOf(normalized) >= 0) {
        hits.push({ vaultId: vaultId, path: path, excerpt: '' });
      }
    }
    return hits;
  }

  private static toHits(vaultId: string, results: FullTextSearchResult[]): CrossVaultHit[] {
    const hits: CrossVaultHit[] = [];
    for (let i = 0; i < results.length; i++) {
      hits.push({ vaultId: vaultId, path: results[i].path, excerpt: results[i].excerpt });
    }
    return hits;
  }
}
