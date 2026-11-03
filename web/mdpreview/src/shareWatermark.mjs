export function appendShareWatermark(content, documentRef) {
  const body = content.querySelector('.preview-body')
  if (!body) {
    throw new Error('分享预览内容不可用，无法添加水印')
  }
  if (body.querySelector('.share-watermark')) {
    return false
  }
  const watermark = documentRef.createElement('footer')
  watermark.className = 'share-watermark'
  watermark.textContent = '曜石笔记'
  body.appendChild(watermark)
  return true
}
