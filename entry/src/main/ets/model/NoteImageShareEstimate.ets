import { NoteImageShareService } from './NoteImageShareService';

/**
 * v1.96：分享格式列表阶段的长图超限预估（用户拍板 B 方案：按内容估算隐藏入口，接受误伤）。
 *
 * 打开分享面板时按当前宽度偏好的捕获宽度估算笔记渲染高度，超过 longImageGeometry
 * 的最小宽度拒绝线（缩放后宽 < 640px，等价高宽比 > 96MiB/(4·640²) ≈ 61.44:1，
 * dpr 在比值两侧同乘抵消，vp 比即 px 比）则不展示「长图」行。
 *
 * 模型是下界：只累计正文 / 代码 / 列表 / 标题 / 表格行的行数 × 行高，忽略图片渲染高度、
 * Mermaid、块间距与标题加高——估算超限时实际渲染高度必然更高；反向漏判（图片等撑高
 * 的笔记仍展示入口）由生成阶段沿用 v1.90 报错引导兜底。
 * 排版度量真源：rawfile mdpreview index.html（--body 16 × --leading 1.85 正文行、
 * --small 14 代码行、#content 左右内边距 --s10×2）。
 */
export class NoteImageShareEstimate {
  /** 预览 #content 左右内边距（--s10 = 40vp，两侧共 80vp）。 */
  static readonly CONTENT_H_PADDING_VP: number = 80;
  /** 正文行高：--body 16 × --leading 1.85。 */
  static readonly BODY_LINE_VP: number = 16 * 1.85;
  /** 代码行高：pre 不换行，每源码行一行，--small 14 × 1.85。 */
  static readonly CODE_LINE_VP: number = 14 * 1.85;
  /** CJK 字符按正文字号计宽。 */
  static readonly CJK_CHAR_VP: number = 16;
  /** 字母数字按下界计宽（实测字母均值约 8vp）。 */
  static readonly ALNUM_CHAR_VP: number = 8;

  /** 长图高度拒绝线（vp）：与 longImageGeometry「缩放后宽 < MIN_IMAGE_WIDTH」等价。 */
  static maxHeightVp(captureWidthVp: number): number {
    const ratio: number = NoteImageShareService.MAX_PIXEL_MAP_BYTES /
      (4 * NoteImageShareService.MIN_IMAGE_WIDTH * NoteImageShareService.MIN_IMAGE_WIDTH);
    return ratio * captureWidthVp;
  }

  /** 预估超限则隐藏「长图」行；空笔记 / 无效宽度一律不隐藏（fail-open）。 */
  static exceedsLongImageLimit(markdown: string, captureWidthVp: number): boolean {
    if (captureWidthVp <= 0 || markdown.length === 0) {
      return false;
    }
    return NoteImageShareEstimate.estimateHeightVp(markdown, captureWidthVp) >
      NoteImageShareEstimate.maxHeightVp(captureWidthVp);
  }

  /** 笔记渲染高度下界估算（vp），度量依据见类注释。 */
  static estimateHeightVp(markdown: string, captureWidthVp: number): number {
    const contentWidthVp: number = Math.max(1,
      captureWidthVp - NoteImageShareEstimate.CONTENT_H_PADDING_VP);
    const lines: string[] = markdown.split('\n');
    let heightVp: number = 0;
    let blockWidthVp: number = 0;
    let inFence: boolean = false;
    // frontmatter（首行 --- … 闭合 ---）：内容不计高度；未闭合时整篇按 0 计（只漏判不误伤）。
    let inFrontmatter: boolean = lines.length > 0 && lines[0].trim() === '---';
    for (let i: number = inFrontmatter ? 1 : 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (inFrontmatter) {
        if (line.trim() === '---') {
          inFrontmatter = false;
        }
        continue;
      }
      const trimmed: string = line.trim();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        if (blockWidthVp > 0) {
          heightVp += NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp);
          blockWidthVp = 0;
        }
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        heightVp += NoteImageShareEstimate.CODE_LINE_VP;
        continue;
      }
      if (trimmed.length === 0) {
        if (blockWidthVp > 0) {
          heightVp += NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp);
          blockWidthVp = 0;
        }
        continue;
      }
      if (NoteImageShareEstimate.isHorizontalRule(trimmed) ||
        NoteImageShareEstimate.isImageOnlyLine(trimmed) ||
        NoteImageShareEstimate.isTableSeparatorRow(trimmed)) {
        if (blockWidthVp > 0) {
          heightVp += NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp);
          blockWidthVp = 0;
        }
        continue;
      }
      if (NoteImageShareEstimate.isHeadingLine(trimmed) ||
        NoteImageShareEstimate.isTableRow(trimmed) ||
        NoteImageShareEstimate.isListItem(trimmed)) {
        if (blockWidthVp > 0) {
          heightVp += NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp);
          blockWidthVp = 0;
        }
        heightVp += Math.max(NoteImageShareEstimate.BODY_LINE_VP,
          NoteImageShareEstimate.textBlockHeightVp(
            NoteImageShareEstimate.lineDisplayWidthVp(trimmed), contentWidthVp));
        continue;
      }
      blockWidthVp += NoteImageShareEstimate.lineDisplayWidthVp(trimmed);
    }
    if (blockWidthVp > 0) {
      heightVp += NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp);
    }
    return heightVp;
  }

  private static textBlockHeightVp(blockWidthVp: number, contentWidthVp: number): number {
    const lineCount: number = Math.max(1, Math.ceil(blockWidthVp / contentWidthVp));
    return lineCount * NoteImageShareEstimate.BODY_LINE_VP;
  }

  /** 行的显示宽下界：CJK 按正文字号，字母数字按下界，其余字符（Markdown 语法符）不计。 */
  private static lineDisplayWidthVp(line: string): number {
    let widthVp: number = 0;
    for (let i: number = 0; i < line.length; i++) {
      const code: number = line.charCodeAt(i);
      if ((code >= 0x4E00 && code <= 0x9FFF) || (code >= 0x3400 && code <= 0x4DBF) ||
        (code >= 0x3000 && code <= 0x303F) || (code >= 0xFF00 && code <= 0xFFEF) ||
        (code >= 0x2010 && code <= 0x2027)) {
        widthVp += NoteImageShareEstimate.CJK_CHAR_VP;
      } else if ((code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A) ||
        (code >= 0x30 && code <= 0x39)) {
        widthVp += NoteImageShareEstimate.ALNUM_CHAR_VP;
      }
    }
    return widthVp;
  }

  private static isHeadingLine(line: string): boolean {
    let level: number = 0;
    while (level < line.length && line.charAt(level) === '#') {
      level++;
    }
    return level >= 1 && level <= 6 && level < line.length && line.charAt(level) === ' ';
  }

  private static isHorizontalRule(line: string): boolean {
    if (line.length < 3) {
      return false;
    }
    const first: string = line.charAt(0);
    if (first !== '-' && first !== '*' && first !== '_') {
      return false;
    }
    for (let i: number = 0; i < line.length; i++) {
      if (line.charAt(i) !== first) {
        return false;
      }
    }
    return true;
  }

  private static isImageOnlyLine(line: string): boolean {
    return line.startsWith('![') && line.endsWith(')') && line.indexOf('](') > 0;
  }

  private static isTableSeparatorRow(line: string): boolean {
    if (!line.startsWith('|')) {
      return false;
    }
    for (let i: number = 0; i < line.length; i++) {
      const c: string = line.charAt(i);
      if (c !== '|' && c !== '-' && c !== ':' && c !== ' ') {
        return false;
      }
    }
    return true;
  }

  private static isTableRow(line: string): boolean {
    return line.startsWith('|') && line.endsWith('|') && line.length >= 2;
  }

  private static isListItem(line: string): boolean {
    if (line.startsWith('- ') || line.startsWith('* ') || line.startsWith('+ ')) {
      return true;
    }
    let i: number = 0;
    while (i < line.length && line.charCodeAt(i) >= 0x30 && line.charCodeAt(i) <= 0x39) {
      i++;
    }
    if (i === 0 || i >= line.length) {
      return false;
    }
    const c: string = line.charAt(i);
    return (c === '.' || c === ')') && i + 1 < line.length && line.charAt(i + 1) === ' ';
  }
}
