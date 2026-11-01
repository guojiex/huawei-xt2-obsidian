import { VaultEntry } from './Vault';

/**
 * ExternalVaultAuthorization.ets —— 外部知识库目录选择与持久授权生命周期（v1.5 15.1）
 *
 * 业务层只处理 Picker 返回的 URI 和授权状态；URI 不作为文件路径使用。
 * 注册与后续 IO 分别由 VaultRegistry / VaultAccess 负责。
 */

/** READ_MODE | WRITE_MODE，API 20 的 CREATE / DELETE 位不在这里使用。 */
export const EXTERNAL_VAULT_PERMISSION_MODE: number = 3;
export const EXTERNAL_VAULT_URI_PREFIX: string = 'file://';
export const FOLDER_SELECTION_SYSCAP: string =
  'SystemCapability.FileManagement.UserFileService.FolderSelection';

export interface ExternalDirectoryPolicy {
  uri: string;
  operationMode: number;
}

export interface ExternalDirectoryPickerPort {
  selectFolder(): Promise<string[]>;
}

export interface ExternalFileSharePort {
  persistPermission(policies: ExternalDirectoryPolicy[]): Promise<void>;
  activatePermission(policies: ExternalDirectoryPolicy[]): Promise<void>;
  checkPersistentPermission(policies: ExternalDirectoryPolicy[]): Promise<boolean[]>;
  revokePermission(policies: ExternalDirectoryPolicy[]): Promise<void>;
}

export interface ExternalDirectoryGrant {
  uri: string;
  displayName: string;
  grantedAt: number;
}

/** Picker 临时选择结果；用户确认关联前不创建持久授权。 */
export interface ExternalDirectorySelection {
  uri: string;
  displayName: string;
}

export type ExternalPermissionState = 'active' | 'missing' | 'activation-failed';

export interface ExternalPermissionStatus {
  id: string;
  state: ExternalPermissionState;
  code: number;
}

export class ExternalVaultAuthorizationError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

/**
 * 可注入授权服务：picker 和 fileshare 都由设备适配器实现，授权时序本身可在 Node 中验证。
 */
export class ExternalVaultAuthorizationService {
  private picker: ExternalDirectoryPickerPort;
  private share: ExternalFileSharePort;
  private isFolderSelectionSupported: () => boolean;
  private now: () => number;

  constructor(
    picker: ExternalDirectoryPickerPort,
    share: ExternalFileSharePort,
    isFolderSelectionSupported: () => boolean,
    now: () => number = (): number => Date.now()
  ) {
    this.picker = picker;
    this.share = share;
    this.isFolderSelectionSupported = isFolderSelectionSupported;
    this.now = now;
  }

  /** 取消返回 null；此步骤只保留 Picker 选择，不创建持久授权。 */
  async pickDirectory(): Promise<ExternalDirectorySelection | null> {
    if (!this.isFolderSelectionSupported()) {
      throw new ExternalVaultAuthorizationError(-2, '此设备不支持系统目录选择');
    }
    const selected: string[] = await this.picker.selectFolder();
    if (selected.length === 0) {
      return null;
    }
    const uri: string = selected[0].trim();
    if (!isExternalDirectoryUri(uri)) {
      throw new ExternalVaultAuthorizationError(-3, '系统未返回可用的目录授权 URI');
    }
    return { uri: uri, displayName: externalDirectoryDisplayName(uri) };
  }

  /** 用户确认关联时创建持久授权；失败会撤销本次新授权。 */
  async persistSelection(selection: ExternalDirectorySelection): Promise<ExternalDirectoryGrant> {
    const uri: string = selection.uri.trim();
    if (!isExternalDirectoryUri(uri)) {
      throw new ExternalVaultAuthorizationError(-3, '拒绝持久化无效的目录授权 URI');
    }
    const policies: ExternalDirectoryPolicy[] = [buildExternalDirectoryPolicy(uri)];
    let persisted: boolean = false;
    try {
      await this.share.persistPermission(policies);
      persisted = true;
      const flags: boolean[] = await this.share.checkPersistentPermission(policies);
      if (flags.length === 0 || flags[0] !== true) {
        throw new ExternalVaultAuthorizationError(-4, '系统未确认目录持久授权');
      }
      await this.share.activatePermission(policies);
      const displayName: string = selection.displayName.length > 0
        ? selection.displayName : externalDirectoryDisplayName(uri);
      return { uri: uri, displayName: displayName, grantedAt: this.now() };
    } catch (error) {
      if (persisted) {
        try {
          await this.share.revokePermission(policies);
        } catch (revokeError) {
          // 授权回滚失败不覆盖原始错误；不触碰用户目录内容。
        }
      }
      throw toExternalAuthorizationError(error, '保存目录授权失败');
    }
  }

  /** 探针和需要一键授权的调用方使用；产品对话框分别调用选择与确认步骤。 */
  async chooseAndPersist(): Promise<ExternalDirectoryGrant | null> {
    const selection: ExternalDirectorySelection | null = await this.pickDirectory();
    if (selection === null) {
      return null;
    }
    return await this.persistSelection(selection);
  }

  /**
   * 应用启动 / 回到前台时恢复注册外部库的持久授权。
   * 单个目录失败不会影响其他库或阻止应用启动；不删除注册项，留给 UI 提示重新关联。
   */
  async restoreRegistered(entries: VaultEntry[]): Promise<ExternalPermissionStatus[]> {
    const statuses: ExternalPermissionStatus[] = [];
    for (let index: number = 0; index < entries.length; index++) {
      const entry: VaultEntry = entries[index];
      if (entry.rootKind !== 'external' || typeof entry.rootUri !== 'string' ||
        !isExternalDirectoryUri(entry.rootUri)) {
        continue;
      }
      const policies: ExternalDirectoryPolicy[] = [buildExternalDirectoryPolicy(entry.rootUri)];
      try {
        const flags: boolean[] = await this.share.checkPersistentPermission(policies);
        if (flags.length === 0 || flags[0] !== true) {
          statuses.push({ id: entry.id, state: 'missing', code: 0 });
          continue;
        }
        await this.share.activatePermission(policies);
        statuses.push({ id: entry.id, state: 'active', code: 0 });
      } catch (error) {
        statuses.push({
          id: entry.id,
          state: 'activation-failed',
          code: externalAuthorizationErrorCode(error)
        });
      }
    }
    return statuses;
  }

  /** 移除外部库时释放 App 的持久授权；调用方不得据此删除原目录。 */
  async revoke(uri: string): Promise<void> {
    if (!isExternalDirectoryUri(uri)) {
      throw new ExternalVaultAuthorizationError(-3, '拒绝撤销无效的目录授权 URI');
    }
    await this.share.revokePermission([buildExternalDirectoryPolicy(uri)]);
  }

  /** 删除关联前确认并释放授权；查询失败则抛错，避免静默遗留持久访问。 */
  async release(uri: string): Promise<void> {
    if (!isExternalDirectoryUri(uri)) {
      throw new ExternalVaultAuthorizationError(-3, '拒绝释放无效的目录授权 URI');
    }
    const policies: ExternalDirectoryPolicy[] = [buildExternalDirectoryPolicy(uri)];
    const flags: boolean[] = await this.share.checkPersistentPermission(policies);
    if (flags.length > 0 && flags[0] === true) {
      await this.share.revokePermission(policies);
    }
  }
}

export function isExternalDirectoryUri(uri: string): boolean {
  const value: string = uri.trim();
  return value.startsWith(EXTERNAL_VAULT_URI_PREFIX) && value.length > EXTERNAL_VAULT_URI_PREFIX.length;
}

export function buildExternalDirectoryPolicy(uri: string): ExternalDirectoryPolicy {
  return { uri: uri, operationMode: EXTERNAL_VAULT_PERMISSION_MODE };
}

/** 展示名只用于界面，不用于路径解析或文件 IO。 */
export function externalDirectoryDisplayName(uri: string): string {
  if (!isExternalDirectoryUri(uri)) {
    return '';
  }
  const slash: number = uri.lastIndexOf('/');
  const encoded: string = slash >= 0 ? uri.substring(slash + 1) : uri;
  if (encoded.length === 0) {
    return '';
  }
  try {
    return decodeURIComponent(encoded);
  } catch (error) {
    return encoded;
  }
}

export function externalAuthorizationErrorCode(error: Object): number {
  const candidate = error as ExternalVaultAuthorizationError;
  return typeof candidate.code === 'number' ? candidate.code : -1;
}

function toExternalAuthorizationError(error: Object, fallback: string): ExternalVaultAuthorizationError {
  if (error instanceof ExternalVaultAuthorizationError) {
    return error;
  }
  const code: number = externalAuthorizationErrorCode(error);
  return new ExternalVaultAuthorizationError(code, fallback);
}
