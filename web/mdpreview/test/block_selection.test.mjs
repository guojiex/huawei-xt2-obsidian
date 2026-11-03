import assert from 'node:assert/strict'
import test from 'node:test'
import { selectedLockedBlocks } from '../src/blockSelection.mjs'

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
