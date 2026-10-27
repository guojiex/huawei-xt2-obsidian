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
