export interface MarkdownLinkParts {
  label: string;
  destination: string;
  labelStart: number;
  labelEnd: number;
  destinationStart: number;
  destinationEnd: number;
  angleDestination: boolean;
}

export class MarkdownInlineParser {
  static parseLink(source: string): MarkdownLinkParts | null {
    if (source.length < 4 || source[0] !== '[' || source[source.length - 1] !== ')') {
      return null;
    }
    const labelEnd: number = MarkdownInlineParser.findLabelEnd(source);
    if (labelEnd < 0 || source[labelEnd + 1] !== '(') {
      return null;
    }

    const contentStart: number = labelEnd + 2;
    const contentEnd: number = source.length - 1;
    const angleDestination: boolean = source[contentStart] === '<';
    const destinationStart: number = angleDestination ? contentStart + 1 : contentStart;
    const destinationEnd: number = angleDestination ? contentEnd - 1 : contentEnd;
    if (angleDestination && (contentEnd <= contentStart + 1 || source[contentEnd - 1] !== '>')) {
      return null;
    }
    if (destinationStart >= destinationEnd) {
      return null;
    }

    for (let index = destinationStart; index < destinationEnd; index++) {
      const character: string = source[index];
      if (MarkdownInlineParser.isEscaped(source, index)) {
        continue;
      }
      if (/\s/.test(character) || character === '(' || character === ')' ||
        (angleDestination && (character === '<' || character === '>'))) {
        return null;
      }
    }

    return {
      label: MarkdownInlineParser.unescapePunctuation(source.substring(1, labelEnd)),
      destination: MarkdownInlineParser.unescapePunctuation(source.substring(destinationStart, destinationEnd)),
      labelStart: 1,
      labelEnd: labelEnd,
      destinationStart: destinationStart,
      destinationEnd: destinationEnd,
      angleDestination: angleDestination
    };
  }

  static replaceLabel(source: string, parts: MarkdownLinkParts, label: string): string {
    return source.substring(0, parts.labelStart) +
      MarkdownInlineParser.escapeLabel(label) +
      source.substring(parts.labelEnd);
  }

  static replaceDestination(source: string, parts: MarkdownLinkParts, destination: string): string | null {
    const value: string = destination.trim();
    if (value.length === 0 || /\s/.test(value)) {
      return null;
    }
    const escaped: string = parts.angleDestination
      ? MarkdownInlineParser.escapeAngleDestination(value)
      : MarkdownInlineParser.escapeDestination(value);
    return source.substring(0, parts.destinationStart) + escaped + source.substring(parts.destinationEnd);
  }

  private static findLabelEnd(source: string): number {
    for (let index = 1; index < source.length; index++) {
      if (MarkdownInlineParser.isEscaped(source, index)) {
        continue;
      }
      if (source[index] === '[') {
        return -1;
      }
      if (source[index] === ']') {
        return index;
      }
    }
    return -1;
  }

  private static isEscaped(source: string, index: number): boolean {
    let slashes: number = 0;
    for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) {
      slashes++;
    }
    return slashes % 2 === 1;
  }

  private static unescapePunctuation(source: string): string {
    let result: string = '';
    for (let index = 0; index < source.length; index++) {
      if (source[index] === '\\' && index + 1 < source.length &&
        MarkdownInlineParser.isAsciiPunctuation(source.charCodeAt(index + 1))) {
        result += source[index + 1];
        index++;
      } else {
        result += source[index];
      }
    }
    return result;
  }

  private static escapeLabel(value: string): string {
    let result: string = '';
    for (let index = 0; index < value.length; index++) {
      const character: string = value[index];
      if (character === '\\' || character === '[' || character === ']') {
        result += '\\';
      }
      result += character;
    }
    return result;
  }

  private static escapeDestination(value: string): string {
    let result: string = '';
    for (let index = 0; index < value.length; index++) {
      const character: string = value[index];
      if (character === '\\' || character === '(' || character === ')') {
        result += '\\';
      }
      result += character;
    }
    return result;
  }

  private static escapeAngleDestination(value: string): string {
    let result: string = '';
    for (let index = 0; index < value.length; index++) {
      const character: string = value[index];
      if (character === '\\' || character === '<' || character === '>') {
        result += '\\';
      }
      result += character;
    }
    return result;
  }

  private static isAsciiPunctuation(code: number): boolean {
    return (code >= 33 && code <= 47) || (code >= 58 && code <= 64) ||
      (code >= 91 && code <= 96) || (code >= 123 && code <= 126);
  }
}
