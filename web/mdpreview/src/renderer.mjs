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

marked.use({
  extensions: [
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
    code(token) {
      if (token.lang?.trim().toLowerCase() !== 'mermaid') return false
      return `<div class="mermaid-block"><pre class="mermaid-source">${escapeHtml(token.text)}</pre></div>\n`
    }
  }
})

let nextMermaidId = 0

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

/** Render frontmatter tags as the v2 note-tags chip row; empty string when there are no valid tags. */
export function renderNoteTags(markdown) {
  const tags = frontmatterTags(markdown)
  if (tags.length === 0) {
    return ''
  }
  const chips = tags.map((tag) => `<span class="note-tag">#${escapeHtml(tag)}</span>`).join('')
  return `<div class="note-tags" aria-label="笔记标签">${chips}</div>`
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
