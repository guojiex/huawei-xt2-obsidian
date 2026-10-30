/**
 * mdpreview/src/index.ts —— M3：Web 组件内的 Markdown 预览渲染器（marked）。
 *
 * 打包：esbuild → 单文件 IIFE → 内联进 index.html → rawfile/mdpreview/index.html
 *      （与 web/mdeditor 同款链路，AGENTS.md §Web 打包约定：改了 src 必须重跑 build）
 *
 * 桥接协议（对称于 mdeditor，方向相反为主）：
 *   ArkTS → Web：window.__mdpreview.setContent(b64) / setNoteDir(b64) / setTheme(t)
 *   Web → ArkTS：window.__arkts.readAsset(b64 relPath) → data URI（同步返回，本地图片用）
 *
 * 本地图片渲染（3.1 的「图片」项）：vault 沙箱里的相对图片引用无法被 WebView 直接加载
 * （resource://rawfile 页面拿不到沙箱文件，api_notes B4：ArkWeb 禁 file/resource 跨域），
 * 所以渲染后对每个 <img> 走一遍 JS→ArkTS 同步桥：readAsset(库内相对路径) → data URI。
 * 网络图片（http/https/data 开头）不走过桥，直接交给 WebView 自己加载。
 */

import { marked } from 'marked'
import { renderMermaidSvg, renderNoteTags, resolveVaultImagePath, shareCaptureBottomPadding, splitFrontmatter } from './renderer.mjs'
import { renderMarkdownWithSourceBlocks, sourceScrollTop } from './sourceMapping.mjs'

declare global {
  interface Window {
    __mdpreview: MdPreviewApi
    __arkts?: {
      readAsset?: (relB64: string) => string
      onImageViewerChange?: (state: string) => void
      onShareCaptureResult?: (payload: string) => void
      onWorkspaceScroll?: (top: number) => void
    }
  }
}

/** 给 ArkTS 侧看的 API 面（setContent/setNoteDir 走 base64，避免引号/换行转义地狱） */
interface MdPreviewApi {
  setContent(b64: string): void
  setNoteDir(b64: string): void
  setTheme(theme: string): void
  resetDocument(): void
  closeImageViewer(): void
  scrollToHeading(index: number): void
  scrollToSourceLine(line: number, lineProgress: number, viewportRatio: number, atStart: boolean, atEnd: boolean): void
  cancelSourceFollow(): void
  restoreScrollTop(top: number): void
  requestShareCaptureMetrics(id: number): void
  prepareShareCapturePages(id: number, pageCount: number): void
  setShareCaptureScrollTop(id: number, top: number): void
}

// ---------- base64（浏览器侧，处理 UTF-8，与 mdeditor 同款） ----------
function b64encode(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let bin = ''
  for (let i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i])
  }
  return btoa(bin)
}

function b64decode(b64: string): string {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i)
  }
  return new TextDecoder().decode(bytes)
}

/** 当前笔记所在目录（库内相对，'' = 根目录）—— 相对图片引用的解析基准 */
let noteDir = ''
let mermaidRender: Promise<void> = Promise.resolve()
let mermaidRenderGeneration = 0

/**
 * 渲染后处理 <img>：本地相对引用 → __arkts.readAsset 换成 data URI。
 * ⚠️ 必须挂在对象上直接调用（mdeditor L-4 踩坑：detach 调用会被桥接接收者校验拒绝），
 * 所以这里写 `window.__arkts.readAsset(...)` 而不是先取出来再调。
 */
function localizeImages(root: HTMLElement): void {
  const imgs = root.querySelectorAll('img')
  for (let i = 0; i < imgs.length; i++) {
    const img = imgs[i] as HTMLImageElement
    const src = img.getAttribute('src') ?? ''
    if (src.length === 0 || src.startsWith('//') || /^(https?:|data:|blob:)/i.test(src)) {
      continue
    }
    const rel = resolveVaultImagePath(noteDir, src)
    try {
      const arkts = window.__arkts
      if (arkts && typeof arkts.readAsset === 'function') {
        const dataUri = arkts.readAsset(b64encode(rel))
        if (dataUri.length > 0) {
          img.src = dataUri
          img.dataset.shareLocal = 'true'
          img.classList.add('preview-local-image')
          img.tabIndex = 0
          img.setAttribute('role', 'button')
          img.setAttribute('title', '点击查看完整图片')
          img.addEventListener('click', () => openImage(img))
          img.addEventListener('keydown', (event: KeyboardEvent) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault()
              openImage(img)
            }
          })
        } else {
          img.alt = src + '（图片不存在）'
        }
      }
    } catch (error) {
      console.log('[mdpreview] readAsset threw: ' + String(error))
    }
  }
}

let imageReturnTarget: HTMLImageElement | null = null
let imageReturnScrollTop = 0

function notifyImageViewerChange(open: boolean): void {
  const arkts = window.__arkts
  if (arkts && typeof arkts.onImageViewerChange === 'function') {
    arkts.onImageViewerChange(open ? 'open' : 'closed')
  }
}

function openImage(image: HTMLImageElement): void {
  const content = document.getElementById('content') as HTMLElement
  const fullImage = document.getElementById('image-viewer-full') as HTMLImageElement
  const viewer = document.getElementById('image-viewer') as HTMLElement
  imageReturnTarget = image
  imageReturnScrollTop = content.scrollTop
  fullImage.src = image.src
  fullImage.alt = image.alt
  const scroll = document.getElementById('image-viewer-scroll') as HTMLElement
  scroll.scrollTop = 0
  viewer.classList.remove('hidden')
  notifyImageViewerChange(true)
  document.getElementById('image-viewer-close')?.focus()
}

function closeImageViewer(): void {
  const viewer = document.getElementById('image-viewer') as HTMLElement
  if (viewer.classList.contains('hidden')) {
    return
  }
  viewer.classList.add('hidden')
  const fullImage = document.getElementById('image-viewer-full') as HTMLImageElement
  fullImage.removeAttribute('src')
  notifyImageViewerChange(false)
  if (imageReturnTarget && imageReturnTarget.isConnected) {
    imageReturnTarget.focus()
  }
  const content = document.getElementById('content') as HTMLElement
  content.scrollTop = imageReturnScrollTop
  imageReturnTarget = null
}

function resetPreviewDocument(): void {
  cancelSourceFollow()
  closeImageViewer()
  const content = document.getElementById('content') as HTMLElement
  workspaceScrollRestoreGeneration++
  workspaceScrollRestorePending = false
  if (workspaceScrollTimer !== undefined) {
    window.clearTimeout(workspaceScrollTimer)
    workspaceScrollTimer = undefined
  }
  workspaceScrollReportSuppressedUntil = Date.now() + 250
  content.scrollTop = 0
}

const viewer = document.getElementById('image-viewer') as HTMLElement
document.getElementById('image-viewer-close')?.addEventListener('click', closeImageViewer)
viewer.addEventListener('click', (event: MouseEvent) => {
  if (event.target === viewer) {
    closeImageViewer()
  }
})
document.addEventListener('keydown', (event: KeyboardEvent) => {
  if (viewer.classList.contains('hidden')) {
    return
  }
  if (event.key === 'Escape') {
    event.preventDefault()
    closeImageViewer()
  } else if (event.key === 'Tab') {
    const close = document.getElementById('image-viewer-close') as HTMLElement
    const scroll = document.getElementById('image-viewer-scroll') as HTMLElement
    if (event.shiftKey && document.activeElement === close) {
      event.preventDefault()
      scroll.focus()
    } else if (!event.shiftKey && document.activeElement === scroll) {
      event.preventDefault()
      close.focus()
    }
  }
})

function updateImageBounds(): void {
  const content = document.getElementById('content') as HTMLElement
  const height = content.clientHeight
  const ratio = parseFloat(getComputedStyle(document.documentElement)
    .getPropertyValue('--preview-image-max-ratio'))
  if (height > 0 && Number.isFinite(ratio) && ratio > 0) {
    content.style.setProperty('--preview-image-max-height', `${height * ratio}px`)
  }
}

const contentResizeObserver = new ResizeObserver((): void => {
  updateImageBounds()
  invalidateSourceGeometry()
})
const contentElement = document.getElementById('content') as HTMLElement
contentResizeObserver.observe(contentElement)
window.addEventListener('resize', updateImageBounds)

let workspaceScrollTimer: number | undefined = undefined
let workspaceScrollRestorePending = false
let workspaceScrollReportSuppressedUntil = 0
let workspaceScrollRestoreGeneration = 0

interface SourceBlockGeometry {
  startLine: number
  endLine: number
  top: number
  height: number
}

interface SourceFollowAnchor {
  line: number
  lineProgress: number
  viewportRatio: number
  atStart: boolean
  atEnd: boolean
}

let sourceBlockGeometry: SourceBlockGeometry[] = []
let sourceGeometryDirty = true
let sourceFollowAnchor: SourceFollowAnchor | null = null
let sourceFollowFrame = 0
let sourceBlockResizeObserver: ResizeObserver | null = null
let workspaceUserScrollIntent = false
let workspaceUserScrollIntentReported = false
let workspaceUserScrollIntentTimer: number | undefined = undefined

function measureSourceBlocks(): void {
  const rootRect = contentElement.getBoundingClientRect()
  const wrappers = contentElement.querySelectorAll('.preview-source-block')
  const measured: SourceBlockGeometry[] = []
  for (let i = 0; i < wrappers.length; i++) {
    const wrapper = wrappers[i] as HTMLElement
    let top = Number.POSITIVE_INFINITY
    let bottom = Number.NEGATIVE_INFINITY
    for (let childIndex = 0; childIndex < wrapper.children.length; childIndex++) {
      const child = wrapper.children[childIndex] as HTMLElement
      const rect = child.getBoundingClientRect()
      if (rect.height > 0) {
        top = Math.min(top, rect.top)
        bottom = Math.max(bottom, rect.bottom)
      }
    }
    if (!Number.isFinite(top) || !Number.isFinite(bottom) || bottom <= top) {
      continue
    }
    const startLine = Number(wrapper.dataset.sourceStartLine)
    const endLine = Number(wrapper.dataset.sourceEndLine)
    if (!Number.isFinite(startLine) || !Number.isFinite(endLine)) {
      continue
    }
    measured.push({
      startLine: startLine,
      endLine: endLine,
      top: top - rootRect.top + contentElement.scrollTop,
      height: bottom - top
    })
  }
  sourceBlockGeometry = measured
  sourceGeometryDirty = false
}

function scheduleSourceFollow(): void {
  if (sourceFollowAnchor === null || sourceFollowFrame !== 0) {
    return
  }
  sourceFollowFrame = window.requestAnimationFrame((): void => {
    sourceFollowFrame = 0
    const anchor = sourceFollowAnchor
    if (anchor === null) {
      return
    }
    if (sourceGeometryDirty) {
      measureSourceBlocks()
    }
    const maxTop = Math.max(0, contentElement.scrollHeight - contentElement.clientHeight)
    const top = sourceScrollTop(sourceBlockGeometry, anchor.line, anchor.lineProgress, anchor.viewportRatio,
      contentElement.clientHeight, maxTop, anchor.atStart, anchor.atEnd)
    if (Math.abs(contentElement.scrollTop - top) <= 1) {
      return
    }
    if (workspaceScrollTimer !== undefined) {
      window.clearTimeout(workspaceScrollTimer)
      workspaceScrollTimer = undefined
    }
    contentElement.scrollTop = top
  })
}

function invalidateSourceGeometry(): void {
  sourceGeometryDirty = true
  scheduleSourceFollow()
}

function observeSourceBlocks(): void {
  if (sourceBlockResizeObserver !== null) {
    sourceBlockResizeObserver.disconnect()
  }
  sourceBlockResizeObserver = new ResizeObserver((): void => {
    invalidateSourceGeometry()
  })
  const children = contentElement.querySelectorAll('.preview-source-block > *')
  for (let i = 0; i < children.length; i++) {
    sourceBlockResizeObserver.observe(children[i])
  }
  sourceGeometryDirty = true
  scheduleSourceFollow()
}

function reportWorkspaceScrollIntent(): void {
  if (workspaceUserScrollIntentReported) {
    return
  }
  workspaceUserScrollIntentReported = true
  sourceFollowAnchor = null
  if (sourceFollowFrame !== 0) {
    window.cancelAnimationFrame(sourceFollowFrame)
    sourceFollowFrame = 0
  }
}

function cancelSourceFollow(): void {
  sourceFollowAnchor = null
  if (sourceFollowFrame !== 0) {
    window.cancelAnimationFrame(sourceFollowFrame)
    sourceFollowFrame = 0
  }
  workspaceUserScrollIntent = false
  workspaceUserScrollIntentReported = false
  if (workspaceUserScrollIntentTimer !== undefined) {
    window.clearTimeout(workspaceUserScrollIntentTimer)
    workspaceUserScrollIntentTimer = undefined
  }
}

function markWorkspaceScrollIntent(event: Event): void {
  if (event.type === 'keydown') {
    const key = (event as KeyboardEvent).key
    if (!['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(key)) {
      return
    }
  }
  workspaceUserScrollIntent = true
  workspaceUserScrollIntentReported = false
  if (workspaceUserScrollIntentTimer !== undefined) {
    window.clearTimeout(workspaceUserScrollIntentTimer)
  }
  workspaceUserScrollIntentTimer = window.setTimeout((): void => {
    workspaceUserScrollIntent = false
    workspaceUserScrollIntentReported = false
    workspaceUserScrollIntentTimer = undefined
  }, 500)
}

for (const type of ['wheel', 'touchstart', 'touchmove', 'pointerdown', 'keydown']) {
  contentElement.addEventListener(type, markWorkspaceScrollIntent, { passive: true, capture: true })
}

const sourceMutationObserver = new MutationObserver((records: MutationRecord[]): void => {
  const sourceChildrenChanged: boolean = records.some((record: MutationRecord): boolean => {
    if (record.type !== 'childList') {
      return false
    }
    const target = record.target as Element
    return target === contentElement || target.classList?.contains('preview-source-block') === true
  })
  if (sourceChildrenChanged) {
    observeSourceBlocks()
  } else {
    invalidateSourceGeometry()
  }
})
sourceMutationObserver.observe(contentElement, { childList: true, characterData: true, subtree: true })
window.addEventListener('resize', invalidateSourceGeometry)

contentElement.addEventListener('scroll', (): void => {
  if (workspaceUserScrollIntent && !workspaceUserScrollIntentReported) {
    reportWorkspaceScrollIntent()
  }
  if (workspaceScrollTimer !== undefined) {
    window.clearTimeout(workspaceScrollTimer)
    workspaceScrollTimer = undefined
  }
  if (workspaceScrollRestorePending || Date.now() < workspaceScrollReportSuppressedUntil) {
    return
  }
  workspaceScrollTimer = window.setTimeout((): void => {
    workspaceScrollTimer = undefined
    const arkts = window.__arkts
    if (arkts && typeof arkts.onWorkspaceScroll === 'function') {
      arkts.onWorkspaceScroll(Math.max(0, contentElement.scrollTop))
    }
  }, 200)
}, { passive: true })

function shareCaptureMetrics(): { scrollHeight: number; viewportHeight: number; viewportWidth: number; scrollTop: number } {
  const content = document.getElementById('content') as HTMLElement
  return {
    scrollHeight: content.scrollHeight,
    viewportHeight: content.clientHeight,
    viewportWidth: content.clientWidth,
    scrollTop: content.scrollTop
  }
}

function sendShareCaptureResult(id: number, errorText: string = ''): void {
  const arkts = window.__arkts
  if (!arkts || typeof arkts.onShareCaptureResult !== 'function') {
    return
  }
  const metrics = shareCaptureMetrics()
  arkts.onShareCaptureResult(JSON.stringify({
    id: id,
    error: errorText,
    scrollHeight: metrics.scrollHeight,
    viewportHeight: metrics.viewportHeight,
    viewportWidth: metrics.viewportWidth,
    scrollTop: metrics.scrollTop
  }))
}

async function waitForLocalImages(root: HTMLElement): Promise<void> {
  const images = root.querySelectorAll<HTMLImageElement>('img[data-share-local="true"]')
  for (let i = 0; i < images.length; i++) {
    const image = images[i]
    await image.decode()
    if (image.naturalWidth <= 0 || image.naturalHeight <= 0) {
      throw new Error('本地图片解码失败，无法生成完整分享图片')
    }
  }
}

function nextRenderedFrame(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    requestAnimationFrame((): void => {
      requestAnimationFrame((): void => resolve())
    })
  })
}

async function renderMermaidBlocks(root: HTMLElement, generation: number): Promise<void> {
  const blocks = root.querySelectorAll('.mermaid-block')
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i] as HTMLElement
    const source = block.querySelector('.mermaid-source')?.textContent ?? ''
    try {
      const svg = await renderMermaidSvg(source)
      if (generation !== mermaidRenderGeneration || !block.isConnected) {
        return
      }
      block.innerHTML = svg
      block.setAttribute('role', 'img')
      block.setAttribute('aria-label', 'Mermaid 图表')
    } catch (error) {
      if (generation !== mermaidRenderGeneration || !block.isConnected) {
        return
      }
      const fallback = document.createElement('div')
      fallback.className = 'mermaid-error'
      fallback.setAttribute('role', 'status')
      fallback.textContent = 'Mermaid 图语法错误，原代码保留在笔记中。'
      block.replaceChildren(fallback)
    }
  }
}

marked.setOptions({ gfm: true, breaks: false })

const api: MdPreviewApi = {
  setContent(b64: string): void {
    const text = b64decode(b64)
    const el = document.getElementById('content') as HTMLElement
    workspaceScrollRestoreGeneration++
    workspaceScrollRestorePending = false
    if (workspaceScrollTimer !== undefined) {
      window.clearTimeout(workspaceScrollTimer)
      workspaceScrollTimer = undefined
    }
    const split = splitFrontmatter(text)
    const tagsHtml = renderNoteTags(text)
    const bodyOffset = text.substring(0, text.length - split.body.length).split('\n').length - 1
    const renderedBody = split.body.trim().length === 0
      ? { html: '', blocks: [] }
      : renderMarkdownWithSourceBlocks(split.body, bodyOffset)
    const bodyHtml = renderedBody.html
    if (tagsHtml.length === 0 && bodyHtml.length === 0) {
      mermaidRenderGeneration++
      mermaidRender = Promise.resolve()
      el.innerHTML = '<div class="empty">空笔记</div>'
      sourceBlockGeometry = []
      observeSourceBlocks()
      updateImageBounds()
      console.log('[mdpreview] setContent: empty')
      return
    }
    el.innerHTML = tagsHtml + bodyHtml
    observeSourceBlocks()
    const headings = el.querySelectorAll('h1,h2,h3,h4,h5,h6')
    for (let i = 0; i < headings.length; i++) {
      headings[i].setAttribute('data-chapter-index', String(i))
    }
    const generation = ++mermaidRenderGeneration
    mermaidRender = renderMermaidBlocks(el, generation)
    localizeImages(el)
    updateImageBounds()
    console.log('[mdpreview] setContent len=' + text.length)
  },

  setNoteDir(b64: string): void {
    noteDir = b64decode(b64)
  },

  setTheme(theme: string): void {
    document.documentElement.setAttribute('data-theme', theme === 'dark' ? 'dark' : 'light')
  },

  resetDocument(): void {
    resetPreviewDocument()
  },

  closeImageViewer(): void {
    closeImageViewer()
  },

  scrollToHeading(index: number): void {
    const heading = document.querySelector(`#content [data-chapter-index="${index}"]`)
    heading?.scrollIntoView({ block: 'start', behavior: 'smooth' })
  },

  scrollToSourceLine(line: number, lineProgress: number, viewportRatio: number,
    atStart: boolean, atEnd: boolean): void {
    workspaceUserScrollIntent = false
    workspaceUserScrollIntentReported = false
    if (workspaceUserScrollIntentTimer !== undefined) {
      window.clearTimeout(workspaceUserScrollIntentTimer)
      workspaceUserScrollIntentTimer = undefined
    }
    sourceFollowAnchor = {
      line: Number.isFinite(line) ? Math.max(1, Math.floor(line)) : 1,
      lineProgress: Number.isFinite(lineProgress) ? Math.max(0, Math.min(1, lineProgress)) : 0,
      viewportRatio: Number.isFinite(viewportRatio) ? Math.max(0, Math.min(1, viewportRatio)) : 0,
      atStart: atStart,
      atEnd: atEnd
    }
    scheduleSourceFollow()
  },

  cancelSourceFollow(): void {
    cancelSourceFollow()
  },

  async restoreScrollTop(top: number): Promise<void> {
    const content = document.getElementById('content') as HTMLElement
    const generation = ++workspaceScrollRestoreGeneration
    workspaceScrollRestorePending = true
    if (workspaceScrollTimer !== undefined) {
      window.clearTimeout(workspaceScrollTimer)
      workspaceScrollTimer = undefined
    }
    try {
      await mermaidRender
      await waitForLocalImages(content)
    } catch (error) {
      // Missing images or a failed diagram must not prevent the text position from restoring.
    }
    await nextRenderedFrame()
    if (generation !== workspaceScrollRestoreGeneration) {
      return
    }
    const safeTop = Number.isFinite(top) ? Math.max(0, top) : 0
    const maxTop = Math.max(0, content.scrollHeight - content.clientHeight)
    workspaceScrollReportSuppressedUntil = Date.now() + 250
    content.scrollTop = Math.min(safeTop, maxTop)
    window.setTimeout((): void => {
      if (generation === workspaceScrollRestoreGeneration) {
        workspaceScrollRestorePending = false
      }
    }, 250)
  },

  async requestShareCaptureMetrics(id: number): Promise<void> {
    try {
      await mermaidRender
      await waitForLocalImages(document.getElementById('content') as HTMLElement)
      await nextRenderedFrame()
      sendShareCaptureResult(id)
    } catch (error) {
      sendShareCaptureResult(id, String(error))
    }
  },

  async prepareShareCapturePages(id: number, pageCount: number): Promise<void> {
    try {
      const content = document.getElementById('content') as HTMLElement
      const metrics = shareCaptureMetrics()
      if (!Number.isInteger(pageCount) || pageCount < 1 || metrics.viewportHeight <= 0) {
        throw new Error('分享图片分页参数无效')
      }
      const targetHeight = pageCount * metrics.viewportHeight
      const currentPadding = Number.parseFloat(getComputedStyle(content).paddingBottom) || 0
      content.style.paddingBottom = `${shareCaptureBottomPadding(metrics.scrollHeight,
        metrics.viewportHeight, pageCount, currentPadding)}px`
      content.scrollTop = 0
      await nextRenderedFrame()
      if (content.scrollHeight < targetHeight) {
        throw new Error('分享预览高度不足，无法完整分页')
      }
      sendShareCaptureResult(id)
    } catch (error) {
      sendShareCaptureResult(id, String(error))
    }
  },

  async setShareCaptureScrollTop(id: number, top: number): Promise<void> {
    try {
      const content = document.getElementById('content') as HTMLElement
      if (!Number.isFinite(top) || top < 0) {
        throw new Error('分享图片滚动位置无效')
      }
      content.scrollTop = top
      await nextRenderedFrame()
      sendShareCaptureResult(id)
    } catch (error) {
      sendShareCaptureResult(id, String(error))
    }
  }
}

window.__mdpreview = api
console.log('[mdpreview] script loaded')
