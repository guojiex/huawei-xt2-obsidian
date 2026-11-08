import assert from 'node:assert/strict'
import { test } from 'node:test'
import { history, redo, undo } from '@codemirror/commands'
import { markdown } from '@codemirror/lang-markdown'
import { EditorState } from '@codemirror/state'
import {
  allowsSimpleModeTransaction,
  appContentReplace,
  createSimpleModeRangesField,
  simpleModeChangeFilter
} from '../src/simpleMode.ts'

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

// 以下用生产同款 simpleModeChangeFilter + createSimpleModeRangesField 复现并钉死
// 「快速切换笔记误报编辑恢复弹窗」的根因：简洁模式 changeFilter 把整篇替换的
// setContent 静默否决（只丢 changes 不报错），页面停留「旧内容 + 新 revision」。

function createProductionGuardedEditor(source = '') {
  const protectedField = createSimpleModeRangesField()
  return EditorState.create({
    doc: source,
    extensions: [markdown(), protectedField, simpleModeChangeFilter(protectedField)]
  })
}

function replaceWholeDoc(state, insert, annotations = []) {
  return state.update({
    changes: { from: 0, to: state.doc.length, insert },
    annotations
  }).state
}

test('full-doc replacement across protected ranges is silently vetoed without appContentReplace', () => {
  const source = 'before\n\n```js\nconst value = 1\n```\n\nafter'
  const state = createProductionGuardedEditor(source)

  const replaced = replaceWholeDoc(state, 'another note')

  assert.equal(replaced.doc.toString(), source)
})

test('setContent full-doc replacement carries appContentReplace and always applies', () => {
  const firstNote = '# A\n\n```js\nconst value = 1\n```'
  const secondNote = '# B\n\n| a | b |\n| --- | --- |\n| 1 | 2 |'
  let state = createProductionGuardedEditor('')
  state = replaceWholeDoc(state, firstNote, [appContentReplace.of(true)])
  assert.equal(state.doc.toString(), firstNote)
  state = replaceWholeDoc(state, secondNote, [appContentReplace.of(true)])
  assert.equal(state.doc.toString(), secondNote)
})

test('typing inside a protected code block is still vetoed by the production changeFilter', () => {
  const source = 'before\n\n```js\nconst value = 1\n```\n\nafter'
  const state = createProductionGuardedEditor(source)
  const insideCode = source.indexOf('const') + 5

  const edited = state.update({ changes: { from: insideCode, to: insideCode, insert: 'x' }, userEvent: 'input.type' })

  assert.equal(edited.docChanged, false)
  assert.equal(edited.newDoc.toString(), source)
})
