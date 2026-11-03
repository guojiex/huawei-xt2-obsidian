import assert from 'node:assert/strict'
import test from 'node:test'
import { marked } from 'marked'
import { renderMarkdownWithSourceBlocks, sourcePositionForLine, sourceScrollTop } from '../src/sourceMapping.mjs'

marked.setOptions({ gfm: true, breaks: false })

function stripSourceBlocks(html) {
  return html
    .replace(/<div class="preview-source-block" data-source-start-line="\d+" data-source-end-line="\d+">/g, '')
    .replace(/<\/div>/g, '')
}

test('source blocks preserve marked output and carry original line ranges', () => {
  const markdown = '# 相同标题\n\n第一段\n续行\n\n# 相同标题\n\n- 列表一\n- 列表二\n\n```ts\nconst value = 1\n```\n\n| 列 | 值 |\n| --- | --- |\n| A | B |'
  const result = renderMarkdownWithSourceBlocks(markdown, 3)

  assert.equal(stripSourceBlocks(result.html), marked.parse(markdown))
  assert.deepEqual(result.blocks.map(({ startLine, endLine }) => [startLine, endLine]), [
    [4, 4], [6, 7], [9, 9], [11, 12], [14, 16], [18, 20]
  ])
  assert.equal((result.html.match(/class="preview-source-block"/g) ?? []).length, 6)
})

test('callout tokens preserve their full source line range and render through source wrappers', () => {
  const markdown = '# 标题\n\n> [!tip]- 标题\n> 第一行\n> 第二行\n\n> 普通引用'
  const result = renderMarkdownWithSourceBlocks(markdown)

  assert.deepEqual(result.blocks.map(({ startLine, endLine }) => [startLine, endLine]), [[1, 1], [3, 5], [7, 7]])
  assert.match(result.html, /data-callout="tip"/)
  assert.match(result.html, /class="callout-title">[\s\S]*?<span>标题<\/span>/)
  assert.match(result.html, /<blockquote>[\s\S]*?普通引用[\s\S]*?<\/blockquote>/)
  assert.equal(result.blocks.length, marked.lexer(markdown).filter(({ type }) => type !== 'space').length)
})

test('source block rendering keeps reference links and image blocks intact', () => {
  const markdown = '![图](images/sample.png)\n\n[外链][source]\n\n[source]: https://example.com'
  const result = renderMarkdownWithSourceBlocks(markdown)

  assert.equal(stripSourceBlocks(result.html), marked.parse(markdown))
  assert.match(result.html, /<img src="images\/sample\.png" alt="图">/)
  assert.match(result.html, /<a href="https:\/\/example\.com">外链<\/a>/)
  assert.equal(result.blocks.length, 2)
})

test('paragraph inline items keep distinct source ranges across CRLF and nested formatting', () => {
  const source = '\uFEFF---\r\ntitle: 保持\r\n---\r\n\r\n首行 **[同名](https://a.test)** 与 ' +
    '[同名](https://b.test) `code` $x$ ![图](images/a.png)\r\n'
  const body = source.slice(source.indexOf('首行'))
  const rendered = renderMarkdownWithSourceBlocks(body, 3, source.length - body.length)
  const paragraph = rendered.blocks[0]

  assert.equal(paragraph.inlineSafe, true)
  assert.deepEqual(paragraph.inlineItems.map((item) => item.type),
    ['link', 'link', 'inlinecode', 'mathInline', 'image'])
  assert.deepEqual(paragraph.inlineItems.map((item) => source.slice(item.from, item.to)), [
    '[同名](https://a.test)',
    '[同名](https://b.test)',
    '`code`',
    '$x$',
    '![图](images/a.png)'
  ])
})

test('escaped Markdown syntax stays plain text while nested repeated links map exactly', () => {
  const source = '转义的 \\[方括号\\] 与 \\[[不是双链\\]\\]，**[重复](https://first.test)** 和 ' +
    '[重复](https://second.test)，\\`不是代码\\`，还有 `code`'
  const paragraph = renderMarkdownWithSourceBlocks(source).blocks[0]

  assert.equal(paragraph.inlineSafe, true)
  assert.deepEqual(paragraph.inlineItems.map((item) => source.slice(item.from, item.to)), [
    '[重复](https://first.test)',
    '[重复](https://second.test)',
    '`code`'
  ])
})

test('wiki-link display edits map an inline item back to the exact source range', () => {
  const source = '前文 [[Target|显示名]] 后文'
  const original = '[[Target|显示名]]'
  const sourceStart = source.indexOf(original)
  const displayLink = '[显示名](#wikilink:opaque)'
  const display = source.slice(0, sourceStart) + displayLink + source.slice(sourceStart + original.length)
  const result = renderMarkdownWithSourceBlocks(display, 0, 0, [{
    displayStart: sourceStart,
    displayEnd: sourceStart + displayLink.length,
    sourceStart,
    sourceEnd: sourceStart + original.length
  }])
  const item = result.blocks[0].inlineItems[0]

  assert.equal(item.type, 'link')
  assert.equal(source.slice(item.from, item.to), original)
})

test('paragraphs containing unsupported inline syntax do not expose a partial item list', () => {
  const result = renderMarkdownWithSourceBlocks('已支持 [链接](https://example.com) 和 ==高亮==')
  assert.equal(result.blocks[0].inlineSafe, false)
  assert.deepEqual(result.blocks[0].inlineItems, [])
})

test('source line lookup disambiguates repeated headings and chooses the nearest block for blank lines', () => {
  const blocks = [
    { startLine: 2, endLine: 2 },
    { startLine: 5, endLine: 6 },
    { startLine: 9, endLine: 9 }
  ]

  assert.deepEqual(sourcePositionForLine(blocks, 5), { index: 1, progress: 0 })
  assert.deepEqual(sourcePositionForLine(blocks, 4), { index: 1, progress: 0 })
  assert.deepEqual(sourcePositionForLine(blocks, 3), { index: 0, progress: 1 })
  assert.deepEqual(sourcePositionForLine(blocks, 100), { index: 2, progress: 1 })
  assert.equal(sourcePositionForLine([], 1), null)
})

test('source scroll target honors block progress, viewport placement, and document boundaries', () => {
  const blocks = [
    { startLine: 4, endLine: 5, top: 100, height: 80 },
    { startLine: 8, endLine: 8, top: 260, height: 40 }
  ]

  assert.equal(sourceScrollTop(blocks, 4, 0.5, 0.25, 100, 400), 95)
  assert.equal(sourceScrollTop(blocks, 4, 0, 0, 100, 400, true, false), 0)
  assert.equal(sourceScrollTop(blocks, 8, 1, 1, 100, 400, false, true), 400)
  assert.equal(sourceScrollTop([], 1, 0, 0, 100, 400), 0)
})
