export function selectedLockedBlocks(blocks, selection, sourceBlockForNode) {
  const candidates = Array.from(blocks)
  if (!selection || selection.rangeCount === 0) return []

  if (selection.isCollapsed) {
    const block = sourceBlockForNode(selection.anchorNode)
    if (block?.dataset.sourceType === 'paragraph') return []
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
  const tableReady = block?.dataset.sourceType === 'table' &&
    block.dataset.tableStructureEditable === 'true'
  return (block?.dataset.editLocked === 'true' || tableReady) && candidates.includes(block) ? block : null
}

export function codeBlockForSourceRange(blocks, from, to) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to <= from) return null
  for (const block of Array.from(blocks)) {
    if (block.dataset?.sourceType === 'code' &&
      Number(block.dataset.sourceFrom) === from && Number(block.dataset.sourceTo) === to) {
      return block
    }
  }
  return null
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
      !['link', 'wikilink', 'image', 'inlinecode', 'mathInline', 'footnoteRef'].includes(type)) {
      return []
    }
    items.push({ index, type, from: itemFrom, to: itemTo })
    previousIndex = index
  }
  return items
}

export function lockedBlockAnchor(block, rect, viewportWidth, viewportHeight) {
  const type = block?.dataset.sourceType ?? ''
  const tableReady = type === 'table' && block.dataset.tableStructureEditable === 'true'
  if (!block || (block.dataset.editLocked !== 'true' && !tableReady)) {
    return null
  }
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
  if (type.length === 0) return null
  const anchor = {
    type,
    from,
    to,
    inlineItems: inlineItemsForBlock(block),
    inlineSafe: block.dataset.inlineSafe === 'true',
    left,
    top,
    width,
    height,
    viewportWidth,
    viewportHeight
  }
  if (type === 'table') {
    Object.assign(anchor, {
      tableRow: Number(block.dataset.tableActiveRow ?? -1),
      tableColumn: Number(block.dataset.tableActiveColumn ?? -1),
      tableRows: Number(block.dataset.tableRows ?? 0),
      tableColumns: Number(block.dataset.tableColumns ?? 0),
      tableStructureEditable: tableReady
    })
  }
  if (type === 'code') {
    let codeLanguages = []
    try {
      const parsed = JSON.parse(block.dataset.codeLanguages ?? '[]')
      if (Array.isArray(parsed)) codeLanguages = parsed.filter((language) => typeof language === 'string')
    } catch {}
    Object.assign(anchor, {
      codeLanguage: block.dataset.codeLanguage ?? '',
      codeLanguageFrom: Number(block.dataset.codeLanguageFrom ?? -1),
      codeLanguageTo: Number(block.dataset.codeLanguageTo ?? -1),
      codeLanguageSelectable: block.dataset.codeLanguageSelectable === 'true',
      codeLanguages,
      codeEditable: block.dataset.codeEditable === 'true'
    })
  }
  return anchor
}
