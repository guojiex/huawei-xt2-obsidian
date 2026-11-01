import { EditorState, Transaction } from '@codemirror/state'
import { ensureSyntaxTree } from '@codemirror/language'

export interface SimpleRange {
  from: number
  to: number
  kind: string
  value?: string
}

export interface SimpleModeRanges {
  protected: SimpleRange[]
  decorations: SimpleRange[]
}

function mergeProtected(ranges: SimpleRange[]): SimpleRange[] {
  const sorted = ranges.filter((range) => range.to > range.from)
    .sort((left, right) => left.from - right.from || left.to - right.to)
  const merged: SimpleRange[] = []
  for (const range of sorted) {
    const last = merged[merged.length - 1]
    if (last && range.from <= last.to) {
      last.to = Math.max(last.to, range.to)
    } else {
      merged.push({ from: range.from, to: range.to, kind: 'protected' })
    }
  }
  return merged
}

function frontmatterRange(source: string): SimpleRange | null {
  const match = /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(source)
  return match ? { from: 0, to: match[0].length, kind: 'protected' } : null
}

function appendPatternRanges(source: string, ranges: SimpleRange[], pattern: RegExp): void {
  const expression = new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g')
  let match: RegExpExecArray | null = expression.exec(source)
  while (match) {
    ranges.push({ from: match.index, to: match.index + match[0].length, kind: 'protected' })
    match = expression.exec(source)
  }
}

function directiveBlockRanges(source: string): SimpleRange[] {
  const ranges: SimpleRange[] = []
  const lines = source.split(/\r?\n/)
  let offset = 0
  let blockStart = -1
  let depth = 0
  let blockEnd = -1

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const closing = /^ {0,3}:{3,}[ \t]*$/.test(line)
    const opening = /^ {0,3}:{3,}[ \t]*[A-Za-z][A-Za-z0-9_-]*(?:\b[^\n]*)?$/.test(line)
    if (opening) {
      if (depth === 0) {
        blockStart = offset
      }
      depth++
      blockEnd = offset + line.length
    } else if (closing && depth > 0) {
      depth--
      blockEnd = offset + line.length
      if (depth === 0) {
        ranges.push({ from: blockStart, to: blockEnd, kind: 'protected' })
        blockStart = -1
      }
    } else if (depth > 0) {
      blockEnd = offset + line.length
    }

    const separatorLength = offset + line.length >= source.length ? 0 :
      (source.startsWith('\r\n', offset + line.length) ? 2 : 1)
    offset += line.length + separatorLength
  }
  if (depth > 0 && blockStart >= 0) {
    ranges.push({ from: blockStart, to: Math.max(blockEnd, source.length), kind: 'protected' })
  }
  return ranges
}

function customProtectedRanges(source: string): SimpleRange[] {
  const ranges: SimpleRange[] = []
  const lines = source.split(/\r?\n/)
  let offset = 0
  let quoteStart = -1
  let quoteEnd = -1
  let callout = false
  let tableStart = -1
  let tableEnd = -1
  let formulaStart = -1
  let formulaEnd = -1

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const quoteLine = /^ {0,3}>/.test(line)
    if (quoteLine) {
      if (quoteStart < 0) {
        quoteStart = offset
        callout = /^ {0,3}>[ \t]*\[![A-Za-z]/.test(line)
      }
      quoteEnd = offset + line.length
    } else if (line.trim().length > 0 && quoteStart >= 0) {
      if (callout) {
        ranges.push({ from: quoteStart, to: quoteEnd, kind: 'protected' })
      }
      quoteStart = -1
      quoteEnd = -1
      callout = false
    }

    const nextLine = index + 1 < lines.length ? lines[index + 1] : ''
    const tableHeader = line.includes('|') && /^\s*\|?\s*:?-{3,}[^\n]*\|/.test(nextLine)
    if (tableHeader && tableStart < 0) {
      tableStart = offset
    }
    if (tableStart >= 0) {
      if (line.includes('|')) {
        tableEnd = offset + line.length
      } else if (line.trim().length > 0) {
        ranges.push({ from: tableStart, to: tableEnd, kind: 'protected' })
        tableStart = -1
        tableEnd = -1
      }
    }

    if (/^ {0,3}\\?\$\$[ \t]*$/.test(line)) {
      if (formulaStart < 0) {
        formulaStart = offset
      } else {
        formulaEnd = offset + line.length
        ranges.push({ from: formulaStart, to: formulaEnd, kind: 'protected' })
        formulaStart = -1
        formulaEnd = -1
      }
    }
    const separatorLength = offset + line.length >= source.length ? 0 :
      (source.startsWith('\r\n', offset + line.length) ? 2 : 1)
    offset += line.length + separatorLength
  }
  if (quoteStart >= 0 && callout) {
    ranges.push({ from: quoteStart, to: quoteEnd, kind: 'protected' })
  }
  if (tableStart >= 0) {
    ranges.push({ from: tableStart, to: tableEnd, kind: 'protected' })
  }
  if (formulaStart >= 0) {
    ranges.push({ from: formulaStart, to: source.length, kind: 'protected' })
  }
  ranges.push(...directiveBlockRanges(source))
  appendPatternRanges(source, ranges, /!?\[\[(?:\\.|[^\]\r\n])+?\]\]/g)
  appendPatternRanges(source, ranges, /\$\$(?!\$)(?:\\.|[^\\$\r\n])+?\$\$/g)
  appendPatternRanges(source, ranges, /%%[\s\S]*?(?:%%|$)/g)
  appendPatternRanges(source, ranges, /==[^=\r\n]+==/g)
  appendPatternRanges(source, ranges, /~~[^~\r\n]+~~/g)
  appendPatternRanges(source, ranges, /(?<!~)~[^~\r\n]+~(?!~)/g)
  appendPatternRanges(source, ranges, /\^[A-Za-z0-9][A-Za-z0-9_-]*\^/g)
  appendPatternRanges(source, ranges, /\[\^[^\]\r\n]+\]/g)
  appendPatternRanges(source, ranges, /^\[\^[^\]\r\n]+\]:[^\r\n]*$/gm)
  appendPatternRanges(source, ranges, /\^[A-Za-z0-9][A-Za-z0-9_-]*[ \t]*$/gm)
  const inlineMath = /\$(?!\$)(?:\\.|[^\\$\n])+?\$/g
  let match: RegExpExecArray | null = inlineMath.exec(source)
  while (match) {
    ranges.push({ from: match.index, to: match.index + match[0].length, kind: 'protected' })
    match = inlineMath.exec(source)
  }
  return ranges
}

function overlapsProtected(from: number, to: number, ranges: SimpleRange[]): boolean {
  return ranges.some((range) => from < range.to && to > range.from)
}

function isTaskCheckboxReference(state: EditorState, from: number, to: number): boolean {
  const line = state.doc.lineAt(from)
  const list = /^(\s*)([-+*]|\d+\.)[ \t]+(\[[ xX]\][ \t]+)?/.exec(line.text)
  if (!list || !list[3]) {
    return false
  }
  const checkboxStart = line.from + list[0].indexOf('[')
  return from === checkboxStart && to === checkboxStart + 3
}

export function collectSimpleModeRanges(state: EditorState): SimpleModeRanges {
  const source = state.doc.toString()
  const protectedRanges: SimpleRange[] = []
  const opaqueSyntaxRanges: SimpleRange[] = []
  const customRanges = customProtectedRanges(source)
  const frontmatter = frontmatterRange(source)
  if (frontmatter) {
    protectedRanges.push(frontmatter)
    opaqueSyntaxRanges.push(frontmatter)
  }
  const tree = ensureSyntaxTree(state, state.doc.length, 100)
  if (!tree) {
    const protectedRange: SimpleRange = { from: 0, to: source.length, kind: 'protected' }
    return {
      protected: source.length > 0 ? [protectedRange] : [],
      decorations: source.length > 0
        ? [{ from: 0, to: 0, kind: 'protected-hint', value: '正在安全解析，请稍后继续编辑' }]
        : []
    }
  }
  tree.iterate({
    enter(node) {
      if (node.name === 'FencedCode' || node.name === 'InlineCode' || node.name === 'Link' ||
        node.name === 'Image' || node.name === 'LinkReference' || node.name === 'Table' ||
        node.name === 'HTMLBlock' || node.name === 'HTMLTag') {
        if (node.name === 'Link' && isTaskCheckboxReference(state, node.from, node.to)) {
          return
        }
        const range: SimpleRange = { from: node.from, to: node.to, kind: 'protected' }
        protectedRanges.push(range)
        opaqueSyntaxRanges.push(range)
      }
    }
  })
  protectedRanges.push(...customRanges.filter((range) => {
    return !opaqueSyntaxRanges.some((opaque) => range.from >= opaque.from && range.from < opaque.to &&
      (range.to <= opaque.to || range.from > opaque.from))
  }))
  const mergedProtected = mergeProtected(protectedRanges)
  const decorations: SimpleRange[] = []
  tree.iterate({
    enter(node) {
      if (node.name === 'ATXHeading1' || node.name === 'ATXHeading2' || node.name === 'ATXHeading3' ||
        node.name === 'ATXHeading4' || node.name === 'ATXHeading5' || node.name === 'ATXHeading6') {
        decorations.push({ from: state.doc.lineAt(node.from).from, to: state.doc.lineAt(node.from).from, kind: 'heading-' + node.name.slice(-1) })
      } else if (node.name === 'SetextHeading1' || node.name === 'SetextHeading2') {
        decorations.push({ from: state.doc.lineAt(node.from).from, to: state.doc.lineAt(node.from).from,
          kind: node.name === 'SetextHeading1' ? 'heading-1' : 'heading-2' })
      } else if (node.name === 'StrongEmphasis') {
        decorations.push({ from: node.from, to: node.to, kind: 'strong' })
      } else if (node.name === 'Emphasis') {
        decorations.push({ from: node.from, to: node.to, kind: 'emphasis' })
      } else if (node.name === 'HeaderMark' || node.name === 'EmphasisMark') {
        if (!overlapsProtected(node.from, node.to, mergedProtected)) {
          decorations.push({ from: node.from, to: node.to, kind: 'hide' })
        }
      } else if (node.name === 'QuoteMark') {
        const start = state.doc.lineAt(node.from).from
        decorations.push({ from: start, to: start, kind: 'quote' })
      }
    }
  })

  for (let number = 1; number <= state.doc.lines; number++) {
    const line = state.doc.line(number)
    const list = /^(\s*)([-+*]|\d+\.)[ \t]+(\[[ xX]\][ \t]+)?/.exec(line.text)
    if (list) {
      const markerStart = line.from + list[1].length
      const markerEnd = line.from + list[0].length
      if (!overlapsProtected(markerStart, markerEnd, mergedProtected)) {
        const checkbox = list[3]
        decorations.push({ from: markerStart, to: markerEnd, kind: checkbox ? 'task' : 'list-marker',
          value: checkbox ? (checkbox.includes('x') || checkbox.includes('X') ? '☑' : '☐') :
            (/^\d/.test(list[2]) ? list[2] : '•') })
      }
    }
  }
  for (const range of mergedProtected) {
    decorations.push({ from: range.from, to: range.from, kind: 'protected-hint', value: '此内容请在专业模式编辑' })
  }
  return { protected: mergedProtected, decorations }
}

export function allowsSimpleModeTransaction(state: EditorState, transaction: Transaction,
  protectedRanges: SimpleRange[] = collectSimpleModeRanges(state).protected): boolean {
  let allowed = true
  transaction.changes.iterChangedRanges((from, to) => {
    for (const range of protectedRanges) {
      const touches = from === to ? from > range.from && from < range.to : from < range.to && to > range.from
      if (touches) {
        allowed = false
        break
      }
    }
  })
  return allowed
}
