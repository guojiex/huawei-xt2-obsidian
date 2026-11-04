import { marked } from 'marked'
import './renderer.mjs'

function lineBreaks(text) {
  return (text.match(/\n/g) || []).length
}

function trimTrailingLineBreaks(text) {
  return text.replace(/(?:\r?\n)+$/, '')
}

function sourceRangeLength(token, raw) {
  if (token.type !== 'footnoteDefinition') return raw.length
  const trailingLineBreaks = raw.match(/\n+$/)?.[0].length ?? 0
  return raw.length - Math.max(0, trailingLineBreaks - 1)
}

function crlfOffsets(markdown) {
  const offsets = []
  let originalOffset = 0
  let normalizedOffset = 0
  while (originalOffset < markdown.length) {
    if (markdown[originalOffset] === '\r' && markdown[originalOffset + 1] === '\n') {
      offsets.push(normalizedOffset)
      originalOffset += 2
    } else {
      originalOffset++
    }
    normalizedOffset++
  }
  return offsets
}

function originalOffsetForNormalizedPosition(position, offsets) {
  let low = 0
  let high = offsets.length
  while (low < high) {
    const middle = Math.floor((low + high) / 2)
    if (offsets[middle] < position) low = middle + 1
    else high = middle
  }
  return position + low
}

function unknownColonRanges(source) {
  const ranges = []
  const lines = []
  let offset = 0
  while (offset < source.length) {
    const newline = source.indexOf('\n', offset)
    const end = newline < 0 ? source.length : newline
    lines.push({ text: source.slice(offset, end), start: offset, end })
    offset = newline < 0 ? source.length : newline + 1
  }

  let blockStart = -1
  let depth = 0
  let fenceCharacter = ''
  let fenceLength = 0
  let mathBlock = false
  for (const line of lines) {
    const fence = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line.text)
    if (fenceCharacter.length > 0) {
      if (fence && fence[1][0] === fenceCharacter && fence[1].length >= fenceLength &&
        fence[2].trim().length === 0) {
        fenceCharacter = ''
        fenceLength = 0
      }
      continue
    }
    if (fence && !(fence[1][0] === '`' && fence[2].includes('`'))) {
      fenceCharacter = fence[1][0]
      fenceLength = fence[1].length
      continue
    }
    if (line.text.trim() === '$$') {
      mathBlock = !mathBlock
      continue
    }
    if (mathBlock) continue

    const opening = /^ {0,3}:{3,}[ \t]*[A-Za-z][A-Za-z0-9_-]*(?:\b[^\n]*)?$/.test(line.text)
    const closing = /^ {0,3}:{3,}[ \t]*$/.test(line.text)
    if (opening) {
      if (depth === 0) blockStart = line.start
      depth++
    } else if (closing && depth > 0) {
      depth--
      if (depth === 0) {
        ranges.push({ start: blockStart, end: line.end })
        blockStart = -1
      }
    }
  }
  if (depth > 0 && blockStart >= 0) {
    ranges.push({ start: blockStart, end: source.length })
  }
  return ranges
}

/** Render each visible top-level Markdown token in a layout-transparent source wrapper. */
function sourcePositionForDisplayOffset(displayOffset, edits, isEnd) {
  let delta = 0
  for (const edit of edits) {
    if (displayOffset <= edit.displayStart) return displayOffset - delta
    if (displayOffset < edit.displayEnd) return isEnd ? edit.sourceEnd : edit.sourceStart
    if (displayOffset === edit.displayEnd) return edit.sourceEnd
    delta += (edit.displayEnd - edit.displayStart) - (edit.sourceEnd - edit.sourceStart)
  }
  return displayOffset - delta
}

const INLINE_ITEM_TYPES = {
  link: 'link',
  image: 'image',
  codespan: 'inlinecode',
  mathInline: 'mathInline',
  footnoteRef: 'footnoteRef'
}

const SAFE_INLINE_TOKEN_TYPES = new Set([
  'text', 'escape', 'br', 'strong', 'em', 'del',
  ...Object.keys(INLINE_ITEM_TYPES)
])

const UNSUPPORTED_INLINE_PATTERN = /!?\[\[[^\]]*\]\]|%%|==|\$\$|(?:^|\s)\^[\w-]+\s*$|^\s*:{3,}/m

function isEscaped(source, index) {
  let slashes = 0
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor--) slashes++
  return slashes % 2 === 1
}

function hasNestedLinkOrImage(token) {
  const pending = [...(token.tokens ?? [])]
  while (pending.length > 0) {
    const child = pending.pop()
    if (child.type === 'link' || child.type === 'image') return true
    if (Array.isArray(child.tokens)) pending.push(...child.tokens)
  }
  return false
}

function isSupportedLinkToken(token) {
  if (token.title || hasNestedLinkOrImage(token)) return false
  const source = token.type === 'image' ? token.raw.slice(1) : token.raw
  if (source.length < 4 || source[0] !== '[' || source[source.length - 1] !== ')') return false

  let labelEnd = -1
  for (let index = 1; index < source.length - 1; index++) {
    if (isEscaped(source, index)) continue
    if (source[index] === '[') return false
    if (source[index] === ']') {
      labelEnd = index
      break
    }
  }
  if (labelEnd < 0 || source[labelEnd + 1] !== '(') return false

  const contentStart = labelEnd + 2
  const contentEnd = source.length - 1
  const angleDestination = source[contentStart] === '<'
  const destinationStart = angleDestination ? contentStart + 1 : contentStart
  const destinationEnd = angleDestination ? contentEnd - 1 : contentEnd
  if (angleDestination && (contentEnd <= contentStart + 1 || source[contentEnd - 1] !== '>')) return false
  if (destinationStart >= destinationEnd) return false

  for (let index = destinationStart; index < destinationEnd; index++) {
    const character = source[index]
    if (isEscaped(source, index)) continue
    if (/\s/.test(character) || character === '(' || character === ')' ||
      (angleDestination && (character === '<' || character === '>'))) return false
  }
  return true
}

function collectInlineTokenRanges(tokens, parentRaw) {
  const items = []
  let safe = true

  const visit = (token, tokenOffset) => {
    if (!SAFE_INLINE_TOKEN_TYPES.has(token.type)) {
      safe = false
      return
    }
    const itemType = INLINE_ITEM_TYPES[token.type]
    if (itemType) {
      if ((token.type === 'link' || token.type === 'image') && !isSupportedLinkToken(token)) {
        safe = false
        return
      }
      items.push({ type: itemType, displayStart: tokenOffset, displayEnd: tokenOffset + token.raw.length })
      return
    }
    if (token.type === 'text' && UNSUPPORTED_INLINE_PATTERN.test(token.raw)) {
      safe = false
      return
    }
    if (Array.isArray(token.tokens) && token.tokens.length > 0) {
      collect(token.tokens, token.raw, tokenOffset)
    }
  }

  const collect = (children, raw, offset) => {
    let cursor = 0
    for (const child of children) {
      const childRaw = child.raw || ''
      const relativeStart = raw.indexOf(childRaw, cursor)
      if (relativeStart < 0) {
        safe = false
        return
      }
      visit(child, offset + relativeStart)
      cursor = relativeStart + childRaw.length
    }
  }

  collect(tokens, parentRaw, 0)
  if (!safe) return { items: [], safe: false }
  return { items, safe: true }
}

export function renderMarkdownWithSourceBlocks(markdown, lineOffset = 0, sourceOffset = 0,
  sourceEdits = [], displayOffset = 0) {
  const normalizedSource = markdown.replace(/\r\n/g, '\n')
  const tokens = marked.lexer(markdown)
  const normalizedLineEndings = crlfOffsets(markdown)
  const htmlParts = []
  const blocks = []
  const ranges = unknownColonRanges(normalizedSource)
  const segments = []
  let segmentStart = 0
  for (const range of ranges) {
    if (range.start > segmentStart) segments.push({ start: segmentStart, end: range.start })
    segments.push({ ...range, directive: true })
    segmentStart = range.end
  }
  if (segmentStart < normalizedSource.length) {
    segments.push({ start: segmentStart, end: normalizedSource.length })
  }
  if (segments.length === 0 && normalizedSource.length > 0) {
    segments.push({ start: 0, end: normalizedSource.length })
  }

  let tokenIndex = 0
  for (const segment of segments) {
    const segmentSource = normalizedSource.slice(segment.start, segment.end)
    const segmentTokens = segment.directive ? marked.lexer(segmentSource)
      : ranges.length === 0 ? tokens : marked.lexer(segmentSource)
    segmentTokens.links = tokens.links
    const segmentLine = Math.max(0, Math.floor(lineOffset)) + 1 +
      lineBreaks(normalizedSource.slice(0, segment.start))
    if (segment.directive) {
      const visibleStart = segmentSource.search(/\S/)
      const content = trimTrailingLineBreaks(segmentSource)
      const startLine = segmentLine + lineBreaks(segmentSource.slice(0, visibleStart))
      const endLine = segmentLine + lineBreaks(content)
      const html = marked.parser(segmentTokens)
      if (html.trim().length > 0) {
        const displayStart = displayOffset +
          originalOffsetForNormalizedPosition(segment.start, normalizedLineEndings)
        const displayEnd = displayOffset +
          originalOffsetForNormalizedPosition(segment.end, normalizedLineEndings)
        const sourceStart = sourceEdits.length > 0
          ? sourcePositionForDisplayOffset(displayStart, sourceEdits, false)
          : sourceOffset + originalOffsetForNormalizedPosition(segment.start, normalizedLineEndings)
        const sourceEnd = sourceEdits.length > 0
          ? sourcePositionForDisplayOffset(displayEnd, sourceEdits, true)
          : sourceOffset + originalOffsetForNormalizedPosition(segment.end, normalizedLineEndings)
        htmlParts.push(`<div class="preview-source-block" data-source-start-line="${startLine}" data-source-end-line="${endLine}">${html}</div>`)
        blocks.push({
          tokenIndex, startLine, endLine, sourceStart, sourceEnd,
          type: 'directive', inlineItems: [], inlineSafe: false
        })
      }
      tokenIndex += segmentTokens.length
      continue
    }

    let line = segmentLine
    let segmentOffset = segment.start
    for (const token of segmentTokens) {
      const raw = token.raw || ''
      const mappedRawLength = sourceRangeLength(token, raw)
      const visibleStart = raw.search(/\S/)
      const content = trimTrailingLineBreaks(raw)

      if (token.type !== 'space' && token.type !== 'def' && visibleStart >= 0 && content.trim().length > 0) {
        const startLine = line + lineBreaks(raw.slice(0, visibleStart))
        const endLine = line + lineBreaks(content)
        const tokenList = [token]
        tokenList.links = segmentTokens.links
        const html = marked.parser(tokenList)
        if (html.trim().length > 0) {
          const displayStart = displayOffset +
            originalOffsetForNormalizedPosition(segmentOffset, normalizedLineEndings)
          const displayEnd = displayOffset +
            originalOffsetForNormalizedPosition(segmentOffset + mappedRawLength, normalizedLineEndings)
          const sourceStart = sourceEdits.length > 0
            ? sourcePositionForDisplayOffset(displayStart, sourceEdits, false)
            : sourceOffset + originalOffsetForNormalizedPosition(segmentOffset, normalizedLineEndings)
          const sourceEnd = sourceEdits.length > 0
            ? sourcePositionForDisplayOffset(displayEnd, sourceEdits, true)
            : sourceOffset + originalOffsetForNormalizedPosition(segmentOffset + mappedRawLength, normalizedLineEndings)
          const inline = token.type === 'paragraph'
            ? collectInlineTokenRanges(token.tokens || [], raw)
            : { items: [], safe: false }
          const inlineItems = inline.safe ? inline.items.map((item, itemIndex) => {
            const itemDisplayStart = displayOffset +
              originalOffsetForNormalizedPosition(segmentOffset + item.displayStart, normalizedLineEndings)
            const itemDisplayEnd = displayOffset +
              originalOffsetForNormalizedPosition(segmentOffset + item.displayEnd, normalizedLineEndings)
            return {
              index: itemIndex,
              type: item.type,
              from: sourceEdits.length > 0
                ? sourcePositionForDisplayOffset(itemDisplayStart, sourceEdits, false)
                : sourceOffset + originalOffsetForNormalizedPosition(segmentOffset + item.displayStart, normalizedLineEndings),
              to: sourceEdits.length > 0
                ? sourcePositionForDisplayOffset(itemDisplayEnd, sourceEdits, true)
                : sourceOffset + originalOffsetForNormalizedPosition(segmentOffset + item.displayEnd, normalizedLineEndings)
            }
          }) : []
          htmlParts.push(`<div class="preview-source-block" data-source-start-line="${startLine}" data-source-end-line="${endLine}">${html}</div>`)
          blocks.push({
            tokenIndex, startLine, endLine, sourceStart, sourceEnd,
            type: token.type === 'mathBlock' ? 'formula' : token.type,
            inlineItems, inlineSafe: inline.safe
          })
        }
      }

      line += lineBreaks(raw)
      segmentOffset += raw.length
      tokenIndex++
    }
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
