import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'
import vm from 'node:vm'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const source = fs.readFileSync(new URL(
  'entry/src/main/ets/model/MarkdownComplexBlockEdit.ets', root), 'utf8')
const compiled = transformSync(source, { loader: 'ts', format: 'cjs' }).code
const module = { exports: {} }
vm.runInNewContext(compiled, { module, exports: module.exports })
const { MarkdownComplexBlockEdit } = module.exports

test('21.1 inline formula edits preserve delimiters and reject nested dollar delimiters', () => {
  const model = MarkdownComplexBlockEdit.parseFormula('$x + y$', true)
  assert.ok(model)
  assert.equal(MarkdownComplexBlockEdit.serializeFormula(model, 'x = y'), '$x = y$')
  assert.equal(MarkdownComplexBlockEdit.serializeFormula(model, 'x$y'), null)
  assert.equal(MarkdownComplexBlockEdit.parseFormula('$$x$$', true), null)
})

test('21.1 block formula edits preserve single-line and CRLF delimiters', () => {
  const single = MarkdownComplexBlockEdit.parseFormula('$$x + y$$', false)
  assert.ok(single)
  assert.equal(MarkdownComplexBlockEdit.serializeFormula(single, 'x = y'), '$$x = y$$')

  const multilineSource = '$$\r\nx + y\r\n$$\r\n'
  const multiline = MarkdownComplexBlockEdit.parseFormula(multilineSource, false)
  assert.ok(multiline)
  assert.equal(MarkdownComplexBlockEdit.serializeFormula(multiline, 'x = y'), '$$\r\nx = y\r\n$$\r\n')
})

test('21.1 formula edits reject empty source and malformed delimiters', () => {
  const model = MarkdownComplexBlockEdit.parseFormula('$$x$$', false)
  assert.ok(model)
  assert.equal(MarkdownComplexBlockEdit.serializeFormula(model, ' \n '), null)
  assert.equal(MarkdownComplexBlockEdit.parseFormula('$$x$', false), null)
})

test('21.1 native panel uses the bundled preview and exact block replacement path', () => {
  const index = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
  const preview = fs.readFileSync(new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8')

  assert.match(index, /FormulaPreviewWeb\(\{[\s\S]*?displayMode: !this\.blockPanelFormulaModel\?\.inline/)
  assert.match(index, /MarkdownComplexBlockEdit\.parseFormula\(raw, inline\)/)
  assert.match(index, /replaceBlockPanelInlineSource\(\s*this\.blockPanelFormulaRaw, replacement/)
  assert.match(preview, /\$rawfile\('mdpreview\/index\.html'\)/)
})

test('21.2 callout edits preserve body, aliases, title spacing, and CRLF', () => {
  const source = '> [!hint]-  Old title\r\n> body\r\n> second line\r\n'
  const model = MarkdownComplexBlockEdit.parseCallout(source)
  assert.ok(model)
  assert.equal(model.knownType, true)
  assert.equal(model.body, '> body\r\n> second line\r\n')
  assert.equal(
    MarkdownComplexBlockEdit.serializeCallout(model, 'title', 'New title'),
    '> [!hint]-  New title\r\n> body\r\n> second line\r\n'
  )
  assert.equal(
    MarkdownComplexBlockEdit.serializeCallout(model, 'type', 'warning'),
    '> [!warning]-  Old title\r\n> body\r\n> second line\r\n'
  )
  assert.equal(
    MarkdownComplexBlockEdit.serializeCallout(model, 'fold', '+'),
    '> [!hint]+  Old title\r\n> body\r\n> second line\r\n'
  )
})

test('21.2 known callout types and aliases are distinct from unknown types', () => {
  assert.deepEqual(Array.from(MarkdownComplexBlockEdit.calloutTypes()), [
    'note', 'abstract', 'info', 'todo', 'tip', 'success', 'question',
    'warning', 'failure', 'danger', 'bug', 'example', 'quote'
  ])
  assert.equal(MarkdownComplexBlockEdit.calloutLabels().length, 13)
  assert.equal(MarkdownComplexBlockEdit.parseCallout('> [!SUMMARY] Title')?.knownType, true)
  assert.equal(MarkdownComplexBlockEdit.parseCallout('> [!vendor_kind] Title')?.knownType, false)
  const unknown = MarkdownComplexBlockEdit.parseCallout('> [!vendor_kind]- Old\n> body')
  assert.ok(unknown)
  assert.equal(
    MarkdownComplexBlockEdit.serializeCallout(unknown, 'title', 'New'),
    '> [!vendor_kind]- New\n> body'
  )
  assert.equal(MarkdownComplexBlockEdit.serializeCallout(unknown, 'type', 'note'), null)
  assert.equal(MarkdownComplexBlockEdit.serializeCallout(unknown, 'fold', '+'), null)
})

test('21.2 callout parser rejects non-callouts and multiline panel values', () => {
  assert.equal(MarkdownComplexBlockEdit.parseCallout('> ordinary quote'), null)
  const model = MarkdownComplexBlockEdit.parseCallout('\uFEFF> [!note] Title\n> body')
  assert.ok(model)
  assert.equal(MarkdownComplexBlockEdit.serializeCallout(model, 'title', 'bad\nheader'), null)
  assert.equal(MarkdownComplexBlockEdit.serializeCallout(model, 'title', 'bad\rheader'), null)
})

test('21.2 native panel keeps unknown callout types and writes the exact source block', () => {
  const index = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
  assert.match(index, /anchor\.type === 'callout'[\s\S]*?loadBlockPanelCallout\(\)/)
  assert.match(index, /MarkdownComplexBlockEdit\.parseCallout\(raw\)/)
  assert.match(index, /this\.replaceBlockPanelInlineSource\(\s*this\.blockPanelCalloutRaw, replacement/)
  assert.match(index, /this\.blockPanelCalloutModel\.knownType/)
})

test('21.2 preview edits only safe callout bodies and preserves their header', () => {
  const preview = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
  assert.match(preview, /function canEditCalloutBody\(/)
  assert.match(preview, /calloutBody\.setAttribute\('data-simple-callout-editable', 'true'\)/)
  assert.match(preview, /serializeCalloutBody\(previous, serializeEditedBlock\(calloutBody\)\)/)
  assert.match(preview, /event\.target\.closest\('\[data-simple-callout-editable="true"\]'\)\) return/)
})

test('21.3 frontmatter edits preserve BOM, CRLF, comments, nested values, and the body', () => {
  const raw = '\uFEFF---\r\n' +
    'title: Old title  # keep comment\r\n' +
    'created: "2024-02-29"\r\n' +
    'published: false\r\n' +
    'tags:\r\n  - reading\r\n  - notes\r\n' +
    'nested:\r\n  path: unchanged\r\n' +
    '...\r\n'
  const model = MarkdownComplexBlockEdit.parseFrontmatter(raw)
  assert.ok(model)
  assert.deepEqual(Array.from(model.properties, (property) => [property.key, property.kind]), [
    ['title', 'text'],
    ['created', 'date'],
    ['published', 'bool'],
    ['tags', 'list'],
    ['nested', 'complex']
  ])

  const updatedTitle = MarkdownComplexBlockEdit.setFrontmatterProperty(raw, 'title', 'New: title')
  assert.ok(updatedTitle)
  assert.equal(updatedTitle, '\uFEFF---\r\n' +
    'title: "New: title"  # keep comment\r\n' +
    'created: "2024-02-29"\r\n' +
    'published: false\r\n' +
    'tags:\r\n  - reading\r\n  - notes\r\n' +
    'nested:\r\n  path: unchanged\r\n' +
    '...\r\n')

  const updatedTags = MarkdownComplexBlockEdit.setFrontmatterProperty(raw, 'tags', 'writing, work、notes')
  assert.ok(updatedTags)
  assert.ok(updatedTags.includes('tags:\r\n  - writing\r\n  - work\r\n  - notes\r\n'))
  assert.ok(updatedTags.includes('nested:\r\n  path: unchanged\r\n'))
  assert.equal(MarkdownComplexBlockEdit.setFrontmatterProperty(raw, 'created', '2023-02-29'), null)
})

test('21.3 adds and removes values while preserving unmodified frontmatter lines', () => {
  const raw = '---\r\n' +
    'title: Existing # inline\r\n' +
    '# keep this comment\r\n' +
    '\r\n' +
    'nested:\r\n  path: keep\r\n' +
    '# keep after nested\r\n' +
    '\r\n' +
    '---\r\n'
  const addedList = MarkdownComplexBlockEdit.addFrontmatterProperty(raw, 'aliases', 'one、two')
  assert.equal(addedList, '---\r\ntitle: Existing # inline\r\n# keep this comment\r\n\r\n' +
    'nested:\r\n  path: keep\r\n# keep after nested\r\n\r\n' +
    'aliases:\r\n  - one\r\n  - two\r\n---\r\n')
  const addedBool = MarkdownComplexBlockEdit.addFrontmatterProperty(addedList, 'published', 'true')
  assert.ok(addedBool?.includes('published: true\r\n'))
  assert.equal(MarkdownComplexBlockEdit.addFrontmatterProperty(addedList, 'title', 'duplicate'), null)

  const removed = MarkdownComplexBlockEdit.removeFrontmatterProperty(addedBool, 'nested')
  assert.ok(removed)
  assert.ok(!removed.includes('nested:'))
  assert.ok(!removed.includes('path: keep'))
  assert.ok(removed.includes('# keep this comment\r\n'))
  assert.ok(removed.includes('# keep after nested\r\n\r\n'))
  assert.equal(MarkdownComplexBlockEdit.removeFrontmatterProperty(raw, 'missing'), null)
})

test('21.3 malformed frontmatter is rejected for structured edits and panel source remains available', () => {
  assert.equal(MarkdownComplexBlockEdit.parseFrontmatter('---\ntitle: value\n'), null)
  assert.equal(MarkdownComplexBlockEdit.parseFrontmatter('---\ntitle value\n---\n'), null)
  assert.equal(MarkdownComplexBlockEdit.parseFrontmatter('---\ntitle: one\ntitle: two\n---\n'), null)
  assert.equal(
    MarkdownComplexBlockEdit.setFrontmatterProperty('---\ntitle: "unterminated\n---\n', 'title', 'safe'),
    null
  )

  const index = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
  const preview = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
  const renderer = fs.readFileSync(new URL('web/mdpreview/src/renderer.mjs', root), 'utf8')
  assert.match(renderer, /data-preview-frontmatter-entry/)
  assert.match(preview, /dataset\.sourceType = 'frontmatter'/)
  assert.match(index, /anchor\.type === 'frontmatter'[\s\S]*?loadBlockPanelFrontmatter\(\)/)
  assert.match(index, /anchor\.type !== 'frontmatter'\) \|\|/)
  assert.match(index, /this\.blockSourceActionLabel\(\)[\s\S]*?openBlockSourceDrawer\(\)/)
  assert.match(index, /Checkbox\(\{ name: entry\.key \}\)/)
  assert.match(index, /DatePicker\(\{[\s\S]*?onDateChange/)
})

test('21.4 footnote definitions parse, edit, and preserve CRLF continuation formatting', () => {
  const source = '[^note]: first line\r\n    second line\r\n'
  const model = MarkdownComplexBlockEdit.parseFootnoteDefinition(source)
  assert.ok(model)
  assert.equal(model.label, 'note')
  assert.equal(model.body, 'first line\n  second line')
  assert.equal(
    MarkdownComplexBlockEdit.serializeFootnoteDefinition(model, 'edited\n  continuation'),
    '[^note]: edited\r\n    continuation\r\n'
  )
  assert.equal(MarkdownComplexBlockEdit.parseFootnoteDefinition('[^note]: first\nnot continued'), null)
})

test('21.4 BOM and tab-indented footnote definitions retain their source formatting', () => {
  const source = '\uFEFF[^note]: first\n\tsecond\n'
  const definitions = MarkdownComplexBlockEdit.findFootnoteDefinitions(source, 'note')
  assert.equal(definitions.length, 1)
  const model = MarkdownComplexBlockEdit.parseFootnoteDefinition(definitions[0].source)
  assert.ok(model)
  assert.equal(model.body, 'first\nsecond')
  assert.equal(
    MarkdownComplexBlockEdit.serializeFootnoteDefinition(model, 'edited\ncontinued'),
    '\uFEFF[^note]: edited\n\tcontinued\n'
  )
})

test('21.4 footnote lookup ignores frontmatter, code, escaped references, and definitions', () => {
  const source = '\uFEFF---\nexample: "[^note]"\n---\n' +
    'Inline `[^note]` and escaped \\[^note].\n\n' +
    '```md\n[^note]\n[^note]: code\n```\n\n' +
    'Citation [^note].\n\n[^note]: definition\n'
  const definitions = MarkdownComplexBlockEdit.findFootnoteDefinitions(source, 'note')
  assert.equal(definitions.length, 1)
  assert.equal(source.slice(definitions[0].from, definitions[0].to), '[^note]: definition\n')
  const reference = MarkdownComplexBlockEdit.findFootnoteReference(source, 'note')
  assert.ok(reference)
  assert.equal(source.slice(reference.from, reference.to), '[^note]')
  assert.equal(source.slice(0, reference.from).endsWith('Citation '), true)
  assert.deepEqual(
    Array.from(MarkdownComplexBlockEdit.findFootnoteDefinitions(source, 'missing')),
    []
  )
  assert.equal(
    MarkdownComplexBlockEdit.createFootnoteDefinition('missing', 'body\nsecond line', '\r\n', '\r\n'),
    '[^missing]: body\r\n  second line\r\n'
  )
  assert.equal(MarkdownComplexBlockEdit.createFootnoteDefinition('missing', '  ', '\n', ''), null)
})

test('21.4 duplicate matching definitions are ambiguous, not missing', () => {
  const source = 'Citation [^note].\n\n[^note]: first\n\n[^note]: duplicate\n'
  const definitions = MarkdownComplexBlockEdit.findFootnoteDefinitions(source, 'note')
  assert.equal(definitions.length, 2)
  assert.ok(definitions.every((definition) => definition.label === 'note'))
})

test('21.4 new footnote definitions use the source line ending without a terminal newline', () => {
  assert.equal(MarkdownComplexBlockEdit.sourceLineEnding('正文\r\n引用'), '\r\n')
  assert.equal(MarkdownComplexBlockEdit.sourceLineEnding('正文\n引用'), '\n')
  assert.equal(MarkdownComplexBlockEdit.sourceLineEnding('正文'), '\n')
})

test('21.4 native panel wires footnote references, definitions, jumps, and guarded writes', () => {
  const index = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
  const preview = fs.readFileSync(new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8')
  const renderer = fs.readFileSync(new URL('web/mdpreview/src/renderer.mjs', root), 'utf8')
  const mapping = fs.readFileSync(new URL('web/mdpreview/src/sourceMapping.mjs', root), 'utf8')

  assert.match(index, /anchor\.tapType === 'footnoteRef'[\s\S]*?loadBlockPanelFootnote\(\)/)
  assert.match(index, /MarkdownComplexBlockEdit\.findFootnoteDefinitions/)
  assert.match(index, /MarkdownComplexBlockEdit\.findFootnoteReference/)
  assert.match(index, /MarkdownComplexBlockEdit\.createFootnoteDefinition/)
  assert.match(index, /definitions\.length > 1/)
  assert.match(index, /source !== this\.blockPanelFootnoteSourceSnapshot/)
  assert.match(index, /replaceBlockSource\(from, to, expectedSource, replacement, revision, 'input', false\)/)
  assert.match(index, /scrollToSourceLine\(target\)/)
  assert.match(index, /脚注正文/)
  assert.match(preview, /'footnoteRef'/)
  assert.match(renderer, /name: 'footnoteDefinition'/)
  assert.match(renderer, /name: 'footnoteRef'/)
  assert.match(mapping, /sourceRangeLength/)
})
