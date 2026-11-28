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

/**
 * Obsidian 段尾块 ID（v1.21 21.5）。规则与 v2 原型 `cbBlockId` 及端侧
 * `MarkdownComplexBlockEdit.parseBlockId` 一致：只看最后一行，允许尾部空白，
 * 反斜杠转义的 `\^id` 不算块 ID。
 * @param {string} raw 段落原始 Markdown
 * @returns {{ id: string, from: number } | null} from 是标记连同前导空白在 raw 中的起点
 */
function trailingBlockId(raw) {
  const content = raw.replace(/(?:\r?\n)+$/, '')
  const lineStart = content.lastIndexOf('\n') + 1
  const line = content.slice(lineStart)
  const match = /\^([A-Za-z0-9][A-Za-z0-9_-]*)[ \t]*$/.exec(line)
  if (match === null) return null
  let escapes = 0
  for (let index = match.index - 1; index >= 0 && line[index] === '\\'; index--) escapes++
  if (escapes % 2 === 1) return null
  let from = match.index
  while (from > 0 && /[ \t]/.test(line[from - 1])) from--
  return { id: match[1], from: lineStart + from }
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
    },
    {
      // v2.11 211.3：正文行内 #tag 渲染为可点 chip。口径对齐原型 inlineTags：
      // # 前必须是行首或空白/半角·全角左括号；代码/公式 token 之后的 #tag
      // 在原型里等价于剥离后接空格，同样渲染。tag 字符集与 validTag 一致。
      name: 'noteTag',
      level: 'inline',
      start(source) {
        const match = /[\s(（]#/u.exec(source)
        return match === null ? undefined : match.index
      },
      tokenizer(source, tokens) {
        let match = /^([\s(（])#([\p{L}\p{N}\p{M}\p{S}_/-]+)/u.exec(source)
        if (match !== null) {
          if (!validTag(match[2])) return undefined
          return { type: 'noteTag', raw: match[0], lead: match[1], tag: match[2] }
        }
        match = /^#([\p{L}\p{N}\p{M}\p{S}_/-]+)/u.exec(source)
        if (match === null || !validTag(match[1])) return undefined
        // 无前置字符可见（行内串起点）：只有块内首 token，或前一个 token 是
        // 换行/行内代码/行内公式（原型剥离后视为空格）时才算行首 #tag。
        const last = tokens.length > 0 ? tokens[tokens.length - 1] : undefined
        if (last !== undefined) {
          const allowed = last.type === 'br' || last.type === 'codespan' || last.type === 'mathInline' ||
            (last.type === 'text' && /[\s(（]$/u.test(last.raw ?? ''))
          if (!allowed) return undefined
        }
        return { type: 'noteTag', raw: match[0], lead: '', tag: match[1] }
      },
      renderer(token) {
        return `${escapeHtml(token.lead)}${noteTagChip(token.tag)}`
      }
    }
  ],
  renderer: {
    /**
     * 段尾块 ID 是引用锚点而非正文：从可见 HTML 移除，保留 `<p data-block-id>`。
     * 只裁剪 token 副本 —— sourceMapping 仍用原 token.raw / token.tokens 计算
     * 源码区间与内联项，因此源码、块定位、复制块链接都不受影响。
     */
    paragraph(token) {
      const block = trailingBlockId(token.raw)
      if (block === null) return false

      const tokens = (token.tokens ?? []).map((item) => ({ ...item }))
      let remove = token.raw.replace(/(?:\r?\n)+$/, '').length - block.from
      for (let index = tokens.length - 1; index >= 0 && remove > 0; index--) {
        const item = tokens[index]
        const rawLength = (item.raw ?? '').length
        if (rawLength === 0) continue
        if (rawLength <= remove) {
          tokens.splice(index, 1)
          remove -= rawLength
          continue
        }
        const keep = rawLength - remove
        if (typeof item.text === 'string') {
          if (item.text.slice(-remove) !== item.raw.slice(-remove)) return false
          item.text = item.text.slice(0, item.text.length - remove)
        }
        item.raw = item.raw.slice(0, keep)
        remove = 0
      }
      // 裁剪不干净时退回默认渲染，宁可显示标记也不要丢正文
      if (remove > 0) return false
      return `<p data-block-id="${escapeHtml(block.id)}">${this.parser.parseInline(tokens)}</p>\n`
    },
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
  return /^[\p{L}\p{N}\p{M}\p{S}_/.-]+$/u.test(value) && /[^\p{N}]/u.test(value)
}

/** Quoted frontmatter values allow spaces and apostrophes beyond the bare-value charset. */
function validQuotedTag(value) {
  return /^[\p{L}\p{N}\p{M}\p{S}_/.' -]+$/u.test(value) && /[^\p{N}]/u.test(value)
}

/** Collect the elements of an inline `[a, b]` list (same item regex across sources). */
function pushInlineItems(values, inline) {
  const items = inline.slice(1, -1).match(/"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,]+/g)
  if (items) {
    values.push(...items)
  }
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
      const inline = key[1].trim()
      if (inline.startsWith('[') && inline.endsWith(']')) {
        // Collect the list verbatim so `#`-prefixed items survive trailing-comment stripping.
        pushInlineItems(values, inline)
      } else {
        const stripped = inline.replace(/[ \t]+#.*$/, '').trim()
        if (stripped.startsWith('[') && stripped.endsWith(']')) {
          pushInlineItems(values, stripped)
        } else if (stripped.length > 0) {
          // Bare scalar (`tags: foo`) is recognized too.
          values.push(stripped)
        }
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
    let quoted = false
    if (value.startsWith('"') && value.endsWith('"')) {
      quoted = true
      try {
        value = JSON.parse(value)
      } catch {
        continue
      }
    } else if (value.startsWith("'") && value.endsWith("'")) {
      quoted = true
      value = value.slice(1, -1).replace(/''/g, "'")
    } else {
      value = value.replace(/[ \t]+#.*$/, '')
    }
    value = value.replace(/^#/, '')
    const valid = quoted ? validQuotedTag(value) : validTag(value)
    if (valid && !seen.has(value.toLowerCase())) {
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

/** v2.11：标签 chip（frontmatter 与正文行内共用），点击由 ArkTS 委托接管进入标签过滤。 */
function noteTagChip(tag) {
  const label = escapeHtml(tag)
  return `<button type="button" class="note-tag" data-note-tag="${label}" ` +
    `aria-label="按标签筛选：#${label}">#${label}</button>`
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
  const chips = tags.map((tag) => noteTagChip(tag)).join('')
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

/** 53.8：返回需额外垫高的流内 spacer 像素，使 scrollHeight 覆盖 pageCount*viewportHeight。
 * 不再改 #content 自身 padding-bottom：border-box 下超大 padding 会把内容盒钳到 0，
 * 盒高下限=上下 padding 之和，clientHeight 随之虚增（710→766），两侧视口不一致。 */
export function shareCaptureBottomPadding(scrollHeight, viewportHeight, pageCount) {
  return Math.max(0, viewportHeight * pageCount - scrollHeight)
}
