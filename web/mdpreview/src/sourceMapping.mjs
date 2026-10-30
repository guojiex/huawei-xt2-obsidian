import { marked } from 'marked'
import './renderer.mjs'

function lineBreaks(text) {
  return (text.match(/\n/g) || []).length
}

function trimTrailingLineBreaks(text) {
  return text.replace(/(?:\r?\n)+$/, '')
}

/** Render each visible top-level Markdown token in a layout-transparent source wrapper. */
export function renderMarkdownWithSourceBlocks(markdown, lineOffset = 0) {
  const tokens = marked.lexer(markdown)
  const htmlParts = []
  const blocks = []
  let line = Math.max(0, Math.floor(lineOffset)) + 1

  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index]
    const raw = token.raw || ''
    const visibleStart = raw.search(/\S/)
    const content = trimTrailingLineBreaks(raw)

    if (token.type !== 'space' && token.type !== 'def' && visibleStart >= 0 && content.trim().length > 0) {
      const startLine = line + lineBreaks(raw.slice(0, visibleStart))
      const endLine = line + lineBreaks(content)
      const tokenList = [token]
      tokenList.links = tokens.links
      const html = marked.parser(tokenList)
      if (html.trim().length > 0) {
        htmlParts.push(`<div class="preview-source-block" data-source-start-line="${startLine}" data-source-end-line="${endLine}">${html}</div>`)
        blocks.push({ tokenIndex: index, startLine, endLine })
      }
    }

    line += lineBreaks(raw)
  }

  return { html: htmlParts.join(''), blocks }
}

/** Map a visible Markdown line to its rendered block; blank lines choose the nearest block. */
export function sourcePositionForLine(blocks, line, lineProgress = 0) {
  if (!Array.isArray(blocks) || blocks.length === 0) {
    return null
  }

  const safeLine = Number.isFinite(line) ? Math.max(1, Math.floor(line)) : 1
  const safeProgress = Number.isFinite(lineProgress) ? Math.max(0, Math.min(1, lineProgress)) : 0
  let previousIndex = -1
  let nextIndex = -1
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index]
    if (safeLine >= block.startLine && safeLine <= block.endLine) {
      const lineCount = Math.max(1, block.endLine - block.startLine + 1)
      return {
        index,
        progress: Math.max(0, Math.min(1, (safeLine - block.startLine + safeProgress) / lineCount))
      }
    }
    if (block.endLine < safeLine) {
      previousIndex = index
      continue
    }
    if (block.startLine > safeLine) {
      nextIndex = index
      break
    }
  }

  let index = 0
  if (previousIndex >= 0 && nextIndex >= 0) {
    const previousDistance = safeLine - blocks[previousIndex].endLine
    const nextDistance = blocks[nextIndex].startLine - safeLine
    index = previousDistance <= nextDistance ? previousIndex : nextIndex
  } else if (previousIndex >= 0) {
    index = previousIndex
  } else if (nextIndex >= 0) {
    index = nextIndex
  }

  const block = blocks[index]
  const lineCount = Math.max(1, block.endLine - block.startLine + 1)
  return {
    index,
    progress: Math.max(0, Math.min(1, (safeLine - block.startLine + safeProgress) / lineCount))
  }
}

export function sourceScrollTop(blocks, line, lineProgress, viewportRatio, viewportHeight, maxScrollTop,
  atStart = false, atEnd = false) {
  const maxTop = Number.isFinite(maxScrollTop) ? Math.max(0, maxScrollTop) : 0
  if (atStart) {
    return 0
  }
  if (atEnd) {
    return maxTop
  }
  const position = sourcePositionForLine(blocks, line, lineProgress)
  if (position === null) {
    return 0
  }
  const block = blocks[position.index]
  const top = Number.isFinite(block.top) ? block.top : 0
  const height = Number.isFinite(block.height) ? Math.max(0, block.height) : 0
  const ratio = Number.isFinite(viewportRatio) ? Math.max(0, Math.min(1, viewportRatio)) : 0
  const viewport = Number.isFinite(viewportHeight) ? Math.max(0, viewportHeight) : 0
  return Math.max(0, Math.min(maxTop, top + height * position.progress - viewport * ratio))
}
