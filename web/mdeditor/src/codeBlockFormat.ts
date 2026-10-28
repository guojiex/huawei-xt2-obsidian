import { EditorState } from '@codemirror/state'
import { syntaxTree } from '@codemirror/language'

interface FencedCodeBlock {
  from: number
  bodyFrom: number
  closeLineFrom: number
  removeTo: number
  closed: boolean
  closeLineEnding: string
}

export interface CodeBlockFormatChange {
  changes: { from: number, to: number, insert: string }
  selection: { anchor: number, head: number }
}

function enclosingFencedCodeNode(state: EditorState, position: number, bias: -1 | 1) {
  const safePosition = Math.max(0, Math.min(position, state.doc.length))
  let node = syntaxTree(state).resolveInner(safePosition, bias)
  while (node) {
    if (node.name === 'FencedCode') {
      return node
    }
    node = node.parent
  }
  return null
}

function selectedFencedCodeNode(state: EditorState) {
  const selection = state.selection.main
  if (selection.empty) {
    return enclosingFencedCodeNode(state, selection.from, 1) ??
      (selection.from > 0 ? enclosingFencedCodeNode(state, selection.from - 1, 1) : null)
  }
  const first = enclosingFencedCodeNode(state, selection.from, 1)
  const last = enclosingFencedCodeNode(state, selection.to - 1, -1)
  return first && last && first.from === last.from && first.to === last.to ? first : null
}

function lineEndingAfter(state: EditorState, lineEnd: number): { text: string, end: number } {
  const next = state.doc.sliceString(lineEnd, lineEnd + 2)
  if (next.startsWith('\r\n')) {
    return { text: '\r\n', end: lineEnd + 2 }
  }
  if (next.startsWith('\n')) {
    return {
      text: state.doc.sliceString(lineEnd - 1, lineEnd) === '\r' ? '\r\n' : '\n',
      end: lineEnd + 1
    }
  }
  return { text: '', end: lineEnd }
}

function selectedFencedCodeBlock(state: EditorState): FencedCodeBlock | null {
  const node = selectedFencedCodeNode(state)
  if (!node) {
    return null
  }
  let openingMark: typeof node | null = null
  let closingMark: typeof node | null = null
  let child = node.firstChild
  while (child) {
    if (child.name === 'CodeMark') {
      if (openingMark === null) {
        openingMark = child
      } else {
        closingMark = child
      }
    }
    child = child.nextSibling
  }
  if (openingMark === null) {
    return null
  }
  const openingLine = state.doc.lineAt(openingMark.from)
  const openingPrefix = state.doc.sliceString(openingLine.from, openingMark.from)
  if (!/^ {0,3}$/.test(openingPrefix)) {
    return null
  }
  const bodyFrom = lineEndingAfter(state, openingLine.to).end
  if (closingMark === null) {
    return {
      from: openingLine.from,
      bodyFrom: bodyFrom,
      closeLineFrom: state.doc.length,
      removeTo: bodyFrom,
      closed: false,
      closeLineEnding: ''
    }
  }
  const closingLine = state.doc.lineAt(closingMark.from)
  const closingPrefix = state.doc.sliceString(closingLine.from, closingMark.from)
  if (!/^ {0,3}$/.test(closingPrefix)) {
    return null
  }
  const closeEnding = lineEndingAfter(state, closingLine.to)
  return {
    from: openingLine.from,
    bodyFrom: bodyFrom,
    closeLineFrom: closingLine.from,
    removeTo: closeEnding.end,
    closed: true,
    closeLineEnding: closeEnding.text
  }
}

export function hasCodeBlockSelection(state: EditorState): boolean {
  return selectedFencedCodeBlock(state) !== null
}

export function toggleCodeBlock(state: EditorState, placeholder = '代码'): CodeBlockFormatChange {
  const selection = state.selection.main
  const block = selectedFencedCodeBlock(state)
  if (block) {
    const bodyEnd = block.closed ? block.closeLineFrom : state.doc.length
    const rawBody = state.sliceDoc(block.bodyFrom, bodyEnd)
    const content = block.closed
      ? (rawBody.endsWith('\r\n') ? rawBody.slice(0, -2) :
        rawBody.endsWith('\n') ? rawBody.slice(0, -1) : rawBody)
      : rawBody
    const replacement = block.closed ? content + block.closeLineEnding : ''
    const replaceTo = block.closed ? block.removeTo : block.bodyFrom
    return {
      changes: { from: block.from, to: replaceTo, insert: replacement },
      selection: { anchor: block.from, head: block.from + content.length }
    }
  }

  const selected = state.sliceDoc(selection.from, selection.to)
  const content = selected || placeholder
  const lineEnding = '\n'
  const runs = content.match(/`+/g) ?? []
  let fenceLength = 2
  for (const run of runs) {
    fenceLength = Math.max(fenceLength, run.length)
  }
  const fence = '`'.repeat(fenceLength + 1)
  const prefix = selection.from > 0 && state.sliceDoc(selection.from - 1, selection.from) !== '\n'
    ? lineEnding : ''
  const suffix = selection.to < state.doc.length && state.sliceDoc(selection.to, selection.to + 1) !== '\n'
    ? lineEnding : ''
  const opening = fence + lineEnding
  const closingBreak = content.endsWith('\n') ? '' : lineEnding
  const replacement = prefix + opening + content + closingBreak + fence + suffix
  const contentStart = selection.from + prefix.length + opening.length
  return {
    changes: { from: selection.from, to: selection.to, insert: replacement },
    selection: { anchor: contentStart, head: contentStart + content.length }
  }
}

export interface NormalizedEditorText {
  text: string
  lineEnding: '\n' | '\r\n'
}

export function normalizeEditorText(sourceText: string): NormalizedEditorText {
  return {
    text: sourceText.replace(/\r\n/g, '\n'),
    lineEnding: sourceText.includes('\r\n') ? '\r\n' : '\n'
  }
}

export function serializeEditorText(text: string, lineEnding: '\n' | '\r\n'): string {
  return lineEnding === '\r\n' ? text.replace(/\n/g, '\r\n') : text
}
