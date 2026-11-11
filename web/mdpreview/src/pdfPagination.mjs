/**
 * pdfPagination.mjs —— PDF 导出的逐页分页纯函数（v1.53 53.2）。
 *
 * 输入是块边界数据（不依赖 DOM），Node 可直接切片测试。
 * 分页规则：块边界贪心——块放得下当前页则继续；放不下且块高不超页高则新页从该块顶
 * 开始（不切断文字行 / 代码块）；单块自身超页高按页高硬切兜底。
 */

export const MAX_PDF_PAGES = 100

/**
 * 标题与下一块合并为一个分页单元（v2 原型 53.7 规则）：标题不孤悬页尾。
 * 输入块的 heading 为 true 表示该块是 h1-h6；自后向前扫描，标题块吞并紧随其后的
 * 块（bottom 取后者），连续标题链式合并（H1+H2+正文 → 一个单元）。
 * 末尾的标题块无后继，保持原样；不修改输入数组。
 */
export function mergeHeadingUnits(bounds) {
  if (!Array.isArray(bounds)) {
    throw new Error('PDF 分页输入无效')
  }
  const units = []
  for (let i = 0; i < bounds.length; i++) {
    const bound = bounds[i]
    const top = bound ? bound.top : NaN
    const bottom = bound ? bound.bottom : NaN
    if (!Number.isFinite(top) || !Number.isFinite(bottom) || bottom <= top) {
      continue
    }
    units.push({ top: top, bottom: bottom, heading: !!(bound && bound.heading) })
  }
  for (let k = units.length - 2; k >= 0; k--) {
    if (units[k].heading) {
      units[k] = { top: units[k].top, bottom: units[k + 1].bottom, heading: true }
      units.splice(k + 1, 1)
    }
  }
  return units
}

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
  // scrollHeight / clientHeight 是浏览器取整值：真实可滚动高度可比报告值小 0.5px，
  // 末页顶为小数（块边界）时按取整值补白会差半像素（2026-11-11 修复）。
  // 恒定多补 1px 舍入余量，保证最终 scrollHeight ≥ 末页顶 + 页高；多余 1px 落在
  // 末页空白，不可见。
  return basePadding + Math.max(0, missing) + 1
}
