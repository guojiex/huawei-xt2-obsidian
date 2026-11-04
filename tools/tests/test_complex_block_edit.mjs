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
