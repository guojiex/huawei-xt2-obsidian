/**
 * VaultPathResolver.ets —— 全工程唯一的库路径解析层
 *
 * 硬约束（AGENTS.md #14 + spec.md FR-013）：
 * 1. 路径只能由 `context.filesDir` 等 Context 属性拼出，禁止硬编码沙箱目录字符串；
 * 2. 「filesDir/vaults」的拼接只允许出现在本文件 —— UI、对话框、管理视图、
 *    将来的端侧意图执行器一律经本解析器取路径，不得旁路。
 */
import { common } from '@kit.AbilityKit';

export class VaultPathResolver {
  /**
   * 回收站目录段名（1.7）。`requireSafeSegment` 拒绝点开头段 —— 这是防**用户输入**
   * 藏进隐藏目录的规则；`.trash` 是本解析器自有的常量段，不是外部输入，
   * 故不走 requireSafeSegment，而是由 `trashDir()` 在这里唯一拼出（仍守硬约束 #14：
   * 拼接只出现在本文件）。FileTree 天然过滤点开头目录，树里看不见它。
   */
  static readonly TRASH_SEG: string = '.trash';
  private static readonly DRAFTS_SEG: string = 'drafts';
  private static readonly SHARE_SEG: string = 'share';

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** vaults 根目录绝对路径（全工程唯一拼接点）。 */
  vaultsRoot(): string {
    return this.context.filesDir + '/vaults';
  }

  /** 隐藏的 Git 导入恢复标记根，只由 VaultRegistry 管理。 */
  gitImportMarkersRoot(): string {
    return this.vaultsRoot() + '/.git-imports';
  }

  gitImportMarkerDir(finalVaultId: string): string {
    return this.gitImportMarkersRoot() + '/' + this.requireSafeSegment(finalVaultId);
  }

  gitImportTempMarkerDir(finalVaultId: string, importingVaultId: string): string {
    return this.gitImportMarkerDir(finalVaultId) + '/' + this.requireSafeSegment(importingVaultId);
  }

  /**
   * 单个库目录绝对路径：filesDir/vaults/<vaultId>。
   * vaultId 本应经 sanitizeVaultName 消毒，这里仍做防御性校验（纵深防御）。
   */
  vaultDir(vaultId: string): string {
    const safeId: string = this.requireSafeSegment(vaultId);
    return this.vaultsRoot() + '/' + safeId;
  }

  /** 回收站目录绝对路径：filesDir/vaults/<vaultId>/.trash（1.7）。 */
  trashDir(vaultId: string): string {
    return this.vaultDir(vaultId) + '/' + VaultPathResolver.TRASH_SEG;
  }

  /** 草稿根目录及单库路径也只在此处从 Context 属性拼出。 */
  draftsRoot(): string {
    return this.context.filesDir + '/' + VaultPathResolver.DRAFTS_SEG;
  }

  /** 分享临时产物根目录；缓存文件由系统按 cacheDir 生命周期回收。 */
  shareRoot(): string {
    return this.context.cacheDir + '/' + VaultPathResolver.SHARE_SEG;
  }

  /** 分享临时产物路径也统一走本解析器，禁止调用方自行拼 cacheDir。 */
  resolveShare(relativePath: string): string {
    return this.joinChecked(this.shareRoot(), relativePath);
  }

  /** 非目录草稿根的保留位置；仅用于启动自愈，避免覆盖未知残留内容。 */
  draftsRootRecoveryFile(): string {
    return this.draftsRoot() + '.recovery';
  }

  draftsVaultDir(vaultId: string): string {
    return this.draftsRoot() + '/' + this.requireSafeSegment(vaultId);
  }

  draftDirectory(vaultId: string, relativeDirectory: string): string {
    return this.joinChecked(this.draftsVaultDir(vaultId), relativeDirectory);
  }

  resolveDraft(vaultId: string, relativePath: string): string {
    if (relativePath.length === 0) {
      throw new Error('VaultPathResolver: 草稿路径不能为空');
    }
    return this.joinChecked(this.draftsVaultDir(vaultId), relativePath) + '.draft';
  }

  /**
   * 库内相对路径 → 沙箱绝对路径（v0.2 文件树与 v0.3+ 意图执行器共用入口）。
   * 拒绝绝对路径入参与 `..` 片段，防止逃逸 vaults/。
   */
  resolve(vaultId: string, relativePath: string): string {
    return this.joinChecked(this.vaultDir(vaultId), relativePath);
  }

  /**
   * 回收站内相对路径 → 沙箱绝对路径（1.7）。relPath = 原库内相对路径（镜像结构），
   * 校验规则与 resolve 一致（拒绝绝对路径与 `..`）。
   */
  resolveInTrash(vaultId: string, relativePath: string): string {
    return this.joinChecked(this.trashDir(vaultId), relativePath);
  }

  /** App 私有 Agent 数据根；与用户知识库、草稿和分享缓存分开。 */
  agentRoot(): string {
    return this.context.filesDir + '/app/agent';
  }

  /** 稳定库身份目录：filesDir/app/agent/vaults/<vaultKey>。 */
  agentVaultDir(vaultKey: string): string {
    return this.agentRoot() + '/vaults/' + this.requireSafeSegment(vaultKey);
  }

  agentConversationsDir(vaultKey: string): string {
    return this.agentVaultDir(vaultKey) + '/conversations';
  }

  agentConversationDir(vaultKey: string, conversationId: string): string {
    return this.agentConversationsDir(vaultKey) + '/' + this.requireSafeSegment(conversationId);
  }

  agentConversationFile(vaultKey: string, conversationId: string): string {
    return this.agentConversationDir(vaultKey, conversationId) + '/conversation.json';
  }

  agentRunDir(vaultKey: string, conversationId: string, runId: string): string {
    return this.agentConversationDir(vaultKey, conversationId) + '/runs/' + this.requireSafeSegment(runId);
  }

  agentRunsDir(vaultKey: string, conversationId: string): string {
    return this.agentConversationDir(vaultKey, conversationId) + '/runs';
  }

  agentRunStateFile(vaultKey: string, conversationId: string, runId: string): string {
    return this.agentRunDir(vaultKey, conversationId, runId) + '/state.json';
  }

  agentRunOperationsDir(vaultKey: string, conversationId: string, runId: string): string {
    return this.agentRunDir(vaultKey, conversationId, runId) + '/operations';
  }

  agentOperationFile(vaultKey: string, conversationId: string, runId: string, operationId: string): string {
    return this.agentRunOperationsDir(vaultKey, conversationId, runId) + '/' +
      this.requireSafeSegment(operationId) + '.json';
  }

  /** 在 base 之下按段拼接并逐段校验（resolve / resolveInTrash 共用）。 */
  private joinChecked(base: string, relativePath: string): string {
    if (relativePath.length > 0 && relativePath.startsWith('/')) {
      throw new Error('VaultPathResolver: relativePath 不允许是绝对路径: ' + relativePath);
    }
    const segments: string[] = relativePath.split('/');
    const kept: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      const seg: string = segments[i];
      if (seg === '..') {
        throw new Error('VaultPathResolver: relativePath 不允许包含 ".." 片段: ' + relativePath);
      }
      if (seg === '.' || seg === '') {
        continue;
      }
      kept.push(this.requireSafeSegment(seg));
    }
    if (kept.length === 0) {
      return base;
    }
    return base + '/' + kept.join('/');
  }

  /** 校验单段路径成分：非空、无分隔符、不以点开头。 */
  private requireSafeSegment(segment: string): string {
    if (segment.length === 0) {
      throw new Error('VaultPathResolver: 路径段为空');
    }
    if (segment.startsWith('.')) {
      throw new Error('VaultPathResolver: 路径段不允许以点开头: ' + segment);
    }
    if (segment.indexOf('/') >= 0 || segment.indexOf('\\') >= 0) {
      throw new Error('VaultPathResolver: 路径段不允许包含分隔符: ' + segment);
    }
    return segment;
  }
}
