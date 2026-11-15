/** GitImportService.ets —— 导入弹窗使用的 Git 库安全编排入口。 */
import fileIo from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { GitCredentialStore } from '../git/GitCredentialStore';
import { GitNativeService } from '../git/GitNativeService';
import { applyRemoteAuth, gitRemoteHost, isGiteeRemote, isGitHubRemote } from '../git/GitRemoteAuth';
import { Git2CloneOptions, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';
import { GIT_IMPORTING_SUFFIX, VaultRegistry } from './VaultRegistry';
import { sanitizeVaultName, VaultEntry } from './Vault';
import { GitImportDraft, GitImportOutcome } from './GitImportDraftStore';

const GIT_DIAGNOSTIC_DOMAIN: number = 0x0000;
const GIT_DIAGNOSTIC_TAG: string = 'GitSync';

export class GitImportService {
  /** 远端名称消毒 + 重名规则与表单预览、正式登记共用。 */
  static previewVaultId(remote: string): string {
    let normalized: string = remote.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('.git')) {
      normalized = normalized.substring(0, normalized.length - 4);
    }
    const slash: number = normalized.lastIndexOf('/');
    const rawName: string = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    const safeName: string = sanitizeVaultName(rawName);
    return VaultRegistry.get().uniqueVaultId(safeName.length > 0 ? safeName : 'Git 笔记库', '');
  }

  static async run(draft: GitImportDraft,
    onProgress: (stage: string) => void): Promise<GitImportOutcome> {
    const remote: string = draft.remote.trim();
    const branch: string = draft.branch.trim();
    const username: string = draft.username.trim();
    const token: string = draft.token;
    if (remote.length === 0) {
      return GitImportService.failure('input', '请填写仓库地址。', '仓库地址为空', 'remote');
    }
    if (GitImportService.urlHasInlineCredentials(remote)) {
      return GitImportService.failure('input', '请移除地址中的认证信息，改在令牌字段填写。',
        '仓库地址包含认证信息', 'remote');
    }
    if (token.length > 0 && !isGitHubRemote(remote) && username.length === 0) {
      return GitImportService.failure('auth', '此 Git 服务需要填写用户名后再重试。',
        '使用令牌时缺少用户名', 'username');
    }

    const registry: VaultRegistry = VaultRegistry.get();
    const finalId: string = GitImportService.previewVaultId(remote);
    const tempId: string = registry.uniqueVaultId(finalId + GIT_IMPORTING_SUFFIX, '');
    const authUsername: string = isGitHubRemote(remote) ? '' : username;
    let markerCreated: boolean = false;
    let importedEntry: VaultEntry | null = null;
    let warning: string = '';
    onProgress('正在准备隔离目录…');
    try {
      registry.beginGitImport(finalId, tempId);
      markerCreated = true;
      const tempDir: string = registry.vaultDirOf(tempId);
      const options: Git2CloneOptions = {
        url: remote,
        targetPath: tempDir,
        branch: branch.length > 0 ? branch : undefined,
        onProgress: (progress: Git2Progress): void => {
          onProgress(GitNativeService.progressLabel(progress));
        },
      };
      applyRemoteAuth(options, remote, authUsername, token);
      onProgress('正在连接远端…');
      const clonedPath: string = await GitNativeService.clone(options);
      if (clonedPath !== tempDir) {
        throw new Error('Native clone 返回的目录与隔离目标不一致');
      }

      onProgress('正在校验仓库…');
      const state: Git2RepositoryState = await GitNativeService.repositoryState(tempDir);
      if (!state.clean || (branch.length > 0 && state.branch !== branch)) {
        throw new Error('clone 后的仓库分支或工作区状态校验失败');
      }

      onProgress('正在登记知识库…');
      const finalDir: string = registry.vaultDirOf(finalId);
      if (fileIo.accessSync(finalDir)) {
        throw new Error('正式库目录已存在，拒绝覆盖: ' + finalId);
      }
      fileIo.renameSync(tempDir, finalDir);
      importedEntry = registry.registerGit(finalId, remote, branch, authUsername);
      registry.finishGitImport(finalId, tempId);
      markerCreated = false;

      if (token.length > 0) {
        try {
          GitCredentialStore.saveToken(importedEntry.id, token);
        } catch (_credentialError) {
          warning = '令牌未能安全保存，下次同步时需要重新填写。';
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      let detail: string = GitImportService.redact(err.message ?? String(error), token);
      hilog.error(GIT_DIAGNOSTIC_DOMAIN, GIT_DIAGNOSTIC_TAG,
        'Git %{public}s failure host=%{public}s code=%{public}d detail=%{public}s',
        'clone', gitRemoteHost(remote), err.code ?? -1, detail);
      if (markerCreated) {
        try {
          registry.cleanupGitImport(finalId, tempId);
        } catch (cleanupError) {
          const cleanup = cleanupError as BusinessError;
          detail += '\n导入目录清理未完成；恢复标记保留，应用下次启动会重试。底层错误：' +
            GitImportService.redact(cleanup.message ?? String(cleanupError), token);
        }
      }
      const guidance: string = GitImportService.explainError(detail, remote);
      const focusTarget: string = GitImportService.focusTarget(detail);
      const category: string = focusTarget === 'token' ? 'auth'
        : detail.includes('ENOTFOUND') || detail.includes('ECONNREFUSED') ||
          detail.toLowerCase().includes('timed out') ? 'network' : 'other';
      onProgress('导入失败，可修改信息后重试');
      return GitImportService.failure(category, guidance, detail, focusTarget);
    }

    if (importedEntry === null) {
      return GitImportService.failure('other', 'Git 导入没有完成，请稍后重试。',
        '未能登记导入的 Git 库', 'retry');
    }
    const success: GitImportOutcome = {
      status: 'success', vaultId: importedEntry.id, category: '', guidance: '', detail: '',
      focusTarget: '', warning: warning
    };
    return success;
  }

  private static failure(category: string, guidance: string, detail: string,
    focusTarget: string): GitImportOutcome {
    return {
      status: 'failed', vaultId: '', category: category, guidance: guidance,
      detail: detail, focusTarget: focusTarget, warning: ''
    };
  }

  private static redact(detail: string, token: string): string {
    return token.length > 0 ? detail.split(token).join('[令牌已隐藏]') : detail;
  }

  private static focusTarget(message: string): string {
    const lower: string = message.toLowerCase();
    return message.includes('401') || lower.includes('unauthorized') || lower.includes('authentication') ||
      message.includes('remote auth required but no callback set') ? 'token' : 'retry';
  }

  private static explainError(message: string, remote: string): string {
    if (message.includes('remote auth required but no callback set')) {
      return '远端要求登录，请检查仓库访问权限，以及用户名和访问令牌是否按该平台要求填写。';
    }
    if (message.includes('401') || message.toLowerCase().includes('unauthorized') ||
      message.toLowerCase().includes('authentication')) {
      if (isGitHubRemote(remote)) {
        return 'GitHub 认证失败，请检查仓库地址和访问令牌权限；私有仓库需要有效令牌。';
      }
      if (isGiteeRemote(remote)) {
        return 'Gitee 认证失败。仓库不存在或私有库未授权都可能返回 401，请检查地址、用户名和私人令牌。';
      }
      return '认证失败，请检查仓库地址、用户名和访问令牌后重试。';
    }
    if (message.includes('404') || message.includes('NotFound')) {
      return '仓库或分支不存在，请检查地址与分支名。';
    }
    if (message.includes('ENOTFOUND') || message.includes('ECONNREFUSED') ||
      message.toLowerCase().includes('timed out')) {
      return '网络不可达，请检查网络或 VPN 后重试。';
    }
    return 'Git 导入未完成；请检查网络、仓库地址和分支后重试。';
  }

  private static urlHasInlineCredentials(url: string): boolean {
    const scheme: number = url.indexOf('://');
    const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
    const authorityEnd: number = url.indexOf('/', authorityStart);
    const authority: string = url.substring(authorityStart, authorityEnd >= 0 ? authorityEnd : url.length);
    if (authority.indexOf('@') >= 0) {
      return true;
    }
    const queryStart: number = url.indexOf('?');
    if (queryStart < 0) {
      return false;
    }
    const fragmentStart: number = url.indexOf('#', queryStart);
    const query: string = url.substring(queryStart + 1, fragmentStart >= 0 ? fragmentStart : url.length);
    const credentialKeys: string[] = [
      'token', 'access_token', 'private_token', 'personal_access_token', 'password', 'passwd',
      'secret', 'authorization', 'auth', 'bearer', 'pat'
    ];
    const parts: string[] = query.split('&');
    for (let i: number = 0; i < parts.length; i++) {
      const equals: number = parts[i].indexOf('=');
      const key: string = (equals >= 0 ? parts[i].substring(0, equals) : parts[i]).toLowerCase();
      if (credentialKeys.indexOf(key) >= 0) {
        return true;
      }
    }
    return false;
  }
}
