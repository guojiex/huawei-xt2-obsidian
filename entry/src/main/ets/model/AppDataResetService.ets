/** v0.5: user-confirmed factory data reset; see api_notes M1/M2. */
import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class AppDataResetService {
  static async reset(context: common.UIAbilityContext): Promise<void> {
    AppDataResetService.clearGitCredentials();
    // Success stops this process. Reopening runs the normal first-install sample path.
    await context.getApplicationContext().clearUpApplicationData();
  }

  private static clearGitCredentials(): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    let entries: Array<asset.AssetMap> = [];
    try {
      entries = asset.querySync(query);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === 24000002) {
        return;
      }
      throw new Error('读取访问令牌失败，请稍后重试');
    }
    const decoder: util.TextDecoder = new util.TextDecoder();
    for (let i = 0; i < entries.length; i++) {
      const bytes = entries[i].get(asset.Tag.ALIAS);
      if (!(bytes instanceof Uint8Array)) {
        throw new Error('无法读取访问令牌标识，请稍后重试');
      }
      const alias: string = decoder.decodeToString(bytes);
      if (!alias.startsWith('vault:') || !alias.endsWith(':token')) {
        continue;
      }
      const removal: asset.AssetMap = new Map();
      removal.set(asset.Tag.ALIAS, bytes);
      try {
        asset.removeSync(removal);
      } catch (error) {
        const err = error as BusinessError;
        if (err.code !== 24000002) {
          throw new Error('清除访问令牌失败，请稍后重试');
        }
      }
    }
  }
}
