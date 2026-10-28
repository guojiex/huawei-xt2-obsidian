import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  stdin: {
    contents: `
      import { EditorState } from '@codemirror/state'
      import { markdown } from '@codemirror/lang-markdown'
      import { hasCodeBlockSelection, normalizeEditorText, serializeEditorText, toggleCodeBlock } from '../src/codeBlockFormat.ts'
      export { EditorState, hasCodeBlockSelection, normalizeEditorText, serializeEditorText, toggleCodeBlock }
      export function createState(doc, from = 0, to = from) {
        return EditorState.create({ doc, selection: { anchor: from, head: to }, extensions: [markdown()] })
      }
    `,
    resolveDir: here,
    sourcefile: 'code_block_test_entry.ts',
    loader: 'ts'
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const codeBlock = await import(
  `data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`
)

function applyCodeBlockChange(state) {
  return state.update(codeBlock.toggleCodeBlock(state)).state
}

test('recognizes a cursor, body selection, partial fence, and whole fence in one code block', () => {
  const source = '```js\n包含内容\n```'
  const body = source.indexOf('包含')
  const closingFence = source.lastIndexOf('```')
  for (const [from, to] of [
    [body + 1, body + 1],
    [body, body + 2],
    [0, 3],
    [0, source.length]
  ]) {
    assert.equal(codeBlock.hasCodeBlockSelection(codeBlock.createState(source, from, to)), true)
  }
})

test('does not mark a selection spanning a code block and adjacent prose', () => {
  const source = '```\n代码\n```\n后文'
  assert.equal(codeBlock.hasCodeBlockSelection(codeBlock.createState(source, 4, source.length)), false)
})

test('removes only the selected fenced block and preserves adjacent paragraphs and blank lines', () => {
  const source = '前文\n\n```js\n包含\n下一行\n```\n\n后文'
  const body = source.indexOf('包含')
  const state = codeBlock.createState(source, body + 1, body + '包含\n下一行'.length)
  const changed = applyCodeBlockChange(state)
  assert.equal(changed.doc.toString(), '前文\n\n包含\n下一行\n\n后文')
  assert.equal(changed.sliceDoc(changed.selection.main.from, changed.selection.main.to), '包含\n下一行')
})

test('wraps ordinary text and toggles it back without stacking fences', () => {
  const source = '前文\n选中内容\n后文'
  const from = source.indexOf('选中')
  const state = codeBlock.createState(source, from, from + '选中内容'.length)
  const wrapped = applyCodeBlockChange(state)
  assert.equal(wrapped.doc.toString(), '前文\n```\n选中内容\n```\n后文')
  assert.equal(codeBlock.hasCodeBlockSelection(wrapped), true)
  const unwrapped = applyCodeBlockChange(wrapped)
  assert.equal(unwrapped.doc.toString(), source)
})

test('uses a longer backtick fence when the body contains a backtick run', () => {
  const source = 'const marker = "```"'
  const wrapped = applyCodeBlockChange(codeBlock.createState(source, 0, source.length))
  assert.equal(wrapped.doc.toString(), '````\nconst marker = "```"\n````')
  assert.equal(codeBlock.hasCodeBlockSelection(wrapped), true)
  assert.equal(applyCodeBlockChange(wrapped).doc.toString(), source)
})

test('recognizes and removes a tilde fence with its language marker', () => {
  const source = '~~~ts\nconst x = 1\n~~~'
  const body = source.indexOf('const')
  const state = codeBlock.createState(source, body, body + 5)
  assert.equal(codeBlock.hasCodeBlockSelection(state), true)
  assert.equal(applyCodeBlockChange(state).doc.toString(), 'const x = 1')
})

test('removes the start marker from an unclosed fenced block without adding a closing fence', () => {
  const source = '前文\n```ts\n代码\n更多代码'
  const body = source.indexOf('代码')
  const state = codeBlock.createState(source, body, body + 2)
  assert.equal(codeBlock.hasCodeBlockSelection(state), true)
  assert.equal(applyCodeBlockChange(state).doc.toString(), '前文\n代码\n更多代码')
})

test('preserves CRLF through editor normalization, code block removal, and serialization', () => {
  const source = '前文\r\n\r\n```js\r\nA\r\n\r\n```\r\n\r\n后文'
  const normalized = codeBlock.normalizeEditorText(source)
  assert.equal(normalized.lineEnding, '\r\n')
  const body = normalized.text.indexOf('A')
  const state = codeBlock.createState(normalized.text, body, body + 1)
  const changed = applyCodeBlockChange(state)
  assert.equal(changed.doc.toString(), '前文\n\nA\n\n\n后文')
  assert.equal(codeBlock.serializeEditorText(changed.doc.toString(), normalized.lineEnding),
    '前文\r\n\r\nA\r\n\r\n\r\n后文')
})

test('normal text with no selection uses the existing placeholder', () => {
  const state = codeBlock.createState('')
  assert.equal(applyCodeBlockChange(state).doc.toString(), '```\n代码\n```')
})
