import { VaultEntry } from './Vault';

export type ShareLinkScope = 'note' | 'folder' | 'vault';

export interface ShareLinkResult {
  url: string;
  accessNotice: string;
}

/** 只为已配置 GitHub / Gitee 仓库与跟踪分支生成页面链接，不包含本地未推送内容。 */
export class ShareLinkService {
  static build(vault: VaultEntry, scope: ShareLinkScope, relativePath: string): ShareLinkResult {
    if (vault.type !== 'git' || vault.remote === undefined || vault.remote.trim().length === 0) {
      throw new Error('当前知识库没有可用的 Git 远端地址，请改为分享 ZIP');
    }
    const remote: string = ShareLinkService.parseRemote(vault.remote);
    const host: string = remote.substring(0, remote.indexOf('/'));
    const repository: string = remote.substring(remote.indexOf('/') + 1);
    if (scope !== 'vault' && (vault.branch === undefined || vault.branch.trim().length === 0)) {
      throw new Error('该 Git 知识库没有跟踪分支，无法确认远端页面链接');
    }
    if (scope === 'vault') {
      return { url: 'https://' + host + '/' + repository, accessNotice: ShareLinkService.accessNotice() };
    }
    const safePath: string = ShareLinkService.encodePath(relativePath);
    const branch: string = encodeURIComponent((vault.branch as string).trim());
    const kind: string = scope === 'note' ? 'blob' : 'tree';
    return {
      url: 'https://' + host + '/' + repository + '/' + kind + '/' + branch + '/' + safePath,
      accessNotice: ShareLinkService.accessNotice()
    };
  }

  private static parseRemote(value: string): string {
    const remote: string = value.trim();
    const schemeEnd: number = remote.indexOf('://');
    if (schemeEnd < 0 || (remote.substring(0, schemeEnd).toLowerCase() !== 'https' &&
      remote.substring(0, schemeEnd).toLowerCase() !== 'http')) {
      throw new Error('远端地址格式不受支持，无法确认分享链接；请改为 ZIP');
    }
    const pathStart: number = remote.indexOf('/', schemeEnd + 3);
    if (pathStart < 0) {
      throw new Error('远端地址格式不受支持，无法确认分享链接；请改为 ZIP');
    }
    const rawHost: string = remote.substring(schemeEnd + 3, pathStart);
    if (rawHost.indexOf('@') >= 0 || rawHost.indexOf(':') >= 0 || rawHost.length === 0) {
      throw new Error('远端地址格式不受支持，无法确认分享链接；请改为 ZIP');
    }
    const host: string = rawHost.toLowerCase();
    if (host !== 'github.com' && host !== 'gitee.com') {
      throw new Error('暂不支持该 Git 托管平台的页面链接；请改为 ZIP');
    }
    let rawPath: string = remote.substring(pathStart + 1);
    if (rawPath.indexOf('?') >= 0 || rawPath.indexOf('#') >= 0) {
      throw new Error('远端地址格式不受支持，无法确认分享链接；请改为 ZIP');
    }
    while (rawPath.endsWith('/')) {
      rawPath = rawPath.substring(0, rawPath.length - 1);
    }
    const rawParts: string[] = rawPath.split('/');
    while (rawParts.length > 0 && rawParts[rawParts.length - 1].length === 0) {
      rawParts.pop();
    }
    if (rawParts.length === 0 || rawParts.length > 2) {
      throw new Error('远端地址无法识别为仓库首页；请改为 ZIP');
    }
    if (rawParts[rawParts.length - 1].toLowerCase().endsWith('.git')) {
      const last: number = rawParts.length - 1;
      rawParts[last] = rawParts[last].substring(0, rawParts[last].length - 4);
    }
    if (rawParts.length !== 2 || !ShareLinkService.isRepositorySegment(rawParts[0]) ||
      !ShareLinkService.isRepositorySegment(rawParts[1])) {
      throw new Error('远端地址无法识别为仓库首页；请改为 ZIP');
    }
    return host + '/' + encodeURIComponent(rawParts[0]) + '/' + encodeURIComponent(rawParts[1]);
  }

  private static isRepositorySegment(value: string): boolean {
    return value.length > 0 && value !== '.' && value !== '..' && /^[A-Za-z0-9_.-]+$/.test(value);
  }

  private static encodePath(path: string): string {
    if (path.length === 0 || path.startsWith('/') || path.indexOf('\\') >= 0) {
      throw new Error('远端路径不是知识库内的相对路径，请改为 ZIP');
    }
    const parts: string[] = path.split('/');
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].length === 0 || parts[i] === '.' || parts[i] === '..' || parts[i].startsWith('.')) {
        throw new Error('远端路径包含无效目录，请改为 ZIP');
      }
      parts[i] = encodeURIComponent(parts[i]);
    }
    return parts.join('/');
  }

  private static accessNotice(): string {
    return '链接来自配置的远端分支；未推送的本地修改不会出现在链接中。若仓库为私有，接收人需要先获得访问权限。';
  }
}
