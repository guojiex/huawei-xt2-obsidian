export function appendShareWatermark(content, documentRef) {
  const body = content.querySelector('.preview-body')
  if (!body) {
    throw new Error('分享预览内容不可用，无法添加水印')
  }
  const existing = body.querySelector('.share-watermark')
  if (existing) {
    // 53.13：同一捕获 Web 连续分享时复用既有水印；清掉 PDF 徽标模式的内联样式，
    // 恢复流内默认样式（长图分享的水印仍为流内 footer）。
    existing.removeAttribute('style')
    return false
  }
  const watermark = documentRef.createElement('footer')
  watermark.className = 'share-watermark'
  watermark.textContent = '曜石笔记'
  body.appendChild(watermark)
  return true
}

/**
 * 53.13：PDF 分页前把流内水印转成脱离文档流的末页徽标并初始隐藏。
 * 水印不再参与 preparePdfPages 的分页 bounds——内容接近满页时，流内水印的
 * margin-top 会把它顶过页底，computePdfPageTops 会为它单独开一页，
 * 造成「预览与 PDF 多出一页整页空白」的回归（2026-11-13 XT2 实测）。
 * 徽标仅在读到末页（tops[last]）时由 setShareWatermarkVisibleAtScroll 显示。
 * 返回徽标元素供逐页显隐；无水印返回 null（调用方保持无水印行为）。
 */
export function prepareShareWatermarkForPdfCapture(body) {
  const watermark = body.querySelector('.share-watermark')
  if (!watermark) {
    return null
  }
  watermark.style.position = 'fixed'
  watermark.style.right = '0'
  watermark.style.bottom = '0'
  watermark.style.margin = '0'
  watermark.style.padding = 'var(--s2)'
  watermark.style.borderTop = 'none'
  watermark.style.background = 'var(--paper)'
  watermark.style.borderRadius = 'var(--pill) 0 0 0'
  watermark.style.display = 'none'
  return watermark
}

/**
 * 53.13：逐页滚动捕获时按页显隐水印徽标——仅末页（top === lastTop）显示。
 * 非末页隐藏保证 53.12 的非末页底部裁切不会把徽标裁掉。
 */
export function setShareWatermarkVisibleAtScroll(watermark, top, lastTop) {
  if (!watermark) {
    return
  }
  watermark.style.display = Math.abs(top - lastTop) < 1 ? '' : 'none'
}
