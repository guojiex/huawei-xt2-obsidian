import assert from 'node:assert/strict'
import test from 'node:test'
import { marked } from 'marked'
import {
  applyTableStructureOperation,
  createMarkdownTableSource,
  isPseudoTableSource,
  parseTableSource,
  replaceTableCellSource,
  serializeTableCellContent,
  tableInsertionPatch,
  tableSourceFromTsv
} from '../src/tableCells.mjs'

marked.setOptions({ gfm: true, breaks: false })

test('14.1 maps trimmed cell source ranges across CRLF and escaped pipes', () => {
  const source = '| 名称 | 内容 |\r\n| :--- | ---: |\r\n| A\\|B | **粗体** 和 *斜体* |\r\n'
  const table = parseTableSource(source)

  assert.ok(table)
  assert.deepEqual(table.header.map((cell) => source.slice(cell.from, cell.to)), ['名称', '内容'])
  assert.deepEqual(table.rows[0].map((cell) => source.slice(cell.from, cell.to)), [
    String.raw`A\|B`,
    '**粗体** 和 *斜体*'
  ])
  assert.equal(table.rows[0][0].editable, true)
  assert.equal(table.header[0].editable, true)
})

test('14.1 maps cells after a BOM and supports tables without outer pipes', () => {
  const bomSource = '\uFEFF| a | b |\n| --- | --- |\n| c | d |\n'
  const bomTable = parseTableSource(bomSource)
  assert.ok(bomTable)
  assert.equal(bomSource.slice(bomTable.rows[0][1].from, bomTable.rows[0][1].to), 'd')

  const pipeLessSource = 'a | b\r\n--- | ---\r\nc | d\r\n'
  const pipeLessTable = parseTableSource(pipeLessSource)
  assert.ok(pipeLessTable)
  assert.equal(pipeLessSource.slice(pipeLessTable.rows[0][1].from, pipeLessTable.rows[0][1].to), 'd')
})

test('14.5 protects only cells containing unsupported inline syntax', () => {
  const source = '| 链接 | 图片 | 双链 | 公式 | 代码 | HTML | 脚注 | 转义 | 可编辑 |\n' +
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n' +
    '| [a](https://a.test) | ![a](a.png) | [[a]] | $x$ | `x` | <b>x</b> | [^1] | \\* | **b** |\n'
  const table = parseTableSource(source)

  assert.ok(table)
  assert.deepEqual(table.rows[0].map((cell) => cell.editable),
    [false, false, false, false, false, false, false, false, true])
})

test('14.5 rejects missing dividers, unequal row widths, and non-table source', () => {
  assert.equal(parseTableSource('| a | b |\n| c | d |\n'), null)
  assert.equal(parseTableSource('| a | b |\n| --- | --- |\n| c |\n'), null)
  assert.equal(parseTableSource('plain text\n'), null)
})

test('14.5 fails closed for fenced markers anywhere in a table', () => {
  const source = '| a | b |\n| --- | --- |\n| ```ts | c |\n'
  const table = parseTableSource(source)

  assert.ok(table)
  assert.equal(table.hasFence, true)
  assert.ok(table.header.every((cell) => !cell.editable))
  assert.ok(table.rows[0].every((cell) => !cell.editable))
})

test('14.1 serializes cell text safely while retaining bold and italic', () => {
  const text = { nodeType: 3, textContent: 'a|b *literal* &' }
  const italic = { nodeType: 1, tagName: 'EM', childNodes: [{ nodeType: 3, textContent: '斜体!' }] }
  const strong = { nodeType: 1, tagName: 'STRONG', childNodes: [
    { nodeType: 3, textContent: '粗体 ' }, italic
  ] }
  const cell = { nodeType: 1, tagName: 'TD', childNodes: [text, strong] }

  assert.equal(serializeTableCellContent(cell), String.raw`a\|b &#42;literal&#42; &#38;**粗体 *斜体&#33;***`)
})

test('14.1 replaces only a validated cell interval and preserves surrounding source', () => {
  const source = 'before\r\n| a | b |\r\n| --- | --- |\r\n| c | d |\r\nafter'
  const tableFrom = source.indexOf('| a |')
  const tableTo = source.indexOf('\r\nafter')
  const tableSource = source.slice(tableFrom, tableTo)
  const table = parseTableSource(tableSource)
  const cell = table.rows[0][1]
  const updated = replaceTableCellSource(tableSource, cell.from, cell.to, 'd', 'new\\|value')

  assert.equal(updated, '| a | b |\r\n| --- | --- |\r\n| c | new\\|value |')
  assert.equal(source.slice(0, tableFrom), 'before\r\n')
  assert.equal(source.slice(tableTo), '\r\nafter')
  assert.equal(replaceTableCellSource(tableSource, cell.from, cell.to, 'stale', 'x'), null)
  assert.equal(replaceTableCellSource(tableSource, cell.from - 1, cell.to, '| d', 'x'), null)
})

test('14.2 inserts a column while preserving cell source, alignment, CRLF, and final newline state', () => {
  const source = '| A | B |\r\n| :--- | ---: |\r\n| a\\|b | x  y |'
  const result = applyTableStructureOperation(source, {
    type: 'insertColumn',
    side: 'right',
    row: 1,
    column: 0
  })

  assert.deepEqual(result, {
    source: '| A |  | B |\r\n| :--- | --- | ---: |\r\n| a\\|b |  | x  y |',
    selection: { row: 1, column: 1 },
    error: ''
  })
  assert.equal(result.source.endsWith('\r\n'), false)
})

test('14.2 inserts and deletes rows without changing a table final newline state', () => {
  const source = '| A |\r\n| --- |\r\n| one |\r\n| two |'
  const inserted = applyTableStructureOperation(source, {
    type: 'insertRow',
    side: 'down',
    row: 2,
    column: 0
  })

  assert.deepEqual(inserted, {
    source: '| A |\r\n| --- |\r\n| one |\r\n| two |\r\n|  |',
    selection: { row: 3, column: 0 },
    error: ''
  })
  assert.equal(inserted.source.endsWith('\r\n'), false)

  const deleted = applyTableStructureOperation(source, {
    type: 'deleteRow',
    row: 2,
    column: 0
  })
  assert.deepEqual(deleted, {
    source: '| A |\r\n| --- |\r\n| one |',
    selection: { row: 1, column: 0 },
    error: ''
  })
  assert.equal(deleted.source.endsWith('\r\n'), false)
})

test('14.2 rejects the divider as a target row and protects the header row', () => {
  const source = '| A | B |\n| --- | --- |\n| one | two |\n'
  assert.equal(applyTableStructureOperation(source, {
    type: 'deleteRow',
    row: 2,
    column: 0
  }), null)

  assert.deepEqual(applyTableStructureOperation(source, {
    type: 'deleteRow',
    row: 0,
    column: 1
  }), {
    source: null,
    error: '表头行不能删除',
    selection: { row: 0, column: 1 }
  })
})

test('14.2 preserves BOM, quote and list prefixes during structural operations', () => {
  const bomSource = '\uFEFF| A | B |\n| --- | --- |\n| one | two |\n'
  const bomResult = applyTableStructureOperation(bomSource, {
    type: 'insertRow',
    side: 'down',
    row: 0,
    column: 1
  })
  assert.equal(bomResult.source, '\uFEFF| A | B |\n| --- | --- |\n|  |  |\n| one | two |\n')

  const quoteSource = '> | A | B |\n> | --- | --- |\n> | one | two |'
  const quoteResult = applyTableStructureOperation(quoteSource, {
    type: 'insertColumn',
    side: 'left',
    row: 1,
    column: 1
  })
  assert.equal(quoteResult.source,
    '> | A |  | B |\n> | --- | --- | --- |\n> | one |  | two |')

  const listSource = '- | A | B |\n  | --- | --- |\n  | one | two |'
  const listResult = applyTableStructureOperation(listSource, {
    type: 'insertRow',
    side: 'down',
    row: 1,
    column: 0
  })
  assert.equal(listResult.source,
    '- | A | B |\n  | --- | --- |\n  | one | two |\n  |  |  |')
})

test('14.2 keeps source outside the table untouched when applying the returned range patch', () => {
  const before = 'before\r\n'
  const tableSource = '| A | B |\r\n| --- | --- |\r\n| one | two |'
  const after = '\r\nafter'
  const result = applyTableStructureOperation(tableSource, {
    type: 'insertColumn',
    side: 'left',
    row: 1,
    column: 0
  })

  assert.equal(before + result.source + after,
    'before\r\n|  | A | B |\r\n| --- | --- | --- |\r\n|  | one | two |\r\nafter')
})

test('14.2 preserves existing alignment and rejects malformed tables and operations', () => {
  const source = '| L | C | R |\n| :--- | :---: | ---: |\n| l | c | r |\n'
  const inserted = applyTableStructureOperation(source, {
    type: 'insertColumn',
    side: 'right',
    row: 1,
    column: 1
  })
  assert.equal(inserted.source, '| L | C |  | R |\n| :--- | :---: | --- | ---: |\n| l | c |  | r |\n')

  assert.equal(applyTableStructureOperation('| A | B |\n| --- |\n', {
    type: 'insertRow',
    side: 'down',
    row: 0,
    column: 0
  }), null)
  assert.equal(applyTableStructureOperation('| A |\n| --- |\n', {
    type: 'deleteColumn',
    row: 0,
    column: 0
  }).error, '至少保留一列')
  assert.equal(applyTableStructureOperation(source, {
    type: 'insertColumn',
    side: 'up',
    row: 0,
    column: 0
  }), null)
})

test('14.4 creates bounded tables with the requested line ending and header placeholders', () => {
  assert.equal(createMarkdownTableSource(2, 2, '\r\n'),
    '| 列 1 | 列 2 |\r\n| --- | --- |\r\n|  |  |')
  assert.equal(createMarkdownTableSource(8, 6).split('\n').length, 9)
  assert.equal(createMarkdownTableSource(0, 2), null)
  assert.equal(createMarkdownTableSource(2, 7), null)
})

test('14.4 converts only rectangular multi-row TSV and escapes cell markup', () => {
  assert.deepEqual(tableSourceFromTsv('A\tB\r\none\t2\r\nthree\t4\r\n'), {
    source: '| A | B |\n| --- | --- |\n| one | 2 |\n| three | 4 |',
    rows: 3,
    columns: 2
  })
  assert.equal(tableSourceFromTsv('A\tB\nx|y\t*literal*').source,
    String.raw`| A | B |
| --- | --- |
| x\|y | &#42;literal&#42; |`)
  assert.equal(tableSourceFromTsv('A\tB'), null)
  assert.equal(tableSourceFromTsv('A\tB\none'), null)
  assert.equal(tableSourceFromTsv('A\none'), null)
  assert.equal(tableSourceFromTsv('A\tB\none\t2\n\n'), null)
})

test('14.4 replaces an empty block or inserts after a non-empty block without touching surrounding source', () => {
  const table = '| A | B |\n| --- | --- |\n| one | two |'
  const emptySource = 'before\n\n\n\nafter'
  const emptyFrom = emptySource.indexOf('\n\n') + 2
  const emptyTo = emptySource.indexOf('after') - 2
  const emptyBlock = emptySource.slice(emptyFrom, emptyTo)
  const emptyPatch = tableInsertionPatch(emptySource, emptyFrom, emptyTo, emptyBlock, table)
  assert.deepEqual(emptyPatch, {
    from: emptyFrom,
    to: emptyTo,
    expected: emptyBlock,
    replacement: table
  })
  assert.equal(emptySource.slice(0, emptyPatch.from) + emptyPatch.replacement +
    emptySource.slice(emptyPatch.to), 'before\n\n' + table + '\n\nafter')

  const source = 'before\r\n\r\nnote\r\n\r\nafter'
  const from = source.indexOf('note')
  const to = from + 'note'.length
  const patch = tableInsertionPatch(source, from, to, 'note', table.replace(/\n/g, '\r\n'), '\r\n')
  assert.deepEqual(patch, {
    from: to,
    to,
    expected: '',
    replacement: '\r\n\r\n' + table.replace(/\n/g, '\r\n')
  })
  assert.equal(source.slice(0, patch.from) + patch.replacement + source.slice(patch.to),
    'before\r\n\r\nnote\r\n\r\n' + table.replace(/\n/g, '\r\n') + '\r\n\r\nafter')
})

test('14.4 refuses a stale block range and offsets that split CRLF', () => {
  assert.equal(tableInsertionPatch('a\r\nb', 1, 2, '\n', '| A |\n| --- |'), null)
  assert.equal(tableInsertionPatch('paragraph', 0, 9, 'changed', '| A |\n| --- |'), null)
})

test('pseudo tables without a divider are identified for read-only protection', () => {
  assert.equal(isPseudoTableSource('| a | b |\n| c | d |'), true)
  assert.equal(isPseudoTableSource('a | b\nc | d'), true)
  assert.equal(isPseudoTableSource('a | b | c'), false)
  assert.equal(isPseudoTableSource('plain | prose\nwithout table rows'), false)
  assert.equal(isPseudoTableSource('| a \\| b |\n| c | d |'), true)
})
