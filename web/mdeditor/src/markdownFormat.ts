import { EditorState } from '@codemirror/state'

export interface MarkdownFormatChange {
  changes: { from: number, to: number, insert: string } | { from: number, to: number, insert: string }[]
  selection: { anchor: number, head: number }
}

interface LineFormat {
  text: string
  oldPrefixLength: number
  newPrefix: string
}

function formatInline(state: EditorState, kind: string): MarkdownFormatChange | null {
  const selection = state.selection.main
  const formats: Record<string, { prefix: string, suffix: string, placeholder: string }> = {
    bold: { prefix: '**', suffix: '**', placeholder: '粗体文字' },
    italic: { prefix: '*', suffix: '*', placeholder: '斜体文字' },
    inlineCode: { prefix: '`', suffix: '`', placeholder: '代码' },
    link: { prefix: '[', suffix: '](https://example.com)', placeholder: '链接文字' }
  }
  const format = formats[kind]
  if (!format) {
    return null
  }
  const prefix = format.prefix
  const selected = state.sliceDoc(selection.from, selection.to)
  const tripleEmphasis = kind === 'italic' && selected.length > 0 &&
    state.sliceDoc(selection.from - 3, selection.from) === '***' &&
    state.sliceDoc(selection.to, selection.to + 3) === '***'
  if (tripleEmphasis) {
    return {
      changes: [
        { from: selection.from - 1, to: selection.from, insert: '' },
        { from: selection.to, to: selection.to + 1, insert: '' }
      ],
      selection: { anchor: selection.from - 1, head: selection.to - 1 }
    }
  }
  const wrapped = (kind === 'bold' || kind === 'italic') && selected.length > 0 &&
    state.sliceDoc(selection.from - prefix.length, selection.from) === prefix &&
    state.sliceDoc(selection.to, selection.to + prefix.length) === prefix &&
    !(kind === 'italic' && (state.sliceDoc(selection.from - 2, selection.from) === '**' ||
      state.sliceDoc(selection.to, selection.to + 2) === '**'))
  if (wrapped) {
    return {
      changes: {
        from: selection.from - prefix.length,
        to: selection.to + prefix.length,
        insert: selected
      },
      selection: { anchor: selection.from - prefix.length, head: selection.to - prefix.length }
    }
  }

  const text = selected || format.placeholder
  const start = selection.from
  const insertion = prefix + text + format.suffix
  return {
    changes: { from: start, to: selection.to, insert: insertion },
    selection: { anchor: start + prefix.length, head: start + prefix.length + text.length }
  }
}

function existingPrefix(line: string): { indent: string, length: number, kind: string } {
  const quote = /^(\s*)> ?/.exec(line)
  if (quote) {
    return { indent: quote[1], length: quote[0].length, kind: 'quote' }
  }
  const task = /^(\s*)(?:[-+*]|\d+\.)[ \t]+\[[ xX]\][ \t]+/.exec(line)
  if (task) {
    return { indent: task[1], length: task[0].length, kind: 'task' }
  }
  const list = /^(\s*)([-+*]|\d+\.)[ \t]+/.exec(line)
  if (list) {
    return { indent: list[1], length: list[0].length, kind: /^\d/.test(list[2]) ? 'ordered' : 'list' }
  }
  const heading = /^(\s*)#{1,6}[ \t]+/.exec(line)
  if (heading) {
    return { indent: heading[1], length: heading[0].length, kind: 'heading' }
  }
  return { indent: '', length: 0, kind: 'paragraph' }
}

function desiredPrefix(kind: string, index: number, indent: string): string {
  if (kind === 'list') {
    return indent + '- '
  }
  if (kind === 'ordered') {
    return indent + (index + 1).toString() + '. '
  }
  if (kind === 'task') {
    return indent + '- [ ] '
  }
  if (kind === 'quote') {
    return indent + '> '
  }
  if (kind === 'paragraph') {
    return indent
  }
  return indent + '#'.repeat(Number(kind.substring(1))) + ' '
}

function formatBlock(state: EditorState, kind: string): MarkdownFormatChange | null {
  const selection = state.selection.main
  if (selection.empty && ['list', 'ordered', 'task', 'quote'].includes(kind)) {
    const placeholder = kind === 'quote' ? '引用文字' : '列表项'
    const prefix = desiredPrefix(kind, 0, '')
    const insertStart = selection.from > 0 && state.sliceDoc(selection.from - 1, selection.from) !== '\n'
      ? '\n' + prefix : prefix
    const insertEnd = selection.to < state.doc.length && state.sliceDoc(selection.to, selection.to + 1) !== '\n'
      ? '\n' : ''
    const linePrefixOffset = insertStart.length - prefix.length
    return {
      changes: { from: selection.from, to: selection.to, insert: insertStart + placeholder + insertEnd },
      selection: {
        anchor: selection.from + linePrefixOffset + prefix.length,
        head: selection.from + linePrefixOffset + prefix.length + placeholder.length
      }
    }
  }

  const startLine = state.doc.lineAt(selection.from)
  const endPosition = selection.empty ? selection.to : Math.max(selection.from, selection.to - 1)
  const endLine = state.doc.lineAt(endPosition)
  const originalLines: string[] = []
  for (let number = startLine.number; number <= endLine.number; number++) {
    originalLines.push(state.doc.line(number).text)
  }
  const prefixKinds = originalLines.map((line) => existingPrefix(line).kind)
  const remove = (kind === 'paragraph' || /^h[1-6]$/.test(kind))
    ? kind === 'paragraph' && prefixKinds.every((existing) => existing === 'heading')
    : prefixKinds.every((existing) => existing === kind)
  const lineFormats: LineFormat[] = originalLines.map((line, index) => {
    const existing = existingPrefix(line)
    const desiredKind = kind === 'paragraph' && existing.kind !== 'heading'
      ? 'paragraph' : kind
    const prefixToRemove = (remove || existing.kind !== 'paragraph') ? existing.length : 0
    const body = line.substring(prefixToRemove)
    const prefix = remove ? existing.indent : desiredPrefix(desiredKind, index, existing.indent)
    return { text: prefix + body, oldPrefixLength: prefixToRemove, newPrefix: prefix }
  })
  const replacement = lineFormats.map((line) => line.text).join('\n')
  const from = startLine.from
  const to = endLine.to
  const original = state.sliceDoc(from, to)
  if (replacement === original) {
    return null
  }

  const mapPosition = (position: number): number => {
    let delta = 0
    for (let index = 0; index < lineFormats.length; index++) {
      const line = state.doc.line(startLine.number + index)
      const lineFormat = lineFormats[index]
      const newLineFrom = line.from + delta
      if (position <= line.to) {
        const contentStart = line.from + lineFormat.oldPrefixLength
        if (position <= contentStart) {
          return newLineFrom + lineFormat.newPrefix.length
        }
        return position + delta + lineFormat.newPrefix.length - lineFormat.oldPrefixLength
      }
      delta += lineFormat.text.length - line.text.length
    }
    return position + delta
  }
  return {
    changes: { from: from, to: to, insert: replacement },
    selection: { anchor: mapPosition(selection.anchor), head: mapPosition(selection.head) }
  }
}

export function toggleMarkdownFormat(state: EditorState, kind: string): MarkdownFormatChange | null {
  if (kind === 'bold' || kind === 'italic' || kind === 'inlineCode' || kind === 'link') {
    return formatInline(state, kind)
  }
  if (kind === 'paragraph' || /^h[1-6]$/.test(kind) ||
    ['list', 'ordered', 'task', 'quote'].includes(kind)) {
    return formatBlock(state, kind)
  }
  return null
}

export function toggleTaskStatus(state: EditorState, from: number, to: number): MarkdownFormatChange | null {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to <= from || to > state.doc.length) {
    return null
  }
  // 区间可以是精确的 `[ ]`，也可以是简单模式 widget 传入的整个列表标记（`- [ ] `）：
  // 在区间内定位复选框再翻转，两种调用方式都成立（精确匹配时 match.index === 0）。
  const marker = state.sliceDoc(from, to)
  const match = /\[[ xX]\]/.exec(marker)
  if (!match) {
    return null
  }
  const checkboxFrom = from + match.index
  const checked = /\[[xX]\]/.test(match[0])
  const selection = state.selection.main
  return {
    changes: { from: checkboxFrom, to: checkboxFrom + match[0].length, insert: checked ? '[ ]' : '[x]' },
    selection: { anchor: selection.anchor, head: selection.head }
  }
}
