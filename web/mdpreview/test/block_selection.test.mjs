import assert from 'node:assert/strict'
import test from 'node:test'
import {
  codeBlockForSourceRange,
  inlineItemsForBlock,
  lockedBlockAnchor,
  selectedLockedBlocks,
  toolbarBlockForSelection
} from '../src/blockSelection.mjs'

function makeBlock(id, locked = true, sourceType = 'table') {
  return { id, dataset: { editLocked: String(locked), sourceType } }
}

const resolveBlock = (node) => node?.block ?? null

test('collapsed caret ignores paragraphs but still activates independent locked blocks', () => {
  const paragraph = makeBlock('paragraph', true, 'paragraph')
  const table = makeBlock('table')
  const editable = makeBlock('editable', false, 'paragraph')
  const blocks = [paragraph, table, editable]

  assert.deepEqual(selectedLockedBlocks(blocks, {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: paragraph }
  }, resolveBlock), [])
  assert.deepEqual(selectedLockedBlocks(blocks, {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: table }
  }, resolveBlock), [table])
  assert.deepEqual(selectedLockedBlocks(blocks, {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: editable }
  }, resolveBlock), [])
})

test('non-collapsed selection highlights every locked block it intersects', () => {
  const first = makeBlock('first')
  const editable = makeBlock('editable', false)
  const second = makeBlock('second')

  assert.deepEqual(selectedLockedBlocks([first, editable, second], {
    rangeCount: 1,
    isCollapsed: false,
    getRangeAt: () => ({
      intersectsNode: (block) => block !== editable
    })
  }, resolveBlock), [first, second])
})

test('non-collapsed text selection still highlights its paragraph', () => {
  const paragraph = makeBlock('paragraph', true, 'paragraph')
  assert.deepEqual(selectedLockedBlocks([paragraph], {
    rangeCount: 1,
    isCollapsed: false,
    getRangeAt: () => ({ intersectsNode: () => true })
  }, resolveBlock), [paragraph])
})

test('missing, empty, or out-of-root selections do not highlight blocks', () => {
  const locked = makeBlock('locked')
  const outside = makeBlock('outside')

  assert.deepEqual(selectedLockedBlocks([locked], null, resolveBlock), [])
  assert.deepEqual(selectedLockedBlocks([locked], { rangeCount: 0 }, resolveBlock), [])
  assert.deepEqual(selectedLockedBlocks([locked], {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: outside }
  }, resolveBlock), [])
})

test('floating-toolbar anchor follows the selection focus block', () => {
  const first = makeBlock('first')
  const second = makeBlock('second')

  assert.equal(toolbarBlockForSelection([first, second], {
    rangeCount: 1,
    anchorNode: { block: first },
    focusNode: { block: second }
  }, resolveBlock), second)
  assert.equal(toolbarBlockForSelection([first], {
    rangeCount: 1,
    focusNode: { block: second }
  }, resolveBlock), null)
  assert.equal(toolbarBlockForSelection([first], { rangeCount: 0 }, resolveBlock), null)
})

test('valid editable tables get a toolbar anchor without becoming locked blocks', () => {
  const table = {
    dataset: {
      editLocked: 'false',
      sourceType: 'table',
      tableStructureEditable: 'true'
    }
  }
  const invalidTable = {
    dataset: {
      editLocked: 'true',
      sourceType: 'table',
      tableStructureEditable: 'false'
    }
  }

  assert.equal(toolbarBlockForSelection([table], {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: table }
  }, resolveBlock), table)
  assert.equal(toolbarBlockForSelection([invalidTable], {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: invalidTable }
  }, resolveBlock), invalidTable)
  assert.equal(toolbarBlockForSelection([], {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: table }
  }, resolveBlock), null)
})

test('code copy resolves only the exact code block source range', () => {
  const first = { dataset: { sourceType: 'code', sourceFrom: '10', sourceTo: '28' } }
  const otherType = { dataset: { sourceType: 'paragraph', sourceFrom: '30', sourceTo: '48' } }
  const second = { dataset: { sourceType: 'code', sourceFrom: '30', sourceTo: '48' } }

  assert.equal(codeBlockForSourceRange([first, otherType, second], 30, 48), second)
  assert.equal(codeBlockForSourceRange([first, second], 30, 49), null)
  assert.equal(codeBlockForSourceRange([first], -1, 28), null)
})

test('locked block anchor contains source identity and visible geometry only', () => {
  const block = {
    dataset: {
      editLocked: 'true',
      sourceType: 'table',
      sourceFrom: '12',
      sourceTo: '48',
      tableActiveRow: '1',
      tableActiveColumn: '2',
      tableRows: '4',
      tableColumns: '3',
      tableStructureEditable: 'true'
    }
  }
  const anchor = lockedBlockAnchor(block, {
    left: 20,
    top: 30,
    right: 120,
    bottom: 80,
    width: 100,
    height: 50
  }, 400, 600)

  assert.deepEqual(anchor, {
    type: 'table',
    from: 12,
    to: 48,
    tableRow: 1,
    tableColumn: 2,
    tableRows: 4,
    tableColumns: 3,
    tableStructureEditable: true,
    inlineItems: [],
    inlineSafe: false,
    left: 20,
    top: 30,
    width: 100,
    height: 50,
    viewportWidth: 400,
    viewportHeight: 600
  })
  assert.equal(Object.hasOwn(anchor, 'text'), false)
})

test('locked block anchors preserve whether a paragraph supports inline editing', () => {
  const block = {
    dataset: {
      editLocked: 'true',
      inlineSafe: 'false',
      sourceType: 'paragraph',
      sourceFrom: '4',
      sourceTo: '30'
    }
  }
  const anchor = lockedBlockAnchor(block, {
    left: 10,
    top: 20,
    right: 110,
    bottom: 60,
    width: 100,
    height: 40
  }, 400, 600)

  assert.equal(anchor.inlineSafe, false)
})

test('structurally valid tables can anchor actions while their cells remain editable', () => {
  const block = {
    dataset: {
      editLocked: 'false',
      sourceType: 'table',
      tableStructureEditable: 'true',
      sourceFrom: '8',
      sourceTo: '40'
    }
  }
  assert.equal(lockedBlockAnchor(block, {
    left: 10,
    top: 20,
    right: 110,
    bottom: 60,
    width: 100,
    height: 40
  }, 400, 600).type, 'table')
})

test('paragraph anchors expose validated inline item identities and exact source ranges', () => {
  const block = {
    dataset: { inlineItemsReady: 'true', sourceFrom: '10', sourceTo: '80' },
    querySelectorAll: () => [
      { dataset: { previewInlineIndex: '0', previewInlineType: 'link', previewInlineFrom: '18', previewInlineTo: '35' } },
      { dataset: { previewInlineIndex: '1', previewInlineType: 'image', previewInlineFrom: '40', previewInlineTo: '58' } }
    ]
  }
  assert.deepEqual(inlineItemsForBlock(block), [
    { index: 0, type: 'link', from: 18, to: 35 },
    { index: 1, type: 'image', from: 40, to: 58 }
  ])
})

test('21.4 paragraph anchors accept exact footnote reference ranges', () => {
  const block = {
    dataset: { inlineItemsReady: 'true', sourceFrom: '10', sourceTo: '40' },
    querySelectorAll: () => [
      { dataset: {
        previewInlineIndex: '0', previewInlineType: 'footnoteRef',
        previewInlineFrom: '18', previewInlineTo: '25'
      } }
    ]
  }
  assert.deepEqual(inlineItemsForBlock(block), [
    { index: 0, type: 'footnoteRef', from: 18, to: 25 }
  ])
})

test('invalid or incomplete inline item metadata fails closed', () => {
  const block = {
    dataset: { inlineItemsReady: 'true', sourceFrom: '10', sourceTo: '80' },
    querySelectorAll: () => [
      { dataset: { previewInlineIndex: '0', previewInlineType: 'link', previewInlineFrom: '18', previewInlineTo: '35' } },
      { dataset: { previewInlineIndex: '0', previewInlineType: 'image', previewInlineFrom: '40', previewInlineTo: '58' } }
    ]
  }
  assert.deepEqual(inlineItemsForBlock(block), [])
  assert.deepEqual(inlineItemsForBlock({
    dataset: { ...block.dataset, inlineItemsReady: 'false' },
    querySelectorAll: block.querySelectorAll
  }), [])
})

test('locked block anchor rejects invalid metadata, geometry, and fully offscreen blocks', () => {
  const block = {
    dataset: {
      editLocked: 'true',
      sourceType: 'table',
      sourceFrom: '12',
      sourceTo: '48'
    }
  }
  const rect = {
    left: 20,
    top: 30,
    right: 120,
    bottom: 80,
    width: 100,
    height: 50
  }

  assert.equal(lockedBlockAnchor(null, rect, 400, 600), null)
  assert.equal(lockedBlockAnchor({ dataset: { ...block.dataset, editLocked: 'false' } }, rect, 400, 600), null)
  assert.equal(lockedBlockAnchor({ dataset: { ...block.dataset, sourceFrom: 'bad' } }, rect, 400, 600), null)
  assert.equal(lockedBlockAnchor({ dataset: { ...block.dataset, sourceType: '' } }, rect, 400, 600), null)
  assert.equal(lockedBlockAnchor(block, { ...rect, left: Number.NaN }, 400, 600), null)
  assert.equal(lockedBlockAnchor(block, { ...rect, width: 0 }, 400, 600), null)
  assert.equal(lockedBlockAnchor(block, rect, 0, 600), null)
  assert.equal(lockedBlockAnchor(block, { ...rect, left: 500, right: 600 }, 400, 600), null)
})
