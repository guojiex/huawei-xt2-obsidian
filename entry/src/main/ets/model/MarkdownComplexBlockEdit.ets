export class FormulaSourceModel {
  prefix: string = '';
  suffix: string = '';
  expression: string = '';
  inline: boolean = false;
}

export class MarkdownComplexBlockEdit {
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
