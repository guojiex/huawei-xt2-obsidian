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

test('unknown colon containers use one read-only source range, including split inner Markdown tokens', () => {
  const source = '前文\n\n:::custom\n# 内部标题\n\n[链接](https://example.test)\n:::\n\n后文'
  const result = renderMarkdownWithSourceBlocks(source)
  const directive = result.blocks.find(({ type }) => type === 'directive')

  assert.ok(directive)
  assert.equal(source.slice(directive.sourceStart, directive.sourceEnd),
    ':::custom\n# 内部标题\n\n[链接](https://example.test)\n:::')
  assert.equal(directive.inlineSafe, false)
  assert.deepEqual(directive.inlineItems, [])
  assert.equal(result.blocks.filter(({ type }) => type === 'directive').length, 1)
  assert.equal(stripSourceBlocks(result.html), marked.parse(source))
  assert.deepEqual(result.blocks.filter(({ type }) => type === 'paragraph')
    .map((block) => source.slice(block.sourceStart, block.sourceEnd)), ['前文', '后文'])
})

test('unknown colon ranges handle nesting, fenced examples, CRLF, and unclosed blocks', () => {
  const source = ':::outer\r\n:::inner\r\n# 标题\r\n:::\r\n```md\r\n:::\r\n```\r\n$$\r\n:::\r\n$$\r\n:::\r\n\r\n后文'
  const result = renderMarkdownWithSourceBlocks(source)
  const directive = result.blocks.find(({ type }) => type === 'directive')
  const closeEnd = source.lastIndexOf('\r\n:::\r\n\r\n后文') + '\r\n:::'.length

  assert.equal(source.slice(directive.sourceStart, directive.sourceEnd), source.slice(0, closeEnd))
  assert.equal(result.blocks.filter(({ type }) => type === 'directive').length, 1)
  assert.equal(stripSourceBlocks(result.html), marked.parse(source))

  const code = '```md\n:::sample\n# 不应识别为容器\n:::\n```\n'
  assert.equal(renderMarkdownWithSourceBlocks(code).blocks.some(({ type }) => type === 'directive'), false)

  const unclosed = '前文\n\n:::unknown\n# 保留至文末'
  const unclosedResult = renderMarkdownWithSourceBlocks(unclosed)
  const unclosedBlock = unclosedResult.blocks.find(({ type }) => type === 'directive')
  assert.equal(unclosed.slice(unclosedBlock.sourceStart, unclosedBlock.sourceEnd),
    ':::unknown\n# 保留至文末')
})

test('block formulas carry a formula anchor and exact source range', () => {
  const source = '$$\r\nx + y\r\n$$\r\n'
  const result = renderMarkdownWithSourceBlocks(source)

  assert.equal(result.blocks[0].type, 'formula')
  assert.equal(source.slice(result.blocks[0].sourceStart, result.blocks[0].sourceEnd), source)
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

test('21.4 footnote references and definitions map to exact CRLF source ranges', () => {
  const source = 'Before [^note] after.\r\n\r\n[^note]: first\r\n  second\r\n\r\nAfter.'
  const result = renderMarkdownWithSourceBlocks(source)
  const paragraph = result.blocks[0]
  const definition = result.blocks[1]
  const reference = paragraph.inlineItems[0]

  assert.equal(paragraph.inlineSafe, true)
  assert.equal(reference.type, 'footnoteRef')
  assert.equal(source.slice(reference.from, reference.to), '[^note]')
  assert.equal(definition.type, 'footnoteDefinition')
  assert.equal(source.slice(definition.sourceStart, definition.sourceEnd),
    '[^note]: first\r\n  second\r\n')
  assert.equal(source.slice(definition.sourceEnd).startsWith('\r\nAfter.'), true)
  assert.match(result.html, /data-footnote-reference="note"/)
  assert.match(result.html, /data-footnote-label="note"/)
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

test('21.4 missing and escaped footnote references render without unsafe labels', () => {
  const source = String.raw`Missing [^<unsafe>] and escaped \[^literal].`
  const paragraph = renderMarkdownWithSourceBlocks(source).blocks[0]

  assert.equal(paragraph.inlineSafe, true)
  assert.deepEqual(paragraph.inlineItems.map((item) => source.slice(item.from, item.to)), ['[^<unsafe>]'])
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

test('HTML blocks remain an explicit source-mapped read-only type', () => {
  const source = '<section>\n<p>HTML 内容</p>\n</section>'
  const result = renderMarkdownWithSourceBlocks(source)

  assert.equal(result.blocks[0].type, 'html')
  assert.equal(source.slice(result.blocks[0].sourceStart, result.blocks[0].sourceEnd), source)
})

test('20.4 rejects unsupported link forms before exposing inline source ranges', () => {
  const cases = [
    '引用 [文本][ref]\n\n[ref]: https://example.test',
    '[外[内](https://inner.test)](https://outer.test)',
    '[外层 [内层]](https://outer.test)',
    '[有标题](https://example.test "title")',
    '[含空格](https://example.test/a b)',
    '[含括号](https://example.test/a(b))',
    '[![图片](images/a.png)](https://example.test)',
    '![含[链接](https://example.test)](images/a.png)',
    '[有空格](<path with space>)'
  ]

  for (const source of cases) {
    const paragraph = renderMarkdownWithSourceBlocks(source).blocks[0]
    assert.equal(paragraph.inlineSafe, false, source)
    assert.deepEqual(paragraph.inlineItems, [], source)
  }
})

test('20.4 keeps escaped parentheses and encoded spaces eligible for exact mapping', () => {
  const source = String.raw`[括号](docs/a\(b\)) 与 [编码空格](docs/a%20b)`
  const paragraph = renderMarkdownWithSourceBlocks(source).blocks[0]

  assert.equal(paragraph.inlineSafe, true)
  assert.deepEqual(paragraph.inlineItems.map((item) => source.slice(item.from, item.to)), [
    String.raw`[括号](docs/a\(b\))`,
    '[编码空格](docs/a%20b)'
  ])
})

test('21.5 hides the trailing block ID in HTML but keeps the full source range for copy-block-link', () => {
  const source = '# 基础排版\n\n正文可以包含 **粗体** 和 `行内代码`。 ^demo-paragraph\n\n后文'
  const result = renderMarkdownWithSourceBlocks(source, 3)
  const paragraph = result.blocks.find((block) => block.type === 'paragraph')

  assert.match(result.html, /<p data-block-id="demo-paragraph">/)
  assert.doesNotMatch(result.html, /\^demo-paragraph/)
  assert.equal(source.slice(paragraph.sourceStart, paragraph.sourceEnd),
    '正文可以包含 **粗体** 和 `行内代码`。 ^demo-paragraph')
  assert.deepEqual([paragraph.startLine, paragraph.endLine], [6, 6])
  // 带块 ID 的段落沿用现有只读保护，不产生可点选的内联项
  assert.equal(paragraph.inlineSafe, false)
  assert.deepEqual(paragraph.inlineItems, [])
  // 其余段落的渲染完全不变
  assert.match(result.html, /<p>后文<\/p>/)
})

test('21.5 source mapping keeps CRLF source and line ranges intact while hiding the block ID', () => {
  const source = '标题\r\n\r\n正文 ^note_1\r\n\r\n末行'
  const result = renderMarkdownWithSourceBlocks(source)
  const paragraph = result.blocks.find((block) => source.slice(block.sourceStart, block.sourceEnd) === '正文 ^note_1')

  assert.ok(paragraph)
  assert.match(result.html, /<p data-block-id="note_1">正文<\/p>/)
  assert.doesNotMatch(result.html, /\^note_1/)
  assert.equal(source.slice(paragraph.sourceStart, paragraph.sourceEnd), '正文 ^note_1')
  assert.deepEqual([paragraph.startLine, paragraph.endLine], [3, 3])
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

test('列表内的链接与行内代码暴露精确 source 区间，可逐项编辑', () => {
  const source = '- 苹果 [官网](https://a.test) 与 `code`\n- 香蕉 ![图](images/b.png)\n'
  const result = renderMarkdownWithSourceBlocks(source)
  const list = result.blocks[0]

  assert.equal(list.type, 'list')
  assert.equal(list.inlineSafe, true)
  assert.deepEqual(list.inlineItems.map((item) => item.type), ['link', 'inlinecode', 'image'])
  assert.deepEqual(list.inlineItems.map((item) => source.slice(item.from, item.to)), [
    '[官网](https://a.test)',
    '`code`',
    '![图](images/b.png)'
  ])
})

test('有序列表与任务列表内行内项同样映射到精确 source 区间', () => {
  const ordered = '1. 第一 [a](https://a.test)\n2. 第二 `x`\n'
  const listBlock = renderMarkdownWithSourceBlocks(ordered).blocks[0]
  assert.equal(listBlock.inlineSafe, true)
  assert.deepEqual(listBlock.inlineItems.map((item) => ordered.slice(item.from, item.to)),
    ['[a](https://a.test)', '`x`'])

  const task = '- [ ] 待办 [链接](https://a.test)\n- [x] 完成 `代码`\n'
  const taskBlock = renderMarkdownWithSourceBlocks(task).blocks[0]
  assert.equal(taskBlock.inlineSafe, true)
  assert.deepEqual(taskBlock.inlineItems.map((item) => task.slice(item.from, item.to)),
    ['[链接](https://a.test)', '`代码`'])
})

test('列表行内项跨 CRLF 与 BOM 仍精确映射', () => {
  const source = '\uFEFF- 首行 [a](https://a.test)\r\n- 次行 `code`\r\n'
  const body = source.slice(1)
  const result = renderMarkdownWithSourceBlocks(body, 0, 1)
  const list = result.blocks[0]

  assert.equal(list.inlineSafe, true)
  assert.deepEqual(list.inlineItems.map((item) => source.slice(item.from, item.to)),
    ['[a](https://a.test)', '`code`'])
})

test('含双链或高亮的列表保持整块只读，不暴露部分行内项', () => {
  const wiki = renderMarkdownWithSourceBlocks('- [[另一篇]] 与 [链接](https://a.test)\n').blocks[0]
  assert.equal(wiki.inlineSafe, false)
  assert.deepEqual(wiki.inlineItems, [])

  const mark = renderMarkdownWithSourceBlocks('- ==高亮== 与 `code`\n').blocks[0]
  assert.equal(mark.inlineSafe, false)
  assert.deepEqual(mark.inlineItems, [])
})
