/**
 * NoteDisplayName.ets —— 笔记显示名单一直真源
 *
 * 此前 12+ 处各自手剥 `.md` / `.markdown`，口径不一（只剥 .md / 剥两种、
 * 大小写敏感/不敏感并存）。统一口径：
 * - 同时剥 `.markdown` 与 `.md`（样例库两种后缀并存，NoteService 同口径）；
 * - 大小写不敏感（以 FileTreeView / TrashView / QuickSwitcher / SearchStore 的多数派为准）；
 * - 只剥一层，非笔记后缀原样返回。
 */

/** 文件名（不含路径）→ 显示名：剥一层 .markdown / .md 后缀，其余原样。 */
export function noteDisplayName(name: string): string {
  const lower: string = name.toLowerCase();
  if (lower.endsWith('.markdown')) {
    return name.substring(0, name.length - '.markdown'.length);
  }
  if (lower.endsWith('.md')) {
    return name.substring(0, name.length - '.md'.length);
  }
  return name;
}

/** 库内相对路径 → 显示名：先取最后一段，再剥后缀。 */
export function noteDisplayNameOfPath(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return noteDisplayName(slash >= 0 ? path.substring(slash + 1) : path);
}
