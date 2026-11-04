import assert from 'node:assert/strict'
import test from 'node:test'
import { marked } from 'marked'
import {
  isPseudoTableSource,
  parseTableSource,
  replaceTableCellSource,
  serializeTableCellContent
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

test('pseudo tables without a divider are identified for read-only protection', () => {
  assert.equal(isPseudoTableSource('| a | b |\n| c | d |'), true)
  assert.equal(isPseudoTableSource('a | b\nc | d'), true)
  assert.equal(isPseudoTableSource('a | b | c'), false)
  assert.equal(isPseudoTableSource('plain | prose\nwithout table rows'), false)
  assert.equal(isPseudoTableSource('| a \\| b |\n| c | d |'), true)
})
