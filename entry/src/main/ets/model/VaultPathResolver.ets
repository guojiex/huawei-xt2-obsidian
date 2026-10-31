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
   * 回收站根目录段名（1.7 引入，v1.5 改为沙箱私有根，见下）。段名是本解析器自有的常量，
   * 不是外部输入，故不走 requireSafeSegment —— 走也很安全，只是没必要。
   */
  private static readonly TRASH_SEG: string = 'trash';
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

  /**
   * 回收站**根**：filesDir/trash（v1.5 15.6）。
   *
   * 为什么不再放 `<vaultDir>/.trash`：外部授权库的库目录是**用户的目录**，往里塞
   * `.trash` 会被 Obsidian / Git / 云盘当成普通内容，还会和 15.5「移除库只解除关联、
   * 不清磁盘」打架 —— 删库时那个目录算 App 的还是用户的，说不清。
   * App 私有数据一律落沙箱。
   */
  trashRoot(): string {
    return this.context.filesDir + '/' + VaultPathResolver.TRASH_SEG;
  }

  /**
   * 回收站目录绝对路径：filesDir/trash/<vaultKey>。
   * 按 vaultKey 而不是 vaultId 分段：库改名 id 变、key 不变，回收站要能在改名后仍定位。
   */
  trashDir(vaultKey: string): string {
    return this.trashRoot() + '/' + this.requireSafeSegment(vaultKey);
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

  /** 草稿的根则由 `draftsRoot()` 给出（同样在 filesDir 下，属于 App 私有数据）。 */
  draftsVaultDir(vaultKey: string): string {
    return this.draftsRoot() + '/' + this.requireSafeSegment(vaultKey);
  }

  /** 同 draftsVaultDir：草稿也在库外，按 vaultKey 分段，改名后仍能找回未恢复的草稿。 */
  draftDirectory(vaultKey: string, relativeDirectory: string): string {
    return this.joinChecked(this.draftsVaultDir(vaultKey), relativeDirectory);
  }

  resolveDraft(vaultKey: string, relativePath: string): string {
    if (relativePath.length === 0) {
      throw new Error('VaultPathResolver: 草稿路径不能为空');
    }
    return this.joinChecked(this.draftsVaultDir(vaultKey), relativePath) + '.draft';
  }

  /**
   * 库内相对路径 → 沙箱绝对路径（v0.2 文件树与 v0.3+ 意图执行器共用入口）。
   * 拒绝绝对路径入参与 `..` 片段，防止逃逸 vaults/。
   */
  resolve(vaultId: string, relativePath: string): string {
    return this.joinChecked(this.vaultDir(vaultId), relativePath);
  }

  /**
   * 回收站内相对路径 → 沙箱绝对路径（1.7，v1.5 改 key 分段）。relPath = 原库内相对
   * 路径（镜像结构），校验规则与 resolve 一致（拒绝绝对路径与 `..`）。
   */
  resolveInTrash(vaultKey: string, relativePath: string): string {
    return this.joinChecked(this.trashDir(vaultKey), relativePath);
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
