/** ExternalVaultAuthorizationDevice.ets —— v1.5 15.1 系统 API 适配层。 */
import { common } from '@kit.AbilityKit';
import { fileShare, picker } from '@kit.CoreFileKit';
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
  async persistPermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    await fileShare.persistPermission(policies);
  }

  async activatePermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    await fileShare.activatePermission(policies);
  }

  async checkPersistentPermission(policies: ExternalDirectoryPolicy[]): Promise<boolean[]> {
    return await fileShare.checkPersistentPermission(policies);
  }

  async revokePermission(policies: ExternalDirectoryPolicy[]): Promise<void> {
    await fileShare.revokePermission(policies);
  }
}

export function createExternalVaultAuthorization(context: common.UIAbilityContext): ExternalVaultAuthorizationService {
  return new ExternalVaultAuthorizationService(
    new DeviceExternalDirectoryPicker(context),
    new DeviceExternalFileShare(),
    (): boolean => canIUse(FOLDER_SELECTION_SYSCAP)
  );
}
