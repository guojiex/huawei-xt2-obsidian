export class FormulaSourceModel {
  prefix: string = '';
  suffix: string = '';
  expression: string = '';
  inline: boolean = false;
}

export class CalloutSourceModel {
  prefix: string = '';
  type: string = '';
  closeBracket: string = ']';
  fold: string = '';
  titleGap: string = '';
  title: string = '';
  lineEnding: string = '';
  body: string = '';
  knownType: boolean = false;
}

export class FrontmatterLineModel {
  text: string = '';
  ending: string = '';
}

export class FrontmatterPropertyModel {
  key: string = '';
  kind: string = 'complex';
  text: string = '';
  items: string[] = [];
  keyPrefix: string = '';
  commentSuffix: string = '';
  listIndent: string = '  ';
  lineStart: number = -1;
  lineEnd: number = -1;
  childLineIndexes: number[] = [];
  touched: boolean = false;
  removed: boolean = false;
  isNew: boolean = false;
}

export class FrontmatterSourceModel {
  lines: FrontmatterLineModel[] = [];
  properties: FrontmatterPropertyModel[] = [];
  closingIndex: number = -1;
  lineEnding: string = '\n';
}

export class FootnoteLineModel {
  text: string = '';
  from: number = 0;
  to: number = 0;
  ending: string = '';
}

export class FootnoteSourceRange {
  label: string = '';
  from: number = 0;
  to: number = 0;
  source: string = '';
}

export class FootnoteSourceModel {
  label: string = '';
  prefix: string = '';
  body: string = '';
  continuationIndent: string = '  ';
  lineEnding: string = '\n';
  trailingLineEnding: string = '';
}

class FrontmatterValueParts {
  token: string = '';
  suffix: string = '';
  valid: boolean = true;
}

class FrontmatterKeyLine {
  key: string = '';
  prefix: string = '';
  token: string = '';
  suffix: string = '';
}

class FrontmatterScalar {
  value: string = '';
  kind: string = '';
}

class FrontmatterList {
  valid: boolean = false;
  items: string[] = [];
  indent: string = '  ';
}

export class MarkdownComplexBlockEdit {
  private static readonly CALLOUT_TYPES: string[] = [
    'note', 'abstract', 'info', 'todo', 'tip', 'success', 'question',
    'warning', 'failure', 'danger', 'bug', 'example', 'quote'
  ];

  private static readonly CALLOUT_ALIASES: string[] = [
    'summary', 'tldr', 'hint', 'important', 'check', 'done', 'help',
    'faq', 'caution', 'attention', 'fail', 'missing', 'error', 'cite'
  ];

  static calloutTypes(): string[] {
    return [...MarkdownComplexBlockEdit.CALLOUT_TYPES];
  }

  static calloutLabels(): string[] {
    return ['笔记', '摘要', '信息', '待办', '提示', '完成', '问题',
      '注意', '失败', '危险', '缺陷', '示例', '引用'];
  }

  static parseFootnoteReference(source: string): string | null {
    const match: RegExpExecArray | null = /^\[\^([^\]\r\n]+)\]$/.exec(source);
    return match === null ? null : match[1];
  }

  static parseBlockId(source: string): string | null {
    let end: number = source.length;
    if (source.endsWith('\r\n')) {
      end -= 2;
    } else if (source.endsWith('\n')) {
      end--;
    }
    const lineStart: number = source.lastIndexOf('\n', end - 1) + 1;
    const line: string = source.substring(lineStart, end);
    const match: RegExpExecArray | null = /\^([A-Za-z0-9][A-Za-z0-9_-]*)[ \t]*$/.exec(line);
    if (match === null) {
      return null;
    }
    let escapeCount: number = 0;
    for (let index: number = match.index - 1; index >= 0 && line[index] === '\\'; index--) {
      escapeCount++;
    }
    return escapeCount % 2 === 0 ? match[1] : null;
  }

  static parseFootnoteDefinition(source: string): FootnoteSourceModel | null {
    const lines: FootnoteLineModel[] = MarkdownComplexBlockEdit.splitFootnoteLines(source);
    if (lines.length === 0) {
      return null;
    }
    const header: RegExpExecArray | null =
      /^(\uFEFF? {0,3}\[\^([^\]\r\n]+)\]:[ \t]*)(.*)$/.exec(lines[0].text);
    if (header === null) {
      return null;
    }

    const model: FootnoteSourceModel = new FootnoteSourceModel();
    model.label = header[2];
    model.prefix = header[1];
    model.lineEnding = lines[0].ending.length > 0 ? lines[0].ending : '\n';
    model.trailingLineEnding = lines[lines.length - 1].ending;
    const bodyLines: string[] = [header[3]];
    let continuationIndent: string = '';
    for (let index = 1; index < lines.length; index++) {
      const text: string = lines[index].text;
      if (text.length === 0) {
        if (index + 1 < lines.length && /^[ \t]{2,}/.test(lines[index + 1].text)) {
          bodyLines.push('');
          continue;
        }
        return null;
      }
      const indentation: RegExpExecArray | null = /^(?: {2,}|\t)/.exec(text);
      if (indentation === null) {
        return null;
      }
      if (continuationIndent.length === 0) {
        continuationIndent = indentation[0].startsWith('\t') ? '\t' : '  ';
      }
      if (!text.startsWith(continuationIndent)) {
        return null;
      }
      bodyLines.push(text.slice(continuationIndent.length));
    }
    model.continuationIndent = continuationIndent.length > 0 ? continuationIndent : '  ';
    model.body = bodyLines.join('\n');
    return model;
  }

  static findFootnoteDefinitions(source: string, label: string): FootnoteSourceRange[] {
    const lines: FootnoteLineModel[] = MarkdownComplexBlockEdit.splitFootnoteLines(source);
    const matches: FootnoteSourceRange[] = [];
    const frontmatter: RegExpExecArray | null =
      /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(source);
    const frontmatterEnd: number = frontmatter === null ? 0 : frontmatter[0].length;
    let fenceCharacter: string = '';
    let fenceLength: number = 0;
    for (let index = 0; index < lines.length; index++) {
      const fence: RegExpExecArray | null = /^ {0,3}(`{3,}|~{3,})/.exec(lines[index].text);
      if (fenceCharacter.length > 0) {
        if (fence !== null && fence[1][0] === fenceCharacter && fence[1].length >= fenceLength) {
          fenceCharacter = '';
          fenceLength = 0;
        }
        continue;
      }
      if (fence !== null) {
        fenceCharacter = fence[1][0];
        fenceLength = fence[1].length;
        continue;
      }
      if (lines[index].from < frontmatterEnd) {
        continue;
      }
      const header: RegExpExecArray | null =
        /^\uFEFF? {0,3}\[\^([^\]\r\n]+)\]:/.exec(lines[index].text);
      if (header === null) {
        continue;
      }
      let lastLine: number = index;
      for (let next = index + 1; next < lines.length; next++) {
        if (lines[next].text.length === 0) {
          if (next + 1 < lines.length &&
            /^(?: {2,}|\t)/.test(lines[next + 1].text)) {
            lastLine = next;
            continue;
          }
          break;
        }
        if (!/^(?: {2,}|\t)/.test(lines[next].text)) {
          break;
        }
        lastLine = next;
      }
      const range: FootnoteSourceRange = new FootnoteSourceRange();
      range.label = header[1];
      range.from = lines[index].from;
      range.to = lines[lastLine].to;
      range.source = source.slice(range.from, range.to);
      if (label.length === 0 || header[1] === label) {
        matches.push(range);
      }
      index = lastLine;
    }
    return matches;
  }

  static findFootnoteReference(source: string, label: string): FootnoteSourceRange | null {
    const excluded: FootnoteSourceRange[] = MarkdownComplexBlockEdit.findFootnoteDefinitions(source, '');
    const lines: FootnoteLineModel[] = MarkdownComplexBlockEdit.splitFootnoteLines(source);
    const frontmatter: RegExpExecArray | null =
      /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(source);
    const frontmatterEnd: number = frontmatter === null ? 0 : frontmatter[0].length;
    let fenceCharacter: string = '';
    let fenceLength: number = 0;
    let codeFenceFrom: number = -1;
    const codeFenceRanges: FootnoteSourceRange[] = [];
    for (const line of lines) {
      const fence: RegExpExecArray | null = /^ {0,3}(`{3,}|~{3,})/.exec(line.text);
      if (fenceCharacter.length === 0 && fence !== null) {
        fenceCharacter = fence[1][0];
        fenceLength = fence[1].length;
        codeFenceFrom = line.from;
      } else if (fenceCharacter.length > 0 && fence !== null &&
        fence[1][0] === fenceCharacter && fence[1].length >= fenceLength) {
        const range: FootnoteSourceRange = new FootnoteSourceRange();
        range.from = codeFenceFrom;
        range.to = line.to;
        codeFenceRanges.push(range);
        fenceCharacter = '';
        fenceLength = 0;
        codeFenceFrom = -1;
      }
    }
    if (fenceCharacter.length > 0 && codeFenceFrom >= 0) {
      const range: FootnoteSourceRange = new FootnoteSourceRange();
      range.from = codeFenceFrom;
      range.to = source.length;
      codeFenceRanges.push(range);
    }
    const inlineCodeRanges: FootnoteSourceRange[] = [];
    for (let index = 0; index < source.length;) {
      if (source[index] !== '`') {
        index++;
        continue;
      }
      let slashCount: number = 0;
      for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) {
        slashCount++;
      }
      let end: number = index + 1;
      while (end < source.length && source[end] === '`') {
        end++;
      }
      if (slashCount % 2 === 1) {
        index = end;
        continue;
      }
      const delimiterLength: number = end - index;
      let close: number = end;
      let closeEnd: number = -1;
      while (close < source.length) {
        const next: number = source.indexOf('`', close);
        if (next < 0) {
          break;
        }
        let nextEnd: number = next + 1;
        while (nextEnd < source.length && source[nextEnd] === '`') {
          nextEnd++;
        }
        if (nextEnd - next === delimiterLength) {
          closeEnd = nextEnd;
          break;
        }
        close = nextEnd;
      }
      if (closeEnd > end) {
        const range: FootnoteSourceRange = new FootnoteSourceRange();
        range.from = index;
        range.to = closeEnd;
        inlineCodeRanges.push(range);
        index = closeEnd;
      } else {
        index = end;
      }
    }

    const expression: RegExp = /\[\^([^\]\r\n]+)\]/g;
    let match: RegExpExecArray | null = expression.exec(source);
    while (match !== null) {
      const from: number = match.index;
      const to: number = from + match[0].length;
      let slashCount: number = 0;
      for (let cursor = from - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) {
        slashCount++;
      }
      if (match[1] === label && slashCount % 2 === 0 && from >= frontmatterEnd &&
        !MarkdownComplexBlockEdit.footnoteRangeContains(excluded, from) &&
        !MarkdownComplexBlockEdit.footnoteRangeContains(codeFenceRanges, from) &&
        !MarkdownComplexBlockEdit.footnoteRangeContains(inlineCodeRanges, from)) {
        const result: FootnoteSourceRange = new FootnoteSourceRange();
        result.label = label;
        result.from = from;
        result.to = to;
        result.source = match[0];
        return result;
      }
      match = expression.exec(source);
    }
    return null;
  }

  static serializeFootnoteDefinition(model: FootnoteSourceModel, body: string): string | null {
    if (body.includes('\r') || model.label.length === 0 || model.label.includes(']') ||
      model.label.includes('\n')) {
      return null;
    }
    const lines: string[] = body.split('\n');
    let result: string = model.prefix + lines[0];
    for (let index = 1; index < lines.length; index++) {
      const line: string = lines[index];
      result += model.lineEnding + (line.length > 0 ? model.continuationIndent + line : '');
    }
    return result + model.trailingLineEnding;
  }

  static createFootnoteDefinition(label: string, body: string, lineEnding: string,
    trailingLineEnding: string): string | null {
    if (label.trim().length === 0 || label.includes(']') || /[\r\n]/.test(label) ||
      body.trim().length === 0 || body.includes('\r')) {
      return null;
    }
    const lines: string[] = body.split('\n');
    let result: string = `[^${label}]: ${lines[0]}`;
    for (let index = 1; index < lines.length; index++) {
      result += lineEnding + (lines[index].length > 0 ? `  ${lines[index]}` : '');
    }
    return result + trailingLineEnding;
  }

  static sourceLineEnding(source: string): string {
    const newline: number = source.indexOf('\n');
    return newline > 0 && source[newline - 1] === '\r' ? '\r\n' : '\n';
  }

  static parseCallout(source: string): CalloutSourceModel | null {
    const newline: number = source.indexOf('\n');
    let firstLine: string = newline >= 0 ? source.slice(0, newline) : source;
    const lineEnding: string = firstLine.endsWith('\r') ? '\r\n' : newline >= 0 ? '\n' : '';
    if (lineEnding === '\r\n') {
      firstLine = firstLine.slice(0, -1);
    }
    const match: RegExpExecArray | null =
      /^(\uFEFF? {0,3}>[ \t]*\[!)([A-Za-z][A-Za-z0-9_-]*)(\])([+-]?)([ \t]*)(.*)$/.exec(firstLine);
    if (match === null) {
      return null;
    }

    const model: CalloutSourceModel = new CalloutSourceModel();
    model.prefix = match[1];
    model.type = match[2];
    model.closeBracket = match[3];
    model.fold = match[4];
    model.titleGap = match[5];
    model.title = match[6];
    model.lineEnding = lineEnding;
    model.body = newline >= 0 ? source.slice(newline + 1) : '';
    const type: string = model.type.toLowerCase();
    model.knownType = MarkdownComplexBlockEdit.CALLOUT_TYPES.includes(type) ||
      MarkdownComplexBlockEdit.CALLOUT_ALIASES.includes(type);
    return model;
  }

  static serializeCallout(model: CalloutSourceModel, field: string, value: string): string | null {
    if (value.includes('\n') || value.includes('\r')) {
      return null;
    }
    const updated: CalloutSourceModel = new CalloutSourceModel();
    updated.prefix = model.prefix;
    updated.type = model.type;
    updated.closeBracket = model.closeBracket;
    updated.fold = model.fold;
    updated.titleGap = model.titleGap;
    updated.title = model.title;
    updated.lineEnding = model.lineEnding;
    updated.body = model.body;
    updated.knownType = model.knownType;

    if (field === 'title') {
      updated.title = value;
      updated.titleGap = value.length > 0
        ? (updated.titleGap.length > 0 ? updated.titleGap : ' ') : '';
    } else if (field === 'type' && model.knownType &&
      (value === model.type || MarkdownComplexBlockEdit.CALLOUT_TYPES.includes(value))) {
      updated.type = value;
    } else if (field === 'fold' && model.knownType && ['', '+', '-'].includes(value)) {
      updated.fold = value;
    } else {
      return null;
    }

    const header: string = updated.prefix + updated.type + updated.closeBracket +
      updated.fold + updated.titleGap + updated.title;
    return updated.lineEnding.length > 0 ? header + updated.lineEnding + updated.body : header;
  }

  static parseFormula(source: string, inline: boolean): FormulaSourceModel | null {
    const model: FormulaSourceModel = new FormulaSourceModel();
    model.inline = inline;
    if (inline) {
      if (source.length < 3 || source[0] !== '$' || source[1] === '$' ||
        source[source.length - 1] !== '$' || source[source.length - 2] === '$' ||
        source.includes('\n') || source.slice(1, -1).includes('$')) {
        return null;
      }
      model.prefix = '$';
      model.suffix = '$';
      model.expression = source.slice(1, -1);
      return model;
    }

    const trailing: string = /(?:\r?\n)*$/.exec(source)?.[0] ?? '';
    const content: string = source.slice(0, source.length - trailing.length);
    const opening: string = /^\$\$[ \t]*(?:\r?\n)?/.exec(content)?.[0] ?? '';
    const closing: string = /(?:\r?\n)?\$\$[ \t]*$/.exec(content)?.[0] ?? '';
    if (opening.length === 0 || closing.length === 0 || opening.length + closing.length > content.length) {
      return null;
    }
    model.prefix = opening;
    model.suffix = closing + trailing;
    model.expression = content.slice(opening.length, content.length - closing.length);
    return model;
  }

  static serializeFormula(model: FormulaSourceModel, expression: string): string | null {
    if (expression.trim().length === 0 || (model.inline && expression.includes('$'))) {
      return null;
    }
    return model.prefix + expression + model.suffix;
  }

  static parseFrontmatter(source: string): FrontmatterSourceModel | null {
    const lines: FrontmatterLineModel[] = MarkdownComplexBlockEdit.splitFrontmatterLines(source);
    if (lines.length < 2 || !/^---[ \t]*$/.test(lines[0].text.replace(/^\uFEFF/, ''))) {
      return null;
    }

    let closingIndex: number = -1;
    for (let index = 1; index < lines.length; index++) {
      if (/^(---|\.\.\.)[ \t]*$/.test(lines[index].text)) {
        closingIndex = index;
        break;
      }
    }
    if (closingIndex < 0 || closingIndex !== lines.length - 1) {
      return null;
    }

    const model: FrontmatterSourceModel = new FrontmatterSourceModel();
    model.lines = lines;
    model.closingIndex = closingIndex;
    model.lineEnding = lines[0].ending.length > 0 ? lines[0].ending : '\n';
    let current: FrontmatterPropertyModel | null = null;

    for (let index = 1; index < closingIndex; index++) {
      const line: string = lines[index].text;
      if (line.trim().length === 0 || /^[ \t]*#/.test(line)) {
        continue;
      }
      if (/^[ \t]/.test(line)) {
        if (current === null || /^\t/.test(line)) {
          return null;
        }
        current.childLineIndexes.push(index);
        continue;
      }

      const keyLine: FrontmatterKeyLine | null = MarkdownComplexBlockEdit.parseFrontmatterKeyLine(line);
      if (keyLine === null) {
        return null;
      }
      for (const property of model.properties) {
        if (property.key === keyLine.key) {
          return null;
        }
      }
      if (current !== null) {
        current.lineEnd = index;
      }
      current = new FrontmatterPropertyModel();
      current.key = keyLine.key;
      current.keyPrefix = keyLine.prefix;
      current.commentSuffix = keyLine.suffix;
      current.text = keyLine.token;
      current.lineStart = index;
      current.lineEnd = closingIndex;
      model.properties.push(current);
    }

    for (const property of model.properties) {
      if (!MarkdownComplexBlockEdit.classifyFrontmatterProperty(property, lines)) {
        return null;
      }
    }
    return model;
  }

  static setFrontmatterProperty(source: string, key: string, value: string): string | null {
    const model: FrontmatterSourceModel | null = MarkdownComplexBlockEdit.parseFrontmatter(source);
    if (model === null || value.includes('\n') || value.includes('\r')) {
      return null;
    }
    const property: FrontmatterPropertyModel | null =
      MarkdownComplexBlockEdit.findFrontmatterProperty(model, key);
    if (property === null || property.kind === 'complex') {
      return null;
    }

    if (property.kind === 'list') {
      property.items = MarkdownComplexBlockEdit.parsePropertyInputList(value);
      property.text = property.items.join('、');
    } else if (property.kind === 'bool') {
      if (value !== 'true' && value !== 'false') {
        return null;
      }
      property.text = value;
    } else if (property.kind === 'date') {
      if (!MarkdownComplexBlockEdit.isIsoDate(value)) {
        return null;
      }
      property.text = value;
    } else if (property.kind === 'text') {
      property.text = value;
    } else {
      return null;
    }
    property.touched = true;
    return MarkdownComplexBlockEdit.serializeFrontmatter(model);
  }

  static removeFrontmatterProperty(source: string, key: string): string | null {
    const model: FrontmatterSourceModel | null = MarkdownComplexBlockEdit.parseFrontmatter(source);
    if (model === null) {
      return null;
    }
    const property: FrontmatterPropertyModel | null =
      MarkdownComplexBlockEdit.findFrontmatterProperty(model, key);
    if (property === null) {
      return null;
    }
    property.removed = true;
    return MarkdownComplexBlockEdit.serializeFrontmatter(model);
  }

  static addFrontmatterProperty(source: string, key: string, value: string): string | null {
    const model: FrontmatterSourceModel | null = MarkdownComplexBlockEdit.parseFrontmatter(source);
    if (model === null || !MarkdownComplexBlockEdit.isFrontmatterKey(key) ||
      value.includes('\n') || value.includes('\r') ||
      MarkdownComplexBlockEdit.findFrontmatterProperty(model, key) !== null) {
      return null;
    }

    const property: FrontmatterPropertyModel = new FrontmatterPropertyModel();
    property.key = key;
    property.keyPrefix = `${key}: `;
    property.lineStart = -1;
    property.lineEnd = -1;
    property.isNew = true;
    property.touched = true;
    MarkdownComplexBlockEdit.setNewFrontmatterValue(property, value);
    model.properties.push(property);
    return MarkdownComplexBlockEdit.serializeFrontmatter(model);
  }

  private static splitFrontmatterLines(source: string): FrontmatterLineModel[] {
    const lines: FrontmatterLineModel[] = [];
    let start: number = 0;
    while (start < source.length) {
      const newline: number = source.indexOf('\n', start);
      const line: FrontmatterLineModel = new FrontmatterLineModel();
      if (newline < 0) {
        line.text = source.slice(start);
        lines.push(line);
        break;
      }
      const crlf: boolean = newline > start && source[newline - 1] === '\r';
      line.text = source.slice(start, crlf ? newline - 1 : newline);
      line.ending = crlf ? '\r\n' : '\n';
      lines.push(line);
      start = newline + 1;
    }
    return lines;
  }

  private static splitFootnoteLines(source: string): FootnoteLineModel[] {
    const lines: FootnoteLineModel[] = [];
    let start: number = 0;
    while (start < source.length) {
      const newline: number = source.indexOf('\n', start);
      const line: FootnoteLineModel = new FootnoteLineModel();
      if (newline < 0) {
        line.text = source.slice(start);
        line.from = start;
        line.to = source.length;
        lines.push(line);
        break;
      }
      const crlf: boolean = newline > start && source[newline - 1] === '\r';
      line.text = source.slice(start, crlf ? newline - 1 : newline);
      line.from = start;
      line.to = newline + 1;
      line.ending = crlf ? '\r\n' : '\n';
      lines.push(line);
      start = newline + 1;
    }
    return lines;
  }

  private static footnoteRangeContains(ranges: FootnoteSourceRange[], offset: number): boolean {
    for (const range of ranges) {
      if (offset >= range.from && offset < range.to) {
        return true;
      }
    }
    return false;
  }

  private static parseFrontmatterKeyLine(line: string): FrontmatterKeyLine | null {
    const match: RegExpExecArray | null =
      /^([A-Za-z0-9_\u0080-\uFFFF][A-Za-z0-9_.\u0080-\uFFFF-]*)([ \t]*):([ \t]*)(.*)$/.exec(line);
    if (match === null || match[3].includes('\t')) {
      return null;
    }
    const value: FrontmatterValueParts = MarkdownComplexBlockEdit.splitFrontmatterValue(match[4]);
    if (!value.valid) {
      return null;
    }
    const parsed: FrontmatterKeyLine = new FrontmatterKeyLine();
    parsed.key = match[1];
    parsed.prefix = match[1] + match[2] + ':' + match[3];
    parsed.token = value.token;
    parsed.suffix = value.suffix;
    return parsed;
  }

  private static splitFrontmatterValue(source: string): FrontmatterValueParts {
    const result: FrontmatterValueParts = new FrontmatterValueParts();
    if (source.startsWith('"') || source.startsWith('\'')) {
      const quote: string = source[0];
      let closing: number = -1;
      for (let index = 1; index < source.length; index++) {
        if (quote === '"' && source[index] === '\\') {
          index++;
        } else if (quote === '\'' && source[index] === '\'' && source[index + 1] === '\'') {
          index++;
        } else if (source[index] === quote) {
          closing = index;
          break;
        }
      }
      if (closing < 0) {
        result.valid = false;
        return result;
      }
      const tail: string = source.slice(closing + 1);
      const trimmedTail: string = tail.trim();
      if (trimmedTail.length > 0 && !trimmedTail.startsWith('#')) {
        result.valid = false;
        return result;
      }
      if (trimmedTail.startsWith('#') && tail.length > 0 && !/^[ \t]+#/.test(tail)) {
        result.valid = false;
        return result;
      }
      result.token = source.slice(0, closing + 1);
      result.suffix = tail;
      return result;
    }

    let comment: number = -1;
    for (let index = 1; index < source.length; index++) {
      if (source[index] === '#' && /[ \t]/.test(source[index - 1])) {
        comment = index;
        break;
      }
    }
    const valueEnd: number = comment >= 0 ? comment : source.length;
    const value: string = source.slice(0, valueEnd);
    const trimmed: string = value.replace(/[ \t]+$/, '');
    result.token = trimmed;
    result.suffix = source.slice(trimmed.length);
    return result;
  }

  private static classifyFrontmatterProperty(
    property: FrontmatterPropertyModel, lines: FrontmatterLineModel[]
  ): boolean {
    const childLines: number[] = property.childLineIndexes;
    if (childLines.length > 0) {
      const list: FrontmatterList = MarkdownComplexBlockEdit.parseFrontmatterBlockList(childLines, lines);
      if (property.text.length === 0 && list.valid) {
        property.kind = 'list';
        property.items = list.items;
        property.text = list.items.join('、');
        property.listIndent = list.indent;
        return true;
      }
      if (property.text.length === 0 ||
        /^[|>&*!]/.test(property.text) || property.text.startsWith('<<:')) {
        property.kind = 'complex';
        return true;
      }
      return false;
    }

    if (property.text.startsWith('[')) {
      if (!property.text.endsWith(']')) {
        return false;
      }
      const list: FrontmatterList = MarkdownComplexBlockEdit.parseFrontmatterFlowList(property.text);
      if (list.valid) {
        property.kind = 'list';
        property.items = list.items;
        property.text = list.items.join('、');
        return true;
      }
      property.kind = 'complex';
      return true;
    }

    const scalar: FrontmatterScalar | null = MarkdownComplexBlockEdit.parseFrontmatterScalar(property.text);
    if (scalar === null) {
      property.kind = 'complex';
      return true;
    }
    if (scalar.kind === 'text' && MarkdownComplexBlockEdit.isIsoDate(scalar.value)) {
      scalar.kind = 'date';
    }
    if (property.key === 'tags') {
      property.kind = 'list';
      property.items = [scalar.value];
      property.text = scalar.value;
    } else {
      property.kind = scalar.kind;
      property.text = scalar.value;
    }
    return true;
  }

  private static parseFrontmatterBlockList(
    childLines: number[], lines: FrontmatterLineModel[]
  ): FrontmatterList {
    const result: FrontmatterList = new FrontmatterList();
    if (childLines.length === 0) {
      return result;
    }
    let indent: string = '';
    for (const lineIndex of childLines) {
      const sourceLine: string = lines[lineIndex].text;
      const item: RegExpExecArray | null = /^([ ]+)-[ \t]+(.+)$/.exec(sourceLine);
      if (item === null || (indent.length > 0 && indent !== item[1])) {
        return result;
      }
      const value: FrontmatterValueParts = MarkdownComplexBlockEdit.splitFrontmatterValue(item[2]);
      if (!value.valid || value.suffix.indexOf('#') >= 0) {
        return result;
      }
      const scalar: FrontmatterScalar | null = MarkdownComplexBlockEdit.parseFrontmatterScalar(value.token);
      if (scalar === null || scalar.kind !== 'text') {
        return result;
      }
      indent = item[1];
      result.items.push(scalar.value);
    }
    result.valid = true;
    result.indent = indent;
    return result;
  }

  private static parseFrontmatterFlowList(source: string): FrontmatterList {
    const result: FrontmatterList = new FrontmatterList();
    if (source.length < 2 || source[0] !== '[' || source[source.length - 1] !== ']') {
      return result;
    }
    const body: string = source.slice(1, -1);
    if (body.trim().length === 0) {
      result.valid = true;
      return result;
    }
    let start: number = 0;
    let quote: string = '';
    let escaped: boolean = false;
    for (let index = 0; index <= body.length; index++) {
      const character: string = index < body.length ? body[index] : ',';
      if (quote.length > 0) {
        if (quote === '"' && escaped) {
          escaped = false;
        } else if (quote === '"' && character === '\\') {
          escaped = true;
        } else if (quote === '\'' && character === '\'' && body[index + 1] === '\'') {
          index++;
        } else if (character === quote) {
          quote = '';
        }
        continue;
      }
      if (character === '"' || character === '\'') {
        quote = character;
      } else if (character === '[' || character === '{' || character === '}' || character === ']') {
        return result;
      } else if (character === ',') {
        const token: string = body.slice(start, index).trim();
        const scalar: FrontmatterScalar | null = MarkdownComplexBlockEdit.parseFrontmatterScalar(token);
        if (token.length === 0 || scalar === null || scalar.kind !== 'text') {
          return result;
        }
        result.items.push(scalar.value);
        start = index + 1;
      }
    }
    if (quote.length > 0) {
      return result;
    }
    result.valid = true;
    return result;
  }

  private static parseFrontmatterScalar(source: string): FrontmatterScalar | null {
    if (source.length === 0) {
      return null;
    }
    const scalar: FrontmatterScalar = new FrontmatterScalar();
    if (source.startsWith('"')) {
      try {
        scalar.value = JSON.parse(source) as string;
        scalar.kind = 'text';
        return scalar;
      } catch {
        return null;
      }
    }
    if (source.startsWith('\'')) {
      if (source.length < 2 || !source.endsWith('\'')) {
        return null;
      }
      scalar.value = source.slice(1, source.length - 1).replace(/''/g, '\'');
      scalar.kind = 'text';
      return scalar;
    }
    if (MarkdownComplexBlockEdit.isIsoDate(source)) {
      scalar.value = source;
      scalar.kind = 'date';
      return scalar;
    }
    if (/^(true|false)$/i.test(source)) {
      scalar.value = source.toLowerCase();
      scalar.kind = 'bool';
      return scalar;
    }
    if (/^(null|~)$/i.test(source) ||
      /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/.test(source) ||
      /^[-+]?(?:\.inf|\.nan)$/i.test(source) ||
      /^0[xob][0-9a-f]+$/i.test(source)) {
      return null;
    }
    if (/^[\-?:,[\]{}#&*!|>'"%@`]/.test(source) || /:\s/.test(source) ||
      /[ \t]#/.test(source) || source.trim() !== source) {
      return null;
    }
    scalar.value = source;
    scalar.kind = 'text';
    return scalar;
  }

  private static isIsoDate(value: string): boolean {
    const match: RegExpExecArray | null = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (match === null) {
      return false;
    }
    const year: number = Number(match[1]);
    const month: number = Number(match[2]);
    const day: number = Number(match[3]);
    if (month < 1 || month > 12 || day < 1) {
      return false;
    }
    const leap: boolean = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const days: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return day <= days[month - 1];
  }

  private static isFrontmatterKey(key: string): boolean {
    return /^[A-Za-z0-9_\u0080-\uFFFF][A-Za-z0-9_.\u0080-\uFFFF-]*$/.test(key);
  }

  private static parsePropertyInputList(value: string): string[] {
    const items: string[] = [];
    const parts: string[] = value.split(/[、,，]/);
    for (const part of parts) {
      const item: string = part.trim();
      if (item.length > 0) {
        items.push(item);
      }
    }
    return items;
  }

  private static setNewFrontmatterValue(property: FrontmatterPropertyModel, value: string): void {
    if (property.key === 'tags' || /[、,，]/.test(value)) {
      property.kind = 'list';
      property.items = MarkdownComplexBlockEdit.parsePropertyInputList(value);
      property.text = property.items.join('、');
    } else if (/^(true|false)$/i.test(value)) {
      property.kind = 'bool';
      property.text = value.toLowerCase();
    } else if (MarkdownComplexBlockEdit.isIsoDate(value)) {
      property.kind = 'date';
      property.text = value;
    } else {
      property.kind = 'text';
      property.text = value;
    }
  }

  private static findFrontmatterProperty(
    model: FrontmatterSourceModel, key: string
  ): FrontmatterPropertyModel | null {
    for (const property of model.properties) {
      if (property.key === key && !property.removed) {
        return property;
      }
    }
    return null;
  }

  private static quoteFrontmatterScalar(value: string): string {
    if (value.length === 0 || value.trim() !== value ||
      /^(true|false|null|~)$/i.test(value) ||
      /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/.test(value) ||
      /^[\-?:,[\]{}#&*!|>'"%@`]/.test(value) || /:\s/.test(value) ||
      /[ \t]#/.test(value)) {
      return JSON.stringify(value);
    }
    return value;
  }

  private static serializeFrontmatter(model: FrontmatterSourceModel): string {
    let output: string = '';
    let index: number = 0;
    while (index < model.closingIndex) {
      let property: FrontmatterPropertyModel | null = null;
      for (const candidate of model.properties) {
        if (!candidate.isNew && candidate.lineStart === index) {
          property = candidate;
          break;
        }
      }
      if (property === null) {
        output += model.lines[index].text + model.lines[index].ending;
        index++;
        continue;
      }

      if (!property.touched && !property.removed) {
        for (let lineIndex = property.lineStart; lineIndex < property.lineEnd; lineIndex++) {
          output += model.lines[lineIndex].text + model.lines[lineIndex].ending;
        }
      } else {
        if (!property.removed) {
          const ending: string = model.lines[property.lineStart].ending.length > 0
            ? model.lines[property.lineStart].ending : model.lineEnding;
          if (property.kind === 'list') {
            const listValue: string = property.items.length === 0
              ? '[]' : '';
            const keyPrefix: string = property.items.length === 0
              ? property.keyPrefix : property.keyPrefix.replace(/:[ \t]*$/, ':');
            output += keyPrefix + listValue + property.commentSuffix + ending;
            for (const item of property.items) {
              output += property.listIndent + '- ' +
                MarkdownComplexBlockEdit.quoteFrontmatterScalar(item) + ending;
            }
          } else {
            const value: string = property.kind === 'bool'
              ? (property.text === 'true' ? 'true' : 'false')
              : MarkdownComplexBlockEdit.quoteFrontmatterScalar(property.text);
            output += property.keyPrefix + value + property.commentSuffix + ending;
          }
        }
        for (let lineIndex = property.lineStart + 1; lineIndex < property.lineEnd; lineIndex++) {
          if (!property.childLineIndexes.includes(lineIndex)) {
            output += model.lines[lineIndex].text + model.lines[lineIndex].ending;
          }
        }
      }
      index = property.lineEnd;
    }

    for (const property of model.properties) {
      if (!property.isNew) {
        continue;
      }
      const ending: string = model.lineEnding;
      if (property.kind === 'list') {
        if (property.items.length === 0) {
          output += property.keyPrefix + '[]' + ending;
        } else {
          output += property.keyPrefix.replace(/:[ \t]*$/, ':') + ending;
          for (const item of property.items) {
            output += property.listIndent + '- ' +
              MarkdownComplexBlockEdit.quoteFrontmatterScalar(item) + ending;
          }
        }
      } else {
        const value: string = property.kind === 'bool'
          ? (property.text === 'true' ? 'true' : 'false')
          : MarkdownComplexBlockEdit.quoteFrontmatterScalar(property.text);
        output += property.keyPrefix + value + ending;
      }
    }
    for (let lineIndex = model.closingIndex; lineIndex < model.lines.length; lineIndex++) {
      output += model.lines[lineIndex].text + model.lines[lineIndex].ending;
    }
    return output;
  }
}
