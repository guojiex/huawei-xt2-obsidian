import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'
import vm from 'node:vm'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const source = fs.readFileSync(new URL('entry/src/main/ets/model/MarkdownInlineParser.ets', root), 'utf8')
const code = transformSync(`${source}\nmodule.exports = MarkdownInlineParser;`, {
  loader: 'ts',
  format: 'cjs'
}).code
const context = vm.createContext({ module: { exports: {} } })
vm.runInContext(code, context)
const parser = context.module.exports

test('20.1 parses a standard inline link and edits only the selected field', () => {
  const source = '[文档](https://example.test/a)'
  const parts = parser.parseLink(source)

  assert.equal(parts.label, '文档')
  assert.equal(parts.destination, 'https://example.test/a')
  assert.equal(parser.replaceLabel(source, parts, '新 [标题]'), '[新 \\[标题\\]](https://example.test/a)')
  assert.equal(parser.replaceDestination(source, parts, 'https://example.test/b'), '[文档](https://example.test/b)')
  assert.equal(parser.replaceDestination(source, parts, 'example.test/page'), '[文档](example.test/page)')
})

test('20.1 retains escaped source and angle-bracket destinations', () => {
  const escaped = String.raw`[a\]b](https://example.test/a\(b\))`
  const escapedParts = parser.parseLink(escaped)
  assert.equal(escapedParts.label, 'a]b')
  assert.equal(escapedParts.destination, 'https://example.test/a(b)')
  assert.equal(parser.replaceLabel(escaped, escapedParts, '保持 (文字)'),
    String.raw`[保持 (文字)](https://example.test/a\(b\))`)

  const angled = '[图片](<attachments/a%20b.png>)'
  const angledParts = parser.parseLink(angled)
  assert.equal(angledParts.angleDestination, true)
  assert.equal(parser.replaceDestination(angled, angledParts, 'attachments/new.png'),
    '[图片](<attachments/new.png>)')
})

test('20.1 rejects reference, nested, titled and unsafe unescaped link forms', () => {
  for (const source of [
    '[文档][id]',
    '[outer [inner]](https://example.test)',
    '[文档](https://example.test "title")',
    '[文档](https://example.test/a b)',
    '[文档](https://example.test/a(b))'
  ]) {
    assert.equal(parser.parseLink(source), null, source)
  }
})

test('20.1 rejects blank or whitespace destinations without changing the source', () => {
  const source = '[文档](https://example.test)'
  const parts = parser.parseLink(source)
  assert.equal(parser.replaceDestination(source, parts, '  '), null)
  assert.equal(parser.replaceDestination(source, parts, 'https://example.test/a b'), null)
  assert.equal(source, '[文档](https://example.test)')
  assert.equal(parser.parseLink('[文档]()'), null)
  assert.equal(parser.parseLink('[文档](<>)'), null)
})
