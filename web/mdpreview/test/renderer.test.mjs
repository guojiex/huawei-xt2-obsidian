import assert from 'node:assert/strict'
import test from 'node:test'
import {
  frontmatterTags,
  renderMarkdown,
  renderNoteTags,
  resolveVaultImagePath,
  shareCaptureBottomPadding,
  splitFrontmatter,
  validateMermaidSource
} from '../src/renderer.mjs'

test('renders headings, ordered and unordered lists, and blockquotes', () => {
  const html = renderMarkdown('# 标题\n\n- 无序项\n\n1. 有序项\n\n> 引用内容')

  assert.match(html, /<h1>标题<\/h1>/)
  assert.match(html, /<ul>[\s\S]*?<li>无序项<\/li>[\s\S]*?<\/ul>/)
  assert.match(html, /<ol>[\s\S]*?<li>有序项<\/li>[\s\S]*?<\/ol>/)
  assert.match(html, /<blockquote>[\s\S]*?引用内容[\s\S]*?<\/blockquote>/)
})

test('renders callout types, custom titles and folded callouts with content kept in the DOM', () => {
  const html = renderMarkdown('> [!note] 记录提示\n> **正文内容**\n\n> [!WARNING] 边界\n> 保持原样\n\n> [!tip]- 可折叠提示\n> 折叠内容仍在 DOM 中。')

  assert.match(html, /class="callout" data-callout="note" data-callout-group="blue"/)
  assert.match(html, /class="callout-title">[\s\S]*?<span>记录提示<\/span>/)
  assert.match(html, /<strong>正文内容<\/strong>/)
  assert.match(html, /class="callout" data-callout="warning" data-callout-group="amber"/)
  // 「-」按官方语义默认折叠：用 details 承载且不带 open，内容仍留在 DOM 中
  assert.match(html, /<details class="callout" data-callout="tip" data-callout-group="blue">/)
  assert.doesNotMatch(html, /<details[^>]*\sopen/)
  assert.match(html, /折叠内容仍在 DOM 中。/)
})

test('escapes callout titles and falls unknown callout types back to note', () => {
  const html = renderMarkdown('> [!note] <img src=x onerror=alert(1)>\n> 正文\n\n> [!custom] 自定义\n> 原始内容')

  assert.match(html, /<span>&lt;img src=x onerror=alert\(1\)&gt;<\/span>/)
  // 未知类型按官方语义回落 note，不退回普通引用
  assert.match(html, /data-callout="note"[\s\S]*?<span>自定义<\/span>[\s\S]*?原始内容/)
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

test('renders inline and block KaTeX while keeping Markdown source unchanged', () => {
  const markdown = '行内公式 $x^2$。\n\n$$\n\\frac{1}{2}\n$$'
  const html = renderMarkdown(markdown)

  assert.match(html, /class="katex"/)
  assert.match(html, /class="katex-display"/)
  assert.equal(markdown, '行内公式 $x^2$。\n\n$$\n\\frac{1}{2}\n$$')
})

test('isolates invalid formulas and continues rendering surrounding Markdown', () => {
  const html = renderMarkdown('前文 $\\notARealCommand$\n\n后文')

  assert.match(html, /class="math-error"[^>]*>公式无法渲染<\/span>/)
  assert.match(html, /<p>后文<\/p>/)
})

test('renders Mermaid fences as escaped, isolated blocks', () => {
  const html = renderMarkdown('图表：\n\n```mermaid\ngraph TD\nA-->B\n```\n\n后文')

  assert.match(html, /class="mermaid-block"/)
  assert.match(html, /class="mermaid-source"[^>]*>graph TD\nA--&gt;B<\/pre>/)
  assert.match(html, /<p>后文<\/p>/)
})

test('validates Mermaid syntax and rejects invalid graph source', async () => {
  await validateMermaidSource('graph TD\nA-->B')
  await assert.rejects(validateMermaidSource('graph TD\nA-->'))
})

test('resolves URL-encoded Unicode image paths relative to the note directory', () => {
  assert.equal(
    resolveVaultImagePath('10_写作', '../50_Assets/%E7%AC%94%E8%AE%B0%E6%B5%81%E7%A8%8B.svg'),
    '50_Assets/笔记流程.svg'
  )
})

test('adds only the missing capture height and preserves existing bottom padding', () => {
  const padding = shareCaptureBottomPadding(3433, 1799, 2, 48)

  assert.equal(padding, 213)
  assert.equal(3433 + padding - 48, 2 * 1799)
  assert.equal(shareCaptureBottomPadding(1600, 800, 2, 48), 48)
})

test('splits frontmatter from body and passes plain Markdown through unchanged', () => {
  const plain = '# 标题\n\n正文'
  const noFrontmatter = splitFrontmatter(plain)
  assert.equal(noFrontmatter.frontmatter, '')
  assert.equal(noFrontmatter.body, plain)

  const withFrontmatter = splitFrontmatter('---\ntitle: 笔记\ntags:\n  - 阅读\n---\n# 标题\n\n正文')
  assert.equal(withFrontmatter.frontmatter, '---\ntitle: 笔记\ntags:\n  - 阅读\n---\n')
  assert.equal(withFrontmatter.body, '# 标题\n\n正文')

  const crlf = splitFrontmatter('---\r\ntags: [a]\r\n---\r\n正文')
  assert.equal(crlf.body, '正文')
  const dots = splitFrontmatter('---\ntags: [a]\n...\n正文')
  assert.equal(dots.body, '正文')
})

test('extracts tags from block lists, inline lists and quoted values with dedupe and validation', () => {
  assert.deepEqual(frontmatterTags('---\ntags:\n  - 阅读\n  - #产品\n  - "多词"\n  - 多 词\n---\n正文'), ['阅读', '产品', '多词'])
  assert.deepEqual(frontmatterTags("---\ntags: [阅读, 产品, 阅读, '多词']\n---\n正文"), ['阅读', '产品', '多词'])
  assert.deepEqual(frontmatterTags('---\ntags: [123, 456, 笔记]\n---\n正文'), ['笔记'])
  assert.deepEqual(frontmatterTags('---\ntitle: 无标签笔记\n---\n正文'), [])
  assert.deepEqual(frontmatterTags('# 无 frontmatter'), [])
})

test('renders note tags as escaped chips and returns empty string without tags', () => {
  const html = renderNoteTags('---\ntags:\n  - 阅读<b>\n  - 产品\n---\n正文')
  assert.equal(
    html,
    '<div class="note-tags" aria-label="笔记标签"><span class="note-tag">#阅读&lt;b&gt;</span><span class="note-tag">#产品</span></div>'
  )
  assert.equal(renderNoteTags('---\ntitle: 无标签\n---\n正文'), '')
  assert.equal(renderNoteTags('# 无 frontmatter'), '')
})

test('renders Obsidian callouts with type, custom title and content', () => {
  const html = renderMarkdown('> [!note] 记录提示\n> 用一句话写出今天最重要的发现。\n\n正文在后')

  assert.match(html, /<div class="callout" data-callout="note" data-callout-group="blue">/)
  assert.match(html, /<div class="callout-title">[^]*?<span>记录提示<\/span><\/div>/)
  assert.match(html, /<div class="callout-content"><p>用一句话写出今天最重要的发现。<\/p>\s*<\/div>/)
  assert.match(html, /<p>正文在后<\/p>/)
  assert.equal(/<blockquote>/.test(html), false)
})

test('normalizes callout aliases, case and unknown types per the Obsidian fallback', () => {
  const html = renderMarkdown(
    '> [!CAUTION] 注意\n> 内容\n\n> [!TLDR]\n> 摘要\n\n> [!made-up-type]\n> 未知\n\n> [!cite]\n> 引用'
  )

  assert.match(html, /data-callout="warning" data-callout-group="amber"/)
  assert.match(html, /<span>注意<\/span>/)
  assert.match(html, /data-callout="abstract"/)
  assert.match(html, /<span>Abstract<\/span>/)
  assert.match(html, /data-callout="note"/)
  assert.match(html, /<span>Note<\/span>/)
  assert.match(html, /data-callout="quote" data-callout-group="gray"/)
  assert.match(html, /<span>Quote<\/span>/)
})

test('renders foldable callouts as details with the Obsidian default state', () => {
  const html = renderMarkdown(
    '> [!tip]- 默认折叠\n> 收起内容\n\n> [!tip]+ 默认展开\n> 展开内容\n\n> [!tip] 不可折叠\n> 普通'
  )

  assert.match(html, /<details class="callout" data-callout="tip" data-callout-group="blue">/)
  assert.match(html, /<summary class="callout-title">[^]*?<span>默认折叠<\/span><\/summary>/)
  assert.match(html, /<details class="callout" data-callout="tip" data-callout-group="blue" open>/)
  assert.match(html, /<div class="callout" data-callout="tip" data-callout-group="blue">/)
  assert.equal(/<\/details>[\s\S]*?<\/details>/.test(html), true)
  assert.match(html, /<p>收起内容<\/p>/)
  assert.match(html, /<p>展开内容<\/p>/)
  assert.match(html, /<p>普通<\/p>/)
})

test('keeps plain blockquotes rendering as blockquote even with bracket text', () => {
  const html = renderMarkdown('> 这是普通引用，含 [!note] 字样但不构成 callout。\n> 第二行')

  assert.match(html, /<blockquote>[\s\S]*?普通引用[\s\S]*?<\/blockquote>/)
  assert.equal(/class="callout"/.test(html), false)
})

test('keeps multi-line, nested and CRLF callout content intact', () => {
  const nested = renderMarkdown('> [!question] 外层\n> > [!todo] 内层\n> > 内层内容\n> 外层继续')

  assert.match(nested, /data-callout="question"/)
  assert.match(nested, /data-callout="todo"/)
  assert.match(nested, /<p>内层内容<\/p>/)
  assert.match(nested, /<p>外层继续<\/p>/)

  const crlf = renderMarkdown('> [!warning] 边界\r\n> 第一行\r\n> 第二行\r\n')
  assert.match(crlf, /data-callout="warning"/)
  assert.match(crlf, /<p>第一行\n第二行<\/p>/)

  const list = renderMarkdown('> [!example] 列表\n> - 甲\n> - 乙\n> ```ts\n> const a = 1\n> ```')
  assert.match(list, /<ul>[\s\S]*?<li>甲<\/li>[\s\S]*?<li>乙<\/li>/)
  assert.match(list, /<pre><code class="language-ts">const a = 1/)
})
