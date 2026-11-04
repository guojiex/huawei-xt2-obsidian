export interface MarkdownLinkParts {
  label: string;
  destination: string;
  labelStart: number;
  labelEnd: number;
  destinationStart: number;
  destinationEnd: number;
  angleDestination: boolean;
}

export interface MarkdownImageParts {
  alt: string;
  destination: string;
  width: string;
  labelStart: number;
  labelEnd: number;
  destinationStart: number;
  destinationEnd: number;
  widthStart: number;
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

  static parseImage(source: string): MarkdownImageParts | null {
    if (source.length < 5 || source[0] !== '!') {
      return null;
    }
    const linkSource: string = source.substring(1);
    const link: MarkdownLinkParts | null = MarkdownInlineParser.parseLink(linkSource);
    if (link === null) {
      return null;
    }
    const rawAlt: string = linkSource.substring(1, link.labelEnd);
    let altSource: string = rawAlt;
    let width: string = '';
    let widthStart: number = -1;
    const widthSeparator: number = rawAlt.lastIndexOf('|');
    if (widthSeparator >= 0 && !MarkdownInlineParser.isEscaped(rawAlt, widthSeparator)) {
      const candidate: string = rawAlt.substring(widthSeparator + 1);
      if (/^\d{2,4}$/.test(candidate)) {
        width = candidate;
        altSource = rawAlt.substring(0, widthSeparator);
        widthStart = widthSeparator + 2;
      }
    }
    return {
      alt: MarkdownInlineParser.unescapePunctuation(altSource),
      destination: link.destination,
      width: width,
      labelStart: 2,
      labelEnd: link.labelEnd + 1,
      destinationStart: link.destinationStart + 1,
      destinationEnd: link.destinationEnd + 1,
      widthStart: widthStart,
      angleDestination: link.angleDestination
    };
  }

  static replaceImageAlt(source: string, parts: MarkdownImageParts, alt: string): string {
    const label: string = MarkdownInlineParser.escapeLabel(alt).replace(/\|/g, '\\|') +
      (parts.width.length > 0 ? '|' + parts.width : '');
    return source.substring(0, parts.labelStart) + label + source.substring(parts.labelEnd);
  }

  static replaceImageWidth(source: string, parts: MarkdownImageParts, width: string): string | null {
    if (width !== '' && !/^\d{2,4}$/.test(width)) {
      return null;
    }
    if (parts.width.length === 0) {
      return source.substring(0, parts.labelEnd) +
        (width.length > 0 ? '|' + width : '') + source.substring(parts.labelEnd);
    }
    return source.substring(0, parts.widthStart) +
      (width.length > 0 ? '|' + width : '') + source.substring(parts.labelEnd);
  }

  static replaceImageDestination(source: string, parts: MarkdownImageParts, destination: string): string | null {
    const value: string = destination.trim();
    if (value.length === 0 || /\s/.test(value)) {
      return null;
    }
    const escaped: string = parts.angleDestination
      ? MarkdownInlineParser.escapeAngleDestination(value)
      : MarkdownInlineParser.escapeDestination(value);
    return source.substring(0, parts.destinationStart) + escaped + source.substring(parts.destinationEnd);
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
