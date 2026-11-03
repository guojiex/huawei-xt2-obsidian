import assert from 'node:assert/strict'
import test from 'node:test'
import {
  inlineItemsForBlock,
  lockedBlockAnchor,
  selectedLockedBlocks,
  toolbarBlockForSelection
} from '../src/blockSelection.mjs'

function makeBlock(id, locked = true) {
  return { id, dataset: { editLocked: String(locked) } }
}

const resolveBlock = (node) => node?.block ?? null

test('collapsed caret highlights only its locked source block', () => {
  const locked = makeBlock('locked')
  const editable = makeBlock('editable', false)
  const blocks = [locked, editable]

  assert.deepEqual(selectedLockedBlocks(blocks, {
    rangeCount: 1,
    isCollapsed: true,
    anchorNode: { block: locked }
  }, resolveBlock), [locked])
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

test('locked block anchor contains source identity and visible geometry only', () => {
  const block = {
    dataset: {
      editLocked: 'true',
      sourceType: 'table',
      sourceFrom: '12',
      sourceTo: '48'
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
    inlineItems: [],
    left: 20,
    top: 30,
    width: 100,
    height: 50,
    viewportWidth: 400,
    viewportHeight: 600
  })
  assert.equal(Object.hasOwn(anchor, 'text'), false)
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
