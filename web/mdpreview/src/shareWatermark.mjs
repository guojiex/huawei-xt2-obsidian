export function appendShareWatermark(content, documentRef) {
  const body = content.querySelector('.preview-body')
  if (!body) {
    throw new Error('分享预览内容不可用，无法添加水印')
  }
  const existing = body.querySelector('.share-watermark')
  if (existing) {
    // 同一捕获 Web 连续分享时复用既有水印；顺手清掉可能残留的内联样式，
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
