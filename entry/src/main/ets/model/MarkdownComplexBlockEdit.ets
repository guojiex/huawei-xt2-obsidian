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
}
