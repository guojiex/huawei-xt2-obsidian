/**
 * GitCredentialStore.ets —— Git 访问令牌的安全存取（@kit.AssetStoreKit）
 *
 * 硬约束（AGENTS.md #11 / v0.3 需求 1.2，api_notes.md C3）：
 * - 令牌只进 `asset.Tag.SECRET`（加密位）；`ALIAS` 仅作检索键，不加密；
 * - 多库场景按库存取：alias = `vault:<库id>:token`；
 * - 无需申请任何权限（SystemCapability.Security.Asset）；
 * - 未存过抛 24000002（NOT_FOUND），本类归一化为 null / 无操作。
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const CRED_DOMAIN: number = 0x0001;
const CRED_TAG: string = 'GitCredentialStore';
const ALIAS_PREFIX: string = 'vault:';
const ALIAS_SUFFIX: string = ':token';

export class GitCredentialStore {
  private static encoder: util.TextEncoder = new util.TextEncoder();
  private static decoder: util.TextDecoder = new util.TextDecoder();

  /** 库 id → alias（bytes 形式，AssetMap 取值只收 Uint8Array）。 */
  private static aliasBytesOf(vaultId: string): Uint8Array {
    return GitCredentialStore.encoder.encodeInto(ALIAS_PREFIX + vaultId + ALIAS_SUFFIX);
  }

  /** 保存 / 覆盖某库令牌（ALIAS 冲突时整体覆盖，避免调用方先查后写留竞态窗口）。 */
  static saveToken(vaultId: string, token: string): void {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.SECRET, GitCredentialStore.encoder.encodeInto(token));
    attrs.set(asset.Tag.ALIAS, GitCredentialStore.aliasBytesOf(vaultId));
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    asset.addSync(attrs);
  }

  /** 读取某库令牌；未存过返回 null（NOT_FOUND 归一化），其余错误原样抛出。 */
  static getToken(vaultId: string): string | null {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, GitCredentialStore.aliasBytesOf(vaultId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = asset.querySync(query);
      if (results.length === 0) {
        return null;
      }
      const secret = results[0].get(asset.Tag.SECRET);
      if (secret === undefined || !(secret instanceof Uint8Array)) {
        return null;
      }
      return GitCredentialStore.decoder.decodeToString(secret);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === 24000002) {
        return null;
      }
      throw new Error(`asset querySync 失败: ${err.code}: ${err.message}`);
    }
  }

  /** 删除某库令牌（未存过视为成功，供删库 / 移除 Git 库时清理）。 */
  static removeToken(vaultId: string): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, GitCredentialStore.aliasBytesOf(vaultId));
    try {
      asset.removeSync(query);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === 24000002) {
        return;
      }
      hilog.warn(CRED_DOMAIN, CRED_TAG, '删除令牌失败 vault=%{public}s code=%{public}d', vaultId, err.code);
    }
  }

  /** 库改名时把令牌迁到新 alias（旧库未存过令牌则为无操作）。 */
  static migrateToken(fromVaultId: string, toVaultId: string): void {
    const token: string | null = GitCredentialStore.getToken(fromVaultId);
    if (token === null) {
      return;
    }
    GitCredentialStore.saveToken(toVaultId, token);
    GitCredentialStore.removeToken(fromVaultId);
  }
}
