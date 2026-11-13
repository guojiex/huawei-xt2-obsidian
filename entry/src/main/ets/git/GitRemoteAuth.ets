/**
 * GitRemoteAuth.ets —— Git 远端 host 判定与认证方式的单一真源
 *
 * 对应 AGENTS.md 已知坑 5：Gitee 用 Basic（`username:私人令牌`），
 * GitHub 用 `Bearer <PAT>` 且用户名留空 —— 两者不同，判定与赋值收口在这，
 * 各页面 / 对话框不得再自抄 URL 解析。
 *
 * host 解析兼容完整 URL（`https://github.com/o/r.git`）与 host/path 形式
 * （`github.com/o/r`，GitSyncDialog 的 remoteLabel 即此形态）。
 */
import { Git2ActionOptions, Git2CloneOptions } from 'libgit2_napi.so';

/** 提取远端 host（小写）：去 scheme、userinfo（@ 前段）、port。 */
export function gitRemoteHost(url: string): string {
  const scheme: number = url.indexOf('://');
  const authorityStart: number = scheme >= 0 ? scheme + 3 : 0;
  const slash: number = url.indexOf('/', authorityStart);
  const authority: string = url.substring(authorityStart, slash >= 0 ? slash : url.length);
  return authority.substring(authority.lastIndexOf('@') + 1).split(':')[0].toLowerCase();
}

/** GitHub 远端（github.com / www.github.com）——用 Bearer 令牌、用户名留空。 */
export function isGitHubRemote(url: string): boolean {
  const host: string = gitRemoteHost(url);
  return host === 'github.com' || host === 'www.github.com';
}

/** Gitee 远端（gitee.com 及其子域）——用 Basic（用户名 + 私人令牌）。 */
export function isGiteeRemote(url: string): boolean {
  const host: string = gitRemoteHost(url);
  return host === 'gitee.com' || host.endsWith('.gitee.com');
}

/**
 * 按远端类型把凭据写进 clone / action options：
 * GitHub → `bearerToken`；其余 → `username + password`。令牌为空时不写任何凭据。
 */
export function applyRemoteAuth(options: Git2ActionOptions | Git2CloneOptions,
  remote: string, username: string, token: string): void {
  if (token.length === 0) {
    return;
  }
  if (isGitHubRemote(remote)) {
    options.bearerToken = token;
  } else {
    options.username = username;
    options.password = token;
  }
}
