import { util } from '@kit.ArkTS';
import { uniformTypeDescriptor } from '@kit.ArkData';

export interface NoteTextSharePreview {
  title: string;
  content: string;
  limitations: string[];
}

interface NoteTextShareFlags {
  hasFrontmatter: boolean;
  hasImage: boolean;
  hasTable: boolean;
  hasFormula: boolean;
  hasWikiLink: boolean;
}

/** 将单篇笔记快照转换为可编辑文本；未知 Markdown 保留原文，避免静默丢内容。 */
export class NoteTextShareService {
  private static readonly SHARE_LIMIT_BYTES: number = 200 * 1024;

  static createPreview(fileName: string, markdown: string): NoteTextSharePreview {
    const lines: string[] = markdown.replace(/\r\n?/g, '\n').split('\n');
    const flags: NoteTextShareFlags = {
      hasFrontmatter: false,
      hasImage: false,
      hasTable: false,
      hasFormula: false,
      hasWikiLink: false
    };
    let title: string = NoteTextShareService.titleFromFileName(fileName);
    let startLine: number = 0;
    if (lines.length > 0 && lines[0].trim() === '---') {
      let endLine: number = -1;
      for (let i = 1; i < lines.length; i++) {
        const marker: string = lines[i].trim();
        if (marker === '---' || marker === '...') {
          endLine = i;
          break;
        }
        const titleMatch: RegExpExecArray | null = /^title:\s*(.*?)\s*$/i.exec(lines[i]);
        if (titleMatch !== null && titleMatch[1].length > 0) {
          const candidate: string = titleMatch[1].replace(/^['"]|['"]$/g, '').trim();
          if (candidate.length > 0) {
            title = candidate;
          }
        }
      }
      if (endLine >= 0) {
        flags.hasFrontmatter = true;
        startLine = endLine + 1;
      }
    }

    const bodyLines: string[] = [];
    let fenceChar: string = '';
    let fenceLength: number = 0;
    let firstHeading: boolean = true;
    let tableActive: boolean = false;
    for (let i = startLine; i < lines.length; i++) {
      const line: string = lines[i];
      const fenceMatch: RegExpExecArray | null = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (fenceMatch !== null) {
        const marker: string = fenceMatch[1][0];
        const markerLength: number = fenceMatch[1].length;
        if (fenceChar.length === 0) {
          fenceChar = marker;
          fenceLength = markerLength;
          continue;
        }
        if (marker === fenceChar && markerLength >= fenceLength) {
          fenceChar = '';
          fenceLength = 0;
          continue;
        }
      }
      if (fenceChar.length > 0) {
        bodyLines.push(line);
        continue;
      }
      if (line.indexOf('$') >= 0 || line.indexOf('\\(') >= 0 || line.indexOf('\\[') >= 0) {
        flags.hasFormula = true;
      }

      if (NoteTextShareService.isTableDivider(line)) {
        flags.hasTable = true;
        tableActive = true;
        continue;
      }
      if (tableActive && line.indexOf('|') >= 0) {
        bodyLines.push(NoteTextShareService.tableRow(line, flags));
        continue;
      }
      if (tableActive && line.trim().length === 0) {
        tableActive = false;
      } else if (tableActive && line.indexOf('|') < 0) {
        tableActive = false;
      }
      if (!tableActive && i + 1 < lines.length && NoteTextShareService.isTableDivider(lines[i + 1])) {
        flags.hasTable = true;
        tableActive = true;
        bodyLines.push(NoteTextShareService.tableRow(line, flags));
        continue;
      }

      if (/^\s*([-*_]\s*){3,}$/.test(line)) {
        continue;
      }
      let converted: string = line;
      const headingMatch: RegExpExecArray | null = /^ {0,3}#{1,6}\s+(.*)$/.exec(converted);
      if (headingMatch !== null) {
        converted = headingMatch[1];
        const cleanHeading: string = NoteTextShareService.cleanInline(converted, flags).trim();
        if (firstHeading && cleanHeading === title) {
          firstHeading = false;
          continue;
        }
        firstHeading = false;
      }
      converted = converted.replace(/^\s{0,3}>\s?/, '');
      const taskMatch: RegExpExecArray | null = /^(\s*)([-+*]|\d+[.)])\s+\[([ xX])\]\s+(.*)$/.exec(converted);
      if (taskMatch !== null) {
        const mark: string = taskMatch[3].toLowerCase() === 'x' ? '☑' : '☐';
        converted = taskMatch[1] + mark + ' ' + NoteTextShareService.cleanInline(taskMatch[4], flags);
      } else {
        const listMatch: RegExpExecArray | null = /^(\s*)([-+*]|\d+[.)])\s+(.*)$/.exec(converted);
        if (listMatch !== null) {
          const marker: string = /^\d/.test(listMatch[2]) ? listMatch[2] : '•';
          converted = listMatch[1] + marker + ' ' + NoteTextShareService.cleanInline(listMatch[3], flags);
        } else {
          converted = NoteTextShareService.cleanInline(converted, flags);
        }
      }
      bodyLines.push(converted);
    }

    const body: string = NoteTextShareService.collapseBlankLines(bodyLines.join('\n')).trim();
    const content: string = body.length === 0 ? title : title + '\n\n' + body;
    const limitations: string[] = [];
    if (flags.hasFrontmatter) {
      limitations.push('YAML 属性区不包含在文本中。');
    }
    if (flags.hasImage) {
      limitations.push('图片以文字占位，不会随文本传递；需保留附件时请选择排版图片或 Markdown / ZIP。');
    }
    if (flags.hasTable) {
      limitations.push('表格改为单元格文字排列，表格版式不会保留。');
    }
    if (flags.hasFormula) {
      limitations.push('公式保留原始表达式，公式排版不会保留。');
    }
    if (flags.hasWikiLink) {
      limitations.push('双链改为可读文字，链接目标放在括号中。');
    }
    if (!NoteTextShareService.isWithinShareLimit(title, content)) {
      limitations.push('文本超过系统分享 200 KB 限制，请删减内容后重试或改用 Markdown / ZIP。');
    }
    return { title: title, content: content, limitations: limitations };
  }

  /** Share Kit 限制 SharedData 总大小；按 UTF-8 字节统计记录中的文本字段。 */
  static isWithinShareLimit(title: string, content: string): boolean {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const totalBytes: number = encoder.encodeInto(title).byteLength + encoder.encodeInto(content).byteLength +
      encoder.encodeInto(uniformTypeDescriptor.UniformDataType.TEXT).byteLength + encoder.encodeInto('TEXT').byteLength;
    return totalBytes <= NoteTextShareService.SHARE_LIMIT_BYTES;
  }

  private static titleFromFileName(fileName: string): string {
    const leaf: string = fileName.substring(fileName.lastIndexOf('/') + 1);
    const title: string = leaf.replace(/\.md$/i, '').trim();
    return title.length > 0 ? title : '未命名笔记';
  }

  private static isTableDivider(line: string): boolean {
    return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
  }

  private static tableRow(line: string, flags: NoteTextShareFlags): string {
    const row: string = line.trim().replace(/^\|/, '').replace(/\|$/, '');
    return row.split('|').map((cell: string): string => NoteTextShareService.cleanInline(cell.trim(), flags))
      .join(' | ');
  }

  private static cleanInline(text: string, flags: NoteTextShareFlags): string {
    const inlineCode: string[] = [];
    let markerPrefix: string = '\uE000';
    while (text.indexOf(markerPrefix) >= 0) {
      markerPrefix += '\uE000';
    }
    let output: string = text.replace(/(`+)([^`\n]+)\1/g,
      (_whole: string, _ticks: string, code: string): string => {
        const marker: string = markerPrefix + inlineCode.length.toString() + '\uE001';
        inlineCode.push(code);
        return marker;
      });
    output = output.replace(/!\[([^\]]*)\]\([^)]*\)/g, (_whole: string, alt: string): string => {
      flags.hasImage = true;
      return alt.length > 0 ? '[图片：' + alt + ']' : '[图片]';
    });
    output = output.replace(/!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g,
      (_whole: string, target: string, alias: string | undefined): string => {
        flags.hasImage = true;
        const label: string = alias === undefined || alias.length === 0 ? target : alias;
        return '[图片：' + label + ']';
      });
    output = output.replace(/!\[([^\]]*)\](?:\[[^\]]*\])?/g,
      (_whole: string, alt: string): string => {
        flags.hasImage = true;
        return alt.length > 0 ? '[图片：' + alt + ']' : '[图片]';
      });
    output = output.replace(/\[([^\]]+)\]\(([^)]+)\)/g,
      (_whole: string, label: string, target: string): string => label === target ? label : label + ' (' + target + ')');
    output = output.replace(/!\[\[([^\]]+)\]\]/g, (_whole: string, target: string): string => {
      flags.hasImage = true;
      return '[图片：' + target + ']';
    });
    output = output.replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g,
      (_whole: string, target: string, alias: string): string => {
        flags.hasWikiLink = true;
        return alias + ' (' + target + ')';
      });
    output = output.replace(/\[\[([^\]]+)\]\]/g, (_whole: string, target: string): string => {
      flags.hasWikiLink = true;
      return target;
    });
    output = output.replace(/<img\b[^>]*>/gi, (tag: string): string => {
      const altMatch: RegExpExecArray | null = /\balt=["']([^"']*)["']/i.exec(tag);
      const alt: string = altMatch === null ? '' : altMatch[1];
      flags.hasImage = true;
      return alt.length > 0 ? '[图片：' + alt + ']' : '[图片]';
    });
    output = output.replace(/<br\s*\/?>/gi, '\n').replace(/<\/?p\b[^>]*>/gi, '\n');
    output = output.replace(/<[^>]+>/g, '');
    output = output.replace(/(\*\*|__)([^\n]+?)\1/g, '$2');
    output = output.replace(/~~([^\n]+?)~~/g, '$1');
    output = output.replace(/\*([^*\n]+)\*/g, '$1');
    output = output.replace(/(^|\s)_([^_\n]+)_(?=\s|$)/g, '$1$2');
    output = output.replace(/\\([\\`*_{}\[\]()#+.!>|~-])/g, '$1');
    output = output.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ');
    for (let i = 0; i < inlineCode.length; i++) {
      const marker: string = markerPrefix + i.toString() + '\uE001';
      output = output.replace(marker, inlineCode[i]);
    }
    return output;
  }

  private static collapseBlankLines(text: string): string {
    return text.replace(/\n[\t ]*\n(?:[\t ]*\n)+/g, '\n\n');
  }
}
