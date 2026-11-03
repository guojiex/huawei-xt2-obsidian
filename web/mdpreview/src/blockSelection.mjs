export function selectedLockedBlocks(blocks, selection, sourceBlockForNode) {
  const candidates = Array.from(blocks)
  if (!selection || selection.rangeCount === 0) return []

  if (selection.isCollapsed) {
    const block = sourceBlockForNode(selection.anchorNode)
    return block?.dataset.editLocked === 'true' && candidates.includes(block) ? [block] : []
  }

  const range = selection.getRangeAt(0)
  if (!range) return []
  return candidates.filter((block) =>
    block.dataset.editLocked === 'true' && range.intersectsNode(block)
  )
}

export function toolbarBlockForSelection(blocks, selection, sourceBlockForNode) {
  if (!selection || selection.rangeCount === 0) return null
  const candidates = Array.from(blocks)
  const block = sourceBlockForNode(selection.focusNode ?? selection.anchorNode)
  return block?.dataset.editLocked === 'true' && candidates.includes(block) ? block : null
}

export function inlineItemsForBlock(block) {
  if (block?.dataset.inlineItemsReady !== 'true' || typeof block.querySelectorAll !== 'function') return []
  const from = Number(block.dataset.sourceFrom)
  const to = Number(block.dataset.sourceTo)
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to <= from) return []
  const nodes = block.querySelectorAll('[data-preview-inline-index]')
  const items = []
  let previousIndex = -1
  for (let position = 0; position < nodes.length; position++) {
    const node = nodes[position]
    const index = Number(node.dataset.previewInlineIndex)
    const itemFrom = Number(node.dataset.previewInlineFrom)
    const itemTo = Number(node.dataset.previewInlineTo)
    const type = node.dataset.previewInlineType
    if (!Number.isInteger(index) || index <= previousIndex || !Number.isInteger(itemFrom) ||
      !Number.isInteger(itemTo) || itemFrom < from || itemTo > to || itemTo <= itemFrom ||
      !['link', 'wikilink', 'image', 'inlinecode', 'mathInline'].includes(type)) {
      return []
    }
    items.push({ index, type, from: itemFrom, to: itemTo })
    previousIndex = index
  }
  return items
}

export function lockedBlockAnchor(block, rect, viewportWidth, viewportHeight) {
  if (!block || block.dataset.editLocked !== 'true') return null
  const from = Number(block.dataset.sourceFrom)
  const to = Number(block.dataset.sourceTo)
  const left = Number(rect?.left)
  const top = Number(rect?.top)
  const right = Number(rect?.right)
  const bottom = Number(rect?.bottom)
  const width = Number(rect?.width)
  const height = Number(rect?.height)
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from ||
    !Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(right) || !Number.isFinite(bottom) ||
    !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 ||
    !Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight) ||
    viewportWidth <= 0 || viewportHeight <= 0 ||
    right <= 0 || bottom <= 0 || left >= viewportWidth || top >= viewportHeight) {
    return null
  }
  const type = block.dataset.sourceType ?? ''
  if (type.length === 0) return null
  return {
    type,
    from,
    to,
    inlineItems: inlineItemsForBlock(block),
    left,
    top,
    width,
    height,
    viewportWidth,
    viewportHeight
  }
}
