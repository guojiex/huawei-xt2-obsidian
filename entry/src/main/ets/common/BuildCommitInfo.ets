/**
 * BuildCommitInfo.ets —— v1.15 构建提交号诊断的展示规则（纯逻辑，可在 Node 单测）。
 *
 * 值来自 hvigor 注入的 BuildProfile（entry/hvigorfile.ts + tools/generators/
 * build_commit_info.mjs），本文件只负责「怎么显示、能不能复制」，不取数据：
 * 这样 Node 侧不需要 BuildProfile 也能测规则。
 */

/** 状态：clean 干净构建 / dirty 有未提交更改 / unknown 取不到可信元数据。 */
export type BuildCommitState = 'clean' | 'dirty' | 'unknown';

export const BUILD_COMMIT_UNKNOWN_LABEL: string = '未知';

/** 是否是可信的构建标识；未知不伪造标识，也不参与复制。 */
export function isBuildCommitKnown(state: string): boolean {
  return state === 'clean' || state === 'dirty';
}

/** 复制只允许带上显示的构建标识本身（不含库路径、笔记或令牌）。 */
export function buildCommitCopyPayload(state: string, label: string): string {
  if (!isBuildCommitKnown(state) || label.length === 0) {
    return '';
  }
  return label;
}

/** 把 BuildProfile 给的两个字段兜底成可显示文本：任何缺失都显示「未知」。 */
export function buildCommitLabel(state: string, label: string): string {
  if (!isBuildCommitKnown(state) || label.length === 0) {
    return BUILD_COMMIT_UNKNOWN_LABEL;
  }
  return label;
}
