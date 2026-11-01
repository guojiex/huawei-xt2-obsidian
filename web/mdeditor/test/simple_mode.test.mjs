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
      import { collectSimpleModeRanges, allowsSimpleModeTransaction } from '../src/simpleMode.ts'
      export function inspect(source) {
        const state = EditorState.create({ doc: source, extensions: [markdown()] })
        return collectSimpleModeRanges(state)
      }
      export function changeAllowed(source, from, to, insert) {
        const state = EditorState.create({ doc: source, extensions: [markdown()] })
        const transaction = state.update({ changes: { from, to, insert } })
        return allowsSimpleModeTransaction(state, transaction)
      }
    `,
    resolveDir: here,
    sourcefile: 'simple_mode_harness.ts',
    loader: 'ts'
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const simpleMode = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`)

function assertProtectedText(source, expectedText) {
  const covered = simpleMode.inspect(source).protected.some((range) => {
    return range.from <= source.indexOf(expectedText) && range.to >= source.indexOf(expectedText) + expectedText.length
  })
  assert(covered, `expected protected Markdown source: ${expectedText}`)
}

test('simple mode keeps Markdown source positions while styling basic blocks', () => {
  const source = '# Heading\n\nText with **bold** and *italic*.\n- bullet\n1. ordered\n- [ ] todo\n> quote\n'
  const result = simpleMode.inspect(source)
  assert.deepEqual(result.protected, [])
  assert(result.decorations.some((range) => range.kind === 'heading-1'))
  assert(result.decorations.some((range) => range.kind === 'strong'))
  assert(result.decorations.some((range) => range.kind === 'emphasis'))
  assert(result.decorations.some((range) => range.kind === 'list-marker' && range.value === '•'))
  assert(result.decorations.some((range) => range.kind === 'list-marker' && range.value === '1.'))
  assert(result.decorations.some((range) => range.kind === 'task' && range.value === '☐'))
  assert(result.decorations.some((range) => range.kind === 'quote'))
})

test('frontmatter, code, links, tables, callouts and math are read-only with inline hints', () => {
  const source = '---\ntitle: demo\n---\nText [link](https://example.com)\n\n`code`\n\n```js\nconst x = 1\n```\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n> [!note] Title\n> body\n\n$$\nx = 1\n$$\n'
  const result = simpleMode.inspect(source)
  const protectedText = result.protected.map((range) => source.slice(range.from, range.to))
  assert(protectedText.some((text) => text.startsWith('---\ntitle: demo')))
  assert(protectedText.some((text) => text.includes('[link](https://example.com)')))
  assert(protectedText.some((text) => text.includes('`code`')))
  assert(protectedText.some((text) => text.includes('```js')))
  assert(protectedText.some((text) => text.includes('```mermaid')))
  assert(protectedText.some((text) => text.includes('| a | b |')))
  assert(protectedText.some((text) => text.includes('[!note]')))
  assert(protectedText.some((text) => text.includes('$$')))
  assert.equal(result.decorations.filter((range) => range.kind === 'protected-hint').length, result.protected.length)
})

test('simple mode blocks edits into protected source and permits neighboring paragraphs', () => {
  const source = 'Safe paragraph\n\n```js\nconst x = 1\n```\n\nAnother paragraph'
  const codeOffset = source.indexOf('const x')
  assert.equal(simpleMode.changeAllowed(source, 5, 5, 'x'), true)
  assert.equal(simpleMode.changeAllowed(source, codeOffset, codeOffset, 'x'), false)
  assert.equal(simpleMode.changeAllowed(source, 0, source.length, 'replacement'), false)
  const codeEnd = source.indexOf('```', codeOffset)
  assert.equal(simpleMode.changeAllowed(source, codeEnd + 3, codeEnd + 3, '!'), true)
})

test('task checkbox markers are not mistaken for reference links', () => {
  const source = '- [x] done\n- [X] uppercase\n- [ ] pending'
  const result = simpleMode.inspect(source)
  assert.deepEqual(result.protected, [])
  assert.deepEqual(result.decorations.filter((range) => range.kind === 'task').map((range) => range.value),
    ['☑', '☑', '☐'])
})

test('BOM frontmatter and inline math retain exact normalized source offsets', () => {
  const source = '\uFEFF---\ntitle: demo\n...\nText $x+y$ after'
  const result = simpleMode.inspect(source)
  const frontmatter = result.protected.find((range) => source.slice(range.from, range.to).includes('title: demo'))
  const math = result.protected.find((range) => source.slice(range.from, range.to) === '$x+y$')
  assert(frontmatter)
  assert.equal(source.slice(frontmatter.from, frontmatter.to), '\uFEFF---\ntitle: demo\n...\n')
  assert(math)
})

test('Obsidian wikilinks, embeds and reference definitions keep their complete Markdown source', () => {
  const source = '[[note#heading|alias]] and ![[assets/photo.png]]\n\n[ref][target]\n\n[target]: https://example.test/path "title"'
  for (const syntax of ['[[note#heading|alias]]', '![[assets/photo.png]]', '[ref][target]',
    '[target]: https://example.test/path "title"']) {
    assertProtectedText(source, syntax)
  }
  assert.equal(simpleMode.changeAllowed(source, 0, source.length, 'replacement'), false)
  assert.equal(simpleMode.changeAllowed(source, 0, 0, 'Safe prefix\n\n'), true)
})

test('Obsidian comments, highlight, strike, subscript, superscript, footnotes and block IDs are protected', () => {
  const source = 'Before %%private\ncomment%% after ==highlight== ~~strike~~ ~sub~ ^super^ [^note]\n\n[^note]: footnote text\n\nParagraph ^block-id'
  for (const syntax of ['%%private\ncomment%%', '==highlight==', '~~strike~~', '~sub~', '^super^', '[^note]',
    '[^note]: footnote text', '^block-id']) {
    assertProtectedText(source, syntax)
  }
})

test('single-line double-dollar math protects both delimiters and directive blocks fail closed', () => {
  const math = 'Before $$x + y$$ after'
  assertProtectedText(math, '$$x + y$$')

  const directive = 'Before\n:::unknown-block\ncontent with **syntax**\n  :::nested\ninner\n  :::\nafter nested\n:::\nAfter'
  assertProtectedText(directive, ':::unknown-block\ncontent with **syntax**\n  :::nested\ninner\n  :::\nafter nested\n:::')
  const unclosed = 'Editable paragraph\n\n:::unknown-block\nkeep all remaining source'
  assertProtectedText(unclosed, ':::unknown-block\nkeep all remaining source')
  assert.equal(simpleMode.changeAllowed(directive, 0, directive.length, 'replacement'), false)
  assert.equal(simpleMode.changeAllowed(directive, 0, 0, 'Prefix\n\n'), true)

  const codeExample = '```md\n:::snippet\n%% unmatched marker\n```\n\nEditable paragraph'
  const editableOffset = codeExample.indexOf('Editable paragraph')
  assert.equal(simpleMode.changeAllowed(codeExample, editableOffset, editableOffset, '!'), true)
})
