/**
 * pdfPagination.mjs —— PDF 导出的逐页分页纯函数（v1.53 53.2）。
 *
 * 输入是块边界数据（不依赖 DOM），Node 可直接切片测试。
 * 分页规则：块边界贪心——块放得下当前页则继续；放不下且块高不超页高则新页从该块顶
 * 开始（不切断文字行 / 代码块）；单块自身超页高按页高硬切兜底。
 */

export const MAX_PDF_PAGES = 100

export function computePdfPageTops(bounds, pageHeight) {
  if (!Number.isFinite(pageHeight) || pageHeight <= 0) {
    throw new Error('PDF 页高参数无效')
  }
  if (!Array.isArray(bounds)) {
    throw new Error('PDF 分页输入无效')
  }
  const tops = [0]
  let currentTop = 0
  for (let i = 0; i < bounds.length; i++) {
    const bound = bounds[i]
    const top = bound ? bound.top : NaN
    const bottom = bound ? bound.bottom : NaN
    if (!Number.isFinite(top) || !Number.isFinite(bottom) || bottom <= top) {
      continue
    }
    if (bottom - currentTop <= pageHeight) {
      continue
    }
    if (top > currentTop && bottom - top <= pageHeight) {
      currentTop = top
      tops.push(currentTop)
    } else {
      while (bottom - currentTop > pageHeight) {
        currentTop = currentTop + pageHeight
        tops.push(currentTop)
      }
    }
    if (tops.length > MAX_PDF_PAGES) {
      throw new Error('笔记超过单文件 PDF 页数上限；请改用 Markdown / ZIP')
    }
  }
  return tops
}

export function pdfBottomPadding(tops, pageHeight, scrollHeight, currentPadding) {
  if (!Array.isArray(tops) || tops.length === 0) {
    throw new Error('PDF 分页结果为空')
  }
  if (!Number.isFinite(pageHeight) || pageHeight <= 0) {
    throw new Error('PDF 页高参数无效')
  }
  if (!Number.isFinite(scrollHeight) || scrollHeight < 0) {
    throw new Error('PDF 内容高度无效')
  }
  const basePadding = Number.isFinite(currentPadding) && currentPadding > 0 ? currentPadding : 0
  const lastTop = tops[tops.length - 1]
  const missing = lastTop + pageHeight - scrollHeight
  return basePadding + Math.max(0, missing)
}
