import { marked } from 'marked'

const SAFE_INLINE_TYPES = new Set(['text', 'escape', 'strong', 'em'])
const UNSUPPORTED_INLINE_PATTERN =
  /!?\[\[[^\]]*\]\]|\[\^[^\]]+\]|%%|==|\$\$|\$[^$\n]+\$|(?:^|\s)\^[\w-]+\s*$/
const ASCII_PUNCTUATION = /[\u0021-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007E]/g

function isEscaped(source, index) {
  let slashes = 0
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) slashes++
  return slashes % 2 === 1
}

function hasUnsupportedEscape(source) {
  for (let index = 0; index < source.length; index++) {
    if (source[index] !== '\\') continue
    const next = source[index + 1]
    if (next !== '|') return true
    index++
  }
  return false
}

function inlineTokensSupported(tokens) {
  for (const token of tokens) {
    if (!SAFE_INLINE_TYPES.has(token.type)) return false
    if (token.type === 'text' && UNSUPPORTED_INLINE_PATTERN.test(token.raw ?? '')) return false
    if (Array.isArray(token.tokens) && !inlineTokensSupported(token.tokens)) return false
  }
  return true
}

function cellAt(line, lineOffset, from, to) {
  let contentFrom = from
  let contentTo = to
  while (contentFrom < contentTo && /[ \t]/.test(line[contentFrom])) contentFrom++
  while (contentTo > contentFrom && /[ \t]/.test(line[contentTo - 1])) contentTo--
  const source = line.slice(contentFrom, contentTo)
  const editable = !hasUnsupportedEscape(source) &&
    inlineTokensSupported(marked.Lexer.lexInline(source))
  return {
    from: lineOffset + contentFrom,
    to: lineOffset + contentTo,
    source,
    editable
  }
}

function splitTableRow(line, lineOffset) {
  const pipes = []
  for (let index = 0; index < line.length; index++) {
    if (line[index] === '|' && !isEscaped(line, index)) pipes.push(index)
  }
  if (pipes.length === 0) return null

  const leadingPipe = line.slice(0, pipes[0]).trim().length === 0
  let start = leadingPipe ? pipes[0] + 1 : 0
  const firstContentPipe = leadingPipe ? 1 : 0
  const cells = []
  let trailingPipe = false

  for (let index = firstContentPipe; index < pipes.length; index++) {
    const pipe = pipes[index]
    cells.push(cellAt(line, lineOffset, start, pipe))
    start = pipe + 1
    if (index === pipes.length - 1 && line.slice(start).trim().length === 0) {
      trailingPipe = true
    }
  }
  if (!trailingPipe) cells.push(cellAt(line, lineOffset, start, line.length))
  return cells.length > 0 ? cells : null
}

function sourceLines(source) {
  const lines = []
  let start = 0
  while (start < source.length) {
    const newline = source.indexOf('\n', start)
    const end = newline < 0 ? source.length : newline
    const contentEnd = end > start && source[end - 1] === '\r' ? end - 1 : end
    lines.push({ offset: start, text: source.slice(start, contentEnd) })
    start = newline < 0 ? source.length : newline + 1
  }
  return lines
}

function isDividerRow(cells) {
  return cells.every((cell) => /^:?-+:?$/.test(cell.source))
}

function escapeCellText(value) {
  return String(value).replace(/\r\n?|\n/g, ' ').replace(ASCII_PUNCTUATION, (character) =>
    character === '|' ? String.raw`\|` : `&#${character.charCodeAt(0)};`)
}

function serializeCellNode(node) {
  if (node.nodeType === 3) return escapeCellText(node.textContent ?? '')
  if (node.nodeType !== 1) return ''
  const tag = String(node.tagName ?? '').toUpperCase()
  if (tag === 'BR') return ' '
  const children = Array.from(node.childNodes ?? []).map(serializeCellNode).join('')
  if (tag === 'STRONG' || tag === 'B') return `**${children}**`
  if (tag === 'EM' || tag === 'I') return `*${children}*`
  return children
}

/** Parse one complete GFM table and retain exact source offsets for each cell. */
export function parseTableSource(source) {
  const tokens = marked.lexer(source).filter((token) => token.type !== 'space' && token.type !== 'def')
  if (tokens.length !== 1 || tokens[0].type !== 'table' ||
    tokens[0].raw.replace(/\r\n/g, '\n') !== source.replace(/\r\n/g, '\n')) {
    return null
  }

  const lines = sourceLines(source)
  if (lines.length < 2) return null
  const parsedRows = lines.map((line) => splitTableRow(line.text, line.offset))
  if (parsedRows.some((row) => row === null) || !isDividerRow(parsedRows[1])) return null

  const header = parsedRows[0]
  const rows = parsedRows.slice(2)
  const expectedColumns = tokens[0].header.length
  if (header.length !== expectedColumns || parsedRows[1].length !== expectedColumns ||
    tokens[0].align.length !== expectedColumns || tokens[0].rows.length !== rows.length ||
    rows.some((row) => row.length !== expectedColumns)) {
    return null
  }

  const hasFence = /```|~~~/.test(source)
  return {
    header: header.map((cell) => ({ ...cell, editable: cell.editable && !hasFence })),
    rows: rows.map((row) => row.map((cell) => ({ ...cell, editable: cell.editable && !hasFence }))),
    hasFence
  }
}

/** Serialize only basic text, strong, and emphasis from an editable table cell. */
export function serializeTableCellContent(node) {
  if (!node || typeof node !== 'object') return ''
  return serializeCellNode(node)
}

/** Return a table source with exactly one validated editable cell replaced. */
export function replaceTableCellSource(source, from, to, expected, replacement) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 ||
    to < from || to > source.length || source.slice(from, to) !== expected) return null
  const table = parseTableSource(source)
  if (!table) return null
  const cells = [...table.header, ...table.rows.flat()]
  if (!cells.some((cell) => cell.editable && cell.from === from && cell.to === to)) return null
  return source.slice(0, from) + replacement + source.slice(to)
}

/** Detect multiline pipe-shaped text that looks like a table but lacks a valid divider row. */
export function isPseudoTableSource(source) {
  const lines = source.split(/\r?\n/).filter((line) => line.trim().length > 0)
  if (lines.length < 2) return false
  const pipeCounts = lines.map((line) => {
    let count = 0
    for (let index = 0; index < line.length; index++) {
      if (line[index] === '|' && !isEscaped(line, index)) count++
    }
    return count
  })
  return pipeCounts.filter((count) => count >= 1).length >= 2
}
