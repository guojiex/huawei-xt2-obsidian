/**
 * GitRemoteAuth.ets —— Git 远端 host 判定与认证方式的单一真源
 *
 * Gitee 用 Basic（`username:私人令牌`）；GitHub 与泛化 HTTPS 同样用 Basic
 *（`username`（占位 `x-access-token`）+ 令牌作密码）—— git 传输层只认 Basic，
 * Bearer 头对 git 端点无效。判定与赋值收口在这，各页面 / 对话框不得再自抄 URL 解析。
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

/** GitHub 远端（github.com / www.github.com）——Basic 认证（用户名占位 + 令牌作密码）。 */
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
 * GitHub / 泛化 HTTPS → `username + password`（git smart-HTTP 只认 Basic，
 * Bearer 头对 git 端点无效）；Gitee → `username + 私人令牌`。
 * 令牌为空时不写任何凭据。
 *
 * ⚠️ 历史坑：GitHub 的 REST/GraphQL API 用 Bearer，但 git 传输层（clone/fetch/push）
 * 只认 Basic（用户名 + 令牌作密码）。曾把 GitHub 令牌当 Bearer 发，导致
 * `remote authentication required but no callback set`（username/password 留空）。
 * 用户名留空时用 `x-access-token` 占位，经典 PAT 与细粒度 PAT 均兼容。
 */
export function applyRemoteAuth(options: Git2ActionOptions | Git2CloneOptions,
  remote: string, username: string, token: string): void {
  if (token.length === 0) {
    return;
  }
  if (isGiteeRemote(remote)) {
    options.username = username;
    options.password = token;
  } else {
    // GitHub 及泛化 HTTPS：git smart-HTTP 必须 Basic，Bearer 头对 git 端点无效
    options.username = username.length > 0 ? username : 'x-access-token';
    options.password = token;
  }
}
