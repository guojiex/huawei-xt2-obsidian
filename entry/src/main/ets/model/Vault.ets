/**
 * Vault.ets —— 库数据模型与库名消毒规则（纯逻辑，无 UI / 无系统调用）
 *
 * 库 = vaults/ 下一个目录（spec.md Key Entities）。
 * 显示名与目录名不分离（mvp_design.md §4.5.1）：id 即目录名即显示名，
 * 否则导出到电脑时目录名对不上，还得查映射表。
 */

/** 库条目：id（= 目录名 = 显示名）/ type / createdAt + Git 库可选字段（v0.3）。 */
export interface VaultEntry {
  /** 目录名 = 显示名（不分离） */
  id: string;
  /** 改名不变、复制成新库时重新生成的私有数据归属标识。 */
  vaultKey: string;
  /** 'local' | 'git'（v0.3 起导入的仓库为 'git'） */
  type: string;
  /** 创建时间戳（ms） */
  createdAt: number;
  /** Git 库：远端仓库地址（local 库无此字段） */
  remote?: string;
  /** Git 库：跟踪分支（clone 时的 ref） */
  branch?: string;
  /**
   * Git 库：认证用户名（Gitee / 自建 GitLab 私有库需要，GitHub 留空）。
   * 非敏感、可明文，随注册表存 preferences；令牌本身只进 Asset Store Kit。
   */
  authUsername?: string;
  /** 上次同步时间戳（ms），同步落地后更新 */
  lastSyncAt?: number;
}

/** 默认库名：首启自动创建，随应用即用，不配远端也能进应用（spec.md FR-007）。 */
export const DEFAULT_VAULT_ID: string = 'local';

/**
 * 库名消毒纯函数（新建与改名共用，spec.md FR-009）：
 * 1. 过滤 `/ \ : * ? " < > |` 与控制字符（charCode < 0x20）；
 * 2. 去前导点（防 `.`/`..` 逃逸 vaults/）；
 * 3. 去首尾空白；
 * 4. 结果为空 → 返回空串，由调用方拒绝（不在此抛错，便于 UI 实时预览）。
 */
export function sanitizeVaultName(raw: string): string {
  let filtered: string = '';
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw.charAt(i);
    const code: number = ch.charCodeAt(0);
    // 控制字符（charCode < 0x20）直接丢弃
    if (code < 0x20) {
      continue;
    }
    // 文件系统非法字符直接丢弃（spec.md FR-009 清单）
    if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' ||
      ch === '"' || ch === '<' || ch === '>' || ch === '|') {
      continue;
    }
    filtered += ch;
  }
  // 去前导点：防 '.' / '..' 逃逸 vaults/（spec.md FR-009 第 2 步）
  let start: number = 0;
  while (start < filtered.length && filtered.charAt(start) === '.') {
    start++;
  }
  // 去首尾空白（第 3 步）
  return filtered.substring(start).trim();
}
