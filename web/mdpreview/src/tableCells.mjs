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

function tableLinesWithEndings(source) {
  const lines = []
  let start = 0
  while (start < source.length) {
    const newline = source.indexOf('\n', start)
    const end = newline < 0 ? source.length : newline
    const hasCarriageReturn = end > start && source[end - 1] === '\r'
    lines.push({
      text: source.slice(start, hasCarriageReturn ? end - 1 : end),
      ending: newline < 0 ? '' : hasCarriageReturn ? '\r\n' : '\n',
      prefix: ''
    })
    start = newline < 0 ? source.length : newline + 1
  }
  return lines
}

function quotePrefix(line) {
  return /^(?: {0,3}>[ \t]?)+/.exec(line)?.[0] ?? ''
}

function listMarkerPrefix(line) {
  return /^(?: {0,3})(?:[-+*]|\d+[.)])[ \t]+/.exec(line)?.[0] ?? ''
}

function tableWithPrefixes(source) {
  const lines = tableLinesWithEndings(source)
  if (lines.length < 2) return null

  const bomPrefix = lines[0].text.startsWith('\uFEFF') ? '\uFEFF' : ''
  const firstText = lines[0].text.slice(bomPrefix.length)
  const firstQuote = quotePrefix(firstText)
  const firstRemainder = firstText.slice(firstQuote.length)
  const firstList = listMarkerPrefix(firstRemainder)
  const firstIndent = !firstQuote && !firstList
    ? /^ {1,3}(?=\|)/.exec(firstRemainder)?.[0] ?? '' : ''

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    let text = line.text
    if (index === 0 && bomPrefix) {
      line.prefix += bomPrefix
      text = text.slice(bomPrefix.length)
    }

    const quote = quotePrefix(text)
    if (firstQuote && quote.length === 0) return null
    if (quote.length > 0) {
      line.prefix += quote
      text = text.slice(quote.length)
    }

    if (index === 0 && firstList) {
      if (!text.startsWith(firstList)) return null
      line.prefix += firstList
      text = text.slice(firstList.length)
    } else if (firstList && index > 0) {
      const continuation = ' '.repeat(firstList.length)
      if (!text.startsWith(continuation)) return null
      line.prefix += continuation
      text = text.slice(continuation.length)
    } else if (firstIndent) {
      const indent = /^ {1,3}/.exec(text)?.[0] ?? ''
      if (indent.length < firstIndent.length) return null
      line.prefix += indent.slice(0, firstIndent.length)
      text = text.slice(firstIndent.length)
    }

    line.text = text
  }

  return { lines, logicalSource: lines.map((line) => line.text + line.ending).join('') }
}

function isDividerRow(cells) {
  return cells.every((cell) => /^:?-+:?$/.test(cell.source))
}

function escapeCellText(value) {
  return String(value).replace(/\r\n?|\n/g, ' ').replace(ASCII_PUNCTUATION, (character) =>
    character === '|' ? String.raw`\|` : `&#${character.charCodeAt(0)};`)
}

function serializeTableRows(rows, lineEnding) {
  const columns = rows[0].length
  const header = rows[0].map(escapeCellText)
  const divider = Array(columns).fill('---')
  return [
    `| ${header.join(' | ')} |`,
    `| ${divider.join(' | ')} |`,
    ...rows.slice(1).map((row) => `| ${row.map(escapeCellText).join(' | ')} |`)
  ].join(lineEnding)
}

export function createMarkdownTableSource(rows, columns, lineEnding = '\n') {
  if (!Number.isInteger(rows) || rows < 1 || rows > 8 ||
    !Number.isInteger(columns) || columns < 1 || columns > 6 ||
    (lineEnding !== '\n' && lineEnding !== '\r\n')) {
    return null
  }
  const matrix = [
    Array.from({ length: columns }, (_, index) => `列 ${index + 1}`),
    ...Array.from({ length: rows - 1 }, () => Array(columns).fill(''))
  ]
  return serializeTableRows(matrix, lineEnding)
}

export function tableSourceFromTsv(text) {
  if (typeof text !== 'string') return null
  const normalized = text.replace(/\r\n?/g, '\n')
  const rows = normalized.split('\n')
  if (rows[rows.length - 1] === '') rows.pop()
  if (rows.length < 2) return null
  const matrix = rows.map((row) => row.split('\t'))
  const columns = matrix[0].length
  if (columns < 2 || matrix.some((row) => row.length !== columns)) return null
  return { source: serializeTableRows(matrix, '\n'), rows: matrix.length, columns }
}

export function tableInsertionPatch(source, from, to, expectedBlock, tableSource, lineEnding = '\n') {
  if (typeof source !== 'string' || typeof expectedBlock !== 'string' ||
    typeof tableSource !== 'string' || tableSource.length === 0 ||
    !Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from ||
    to > source.length || (lineEnding !== '\n' && lineEnding !== '\r\n') ||
    (source[from - 1] === '\r' && source[from] === '\n') ||
    (source[to - 1] === '\r' && source[to] === '\n') ||
    source.slice(from, to) !== expectedBlock) {
    return null
  }

  if (expectedBlock.trim().length === 0) {
    return { from, to, expected: expectedBlock, replacement: tableSource }
  }
  return {
    from: to,
    to,
    expected: '',
    replacement: `${lineEnding}${lineEnding}${tableSource}`
  }
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
  // marked 的 table token raw 会吸收尾随换行（含块间空行分隔符），
  // 调用方传入的块切片常带尾部 \n；空行会被 sourceLines 当成表格行导致解析失败，
  // 这里统一剥掉尾随换行串再解析（只影响末尾，单元格偏移不受影响）。
  const trimmed = source.replace(/(?:\r?\n)+$/, '')
  const tokens = marked.lexer(trimmed).filter((token) => token.type !== 'space' && token.type !== 'def')
  if (tokens.length !== 1 || tokens[0].type !== 'table' ||
    tokens[0].raw.replace(/\r\n/g, '\n') !== trimmed.replace(/\r\n/g, '\n')) {
    return null
  }

  const lines = sourceLines(trimmed)
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

  const hasFence = /```|~~~/.test(trimmed)
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

/**
 * Apply one row or column operation to a complete, structurally valid table.
 * Cell source and divider alignment tokens are retained; only layout spacing is normalized.
 */
export function applyTableStructureOperation(source, operation) {
  const prepared = tableWithPrefixes(source)
  const table = prepared ? parseTableSource(prepared.logicalSource) : null
  if (!prepared || !table || !operation || typeof operation !== 'object') return null

  const logicalLines = tableLinesWithEndings(prepared.logicalSource)
  if (logicalLines.length !== prepared.lines.length) return null
  const matrix = [
    table.header.map((cell) => cell.source),
    splitTableRow(logicalLines[1].text, 0).map((cell) => cell.source),
    ...table.rows.map((row) => row.map((cell) => cell.source))
  ]
  const columnCount = matrix[0].length
  const hadFinalNewline = prepared.lines[prepared.lines.length - 1].ending.length > 0
  const selectedRow = operation.row
  const selectedColumn = operation.column
  if (!Number.isInteger(selectedRow) || selectedRow < 0 || selectedRow >= matrix.length - 1 ||
    !Number.isInteger(selectedColumn) || selectedColumn < 0 || selectedColumn >= columnCount) {
    return null
  }

  let selection = { row: selectedRow, column: selectedColumn }
  if (operation.type === 'insertRow') {
    const side = operation.side
    if (side !== 'up' && side !== 'down') return null
    if (side === 'up' && selectedRow === 0) {
      return { source: null, error: '表头上方不能插入行', selection }
    }
    const insertAt = selectedRow + (side === 'down' ? 1 : 0)
    const lineIndex = insertAt + 1
    const adjacentIndex = Math.min(lineIndex, prepared.lines.length - 1)
    const adjacent = prepared.lines[adjacentIndex]
    const defaultEnding = prepared.lines.find((line) => line.ending)?.ending ?? '\n'
    const ending = lineIndex < prepared.lines.length
      ? adjacent.ending || defaultEnding
      : hadFinalNewline ? defaultEnding : ''
    const prefix = adjacent.prefix

    if (lineIndex === prepared.lines.length && !hadFinalNewline) {
      prepared.lines[prepared.lines.length - 1].ending = defaultEnding
    }
    matrix.splice(insertAt + 1, 0, Array(columnCount).fill(''))
    prepared.lines.splice(lineIndex, 0, { text: '', ending, prefix })
    selection = { row: insertAt, column: selectedColumn }
  } else if (operation.type === 'deleteRow') {
    if (selectedRow === 0) return { source: null, error: '表头行不能删除', selection }
    matrix.splice(selectedRow + 1, 1)
    prepared.lines.splice(selectedRow + 1, 1)
    selection = {
      row: Math.min(selectedRow, matrix.length - 2),
      column: selectedColumn
    }
  } else if (operation.type === 'insertColumn') {
    const side = operation.side
    if (side !== 'left' && side !== 'right') return null
    const insertAt = selectedColumn + (side === 'right' ? 1 : 0)
    for (let row = 0; row < matrix.length; row++) {
      matrix[row].splice(insertAt, 0, row === 1 ? '---' : '')
    }
    selection = { row: selectedRow, column: insertAt }
  } else if (operation.type === 'deleteColumn') {
    if (columnCount <= 1) return { source: null, error: '至少保留一列', selection }
    for (const row of matrix) row.splice(selectedColumn, 1)
    selection = {
      row: selectedRow,
      column: Math.min(selectedColumn, columnCount - 2)
    }
  } else {
    return null
  }

  if (!hadFinalNewline) prepared.lines[prepared.lines.length - 1].ending = ''
  const replacement = matrix.map((cells, index) => {
    const line = prepared.lines[index]
    return `${line.prefix}| ${cells.join(' | ')} |${line.ending}`
  }).join('')
  return { source: replacement, selection, error: '' }
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
