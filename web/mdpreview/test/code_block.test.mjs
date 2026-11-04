import assert from 'node:assert/strict'
import test from 'node:test'
import {
  COMMON_CODE_LANGUAGES,
  inspectCodeFence,
  prepareCodeBodyEdit,
  prepareCodeLanguageEdit,
  prepareInlineCodeUnwrap
} from '../src/codeBlock.mjs'

test('recognizes fenced code with BOM, tilde fences, and CRLF source', () => {
  const raw = '\uFEFF~~~python\r\nprint("你好")\r\n~~~'
  const model = inspectCodeFence(raw, 'print("你好")')

  assert.equal(model.editable, true)
  assert.equal(model.language, 'python')
  assert.equal(model.logicalBody, 'print("你好")')
  assert.equal(raw.slice(model.languageFrom, model.languageTo), 'python')
})

test('protects indented, unclosed, nested, and rendered-text-mismatched fences', () => {
  assert.equal(inspectCodeFence(' ```js\nx\n ```', 'x').reason, 'indented')
  assert.equal(inspectCodeFence('```js\nx', 'x').reason, 'unclosed')
  assert.equal(inspectCodeFence('```\nx\n~~~\ny\n~~~\n```', 'x\n~~~\ny\n~~~').reason, 'nested')
  assert.equal(inspectCodeFence('```js\nsource\n```', 'changed').reason, 'unmapped')
  assert.equal(inspectCodeFence('```js\nsource\n```', 'source\n').editable, true)
})

test('body edits preserve both fences, CRLF, and all source outside the body range', () => {
  const prefix = 'before\r\n'
  const block = '~~~ts\r\nold\r\n~~~'
  const suffix = '\r\nafter'
  const source = prefix + block + suffix
  const edit = prepareCodeBodyEdit(source, prefix.length, prefix.length + block.length, 'new\nline')

  assert.deepEqual(edit, {
    from: prefix.length + '~~~ts\r\n'.length,
    to: prefix.length + '~~~ts\r\nold'.length,
    expected: 'old',
    replacement: 'new\r\nline',
    kind: 'code-body'
  })
  const after = source.slice(0, edit.from) + edit.replacement + source.slice(edit.to)
  assert.equal(after.slice(0, edit.from), source.slice(0, edit.from))
  assert.equal(after.slice(edit.from + edit.replacement.length), source.slice(edit.to))
  assert.ok(after.includes('~~~ts\r\nnew\r\nline\r\n~~~'))
})

test('the first input into an empty code body is an exact zero-length insertion', () => {
  const source = '```js\n```\nafter'
  const edit = prepareCodeBodyEdit(source, 0, '```js\n```'.length, 'hello')

  assert.equal(edit.from, '```js\n'.length)
  assert.equal(edit.to, edit.from)
  assert.equal(edit.expected, '')
  assert.equal(edit.replacement, 'hello\n')
  assert.equal(source.slice(0, edit.from) + edit.replacement + source.slice(edit.to), '```js\nhello\n```\nafter')
})

test('successive code input returns only the changed character range', () => {
  const firstSource = '```js\n```\nafter'
  const first = prepareCodeBodyEdit(firstSource, 0, '```js\n```'.length, 'a')
  const afterFirst = firstSource.slice(0, first.from) + first.replacement + firstSource.slice(first.to)
  const second = prepareCodeBodyEdit(afterFirst, 0, afterFirst.indexOf('\nafter'), 'ab')

  assert.deepEqual(first, {
    from: 6, to: 6, expected: '', replacement: 'a\n', kind: 'code-body'
  })
  assert.deepEqual(second, {
    from: 7, to: 7, expected: '', replacement: 'b', kind: 'code-body'
  })
})

test('body edits reject any fence-like line that would make the block unsafe', () => {
  const source = '```js\nx\n```'
  const to = source.length
  assert.equal(prepareCodeBodyEdit(source, 0, to, 'x\n~~~\ny'), null)
  assert.equal(prepareCodeBodyEdit(source, 0, to, 'x\n```\ny'), null)
})

test('body edits preserve Markdown-looking symbols, tabs, blank lines, and literal CRLF text', () => {
  const source = '```text\nold\n```\nafter'
  const replacement = '* # heading\n\tindented\n\nlast'
  const edit = prepareCodeBodyEdit(source, 0, source.indexOf('\nafter'), replacement)
  const after = source.slice(0, edit.from) + edit.replacement + source.slice(edit.to)

  assert.equal(after, '```text\n* # heading\n\tindented\n\nlast\n```\nafter')
  assert.ok(edit.replacement.includes('\tindented'))
})

test('language changes touch only a known language marker, including plain-text insertion', () => {
  assert.equal(COMMON_CODE_LANGUAGES.length, 19)
  const source = '```ts extra\nx\n```'
  assert.equal(prepareCodeLanguageEdit(source, 0, source.length, 'python'), null)
  assert.equal(prepareCodeLanguageEdit('```ts\nx\n```', 0, '```ts\nx\n```'.length, 'python'), null)

  const simple = '```typescript\nx\n```'
  const change = prepareCodeLanguageEdit(simple, 0, simple.length, 'python')
  assert.deepEqual(change, {
    from: 3,
    to: 13,
    expected: 'typescript',
    replacement: 'python',
    kind: 'code-language'
  })
  const plain = '```\nx\n```'
  const addLanguage = prepareCodeLanguageEdit(plain, 0, plain.length, 'typescript')
  assert.deepEqual(addLanguage, {
    from: 3,
    to: 3,
    expected: '',
    replacement: 'typescript',
    kind: 'code-language'
  })
})

test('inline-code unwrapping removes only the matching backtick runs', () => {
  const source = 'before ``a`b`` after'
  const from = source.indexOf('``')
  const to = source.indexOf(' after')
  const edit = prepareInlineCodeUnwrap(source, from, to)

  assert.deepEqual(edit, {
    from,
    to,
    expected: '``a`b``',
    replacement: 'a`b',
    kind: 'inline-code'
  })
  assert.equal(source.slice(0, from) + edit.replacement + source.slice(to), 'before a`b after')
  assert.equal(prepareInlineCodeUnwrap('`unclosed', 0, 9), null)
})
