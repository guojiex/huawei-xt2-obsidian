import { BridgeCodec } from '../common/BridgeCodec';

export interface WikiLinkReference {
  start: number;
  end: number;
  targetStart: number;
  targetEnd: number;
  target: string;
  alias: string;
}

export interface WikiLinkResolution {
  status: string;
  path: string;
}

export interface WikiLinkCandidate {
  path: string;
  insertTarget: string;
}

/** Parser and resolver for the v1.2 current-vault wikilink subset. */
export class WikiLinkParser {
  static parse(markdown: string): WikiLinkReference[] {
    const references: WikiLinkReference[] = [];
    let cursor: number = 0;
    let fenceChar: string = '';
    let fenceLength: number = 0;
    while (cursor < markdown.length) {
      if (cursor === 0 || markdown[cursor - 1] === '\n') {
        const lineStart: number = cursor;
        let markerAt: number = lineStart;
        let indent: number = 0;
        while (markerAt < markdown.length && markdown[markerAt] === ' ' && indent < 4) {
          markerAt++;
          indent++;
        }
        const marker: string = markerAt < markdown.length ? markdown[markerAt] : '';
        if (marker === '`' || marker === '~') {
          let runEnd: number = markerAt;
          while (runEnd < markdown.length && markdown[runEnd] === marker) {
            runEnd++;
          }
          const runLength: number = runEnd - markerAt;
          if (runLength >= 3 && indent <= 3) {
            const lineEnd: number = WikiLinkParser.lineEnd(markdown, runEnd);
            if (fenceChar.length === 0) {
              fenceChar = marker;
              fenceLength = runLength;
              cursor = lineEnd;
              continue;
            }
            if (marker === fenceChar && runLength >= fenceLength &&
              WikiLinkParser.isBlankLineTail(markdown, runEnd, lineEnd)) {
              fenceChar = '';
              fenceLength = 0;
            }
          }
        }
        if (fenceChar.length > 0) {
          cursor = WikiLinkParser.lineEnd(markdown, lineStart);
          continue;
        }
      }

      if (markdown[cursor] === '`') {
        let runEnd: number = cursor;
        while (runEnd < markdown.length && markdown[runEnd] === '`') {
          runEnd++;
        }
        const runLength: number = runEnd - cursor;
        const close: number = WikiLinkParser.findBacktickRun(markdown, runEnd, runLength);
        cursor = close < 0 ? runEnd : close + runLength;
        continue;
      }

      if (markdown[cursor] !== '[' || markdown[cursor + 1] !== '[' ||
        WikiLinkParser.isEscaped(markdown, cursor) ||
        (cursor > 0 && markdown[cursor - 1] === '!')) {
        cursor++;
        continue;
      }

      const close: number = markdown.indexOf(']]', cursor + 2);
      if (close < 0) {
        cursor += 2;
        continue;
      }
      const lineBreak: number = markdown.indexOf('\n', cursor + 2);
      if (lineBreak >= 0 && lineBreak < close) {
        cursor += 2;
        continue;
      }
      const pipeAt: number = markdown.indexOf('|', cursor + 2);
      const rawTargetEnd: number = pipeAt >= 0 && pipeAt < close ? pipeAt : close;
      let targetStart: number = cursor + 2;
      let targetEnd: number = rawTargetEnd;
      while (targetStart < targetEnd && /\s/.test(markdown[targetStart])) {
        targetStart++;
      }
      while (targetEnd > targetStart && /\s/.test(markdown[targetEnd - 1])) {
        targetEnd--;
      }
      const target: string = markdown.substring(targetStart, targetEnd);
      if (target.length > 0 && target.indexOf('[') < 0 && target.indexOf(']') < 0) {
        let alias: string = '';
        if (pipeAt >= 0 && pipeAt < close) {
          alias = markdown.substring(pipeAt + 1, close).trim();
        }
        references.push({
          start: cursor,
          end: close + 2,
          targetStart: targetStart,
          targetEnd: targetEnd,
          target: target,
          alias: alias
        });
      }
      cursor = close + 2;
    }
    return references;
  }

  /** Path-bearing links are vault-root-relative; bare names are source-directory-relative. */
  static resolve(target: string, sourcePath: string, files: string[]): WikiLinkResolution {
    const value: string = target.trim();
    if (value.length === 0 || value.indexOf('#') >= 0 || value.indexOf('\\') >= 0 || value.startsWith('/')) {
      return { status: 'invalid', path: '' };
    }
    const explicitRoot: boolean = value.startsWith('./');
    const hasPath: boolean = value.indexOf('/') >= 0;
    const pathValue: string = explicitRoot ? value.substring(2) : value;
    if (pathValue.length === 0) {
      return { status: 'invalid', path: '' };
    }
    const segments: string[] = pathValue.split('/');
    for (let i = 0; i < segments.length; i++) {
      if (segments[i].length === 0 || segments[i] === '.' || segments[i] === '..' ||
        segments[i].startsWith('.')) {
        return { status: 'invalid', path: '' };
      }
    }
    const rootRelative: boolean = explicitRoot || hasPath;
    let candidate: string = pathValue;
    if (!rootRelative) {
      const slash: number = sourcePath.lastIndexOf('/');
      const parent: string = slash >= 0 ? sourcePath.substring(0, slash) : '';
      candidate = parent.length > 0 ? parent + '/' + pathValue : pathValue;
    }
    const hasMarkdownExtension: boolean = candidate.endsWith('.md') || candidate.endsWith('.markdown');
    const candidates: string[] = hasMarkdownExtension
      ? [candidate] : [candidate + '.md', candidate + '.markdown'];
    const matches: string[] = [];
    for (let i = 0; i < candidates.length; i++) {
      if (files.indexOf(candidates[i]) >= 0) {
        matches.push(candidates[i]);
      }
    }
    if (matches.length === 1) {
      return { status: 'resolved', path: matches[0] };
    }
    if (matches.length > 1) {
      return { status: 'ambiguous', path: '' };
    }
    return { status: 'missing', path: candidates[0] };
  }

  static completionCandidates(query: string, files: string[], limit: number = 20): WikiLinkCandidate[] {
    let needle: string = query.trim();
    if (needle.startsWith('./')) {
      needle = needle.substring(2);
    }
    if (needle.indexOf('|') >= 0 || needle.indexOf('#') >= 0 || needle.indexOf('\\') >= 0) {
      return [];
    }
    const result: WikiLinkCandidate[] = [];
    for (let i = 0; i < files.length && result.length < limit; i++) {
      const path: string = files[i];
      if (needle.length > 0 && path.indexOf(needle) < 0) {
        continue;
      }
      result.push({ path: path, insertTarget: path.indexOf('/') >= 0 ? path : './' + path });
    }
    return result;
  }

  static pathToTarget(path: string): string {
    return path.indexOf('/') >= 0 ? path : './' + path;
  }

  static renderForPreview(markdown: string, sourcePath: string, files: string[]): string {
    const references: WikiLinkReference[] = WikiLinkParser.parse(markdown);
    let result: string = markdown;
    for (let i = references.length - 1; i >= 0; i--) {
      const reference: WikiLinkReference = references[i];
      const resolution: WikiLinkResolution = WikiLinkParser.resolve(reference.target, sourcePath, files);
      const label: string = reference.alias.length > 0
        ? reference.alias : WikiLinkParser.displayLabel(reference.target);
      let html: string;
      if (resolution.status === 'invalid') {
        html = '<span class="wiki-link-invalid">' + WikiLinkParser.escapeHtml(label) + '（暂不支持）</span>';
      } else if (resolution.status === 'ambiguous') {
        const encoded: string = BridgeCodec.encode(reference.target);
        html = '<a class="wiki-link" href="#wikilink:' + encoded + '">' +
          WikiLinkParser.escapeHtml(label) + '</a>' +
          '<small class="wiki-link-state">（目标不唯一，请补全扩展名）</small>';
      } else {
        const state: string = resolution.status === 'missing' ? '（未创建）' : '';
        const encoded: string = BridgeCodec.encode(reference.target);
        html = '<a class="wiki-link" href="#wikilink:' + encoded + '">' +
          WikiLinkParser.escapeHtml(label) + '</a>' +
          (state.length > 0 ? '<small class="wiki-link-state">' + state + '</small>' : '');
      }
      result = result.substring(0, reference.start) + html + result.substring(reference.end);
    }
    return result;
  }

  private static displayLabel(target: string): string {
    const noExtension: string = target.endsWith('.markdown')
      ? target.substring(0, target.length - '.markdown'.length)
      : (target.endsWith('.md') ? target.substring(0, target.length - 3) : target);
    const slash: number = noExtension.lastIndexOf('/');
    return slash >= 0 ? noExtension.substring(slash + 1) : noExtension;
  }

  private static escapeHtml(text: string): string {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  private static isEscaped(markdown: string, index: number): boolean {
    let slashCount: number = 0;
    let cursor: number = index - 1;
    while (cursor >= 0 && markdown[cursor] === '\\') {
      slashCount++;
      cursor--;
    }
    return slashCount % 2 === 1;
  }

  private static lineEnd(markdown: string, index: number): number {
    const end: number = markdown.indexOf('\n', index);
    return end < 0 ? markdown.length : end + 1;
  }

  private static isBlankLineTail(markdown: string, from: number, end: number): boolean {
    let cursor: number = from;
    while (cursor < end && markdown[cursor] !== '\n') {
      if (markdown[cursor] !== ' ' && markdown[cursor] !== '\t' && markdown[cursor] !== '\r') {
        return false;
      }
      cursor++;
    }
    return true;
  }

  private static findBacktickRun(markdown: string, from: number, length: number): number {
    let cursor: number = from;
    while (cursor < markdown.length) {
      const next: number = markdown.indexOf('`', cursor);
      if (next < 0) {
        return -1;
      }
      let end: number = next;
      while (end < markdown.length && markdown[end] === '`') {
        end++;
      }
      if (end - next === length) {
        return next;
      }
      cursor = end;
    }
    return -1;
  }
}
