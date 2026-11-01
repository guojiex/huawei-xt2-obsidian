import assert from 'node:assert/strict'
import { test } from 'node:test'
import { history, redo, undo } from '@codemirror/commands'
import { markdown } from '@codemirror/lang-markdown'
import { EditorState } from '@codemirror/state'
import { allowsSimpleModeTransaction } from '../src/simpleMode.ts'

function createEditor(source = '') {
  return EditorState.create({
    doc: source,
    extensions: [
      markdown(),
      history(),
      EditorState.changeFilter.of((transaction) => allowsSimpleModeTransaction(transaction.startState, transaction))
    ]
  })
}

function applyInput(state, from, to, insert) {
  return state.update({ changes: { from, to, insert }, userEvent: 'input.type' }).state
}

test('simple mode supports empty notes, typing, paste, newline, deletion, split and merge', () => {
  let state = createEditor()
  state = applyInput(state, 0, 0, 'First paragraph')
  state = applyInput(state, state.doc.length, state.doc.length, ' pasted text')
  state = applyInput(state, state.doc.length, state.doc.length, '\nSecond paragraph')
  assert.equal(state.doc.toString(), 'First paragraph pasted text\nSecond paragraph')

  const splitAt = 'First paragraph'.length
  state = applyInput(state, splitAt, splitAt, '\n')
  assert.equal(state.doc.toString(), 'First paragraph\n pasted text\nSecond paragraph')
  state = applyInput(state, splitAt, splitAt + 1, '')
  assert.equal(state.doc.toString(), 'First paragraph pasted text\nSecond paragraph')

  state = applyInput(state, state.doc.length - 1, state.doc.length, '')
  assert.equal(state.doc.toString(), 'First paragraph pasted text\nSecond paragrap')
})

test('undo and redo restore the same Markdown source state', () => {
  let state = createEditor('draft')
  state = applyInput(state, 0, state.doc.length, 'edited paragraph\nsecond paragraph')
  assert.equal(state.doc.toString(), 'edited paragraph\nsecond paragraph')

  assert.equal(undo({ state, dispatch: (transaction) => { state = state.update(transaction).state } }), true)
  assert.equal(state.doc.toString(), 'draft')
  assert.equal(redo({ state, dispatch: (transaction) => { state = state.update(transaction).state } }), true)
  assert.equal(state.doc.toString(), 'edited paragraph\nsecond paragraph')
})

test('replacing a selection across ordinary paragraphs leaves later paragraphs intact', () => {
  const source = 'alpha\nbeta\ngamma'
  let state = createEditor(source)
  state = applyInput(state, 2, 8, 'X')

  assert.equal(state.doc.toString(), 'alXta\ngamma')
})

test('paste spanning a protected code block is rejected without changing adjacent paragraphs', () => {
  const source = 'before\n\n```js\nconst value = 1\n```\n\nafter'
  const start = source.indexOf('before') + 2
  const end = source.indexOf('after') + 2
  const state = createEditor(source)
  const filtered = state.update({ changes: { from: start, to: end, insert: 'replacement' }, userEvent: 'input.type' })

  assert.equal(filtered.docChanged, false)
  assert.equal(filtered.newDoc.toString(), source)
})
