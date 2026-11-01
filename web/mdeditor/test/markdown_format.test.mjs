import assert from 'node:assert/strict'
import { test } from 'node:test'
import { markdown } from '@codemirror/lang-markdown'
import { EditorState } from '@codemirror/state'
import { allowsSimpleModeTransaction } from '../src/simpleMode.ts'
import { toggleMarkdownFormat, toggleTaskStatus } from '../src/markdownFormat.ts'

function createState(doc, anchor = 0, head = anchor) {
  return EditorState.create({
    doc,
    selection: { anchor, head },
    extensions: [
      markdown(),
      EditorState.changeFilter.of((transaction) => allowsSimpleModeTransaction(transaction.startState, transaction))
    ]
  })
}

function applyFormat(state, kind) {
  const change = toggleMarkdownFormat(state, kind)
  assert.ok(change, `${kind} should produce a formatting change`)
  return state.update({ ...change, userEvent: 'input' }).state
}

test('bold and italic apply to the selection, preserve it, and can be removed', () => {
  let state = createState('plain bold and italic', 6, 10)
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), 'plain **bold** and italic')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'bold')
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), 'plain bold and italic')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'bold')

  state = createState('plain italic', 6, 12)
  state = applyFormat(state, 'italic')
  assert.equal(state.doc.toString(), 'plain *italic*')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'italic')
  state = applyFormat(state, 'italic')
  assert.equal(state.doc.toString(), 'plain italic')
})

test('an empty inline selection inserts a selected placeholder and the same format removes its markers', () => {
  let state = createState('')
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), '**粗体文字**')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), '粗体文字')
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), '粗体文字')
})

test('bold and italic can be toggled independently on the same selection', () => {
  let state = createState('bold', 0, 4)
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), '**bold**')
  state = applyFormat(state, 'italic')
  assert.equal(state.doc.toString(), '***bold***')
  state = applyFormat(state, 'italic')
  assert.equal(state.doc.toString(), '**bold**')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'bold')
  state = applyFormat(state, 'bold')
  assert.equal(state.doc.toString(), 'bold')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'bold')
})

test('existing inline-code and link toolbar actions still wrap selected source text', () => {
  let state = createState('write this', 0, 5)
  state = applyFormat(state, 'inlineCode')
  assert.equal(state.doc.toString(), '`write` this')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'write')

  state = createState('open page', 5, 9)
  state = applyFormat(state, 'link')
  assert.equal(state.doc.toString(), 'open [page](https://example.com)')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'page')
})

test('headings switch level and paragraph formatting removes the heading prefix without losing selection', () => {
  let state = createState('A title', 0, 7)
  for (let level = 1; level <= 6; level++) {
    state = applyFormat(state, 'h' + level.toString())
    assert.equal(state.doc.toString(), '#'.repeat(level) + ' A title')
    assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'A title')
  }
  state = applyFormat(state, 'paragraph')
  assert.equal(state.doc.toString(), 'A title')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'A title')
})

test('unordered, ordered, task and quote blocks apply to each selected line and toggle off', () => {
  const cases = [
    ['list', 'Alpha\nBeta', '- Alpha\n- Beta'],
    ['ordered', 'Alpha\nBeta', '1. Alpha\n2. Beta'],
    ['task', 'Alpha\nBeta', '- [ ] Alpha\n- [ ] Beta'],
    ['quote', 'Alpha\nBeta', '> Alpha\n> Beta']
  ]
  for (const [kind, plain, formatted] of cases) {
    let state = createState(plain, 0, plain.length)
    state = applyFormat(state, kind)
    assert.equal(state.doc.toString(), formatted, `${kind} applies`)
    assert.equal(state.selection.main.from, formatted.indexOf(plain.split('\n')[0]),
      `${kind} keeps the selection start on the first content line`)
    assert.equal(state.selection.main.to, formatted.length,
      `${kind} keeps the selection end on the final content line`)
    state = applyFormat(state, kind)
    assert.equal(state.doc.toString(), plain, `${kind} toggles off`)
    assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), plain,
      `${kind} keeps the selected block after removing`)
  }
})

test('point formatting inserts a list item at the cursor without replacing adjacent text', () => {
  let state = createState('left right', 4)
  state = applyFormat(state, 'list')

  assert.equal(state.doc.toString(), 'left\n- 列表项\n right')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), '列表项')
})

test('simple mode rejects formatting that would change a protected code block', () => {
  const source = 'before\n\n```js\nvalue\n```\n\nafter'
  const start = source.indexOf('value')
  let state = createState(source, start, start + 'value'.length)
  const change = toggleMarkdownFormat(state, 'bold')
  assert.ok(change)
  const transaction = state.update({ ...change, userEvent: 'input' })

  assert.equal(transaction.docChanged, false)
  assert.equal(transaction.newDoc.toString(), source)
})

test('task status toggles checked state without changing source length or selection', () => {
  let state = createState('- [ ] done', 6, 10)
  const from = 2
  const to = 5
  const check = toggleTaskStatus(state, from, to)
  assert.ok(check)
  state = state.update({ ...check, userEvent: 'input' }).state
  assert.equal(state.doc.toString(), '- [x] done')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'done')

  const uncheck = toggleTaskStatus(state, from, to)
  assert.ok(uncheck)
  state = state.update({ ...uncheck, userEvent: 'input' }).state
  assert.equal(state.doc.toString(), '- [ ] done')
  assert.equal(state.sliceDoc(state.selection.main.from, state.selection.main.to), 'done')
})
