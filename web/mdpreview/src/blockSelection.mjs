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
