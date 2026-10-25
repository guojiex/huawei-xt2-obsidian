import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'
import { BusinessError } from '@kit.BasicServicesKit'

/** 按库保存 Git 访问令牌；令牌明文只进入 AssetStoreKit 的 SECRET 属性。 */
export class GitCredentialStore {
  private static encoder: util.TextEncoder = new util.TextEncoder()
  private static decoder: util.TextDecoder = new util.TextDecoder()
  private static readonly PENDING_IMPORT_ID: string = 'pending-import'

  private static alias(vaultId: string): string {
    return 'vault:' + vaultId + ':token'
  }

  static save(vaultId: string, token: string): void {
    if (token.length === 0) {
      return
    }
    const alias: string = GitCredentialStore.alias(vaultId)
    const query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, GitCredentialStore.encoder.encodeInto(alias))
    const attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, GitCredentialStore.encoder.encodeInto(alias))
    attributes.set(asset.Tag.SECRET, GitCredentialStore.encoder.encodeInto(token))
    try {
      asset.addSync(attributes)
    } catch (error) {
      const err = error as BusinessError
      if (err.code !== 24000003) {
        throw new Error(err.message)
      }
      const update: asset.AssetMap = new Map()
      update.set(asset.Tag.SECRET, GitCredentialStore.encoder.encodeInto(token))
      asset.updateSync(query, update)
    }
  }

  static load(vaultId: string): string {
    const query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, GitCredentialStore.encoder.encodeInto(GitCredentialStore.alias(vaultId)))
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      const result: Array<asset.AssetMap> = asset.querySync(query)
      if (result.length === 0) {
        return ''
      }
      const secret = result[0].get(asset.Tag.SECRET)
      return secret instanceof Uint8Array ? GitCredentialStore.decoder.decodeToString(secret) : ''
    } catch (error) {
      const err = error as BusinessError
      if (err.code === 24000002) {
        return ''
      }
      throw new Error(err.message)
    }
  }

  static remove(vaultId: string): void {
    const query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, GitCredentialStore.encoder.encodeInto(GitCredentialStore.alias(vaultId)))
    try {
      asset.removeSync(query)
    } catch (error) {
      const err = error as BusinessError
      if (err.code !== 24000002) {
        throw new Error(err.message)
      }
    }
  }

  /** 暂存旧版全局令牌，等待用户导入仓库后迁移到具体库 alias。 */
  static savePendingImport(token: string): void {
    GitCredentialStore.save(GitCredentialStore.PENDING_IMPORT_ID, token)
  }

  static loadPendingImport(): string {
    return GitCredentialStore.load(GitCredentialStore.PENDING_IMPORT_ID)
  }

  static removePendingImport(): void {
    GitCredentialStore.remove(GitCredentialStore.PENDING_IMPORT_ID)
  }
}
