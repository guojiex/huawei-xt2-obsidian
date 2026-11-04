import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'
import vm from 'node:vm'
import { parseTableSource, replaceTableCellSource } from '../src/tableCells.mjs'

const require = createRequire(new URL('../package.json', import.meta.url))
const { transformSync } = require('esbuild')
const previewSource = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')

function extract(startMarker, endMarker) {
  const start = previewSource.indexOf(startMarker)
  const end = previewSource.indexOf(endMarker, start)
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`)
  return previewSource.slice(start, end)
}

function createSessionHarness() {
  const sessionFunctions = extract(
    'function finishTableCellEditSession(',
    'function submitCodeBodyEdit('
  )
  const completeMethodStart = previewSource.indexOf(
    '  completeCodeBlockEdit(id: number, applied: boolean): void {'
  )
  const completeMethodEnd = previewSource.indexOf('\n  },\n\n  copyCodeBlock(', completeMethodStart)
  assert.ok(completeMethodStart >= 0 && completeMethodEnd > completeMethodStart)
  const completeMethod = previewSource.slice(completeMethodStart, completeMethodEnd + '\n  }'.length)
    .replace('  completeCodeBlockEdit(', 'function completeCodeBlockEdit(')
    .replace(/\n  \}$/, '\n}')
  const module = { exports: {} }
  const code = transformSync(`
    let codeEditSession = null;
    let pendingCodeEdit = null;
    let tableCellEditSession = null;
    const tableCellEditSessions = new Map();
    let pendingTableCellEdit = null;
    let nextCodeEditId = 1;
    let editableComposing = false;
    let blockEditingNotified = false;
    const codeEditFlushWaiters = [];
    const requests = [];
    const window = { __arkts: { onCodeBlockEdit(...args) { requests.push(args); } } };
    const api = { completeCodeBlockEdit() {} };
    function sourceBlockForNode(target) { return target.block; }
    function serializeTableCellContent(target) { return target.value; }
    function b64encode(value) { return value; }
    function notifyBlockEditingState() {}
    function notifyCodeEditWaiters() {}
    function postEditableContent() {}
    function applyTableCellSourcePatch() { return true; }
    ${sessionFunctions}
    ${completeMethod}
    module.exports = {
      startTableCellEditSession,
      updateTableCellEditSessionFromDom,
      navigateTableCell,
      completeCodeBlockEdit,
      preventTableNavigationDuringComposition,
      requests,
      sessions: tableCellEditSessions,
      get pending() { return pendingTableCellEdit; }
    };
  `, { loader: 'ts', format: 'cjs' }).code
  vm.runInNewContext(code, { module })
  return module.exports
}

function createTableAnnotationHarness() {
  const implementation = extract(
    'function annotateTableCells(',
    '\nfunction applyTableCellSourcePatch('
  )
  const module = { exports: {} }
  const code = transformSync(`
    function setTableEditHint(block, message) { block.hint = message; }
    ${implementation}
    module.exports = annotateTableCells;
  `, { loader: 'ts', format: 'cjs' }).code
  vm.runInNewContext(code, { module, parseTableSource })
  return module.exports
}

function makeCell(name, from) {
  return {
    name,
    dataset: {
      simpleTableEditable: 'true',
      cellSourceFrom: String(from),
      cellSourceTo: String(from + 1),
      cellSource: name
    },
    block: { dataset: { sourceFrom: '0', sourceTo: '40' } },
    isContentEditable: true,
    isConnected: true,
    innerHTML: name,
    value: name
  }
}

test('14.1 applies a cell patch inside its block and shifts later source ranges', () => {
  const source = '\uFEFF---\r\ntitle: keep\r\n---\r\nbefore\r\n' +
    '| a | b |\r\n| --- | --- |\r\n| c | d |\r\n\r\nafter'
  const tableFrom = source.indexOf('| a |')
  const tableTo = source.indexOf('\r\n\r\nafter')
  const tableSource = source.slice(tableFrom, tableTo)
  const model = parseTableSource(tableSource)
  assert.ok(model)
  const cell = model.rows[0][1]
  const laterFrom = source.indexOf('after')
  const tableBlock = { dataset: { sourceFrom: String(tableFrom), sourceTo: String(tableTo) } }
  const laterBlock = { dataset: { sourceFrom: String(laterFrom), sourceTo: String(source.length) } }
  const queuedFrom = tableFrom + cell.to + 4
  const tableCellEditSessions = new Map()
  const pendingSession = { target: {}, from: tableFrom + cell.from, to: tableFrom + cell.to, expected: 'd' }
  const queuedSession = { target: {}, from: queuedFrom, to: queuedFrom + 1, expected: 'x' }
  tableCellEditSessions.set(pendingSession.target, pendingSession)
  tableCellEditSessions.set(queuedSession.target, queuedSession)
  const module = { exports: {} }
  const patchFunction = extract('function applyTableCellSourcePatch(', '\nfunction finishTableCellEditSession(')
  const code = transformSync(`
    let sourceText = ${JSON.stringify(source)};
    let editable = true;
    const contentElement = { querySelectorAll() { return [tableBlock, laterBlock]; } };
    const tableCellEditSessions = suppliedSessions;
    const tableBlock = suppliedTableBlock;
    const laterBlock = suppliedLaterBlock;
    function annotateTableCells() { return true; }
    ${patchFunction}
    module.exports = { applyTableCellSourcePatch, get sourceText() { return sourceText; } };
  `, { loader: 'ts', format: 'cjs' }).code
  vm.runInNewContext(code, {
    module,
    suppliedSessions: tableCellEditSessions,
    suppliedTableBlock: tableBlock,
    suppliedLaterBlock: laterBlock,
    replaceTableCellSource
  })

  const replacement = String.raw`new\|value`
  const patch = {
    from: tableFrom + cell.from,
    to: tableFrom + cell.to,
    expected: 'd',
    replacement,
    block: tableBlock,
    session: pendingSession
  }
  assert.equal(module.exports.applyTableCellSourcePatch(patch), true)
  const updated = source.slice(0, patch.from) + replacement + source.slice(patch.to)
  assert.equal(module.exports.sourceText, updated)
  assert.equal(updated.slice(0, tableFrom), source.slice(0, tableFrom))
  assert.equal(updated.slice(tableFrom + tableSource.length + replacement.length - 1),
    source.slice(tableTo))
  assert.equal(laterBlock.dataset.sourceFrom, String(laterFrom + replacement.length - 1))
  assert.equal(queuedSession.from, queuedFrom + replacement.length - 1)
})

test('14.1 queues edits from successive cells while an earlier write is pending', () => {
  const harness = createSessionHarness()
  const first = makeCell('a', 10)
  const second = makeCell('b', 20)

  harness.startTableCellEditSession(first)
  first.value = 'A'
  first.innerHTML = 'A'
  harness.updateTableCellEditSessionFromDom(first)
  assert.equal(harness.requests.length, 1)

  harness.startTableCellEditSession(second)
  second.value = 'B'
  second.innerHTML = 'B'
  harness.updateTableCellEditSessionFromDom(second)
  assert.equal(harness.requests.length, 1)

  const firstRequestId = harness.requests[0][0]
  harness.completeCodeBlockEdit(firstRequestId, true)
  assert.equal(harness.requests.length, 2)
  assert.equal(harness.requests[1][1], 20)
  assert.equal(harness.requests[1][2], 21)
  assert.equal(harness.requests[1][4], 'B')

  harness.sessions.get(second).exiting = true
  harness.completeCodeBlockEdit(harness.requests[1][0], true)
  assert.equal(harness.sessions.size, 0)
})

test('14.6 focusing a cell with escaped source does not create a write', () => {
  const harness = createSessionHarness()
  const cell = makeCell('a&amp;b', 10)
  cell.innerHTML = 'a&b'
  cell.value = 'a&#38;b'

  harness.startTableCellEditSession(cell)
  harness.updateTableCellEditSessionFromDom(cell)

  assert.equal(harness.requests.length, 0)
  assert.equal(harness.sessions.get(cell).dirty, false)
})

test('14.3 Tab, Shift+Tab, Enter, and navigation boundaries stay within table cells', () => {
  const harness = createSessionHarness()
  const focused = []
  const cells = Array.from({ length: 4 }, (_, index) => ({
    dataset: {
      simpleTableEditable: 'true',
      tableRow: String(Math.floor(index / 2)),
      tableColumn: String(index % 2)
    },
    closest() { return table },
    focus() { focused.push(index) }
  }))
  const table = {
    rows: [{ cells: cells.slice(0, 2) }, { cells: cells.slice(2) }],
    querySelectorAll() { return cells }
  }
  const key = (name, shiftKey = false) => ({
    key: name,
    shiftKey,
    isComposing: false,
    prevented: false,
    preventDefault() { this.prevented = true }
  })

  const tab = key('Tab')
  assert.equal(harness.navigateTableCell(tab, cells[0]), true)
  assert.deepEqual(focused, [1])
  assert.equal(tab.prevented, true)

  const shiftTab = key('Tab', true)
  harness.navigateTableCell(shiftTab, cells[1])
  assert.deepEqual(focused, [1, 0])

  const enter = key('Enter')
  harness.navigateTableCell(enter, cells[0])
  assert.deepEqual(focused, [1, 0, 2])

  const lastEnter = key('Enter')
  harness.navigateTableCell(lastEnter, cells[2])
  assert.deepEqual(focused, [1, 0, 2])
  assert.equal(lastEnter.prevented, true)

  const lastTab = key('Tab')
  harness.navigateTableCell(lastTab, cells[3])
  assert.deepEqual(focused, [1, 0, 2])
  assert.equal(lastTab.prevented, true)
})

test('14.1 Tab and Enter do not navigate during input-method composition', () => {
  const harness = createSessionHarness()
  let prevented = false
  const composing = {
    key: 'Tab',
    isComposing: true,
    preventDefault() { prevented = true }
  }

  assert.equal(harness.preventTableNavigationDuringComposition(composing), true)
  assert.equal(prevented, true)
  assert.equal(harness.preventTableNavigationDuringComposition({
    key: 'a',
    isComposing: false,
    preventDefault() { assert.fail('ordinary input must not be prevented') }
  }), false)
  assert.match(previewSource, /if \(preventTableNavigationDuringComposition\(event\)\) return/)

  const cell = {
    dataset: { simpleTableEditable: 'true' },
    closest() { return { querySelectorAll() { return [] } } },
    focus() { assert.fail('composition must not move the cell focus') }
  }
  let navigationPrevented = false
  assert.equal(harness.navigateTableCell({
    key: 'Tab',
    isComposing: true,
    preventDefault() { navigationPrevented = true }
  }, cell), true)
  assert.equal(navigationPrevented, true)
})

test('14.5 a complex cell stays read-only without locking its editable table cells', () => {
  const annotate = createTableAnnotationHarness()
  const raw = '| name | link |\n| --- | --- |\n| value | [open](https://example.test) |\n'
  const cells = Array.from({ length: 4 }, () => ({
    dataset: {},
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value },
    removeAttribute(name) { delete this.attributes[name] }
  }))
  const rows = [{ cells: cells.slice(0, 2) }, { cells: cells.slice(2) }]
  const table = {
    querySelectorAll(selector) {
      return selector === 'tr' ? rows : cells
    }
  }
  const block = {
    dataset: {},
    attributes: {},
    querySelector(selector) {
      return selector === 'table' ? table : null
    },
    setAttribute(name, value) { this.attributes[name] = value }
  }

  assert.equal(annotate(block, raw, 100, true), true)
  assert.equal(block.dataset.editLocked, 'false')
  assert.equal(cells[0].dataset.simpleTableEditable, 'true')
  assert.equal(cells[3].dataset.simpleTableEditable, 'false')
  assert.equal(cells[3].tabIndex, 0)
  assert.equal(block.hint, '复杂单元格请在专业模式编辑')

  const clickHandler = extract(
    "contentElement.addEventListener('click', (event: MouseEvent): void => {",
    "contentElement.addEventListener('scroll'"
  )
  assert.match(clickHandler, /if \(tableCell\) return/)
})
