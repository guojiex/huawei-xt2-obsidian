/**
 * v1.32 32.9：更新日志不超前于当前版本。
 * 原型同源：versionNotAfter / releasedEntries（docs/prototype/v2/index.html）。
 * 版本号按「.」分段数值比较；解析失败的段按 0 处理（原型 Number() + ||0 语义）。
 */
import { ChangelogEntry } from './ChangelogData';

/** candidate ≤ installed 返回 true（含相等）。 */
export function versionNotAfter(candidate: string, installed: string): boolean {
  const ca: string[] = candidate.split('.');
  const ia: string[] = installed.split('.');
  const len: number = ca.length > ia.length ? ca.length : ia.length;
  for (let i = 0; i < len; i++) {
    const x: number = i < ca.length ? parseSegment(ca[i]) : 0;
    const y: number = i < ia.length ? parseSegment(ia[i]) : 0;
    if (x !== y) {
      return x < y;
    }
  }
  return true;
}

/**
 * 只保留版本号 ≤ 已安装版本的条目。
 * installedVersion 为空（包信息读取失败，占位值不出现在数据层）时不过滤：
 * 读不到安装版本不应清空更新日志，保留原有信息展示。
 */
export function releasedEntries(entries: ChangelogEntry[], installedVersion: string): ChangelogEntry[] {
  if (installedVersion.length === 0) {
    return entries;
  }
  const released: ChangelogEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    if (versionNotAfter(entries[i].version, installedVersion)) {
      released.push(entries[i]);
    }
  }
  return released;
}

function parseSegment(segment: string): number {
  const value: number = Number.parseInt(segment);
  return Number.isNaN(value) ? 0 : value;
}
