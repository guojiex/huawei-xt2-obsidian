/** ExternalVaultAuthorizationDevice.ets —— v1.5 15.1 系统 API 适配层。
 *  2026-11-15 冷启动优化（XT2 trace）：fileShare（@ohos.fileshare）改方法内动态 import，
 *  只在真正走外部目录授权时才加载；picker 改直连子模块，不再拉起 CoreFileKit 全 barrel。 */
import { common } from '@kit.AbilityKit';
import picker from '@ohos.file.picker';
import {
  ExternalDirectoryPickerPort, ExternalDirectoryPolicy, ExternalFileSharePort,
  ExternalVaultAuthorizationService, FOLDER_SELECTION_SYSCAP
} from './ExternalVaultAuthorization';

export class DeviceExternalDirectoryPicker implements ExternalDirectoryPickerPort {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async selectFolder(): Promise<string[]> {
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,
      selectMode: picker.DocumentSelectMode.FOLDER
    };
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
    return await documentPicker.select(options);
  }
}

export class DeviceExternalFileShare implements ExternalFileSharePort {
  private async shareModule(): Promise<ESObject> {
    const mod: ESObject = await import('@ohos.fileshare');
    return mod.default;
  }

  async persistPermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    const fileShare: ESObject = await this.shareModule();
    const fn: (policies: ExternalDirectoryPolicy[]) => Promise<void> = fileShare.persistPermission;
    await fn(policies);
  }

  async activatePermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    const fileShare: ESObject = await this.shareModule();
    const fn: (policies: ExternalDirectoryPolicy[]) => Promise<void> = fileShare.activatePermission;
    await fn(policies);
  }

  async checkPersistentPermission(policies: ExternalDirectoryPolicy[]): Promise<boolean[]> {
    const fileShare: ESObject = await this.shareModule();
    const fn: (policies: ExternalDirectoryPolicy[]) => Promise<boolean[]> = fileShare.checkPersistentPermission;
    return await fn(policies);
  }

  async revokePermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    const fileShare: ESObject = await this.shareModule();
    const fn: (policies: ExternalDirectoryPolicy[]) => Promise<void> = fileShare.revokePermission;
    await fn(policies);
  }
}

export function createExternalVaultAuthorization(context: common.UIAbilityContext): ExternalVaultAuthorizationService {
  return new ExternalVaultAuthorizationService(
    new DeviceExternalDirectoryPicker(context),
    new DeviceExternalFileShare(),
    (): boolean => canIUse(FOLDER_SELECTION_SYSCAP)
  );
}
