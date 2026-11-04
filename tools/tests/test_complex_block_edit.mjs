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
