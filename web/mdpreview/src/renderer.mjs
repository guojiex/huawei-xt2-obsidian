import { marked } from 'marked'
import katex from 'katex'
import mermaid from 'mermaid'

marked.setOptions({ gfm: true, breaks: false })

mermaid.initialize({
  startOnLoad: false,
  securityLevel: 'strict',
  theme: 'default'
})

function mathHtml(source, displayMode) {
  try {
    return katex.renderToString(source, { displayMode, throwOnError: true })
  } catch {
    const tag = displayMode ? 'div' : 'span'
    return `<${tag} class="math-error" role="status">公式无法渲染</${tag}>`
  }
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => {
    if (character === '&') return '&amp;'
    if (character === '<') return '&lt;'
    if (character === '>') return '&gt;'
    if (character === '"') return '&quot;'
    return '&#39;'
  })
}

export function applyImageMarkdownAttributes(image) {
  const width = image.dataset.markdownWidth ?? ''
  if (/^\d{2,4}$/.test(width) && Number(width) > 0) {
    image.style.width = `${Number(width)}px`
    image.style.maxWidth = '100%'
    image.style.height = 'auto'
  }
  if (image.alt.length === 0) {
    image.setAttribute('aria-label', '图片')
  }
}

function imageWidthFromRaw(raw) {
  let labelEnd = -1
  for (let index = 2; index < raw.length - 1; index++) {
    if (raw[index] === '\\') {
      index++
    } else if (raw[index] === ']' && raw[index + 1] === '(') {
      labelEnd = index
      break
    }
  }
  if (labelEnd < 0) return ''

  const alt = raw.slice(2, labelEnd)
  const separator = alt.lastIndexOf('|')
  if (separator < 0) return ''
  let slashes = 0
  for (let index = separator - 1; index >= 0 && alt[index] === '\\'; index--) slashes++
  const width = alt.slice(separator + 1)
  return slashes % 2 === 0 && /^\d{2,4}$/.test(width) ? width : ''
}

marked.use({
  extensions: [
    {
      name: 'footnoteDefinition',
      level: 'block',
      start(source) {
        const match = /(?:^|\n)(\uFEFF? {0,3}\[\^[^\]\r\n]+\]:)/.exec(source)
        if (!match) return undefined
        return match.index + match[0].length - match[1].length
      },
      tokenizer(source) {
        const token = tokenizeFootnoteDefinition(source)
        if (!token) return undefined
        token.tokens = this.lexer.blockTokens(token.body, [])
        return token
      },
      renderer(token) {
        const id = footnoteDefinitionId(token.label)
        const body = this.parser.parse(token.tokens)
        return `<div class="footnote-definition" id="${id}" data-footnote-label="${escapeHtml(token.label)}">` +
          `${body}</div>\n`
      }
    },
    {
      name: 'footnoteRef',
      level: 'inline',
      start(source) {
        const index = unescapedFootnoteStart(source)
        return index < 0 ? undefined : index
      },
      tokenizer(source) {
        const match = /^\[\^([^\]\r\n]+)\]/.exec(source)
        if (!match) return undefined
        return { type: 'footnoteRef', raw: match[0], label: match[1] }
      },
      renderer(token) {
        const id = footnoteDefinitionId(token.label)
        const label = escapeHtml(token.label)
        return `<sup><a class="footnote-reference" href="#${id}" ` +
          `data-footnote-reference="${label}" aria-label="脚注 ${label}">${label}</a></sup>`
      }
    },
    {
      name: 'callout',
      level: 'block',
      start(source) {
        const index = source.search(/(^|\n) {0,3}>[ \t]*\[/)
        return index < 0 ? undefined : index
      },
      tokenizer(source) {
        const token = tokenizeCallout(source)
        if (!token) return undefined
        token.tokens = this.lexer.blockTokens(token.inner, [])
        return token
      },
      renderer(token) {
        const group = CALLOUT_GROUPS[token.kind] ?? 'blue'
        const title = token.title.length > 0
          ? escapeHtml(token.title)
          : (CALLOUT_DEFAULT_TITLES[token.kind] ?? 'Note')
        const content = this.parser.parse(token.tokens)
        const titleRow = `${calloutIcon(group)}<span>${title}</span>`
        if (token.fold === 'none') {
          return `<div class="callout" data-callout="${token.kind}" data-callout-group="${group}">` +
            `<div class="callout-title">${titleRow}</div>` +
            `<div class="callout-content">${content}</div></div>\n`
        }
        const open = token.fold === 'open' ? ' open' : ''
        return `<details class="callout" data-callout="${token.kind}" data-callout-group="${group}"${open}>` +
          `<summary class="callout-title">${titleRow}</summary>` +
          `<div class="callout-content">${content}</div></details>\n`
      }
    },
    {
      name: 'mathBlock',
      level: 'block',
      start(source) {
        const index = source.indexOf('$$')
        return index < 0 ? undefined : index
      },
      tokenizer(source) {
        const match = /^\$\$[ \t]*([\s\S]*?)[ \t]*\$\$[ \t]*(?:\n|$)/.exec(source)
        if (!match) return undefined
        return { type: 'mathBlock', raw: match[0], text: match[1].trim() }
      },
      renderer(token) {
        return `${mathHtml(token.text, true)}\n`
      }
    },
    {
      name: 'mathInline',
      level: 'inline',
      start(source) {
        const index = source.indexOf('$')
        return index < 0 ? undefined : index
      },
      tokenizer(source) {
        const match = /^\$((?:\\.|[^\\$\n])+?)\$/.exec(source)
        if (!match) return undefined
        return { type: 'mathInline', raw: match[0], text: match[1] }
      },
      renderer(token) {
        return mathHtml(token.text, false)
      }
    }
  ],
  renderer: {
    image(token) {
      const width = imageWidthFromRaw(token.raw)
      if (!width) return false

      const alt = this.parser.parseInline(token.tokens, this.parser.textRenderer)
      const suffix = `|${width}`
      if (!alt.endsWith(suffix)) return false
      const renderer = new marked.Renderer()
      renderer.options = this.options
      renderer.parser = this.parser
      const html = renderer.image({
        href: token.href,
        title: token.title,
        text: alt.slice(0, -suffix.length)
      })
      return html.replace('<img ', `<img data-markdown-width="${width}" `)
    },
    code(token) {
      if (token.lang?.trim().toLowerCase() !== 'mermaid') return false
      return `<div class="mermaid-block"><pre class="mermaid-source">${escapeHtml(token.text)}</pre></div>\n`
    }
  }
})

let nextMermaidId = 0

/**
 * Obsidian callout 支持（v1.4；类型与折叠语义按 help.obsidian.md/callouts 2026-10-31 核对）：
 * - 语法 `> [!类型] 可选标题` + 后续 `>` 行；类型大小写不敏感；
 * - alias 归一化到 canonical 类型；未知类型按官方语义回落 note；
 * - `[!类型]-` 默认折叠、`[!类型]+` 默认展开；无标记不可折叠；
 * - 标题缺省显示 canonical 类型名（title case）。
 * 配色按 accent 分组（blue/green/amber/red/gray），CSS 色板见 build.mjs 渲染器专属值。
 */
const CALLOUT_ALIASES = {
  summary: 'abstract', tldr: 'abstract',
  hint: 'tip', important: 'tip',
  check: 'success', done: 'success',
  help: 'question', faq: 'question',
  caution: 'warning', attention: 'warning',
  fail: 'failure', missing: 'failure',
  error: 'danger',
  cite: 'quote'
}

const CALLOUT_DEFAULT_TITLES = {
  note: 'Note', abstract: 'Abstract', info: 'Info', todo: 'Todo', tip: 'Tip',
  success: 'Success', question: 'Question', warning: 'Warning', failure: 'Failure',
  danger: 'Danger', bug: 'Bug', example: 'Example', quote: 'Quote'
}

const CALLOUT_GROUPS = {
  note: 'blue', abstract: 'blue', info: 'blue', todo: 'blue', tip: 'blue', example: 'blue',
  success: 'green',
  question: 'amber', warning: 'amber',
  failure: 'red', danger: 'red', bug: 'red',
  quote: 'gray'
}

const CALLOUT_HEAD_PATTERN = /^ {0,3}>[ \t]*\[!([A-Za-z][\w-]*)\]([+-])?[ \t]*([^\n]*)\r?\n?/
const CALLOUT_BODY_LINE_PATTERN = /^ {0,3}>([^\n]*)\r?\n?/
const CALLOUT_ICON_SHAPE = {
  blue: '<circle cx="12" cy="12" r="8.6"/><path d="M12 11v5.2"/><path d="M12 7.6v.1"/>',
  green: '<path d="M4.6 12.6l4.8 4.8L19.4 7"/>',
  amber: '<path d="M12 3.6 21.4 20H2.6Z"/><path d="M12 9.6v4.6"/><path d="M12 17v.1"/>',
  red: '<circle cx="12" cy="12" r="8.6"/><path d="M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6"/>',
  gray: '<path d="M4.5 10.5h5v5h-5zM14.5 10.5h5v5h-5z"/>'
}

function calloutIcon(group) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ` +
    `stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${CALLOUT_ICON_SHAPE[group]}</svg>`
}

function footnoteDefinitionId(label) {
  const key = Array.from(label, (character) => character.codePointAt(0).toString(16)).join('-')
  return `footnote-definition-${key}`
}

function footnoteContinuation(line) {
  return /^ {2,}/.test(line) || line.startsWith('\t')
}

function tokenizeFootnoteDefinition(source) {
  const first = /^\uFEFF? {0,3}\[\^([^\]\r\n]+)\]:[ \t]*(.*?)(?:\r?\n|$)/.exec(source)
  if (!first) return undefined

  const body = [first[2]]
  let raw = first[0]
  let rest = source.slice(first[0].length)
  while (rest.length > 0) {
    const line = /^(.*?)(?:\r?\n|$)/.exec(rest)
    if (!line || line[0].length === 0) break
    if (line[1].length === 0) {
      const next = /^(.*?)(?:\r?\n|$)/.exec(rest.slice(line[0].length))
      if (!next || !footnoteContinuation(next[1])) break
      body.push('')
      raw += line[0]
      rest = rest.slice(line[0].length)
      continue
    }
    if (!footnoteContinuation(line[1])) break
    const indentation = line[1].startsWith('\t') ? '\t' : '  '
    body.push(line[1].slice(indentation.length))
    raw += line[0]
    rest = rest.slice(line[0].length)
  }
  return { type: 'footnoteDefinition', raw, label: first[1], body: body.join('\n') }
}

function unescapedFootnoteStart(source) {
  let index = source.indexOf('[^')
  while (index >= 0) {
    let slashes = 0
    for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) slashes++
    if (slashes % 2 === 0) return index
    index = source.indexOf('[^', index + 2)
  }
  return -1
}

/** Split one Obsidian callout out of a blockquote, or return undefined for a normal quote. */
function tokenizeCallout(source) {
  const head = CALLOUT_HEAD_PATTERN.exec(source)
  if (!head) {
    return undefined
  }
  const rawKind = head[1].toLowerCase()
  const kind = rawKind in CALLOUT_DEFAULT_TITLES
    ? rawKind
    : (rawKind in CALLOUT_ALIASES ? CALLOUT_ALIASES[rawKind] : 'note')
  let rest = source.slice(head[0].length)
  let inner = ''
  while (true) {
    const line = CALLOUT_BODY_LINE_PATTERN.exec(rest)
    if (!line) {
      break
    }
    inner += `${line[1].replace(/^ /, '')}\n`
    rest = rest.slice(line[0].length)
  }
  return {
    type: 'callout',
    raw: source.slice(0, source.length - rest.length),
    kind,
    group: CALLOUT_GROUPS[kind],
    fold: head[2] === '-' ? 'closed' : (head[2] === '+' ? 'open' : 'none'),
    title: head[3].trim(),
    inner
  }
}

/** Leading YAML frontmatter block（BOM / CRLF / `---`·`...` 闭合），与 v2 原型 markdownBody 同规则。 */
const FRONTMATTER_PATTERN = /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/

/** Split a note into its leading YAML frontmatter (delimiters included) and body. */
export function splitFrontmatter(markdown) {
  const match = FRONTMATTER_PATTERN.exec(markdown)
  if (!match) {
    return { frontmatter: '', body: markdown }
  }
  return { frontmatter: match[0], body: markdown.slice(match[0].length) }
}

/** Tag validity per v2 prototype: non-empty word characters plus at least one non-numeric character. */
function validTag(value) {
  return /^[\p{L}\p{N}\p{M}\p{S}_/-]+$/u.test(value) && /[^\p{N}]/u.test(value)
}

/** Extract deduplicated `tags:` values from the YAML frontmatter (inline or block list, quoted or bare). */
export function frontmatterTags(markdown) {
  const split = splitFrontmatter(markdown)
  if (split.frontmatter.length === 0) {
    return []
  }
  const lines = split.frontmatter.replace(/^\uFEFF/, '').split(/\r?\n/)
  const values = []
  let reading = false
  for (const line of lines.slice(1, -1)) {
    const key = line.match(/^tags:[ \t]*(.*)$/)
    if (key) {
      reading = true
      const inline = key[1].replace(/[ \t]+#.*$/, '').trim()
      if (inline.startsWith('[') && inline.endsWith(']')) {
        values.push(...(inline.slice(1, -1).match(/"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,]+/g) || []))
      }
      continue
    }
    if (reading) {
      const item = line.match(/^[ \t]*-[ \t]+(.*)$/)
      if (item) {
        values.push(item[1])
      } else if (/^[^ \t#]/.test(line)) {
        reading = false
      }
    }
  }
  const tags = []
  const seen = new Set()
  for (let value of values) {
    value = value.trim()
    if (value.startsWith('"') && value.endsWith('"')) {
      try {
        value = JSON.parse(value)
      } catch {
        continue
      }
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1).replace(/''/g, "'")
    } else {
      value = value.replace(/[ \t]+#.*$/, '')
    }
    value = value.replace(/^#/, '')
    if (validTag(value) && !seen.has(value.toLowerCase())) {
      seen.add(value.toLowerCase())
      tags.push(value)
    }
  }
  return tags
}

function frontmatterPropertyCount(frontmatter) {
  const lines = frontmatter.replace(/^\uFEFF/, '').split(/\r?\n/)
  return lines.filter((line) => /^[^\s#:-][^:\n]*:/.test(line)).length
}

/** Render the editable property entry and frontmatter tags for the v2 preview. */
export function renderNoteTags(markdown, propertySource = markdown) {
  const tags = frontmatterTags(markdown)
  const frontmatter = splitFrontmatter(propertySource).frontmatter
  if (tags.length === 0 && frontmatter.length === 0) {
    return ''
  }
  const propertyCount = frontmatterPropertyCount(frontmatter)
  const entry = frontmatter.length > 0
    ? `<button type="button" class="md-props-entry" data-preview-frontmatter-entry ` +
      `aria-label="笔记属性，共 ${propertyCount} 项，打开编辑">` +
      `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16M4 12h10M4 18h7"/></svg>` +
      `属性 · ${propertyCount} 项</button>`
    : ''
  const chips = tags.map((tag) => `<span class="note-tag">#${escapeHtml(tag)}</span>`).join('')
  return `<div class="note-tags" aria-label="笔记属性与标签">${entry}${chips}</div>`
}

/** Parse and render one Mermaid block, allowing the caller to isolate failures per block. */
export async function renderMermaidSvg(source) {
  const id = `mdpreview-mermaid-${nextMermaidId++}`
  const result = await mermaid.render(id, source)
  return result.svg
}

/** Validate a Mermaid source without requiring a browser DOM. */
export async function validateMermaidSource(source) {
  await mermaid.parse(source)
}

/** Resolve a Markdown image URL to a normalized path inside its vault. */
export function resolveVaultImagePath(noteDir, src) {
  let decodedSrc = src
  try {
    decodedSrc = decodeURIComponent(src)
  } catch {
    // Keep malformed percent escapes intact; the vault lookup will report it missing.
  }
  const base = noteDir.length > 0 ? `${noteDir}/${decodedSrc}` : decodedSrc
  const segments = []
  for (const segment of base.split('/')) {
    if (segment === '' || segment === '.') {
      continue
    }
    if (segment === '..') {
      segments.pop()
      continue
    }
    segments.push(segment)
  }
  return segments.join('/')
}

/** @param {string} markdown @returns {string} */
export function renderMarkdown(markdown) {
  return /** @type {string} */ (marked.parse(markdown))
}

/** Preserve the viewport's existing bottom padding while extending a partial final capture page. */
export function shareCaptureBottomPadding(scrollHeight, viewportHeight, pageCount, currentPadding) {
  const targetHeight = viewportHeight * pageCount
  return currentPadding + Math.max(0, targetHeight - scrollHeight)
}
