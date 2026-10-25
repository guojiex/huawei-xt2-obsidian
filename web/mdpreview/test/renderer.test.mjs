import assert from 'node:assert/strict'
import test from 'node:test'
import { renderMarkdown, resolveVaultImagePath } from '../src/renderer.mjs'

test('renders headings, ordered and unordered lists, and blockquotes', () => {
  const html = renderMarkdown('# 标题\n\n- 无序项\n\n1. 有序项\n\n> 引用内容')

  assert.match(html, /<h1>标题<\/h1>/)
  assert.match(html, /<ul>[\s\S]*?<li>无序项<\/li>[\s\S]*?<\/ul>/)
  assert.match(html, /<ol>[\s\S]*?<li>有序项<\/li>[\s\S]*?<\/ol>/)
  assert.match(html, /<blockquote>[\s\S]*?引用内容[\s\S]*?<\/blockquote>/)
})

test('renders GFM tables and fenced code blocks', () => {
  const html = renderMarkdown('| 名称 | 值 |\n| --- | --- |\n| 条目 | 3 |\n\n```ts\nconst answer = 42\n```')

  assert.match(html, /<table>[\s\S]*?<th>名称<\/th>[\s\S]*?<td>条目<\/td>[\s\S]*?<\/table>/)
  assert.match(html, /<pre><code class="language-ts">const answer = 42\n<\/code><\/pre>/)
})

test('renders GFM task lists and inline emphasis', () => {
  const html = renderMarkdown('- [x] 已完成\n- [ ] 待处理\n\n**粗体** *斜体* ~~删除线~~')

  assert.match(html, /type="checkbox"/)
  assert.match(html, /<strong>粗体<\/strong>/)
  assert.match(html, /<em>斜体<\/em>/)
  assert.match(html, /<del>删除线<\/del>/)
})

test('renders image syntax with its source and alternative text', () => {
  const html = renderMarkdown('![示例图片](assets/example.png)')

  assert.match(html, /<img src="assets\/example\.png" alt="示例图片">/)
})

test('resolves URL-encoded Unicode image paths relative to the note directory', () => {
  assert.equal(
    resolveVaultImagePath('10_写作', '../50_Assets/%E7%AC%94%E8%AE%B0%E6%B5%81%E7%A8%8B.svg'),
    '50_Assets/笔记流程.svg'
  )
})
