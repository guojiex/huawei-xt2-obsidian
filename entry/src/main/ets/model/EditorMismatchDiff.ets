/**
 * 编辑不一致双栏 diff 模型（v1.70 70.1 升级，2026-11-15）：
 * 「编辑内容与笔记不一致」恢复弹窗用，把基线（笔记文件版本）与编辑器内容
 * 按行做 LCS 对齐，输出逐行对照的行对列表供双栏渲染。
 *
 * 隐私红线（仓库手册硬约束 16）：本模块只做纯文本变换，不产生日志 / 埋点；
 * 摘要口径见 pages/Index.ets 的 describeEditorTextMismatch（只出长度 / 位置 / 码点）。
 */

/** 行对单元格种类 */
export const EDITOR_MISMATCH_KIND_SAME: number = 0;
/** 仅笔记版本有该行（对照 git 删除侧，红） */
export const EDITOR_MISMATCH_KIND_REMOVED: number = 1;
/** 仅编辑区版本有该行（对照 git 新增侧，绿） */
export const EDITOR_MISMATCH_KIND_ADDED: number = 2;
/** 折叠提示行（「⋯ N 行一致」等） */
export const EDITOR_MISMATCH_KIND_COLLAPSED: number = 3;

/** 相同行连续超过该值折叠为「⋯ N 行一致」，保留首尾各 EDITOR_MISMATCH_CONTEXT 行 */
export const EDITOR_MISMATCH_COLLAPSE_THRESHOLD: number = 8;
export const EDITOR_MISMATCH_CONTEXT: number = 3;
/** 单个单元格最大字符数，超出截断加省略号（防超长行拖垮渲染） */
export const EDITOR_MISMATCH_CELL_MAX: number = 2000;
/** 行对总数上限，超出保留首尾并插入折叠提示行 */
export const EDITOR_MISMATCH_ROW_MAX: number = 400;
/** LCS DP 单元格上限（Uint32Array 预算约 4MB），超出走公共前后缀回退路径 */
export const EDITOR_MISMATCH_LCS_CELL_MAX: number = 1000000;

/** 双栏 diff 的单行行对：左右各一个单元格（文本 + 种类） */
export class EditorMismatchDiffRow {
  leftText: string;
  leftKind: number;
  rightText: string;
  rightKind: number;

  constructor(leftText: string, leftKind: number, rightText: string, rightKind: number) {
    this.leftText = leftText;
    this.leftKind = leftKind;
    this.rightText = rightText;
    this.rightKind = rightKind;
  }
}

function truncateCell(text: string): string {
  if (text.length <= EDITOR_MISMATCH_CELL_MAX) {
    return text;
  }
  return text.substring(0, EDITOR_MISMATCH_CELL_MAX) + '…';
}

function sameRow(line: string): EditorMismatchDiffRow {
  return new EditorMismatchDiffRow(line, EDITOR_MISMATCH_KIND_SAME,
    line, EDITOR_MISMATCH_KIND_SAME);
}

function removedRow(line: string): EditorMismatchDiffRow {
  return new EditorMismatchDiffRow(truncateCell(line), EDITOR_MISMATCH_KIND_REMOVED,
    '', EDITOR_MISMATCH_KIND_SAME);
}

function addedRow(line: string): EditorMismatchDiffRow {
  return new EditorMismatchDiffRow('', EDITOR_MISMATCH_KIND_SAME,
    truncateCell(line), EDITOR_MISMATCH_KIND_ADDED);
}

function pairRow(leftLine: string, rightLine: string): EditorMismatchDiffRow {
  return new EditorMismatchDiffRow(truncateCell(leftLine), EDITOR_MISMATCH_KIND_REMOVED,
    truncateCell(rightLine), EDITOR_MISMATCH_KIND_ADDED);
}

function isSamePair(row: EditorMismatchDiffRow): boolean {
  return row.leftKind === EDITOR_MISMATCH_KIND_SAME && row.rightKind === EDITOR_MISMATCH_KIND_SAME;
}

/**
 * 把相邻的删除 / 新增行按出现顺序两两配成同一行对（左删右增，贴近 git 双栏观感），
 * 多余的单侧行独立成行。输入行序列已保证相同行不会出现在同一相邻块内。
 */
function pairAdjacentEdits(rows: EditorMismatchDiffRow[]): EditorMismatchDiffRow[] {
  const out: EditorMismatchDiffRow[] = [];
  let index: number = 0;
  while (index < rows.length) {
    if (isSamePair(rows[index])) {
      out.push(rows[index]);
      index++;
      continue;
    }
    const start: number = index;
    while (index < rows.length && !isSamePair(rows[index])) {
      index++;
    }
    const removedTexts: string[] = [];
    const addedTexts: string[] = [];
    for (let k: number = start; k < index; k++) {
      if (rows[k].leftKind === EDITOR_MISMATCH_KIND_REMOVED) {
        removedTexts.push(rows[k].leftText);
      } else {
        addedTexts.push(rows[k].rightText);
      }
    }
    const pairs: number = Math.min(removedTexts.length, addedTexts.length);
    for (let t: number = 0; t < pairs; t++) {
      out.push(pairRow(removedTexts[t], addedTexts[t]));
    }
    for (let t: number = pairs; t < removedTexts.length; t++) {
      out.push(removedRow(removedTexts[t]));
    }
    for (let t: number = pairs; t < addedTexts.length; t++) {
      out.push(addedRow(addedTexts[t]));
    }
  }
  return out;
}

/** LCS 对齐主路径：倒序 DP + 正序回放，规模受 EDITOR_MISMATCH_LCS_CELL_MAX 约束 */
function buildAlignedRows(leftLines: string[], rightLines: string[]): EditorMismatchDiffRow[] {
  const m: number = leftLines.length;
  const n: number = rightLines.length;
  const width: number = n + 1;
  const dp: Uint32Array = new Uint32Array((m + 1) * width);
  for (let i: number = m - 1; i >= 0; i--) {
    for (let j: number = n - 1; j >= 0; j--) {
      dp[i * width + j] = leftLines[i] === rightLines[j]
        ? dp[(i + 1) * width + (j + 1)] + 1
        : Math.max(dp[(i + 1) * width + j], dp[i * width + (j + 1)]);
    }
  }
  const rows: EditorMismatchDiffRow[] = [];
  let i: number = 0;
  let j: number = 0;
  while (i < m && j < n) {
    if (leftLines[i] === rightLines[j]) {
      rows.push(sameRow(leftLines[i]));
      i++;
      j++;
      continue;
    }
    if (dp[(i + 1) * width + j] >= dp[i * width + (j + 1)]) {
      rows.push(removedRow(leftLines[i]));
      i++;
    } else {
      rows.push(addedRow(rightLines[j]));
      j++;
    }
  }
  while (i < m) {
    rows.push(removedRow(leftLines[i]));
    i++;
  }
  while (j < n) {
    rows.push(addedRow(rightLines[j]));
    j++;
  }
  return pairAdjacentEdits(rows);
}

/** 规模超限的回退：公共前后缀逐行对齐，中间整段分侧呈现（不逐行配对） */
function buildFallbackRows(leftLines: string[], rightLines: string[]): EditorMismatchDiffRow[] {
  const m: number = leftLines.length;
  const n: number = rightLines.length;
  let prefix: number = 0;
  while (prefix < m && prefix < n && leftLines[prefix] === rightLines[prefix]) {
    prefix++;
  }
  let suffix: number = 0;
  while (suffix < m - prefix && suffix < n - prefix &&
    leftLines[m - 1 - suffix] === rightLines[n - 1 - suffix]) {
    suffix++;
  }
  const rows: EditorMismatchDiffRow[] = [];
  for (let k: number = 0; k < prefix; k++) {
    rows.push(sameRow(leftLines[k]));
  }
  for (let k: number = prefix; k < m - suffix; k++) {
    rows.push(removedRow(leftLines[k]));
  }
  for (let k: number = prefix; k < n - suffix; k++) {
    rows.push(addedRow(rightLines[k]));
  }
  for (let k: number = 0; k < suffix; k++) {
    rows.push(sameRow(leftLines[m - suffix + k]));
  }
  return rows;
}

/** 相同行长 run 折叠：> 阈值时保留首尾各 CONTEXT 行，中间替换为一行「⋯ N 行一致」 */
function collapseSameRuns(rows: EditorMismatchDiffRow[]): EditorMismatchDiffRow[] {
  const out: EditorMismatchDiffRow[] = [];
  let index: number = 0;
  while (index < rows.length) {
    if (!isSamePair(rows[index])) {
      out.push(rows[index]);
      index++;
      continue;
    }
    const start: number = index;
    while (index < rows.length && isSamePair(rows[index])) {
      index++;
    }
    const runLength: number = index - start;
    if (runLength <= EDITOR_MISMATCH_COLLAPSE_THRESHOLD) {
      for (let k: number = start; k < index; k++) {
        out.push(rows[k]);
      }
      continue;
    }
    const headEnd: number = start + EDITOR_MISMATCH_CONTEXT;
    for (let k: number = start; k < headEnd; k++) {
      out.push(rows[k]);
    }
    const tailStart: number = index - EDITOR_MISMATCH_CONTEXT;
    const hidden: number = tailStart - headEnd;
    const note: string = '⋯ ' + hidden + ' 行一致';
    out.push(new EditorMismatchDiffRow(note, EDITOR_MISMATCH_KIND_COLLAPSED,
      note, EDITOR_MISMATCH_KIND_COLLAPSED));
    for (let k: number = tailStart; k < index; k++) {
      out.push(rows[k]);
    }
  }
  return out;
}

/** 行对总数超限时保留首尾（各约一半），中间插入一行折叠提示 */
function capTotalRows(rows: EditorMismatchDiffRow[]): EditorMismatchDiffRow[] {
  if (rows.length <= EDITOR_MISMATCH_ROW_MAX) {
    return rows;
  }
  const headKeep: number = 199;
  const tailKeep: number = 200;
  const out: EditorMismatchDiffRow[] = [];
  for (let k: number = 0; k < headKeep; k++) {
    out.push(rows[k]);
  }
  const hidden: number = rows.length - headKeep - tailKeep;
  const note: string = '⋯ 其余 ' + hidden + ' 行未展示（差异过多，建议直接对照两版取舍）';
  out.push(new EditorMismatchDiffRow(note, EDITOR_MISMATCH_KIND_COLLAPSED,
    note, EDITOR_MISMATCH_KIND_COLLAPSED));
  for (let k: number = rows.length - tailKeep; k < rows.length; k++) {
    out.push(rows[k]);
  }
  return out;
}

/**
 * 构建双栏 diff 行对（v1.70 70.1）。
 * 入参为原始基线与编辑器文本（不做 BOM / CRLF 归一 —— 弹窗只在真实差异时出现，
 * 展示真实内容）；输出经过「相邻增删配对 → 相同行折叠 → 总量截断」三级收敛。
 */
export function buildEditorMismatchDiffRows(baseline: string, editor: string): EditorMismatchDiffRow[] {
  const leftLines: string[] = baseline.split('\n');
  const rightLines: string[] = editor.split('\n');
  const cellCount: number = (leftLines.length + 1) * (rightLines.length + 1);
  const rows: EditorMismatchDiffRow[] = cellCount <= EDITOR_MISMATCH_LCS_CELL_MAX
    ? buildAlignedRows(leftLines, rightLines)
    : buildFallbackRows(leftLines, rightLines);
  return capTotalRows(collapseSameRuns(rows));
}
