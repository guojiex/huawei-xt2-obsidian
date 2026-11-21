import { NoteImageShareService } from './NoteImageShareService';

/**
 * v1.96：分享格式列表阶段的长图超限预估（用户拍板 B 方案：按内容估算隐藏入口，接受误伤）。
 *
 * 打开分享面板时按当前宽度偏好的捕获宽度估算笔记渲染高度，超过 longImageGeometry
 * 的最小宽度拒绝线（缩放后宽 < 640px，等价高宽比 > 96MiB/(4·640²) ≈ 61.44:1，
 * dpr 在比值两侧同乘抵消，vp 比即 px 比）则不展示「长图」行。
 *
 * v1.96.3 校准修订（2026-11-21 真机漏判修复）：初版为纯下界模型（只计行数 × 行高，
 * 段落间距 / 标题加高 / 代码块内边距全部计 0），纯文字笔记真实高度比估算高 20%~50%，
 * 真实高宽比落在 61.44~90 区间的笔记全部漏判（真机实测：超长纯文字笔记仍展示「长图」，
 * 点击后仍报 v1.90 文案）。现按排版真源把块级间距与真实高度计入，相邻块垂直 margin
 * 按 CSS 折叠规则取 max(下边距, 上边距)，模型从「纯下界」升级为「校准估算」。
 * 仍按 0 计的部分：图片渲染高度、Mermaid、双链展开（图片为主的超长笔记仍可能漏判，
 * 由生成阶段 v1.90 报错兜底）。
 * 排版度量真源：rawfile mdpreview index.html（:root 变量与 #content 块级规则）。
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
  /** 段落下边距（p margin 0 0 --s5）。 */
  static readonly PARAGRAPH_MARGIN_VP: number = 20;
  /** h1 高度与上下边距（32 × 1.35；margin --s3 0 --s4）。 */
  static readonly H1_HEIGHT_VP: number = 32 * 1.35;
  static readonly H1_TOP_VP: number = 12;
  static readonly H1_BOTTOM_VP: number = 16;
  /** h2 高度与上下边距（20 × 1.35；margin --s8 0 --s3）。 */
  static readonly H2_HEIGHT_VP: number = 20 * 1.35;
  static readonly H2_TOP_VP: number = 32;
  static readonly H2_BOTTOM_VP: number = 12;
  /** h3~h6 高度与上下边距（16 × 1.35；margin --s5 0 --s2）。 */
  static readonly H3_HEIGHT_VP: number = 16 * 1.35;
  static readonly H3_TOP_VP: number = 20;
  static readonly H3_BOTTOM_VP: number = 8;
  /** 列表项下边距（li margin-bottom --s2）与列表左缩进（ul/ol padding-left --s6）。 */
  static readonly LIST_ITEM_MARGIN_VP: number = 8;
  static readonly LIST_INDENT_VP: number = 24;
  /** 列表下边距（ul/ol margin 0 0 --s5）。 */
  static readonly LIST_MARGIN_BOTTOM_VP: number = 20;
  /** 代码块上下内边距（pre padding --s4 ×2）与下边距（pre margin 0 0 --s5）。 */
  static readonly PRE_PADDING_VP: number = 32;
  static readonly PRE_MARGIN_BOTTOM_VP: number = 20;
  /** 引用块上下边距（blockquote margin --s6 0）与上下内边距（padding --s4 --s5）。 */
  static readonly QUOTE_TOP_VP: number = 24;
  static readonly QUOTE_BOTTOM_VP: number = 24;
  static readonly QUOTE_PADDING_VP: number = 32;
  /** 引用内容左缩进（border-left 2 + padding-left --s5）。 */
  static readonly QUOTE_INDENT_VP: number = 22;
  /** 表格行高（caption 12 × 1.85 + td 上下 padding 8×2 + border 1）。 */
  static readonly TABLE_ROW_VP: number = 12 * 1.85 + 17;
  /** 表格下边距（table margin 0 0 --s5）。 */
  static readonly TABLE_MARGIN_BOTTOM_VP: number = 20;
  /** 分隔线（hr margin --s8 0 + 1px 边线）。 */
  static readonly HR_TOP_VP: number = 32;
  static readonly HR_HEIGHT_VP: number = 1;
  static readonly HR_BOTTOM_VP: number = 32;
  /** 分享水印（.share-watermark margin-top --s8 + padding-top --s3 + 1px 边线 + caption 行高）。 */
  static readonly WATERMARK_VP: number = 32 + 12 + 1 + 12 * 1.85;

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
    return NoteImageShareEstimate.estimateHeightVp(markdown, captureWidthVp) +
      NoteImageShareEstimate.WATERMARK_VP >
      NoteImageShareEstimate.maxHeightVp(captureWidthVp);
  }

  /** 笔记渲染高度校准估算（vp），度量依据见类注释。 */
  static estimateHeightVp(markdown: string, captureWidthVp: number): number {
    const contentWidthVp: number = Math.max(1,
      captureWidthVp - NoteImageShareEstimate.CONTENT_H_PADDING_VP);
    const lines: string[] = markdown.split('\n');
    let heightVp: number = 0;
    // 相邻块垂直 margin 折叠：块间垂直间隙 = max(上一块下边距, 当前块上边距)。
    let lastBottomMarginVp: number = 0;
    let blockWidthVp: number = 0;
    let quoteWidthVp: number = 0;
    let codeLineCount: number = 0;
    let tableRowCount: number = 0;
    let inFence: boolean = false;
    let inList: boolean = false;
    const appendBlock = (blockHeightVp: number, topMarginVp: number, bottomMarginVp: number): void => {
      heightVp += Math.max(lastBottomMarginVp, topMarginVp) + blockHeightVp;
      lastBottomMarginVp = bottomMarginVp;
    };
    const flushParagraph = (): void => {
      if (blockWidthVp > 0) {
        appendBlock(NoteImageShareEstimate.textBlockHeightVp(blockWidthVp, contentWidthVp),
          0, NoteImageShareEstimate.PARAGRAPH_MARGIN_VP);
        blockWidthVp = 0;
      }
    };
    const flushQuote = (): void => {
      if (quoteWidthVp > 0) {
        appendBlock(NoteImageShareEstimate.quoteBlockHeightVp(quoteWidthVp, contentWidthVp),
          NoteImageShareEstimate.QUOTE_TOP_VP, NoteImageShareEstimate.QUOTE_BOTTOM_VP);
        quoteWidthVp = 0;
      }
    };
    const flushTable = (): void => {
      if (tableRowCount > 0) {
        appendBlock(tableRowCount * NoteImageShareEstimate.TABLE_ROW_VP,
          0, NoteImageShareEstimate.TABLE_MARGIN_BOTTOM_VP);
        tableRowCount = 0;
      }
    };
    const flushList = (): void => {
      if (inList) {
        inList = false;
        appendBlock(0, 0, NoteImageShareEstimate.LIST_MARGIN_BOTTOM_VP);
      }
    };
    const flushAll = (): void => {
      flushParagraph();
      flushQuote();
      flushTable();
      flushList();
    };
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
        flushAll();
        if (inFence) {
          appendBlock(NoteImageShareEstimate.PRE_PADDING_VP +
            codeLineCount * NoteImageShareEstimate.CODE_LINE_VP,
            0, NoteImageShareEstimate.PRE_MARGIN_BOTTOM_VP);
          codeLineCount = 0;
        }
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        codeLineCount++;
        continue;
      }
      if (trimmed.length === 0) {
        flushAll();
        continue;
      }
      if (NoteImageShareEstimate.isHorizontalRule(trimmed) ||
        NoteImageShareEstimate.isImageOnlyLine(trimmed)) {
        flushAll();
        if (NoteImageShareEstimate.isHorizontalRule(trimmed)) {
          appendBlock(NoteImageShareEstimate.HR_HEIGHT_VP,
            NoteImageShareEstimate.HR_TOP_VP, NoteImageShareEstimate.HR_BOTTOM_VP);
        }
        continue;
      }
      if (NoteImageShareEstimate.isHeadingLine(trimmed)) {
        flushAll();
        const level: number = NoteImageShareEstimate.headingLevel(trimmed);
        if (level === 1) {
          appendBlock(NoteImageShareEstimate.H1_HEIGHT_VP,
            NoteImageShareEstimate.H1_TOP_VP, NoteImageShareEstimate.H1_BOTTOM_VP);
        } else if (level === 2) {
          appendBlock(NoteImageShareEstimate.H2_HEIGHT_VP,
            NoteImageShareEstimate.H2_TOP_VP, NoteImageShareEstimate.H2_BOTTOM_VP);
        } else {
          appendBlock(NoteImageShareEstimate.H3_HEIGHT_VP,
            NoteImageShareEstimate.H3_TOP_VP, NoteImageShareEstimate.H3_BOTTOM_VP);
        }
        continue;
      }
      if (NoteImageShareEstimate.isTableSeparatorRow(trimmed)) {
        flushParagraph();
        flushQuote();
        flushList();
        continue;
      }
      if (NoteImageShareEstimate.isTableRow(trimmed)) {
        flushParagraph();
        flushQuote();
        flushList();
        tableRowCount++;
        continue;
      }
      if (NoteImageShareEstimate.isListItem(trimmed)) {
        flushParagraph();
        flushQuote();
        flushTable();
        appendBlock(NoteImageShareEstimate.textBlockHeightVp(
          NoteImageShareEstimate.lineDisplayWidthVp(trimmed),
          Math.max(1, contentWidthVp - NoteImageShareEstimate.LIST_INDENT_VP)),
          0, NoteImageShareEstimate.LIST_ITEM_MARGIN_VP);
        inList = true;
        continue;
      }
      if (trimmed.startsWith('>')) {
        flushParagraph();
        flushTable();
        flushList();
        quoteWidthVp += NoteImageShareEstimate.lineDisplayWidthVp(trimmed.substring(1));
        continue;
      }
      flushQuote();
      flushTable();
      flushList();
      blockWidthVp += NoteImageShareEstimate.lineDisplayWidthVp(trimmed);
    }
    flushAll();
    return heightVp;
  }

  private static textBlockHeightVp(blockWidthVp: number, contentWidthVp: number): number {
    const lineCount: number = Math.max(1, Math.ceil(blockWidthVp / contentWidthVp));
    return lineCount * NoteImageShareEstimate.BODY_LINE_VP;
  }

  private static quoteBlockHeightVp(quoteWidthVp: number, contentWidthVp: number): number {
    const lineCount: number = Math.max(1, Math.ceil(quoteWidthVp /
      Math.max(1, contentWidthVp - NoteImageShareEstimate.QUOTE_INDENT_VP)));
    return NoteImageShareEstimate.QUOTE_PADDING_VP +
      lineCount * NoteImageShareEstimate.CODE_LINE_VP;
  }

  private static headingLevel(line: string): number {
    let level: number = 0;
    while (level < line.length && line.charAt(level) === '#') {
      level++;
    }
    return level;
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
    const level: number = NoteImageShareEstimate.headingLevel(line);
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
