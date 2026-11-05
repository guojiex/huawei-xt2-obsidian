import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import test from 'node:test'
import vm from 'node:vm'
import { applyTableStructureOperation, tableInsertionPatch } from '../src/tableCells.mjs'

const require = createRequire(new URL('../package.json', import.meta.url))
const { transformSync } = require('esbuild')
const previewSource = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')

function extract(startMarker, endMarker) {
  const start = previewSource.indexOf(startMarker)
  const end = previewSource.indexOf(endMarker, start)
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`)
  return previewSource.slice(start, end)
}

function createWorkflowHarness(sourceText, action) {
  const drainFunction = extract('function drainQueuedTableEdit(', 'function queueTableEdit(')
  const completeStart = previewSource.indexOf(
    '  completeCodeBlockEdit(id: number, applied: boolean): void {'
  )
  const completeEnd = previewSource.indexOf('\n  },\n\n  copyCodeBlock(', completeStart)
  assert.ok(completeStart >= 0 && completeEnd > completeStart)
  const completeMethod = previewSource.slice(completeStart, completeEnd + '\n  }'.length)
    .replace('  completeCodeBlockEdit(', 'function completeCodeBlockEdit(')
    .replace(/\n  \}$/, '\n}')
  const module = { exports: {} }
  const code = transformSync(`
    let sourceText = suppliedSource;
    let contentGeneration = 4;
    let pendingTableSourceEdit = null;
    let pendingCodeEdit = null;
    let pendingTableCellEdit = null;
    let nextCodeEditId = 1;
    let editableComposing = false;
    const queuedTableEdits = [suppliedAction];
    const dispatched = [];
    const messages = [];
    function notifyTableActionMessage(message) { messages.push(message); }
    function dispatchTableSourceEdit(edit) {
      pendingTableSourceEdit = edit;
      dispatched.push(edit);
    }
    function notifyBlockEditingState() {}
    function drainBlockSourceEdits() {}
    function notifyCodeEditWaiters() {}
    ${drainFunction}
    ${completeMethod}
    module.exports = {
      drainQueuedTableEdit,
      completeCodeBlockEdit,
      dispatched,
      messages,
      get sourceText() { return sourceText; },
      get pendingTableSourceEdit() { return pendingTableSourceEdit; }
    };
  `, { loader: 'ts', format: 'cjs' }).code
  vm.runInNewContext(code, {
    module,
    suppliedSource: sourceText,
    suppliedAction: action,
    applyTableStructureOperation,
    tableInsertionPatch
  })
  return module.exports
}

function target(sourceType, sourceFrom, sourceTo, isConnected = true) {
  return {
    isConnected,
    dataset: {
      sourceType,
      sourceFrom: String(sourceFrom),
      sourceTo: String(sourceTo),
      tableStructureEditable: sourceType === 'table' ? 'true' : 'false'
    }
  }
}

test('14.2 structure queue accepts a table and prepares a range-only replacement', () => {
  const table = '| A | B |\n| --- | --- |\n| one | two |'
  const prefix = 'before\n'
  const suffix = '\n\nafter'
  const source = prefix + table + suffix
  const from = prefix.length
  const to = from + table.length
  const harness = createWorkflowHarness(source, {
    kind: 'structure',
    generation: 4,
    block: target('table', from, to),
    type: 'insertColumn',
    side: 'right',
    row: 1,
    column: 0,
    showUndo: false,
    undoMessage: ''
  })

  harness.drainQueuedTableEdit()

  assert.equal(harness.dispatched.length, 1)
  assert.equal(harness.dispatched[0].from, from)
  assert.equal(harness.dispatched[0].to, to)
  assert.equal(harness.dispatched[0].expected, table)
  assert.equal(harness.dispatched[0].replacement,
    applyTableStructureOperation(table, {
      type: 'insertColumn',
      side: 'right',
      row: 1,
      column: 0
    }).source)
  assert.equal(source.slice(0, from), prefix)
  assert.equal(source.slice(to), suffix)
})

test('14.4 insertion queue accepts a paragraph and preserves its source as a separate range', () => {
  const source = 'before\nnote\nafter'
  const from = source.indexOf('note')
  const to = from + 'note'.length
  const tableSource = '| A | B |\n| --- | --- |\n| one | two |'
  const harness = createWorkflowHarness(source, {
    kind: 'insert',
    generation: 4,
    block: target('paragraph', from, to),
    tableSource,
    focusRow: 0,
    focusColumn: 0,
    showUndo: true,
    undoMessage: '已转为表格'
  })

  harness.drainQueuedTableEdit()

  assert.equal(harness.dispatched.length, 1)
  assert.equal(harness.dispatched[0].from, to)
  assert.equal(harness.dispatched[0].to, to)
  assert.equal(harness.dispatched[0].expected, '')
  assert.equal(harness.dispatched[0].replacement, `\n\n${tableSource}`)
  assert.equal(harness.dispatched[0].focusFrom, to + 2)
  assert.equal(harness.dispatched[0].showUndo, true)
  assert.equal(harness.sourceText, source)
})

test('14.2 and 14.4 reject wrong-type or stale targets without dispatching a write', () => {
  const source = '| A | B |\n| --- | --- |\n| one | two |'
  const tableAction = {
    kind: 'structure',
    generation: 4,
    block: target('paragraph', 0, source.length),
    type: 'deleteRow',
    side: 'down',
    row: 1,
    column: 0,
    showUndo: false,
    undoMessage: ''
  }
  const wrongStructureTarget = createWorkflowHarness(source, tableAction)
  wrongStructureTarget.drainQueuedTableEdit()
  assert.equal(wrongStructureTarget.dispatched.length, 0)
  assert.equal(wrongStructureTarget.sourceText, source)

  const staleInsertTarget = createWorkflowHarness(source, {
    kind: 'insert',
    generation: 3,
    block: target('paragraph', 0, source.length),
    tableSource: source,
    focusRow: 0,
    focusColumn: 0,
    showUndo: true,
    undoMessage: '已转为表格'
  })
  staleInsertTarget.drainQueuedTableEdit()
  assert.equal(staleInsertTarget.dispatched.length, 0)
  assert.equal(staleInsertTarget.sourceText, source)
})

test('14.2 a failed editor write leaves preview source unchanged', () => {
  const table = '| A | B |\n| --- | --- |\n| one | two |'
  const prefix = 'before\n'
  const source = prefix + table + '\nafter'
  const harness = createWorkflowHarness(source, {
    kind: 'structure',
    generation: 4,
    block: target('table', prefix.length, prefix.length + table.length),
    type: 'deleteRow',
    side: 'down',
    row: 1,
    column: 0,
    showUndo: false,
    undoMessage: ''
  })
  harness.drainQueuedTableEdit()
  assert.equal(harness.dispatched.length, 1)

  harness.completeCodeBlockEdit(harness.dispatched[0].id, false)

  assert.equal(harness.sourceText, source)
  assert.equal(harness.pendingTableSourceEdit, null)
})
