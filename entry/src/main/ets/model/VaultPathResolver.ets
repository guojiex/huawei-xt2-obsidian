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
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** vaults 根目录绝对路径（全工程唯一拼接点）。 */
  vaultsRoot(): string {
    return this.context.filesDir + '/vaults';
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
   * 库内相对路径 → 沙箱绝对路径（v0.2 文件树与 v0.3+ 意图执行器共用入口）。
   * 拒绝绝对路径入参与 `..` 片段，防止逃逸 vaults/。
   */
  resolve(vaultId: string, relativePath: string): string {
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
    const base: string = this.vaultDir(vaultId);
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
