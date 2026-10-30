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

test('source block rendering keeps reference links and image blocks intact', () => {
  const markdown = '![图](images/sample.png)\n\n[外链][source]\n\n[source]: https://example.com'
  const result = renderMarkdownWithSourceBlocks(markdown)

  assert.equal(stripSourceBlocks(result.html), marked.parse(markdown))
  assert.match(result.html, /<img src="images\/sample\.png" alt="图">/)
  assert.match(result.html, /<a href="https:\/\/example\.com">外链<\/a>/)
  assert.equal(result.blocks.length, 2)
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
