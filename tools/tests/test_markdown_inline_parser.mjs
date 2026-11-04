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

test('20.3 parses image alt text, destination, and display width without changing surrounding source', () => {
  const source = '前文 ![日落|360](assets/sunset.png) 后文'
  const from = source.indexOf('![')
  const to = source.indexOf(')', from) + 1
  const image = source.slice(from, to)
  const parts = parser.parseImage(image)

  assert.equal(parts.alt, '日落')
  assert.equal(parts.destination, 'assets/sunset.png')
  assert.equal(parts.width, '360')
  assert.equal(
    source.slice(0, from) + parser.replaceImageAlt(image, parts, '新图') + source.slice(to),
    '前文 ![新图|360](assets/sunset.png) 后文'
  )
  assert.equal(parser.replaceImageWidth(image, parts, '480'), '![日落|480](assets/sunset.png)')
  assert.equal(parser.replaceImageWidth(image, parts, '120'), '![日落|120](assets/sunset.png)')
  assert.equal(parser.replaceImageDestination(image, parts, 'assets/new.png'),
    '![日落|360](assets/new.png)')
})

test('20.3 preserves escaped image delimiters and rejects empty or whitespace destinations', () => {
  const escaped = String.raw`![a\|b|240](https://example.test/a.png)`
  const parts = parser.parseImage(escaped)
  assert.equal(parts.alt, 'a|b')
  assert.equal(parts.width, '240')
  assert.equal(parser.replaceImageAlt(escaped, parts, '保留 [文字]'),
    String.raw`![保留 \[文字\]|240](https://example.test/a.png)`)

  const ordinaryPipe = String.raw`![a\|360](assets/a.png)`
  assert.equal(parser.parseImage(ordinaryPipe).width, '')
  assert.equal(parser.replaceImageWidth(escaped, parts, 'invalid'), null)
  assert.equal(parser.replaceImageDestination(escaped, parts, '  '), null)
  assert.equal(parser.replaceImageDestination(escaped, parts, 'https://example.test/a b'), null)
})

test('20.3 escapes literal pipes in edited alternative text', () => {
  const source = '![旧图|360](assets/image.png)'
  const parts = parser.parseImage(source)
  const edited = parser.replaceImageAlt(source, parts, '版本|360')
  const editedParts = parser.parseImage(edited)

  assert.equal(edited, String.raw`![版本\|360|360](assets/image.png)`)
  assert.equal(editedParts.alt, '版本|360')
  assert.equal(editedParts.width, '360')
})

test('20.3 reparses escaped brackets and pipes in image alternative text', () => {
  const source = String.raw`![保留 \[文字\]\|360|240](assets/image.png)`
  const parts = parser.parseImage(source)

  assert.equal(parts.alt, '保留 [文字]|360')
  assert.equal(parts.width, '240')
  assert.equal(
    parser.replaceImageAlt(source, parts, parts.alt),
    String.raw`![保留 \[文字\]\|360|240](assets/image.png)`
  )
})
