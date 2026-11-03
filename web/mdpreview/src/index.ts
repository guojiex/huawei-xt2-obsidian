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
import { normalizePreviewZoomPercent } from './previewZoom.mjs'
import { lockedBlockAnchor, selectedLockedBlocks, toolbarBlockForSelection } from './blockSelection.mjs'

declare global {
  interface Window {
    __mdpreview: MdPreviewApi
    __arkts?: {
      readAsset?: (relB64: string) => string
      onImageViewerChange?: (state: string) => void
      onShareCaptureResult?: (payload: string) => void
      onWorkspaceScroll?: (top: number) => void
      onEditableContentChange?: (contentB64: string) => void
      onEditableContent?: (id: number, contentB64: string) => void
      onCompositionChange?: (state: string) => void
      onLockedContentTap?: () => void
      onLockedBlockSelection?: (payload: string) => void
      onPreviewZoomChange?: (percent: number) => void
    }
  }
}

/** 给 ArkTS 侧看的 API 面（setContent/setNoteDir 走 base64，避免引号/换行转义地狱） */
interface MdPreviewApi {
  setContent(b64: string, sourceB64?: string, sourceMapB64?: string): void
  setEditable(editable: boolean): void
  applyFormat(kind: string): void
  insertText(b64: string): void
  flushEditableContent(id: number): void
  setNoteDir(b64: string): void
  setTheme(theme: string): void
  setPreviewZoomPercent(percent: number): void
  setPreviewZoomControlsVisible(visible: boolean): void
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
let sourceText = ''
let sourceEdits: Array<{ displayStart: number; displayEnd: number; sourceStart: number; sourceEnd: number }> = []
let editable = false
let editableChangeTimer: number | undefined
let editableComposing = false
let savedEditableSelection: Range | null = null
let activeToolbarBlock: HTMLElement | null = null
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
      console.warn('[mdpreview] readAsset failed')
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
const previewZoomControls = document.getElementById('preview-zoom-controls') as HTMLElement
const previewZoomSelect = document.getElementById('preview-zoom-select') as HTMLSelectElement
const previewZoomReset = document.getElementById('preview-zoom-reset') as HTMLButtonElement
contentResizeObserver.observe(contentElement)
window.addEventListener('resize', updateImageBounds)

let previewZoomControlsVisible = false
let previewZoomFadeTimer: number | undefined

function previewZoomControlFocused(): boolean {
  return previewZoomControls.contains(document.activeElement)
}

function schedulePreviewZoomFade(): void {
  if (!previewZoomControlsVisible) {
    return
  }
  if (previewZoomFadeTimer !== undefined) {
    window.clearTimeout(previewZoomFadeTimer)
    previewZoomFadeTimer = undefined
  }
  if (previewZoomControlFocused()) {
    previewZoomControls.classList.remove('is-scrolling')
    return
  }
  previewZoomControls.classList.add('is-scrolling')
  previewZoomFadeTimer = window.setTimeout((): void => {
    previewZoomFadeTimer = undefined
    if (!previewZoomControlFocused()) {
      previewZoomControls.classList.remove('is-scrolling')
    }
  }, 900)
}

function setPreviewZoomPercent(value: number, notifyNative: boolean = false): void {
  const percent = normalizePreviewZoomPercent(value)
  document.documentElement.style.setProperty('--preview-scale', String(percent / 100))
  previewZoomSelect.value = String(percent)
  previewZoomReset.hidden = percent === 100
  invalidateSourceGeometry()
  publishLockedBlockAnchor(activeToolbarBlock)
  if (notifyNative) {
    const arkts = window.__arkts
    if (arkts && typeof arkts.onPreviewZoomChange === 'function') {
      arkts.onPreviewZoomChange(percent)
    }
  }
}

function setPreviewZoomControlsVisible(visible: boolean): void {
  previewZoomControlsVisible = visible
  previewZoomControls.hidden = !visible
  previewZoomControls.classList.remove('is-scrolling')
  if (previewZoomFadeTimer !== undefined) {
    window.clearTimeout(previewZoomFadeTimer)
    previewZoomFadeTimer = undefined
  }
}

previewZoomSelect.addEventListener('change', (): void => {
  setPreviewZoomPercent(Number(previewZoomSelect.value), true)
})
previewZoomReset.addEventListener('click', (): void => {
  setPreviewZoomPercent(100, true)
})
previewZoomControls.addEventListener('focusin', (): void => {
  if (previewZoomFadeTimer !== undefined) {
    window.clearTimeout(previewZoomFadeTimer)
    previewZoomFadeTimer = undefined
  }
  previewZoomControls.classList.remove('is-scrolling')
})

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
  schedulePreviewZoomFade()
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

function notifyEditableContentChange(): void {
  if (!editable || editableComposing) return
  if (editableChangeTimer !== undefined) window.clearTimeout(editableChangeTimer)
  editableChangeTimer = window.setTimeout(() => {
    editableChangeTimer = undefined
    const arkts = window.__arkts
    if (arkts && typeof arkts.onEditableContentChange === 'function') {
      arkts.onEditableContentChange(b64encode(sourceText))
    }
  }, 180)
}

function markdownText(text: string): string {
  return text.replace(/([\\`*_{}\[\]<>#+.!|~])/g, '\\$1')
}

function serializeInline(node: Node): string {
  if (node.nodeType === Node.TEXT_NODE) return markdownText(node.textContent ?? '')
  if (!(node instanceof HTMLElement)) return ''
  if (node.dataset.sourceMarkdown) return node.dataset.sourceMarkdown
  if (node.tagName === 'INPUT') return ''
  if (node.tagName === 'BR') return '  \n'
  const children = Array.from(node.childNodes).map((child) => serializeInline(child)).join('')
  if (node.tagName === 'STRONG' || node.tagName === 'B') return `**${children}**`
  if (node.tagName === 'EM' || node.tagName === 'I') return `*${children}*`
  if (node.tagName === 'DEL' || node.tagName === 'S') return `~~${children}~~`
  return children
}

function serializeList(list: HTMLElement, ordered: boolean): string {
  const items = list.querySelectorAll(':scope > li')
  const rows: string[] = []
  for (let index = 0; index < items.length; index++) {
    const item = items[index]
    const checkbox = item.querySelector(':scope > input[type="checkbox"]') as HTMLInputElement | null
    const nested = item.querySelector(':scope > ul, :scope > ol') as HTMLElement | null
    const clone = item.cloneNode(true) as HTMLElement
    clone.querySelector(':scope > input[type="checkbox"]')?.remove()
    clone.querySelector(':scope > ul, :scope > ol')?.remove()
    const text = serializeInline(clone).trim()
    const marker = checkbox ? (checkbox.checked ? '- [x] ' : '- [ ] ') :
      (ordered ? `${index + 1}. ` : '- ')
    rows.push(marker + text)
    if (nested) {
      rows.push(...serializeList(nested, nested.tagName === 'OL').split('\n').map((line) => '  ' + line))
    }
  }
  return rows.join('\n')
}

function serializeEditedBlock(block: HTMLElement): string {
  const children = Array.from(block.children).filter((child) => !child.classList.contains('preview-edit-hint'))
  if (children.length === 0) return serializeInline(block).trim()
  const rendered = children.map((child) => {
    const element = child as HTMLElement
    if (/^H[1-6]$/.test(element.tagName)) {
      return `${'#'.repeat(Number(element.tagName.slice(1)))} ${serializeInline(element).trim()}`
    }
    if (element.tagName === 'UL' || element.tagName === 'OL') {
      return serializeList(element, element.tagName === 'OL')
    }
    if (element.tagName === 'BLOCKQUOTE') {
      return serializeEditedBlock(element).split('\n').map((line) => `> ${line}`).join('\n')
    }
    if (element.tagName === 'P') return serializeInline(element).trim()
    if (element.tagName === 'DIV') return serializeInline(element).trim()
    return serializeInline(element).trim()
  }).filter((text) => text.length > 0)
  return rendered.join('\n\n')
}

function containsLockedSyntax(block: HTMLElement): boolean {
  const from = Number(block.dataset.sourceFrom)
  const to = Number(block.dataset.sourceTo)
  const raw = Number.isInteger(from) && Number.isInteger(to) && from >= 0 && to >= from
    ? sourceText.slice(from, to) : ''
  return block.textContent?.includes('[[') === true ||
    block.querySelector('a, img, code, pre, details, .callout, .math-error, .mermaid-block') !== null ||
    /%%|\[\^[^\]]+\]|==|\$\$|(?:^|\s)\^[\w-]+\s*$|^\s*:{3,}/m.test(raw)
}

function editableElementFor(block: HTMLElement): HTMLElement | null {
  if (block.classList.contains('empty')) return block
  const child = block.firstElementChild
  if (!(child instanceof HTMLElement)) return null
  if (/^(P|H[1-6]|UL|OL|BLOCKQUOTE|DIV)$/.test(child.tagName)) return child
  return null
}

function sourceBlockForNode(node: Node | null): HTMLElement | null {
  const element = node instanceof HTMLElement ? node : node?.parentElement
  return element?.closest('.preview-source-block, .empty[data-source-from]') as HTMLElement | null;
}

function setActiveLockedBlocks(root: HTMLElement, selected: HTMLElement[]): void {
  const activeBlocks = root.querySelectorAll('.preview-source-block.simple-block-active')
  for (let index = 0; index < activeBlocks.length; index++) {
    const block = activeBlocks[index] as HTMLElement
    if (!selected.includes(block)) block.classList.remove('simple-block-active')
  }
  for (const block of selected) {
    block.classList.add('simple-block-active')
  }
}

function publishLockedBlockAnchor(block: HTMLElement | null): void {
  activeToolbarBlock = block
  const rect = block?.getBoundingClientRect()
  const anchor = rect ? lockedBlockAnchor(block, rect, window.innerWidth, window.innerHeight) : null
  const arkts = window.__arkts
  if (arkts && typeof arkts.onLockedBlockSelection === 'function') {
    arkts.onLockedBlockSelection(anchor ? JSON.stringify(anchor) : '')
  }
}

function configureEditableBlocks(root: HTMLElement, bodyOffset: number): void {
  setActiveLockedBlocks(root, [])
  publishLockedBlockAnchor(null)
  const previousEditables = root.querySelectorAll('[data-simple-editable="true"]')
  for (let index = 0; index < previousEditables.length; index++) {
    const element = previousEditables[index] as HTMLElement
    element.removeAttribute('contenteditable')
    element.removeAttribute('aria-label')
    element.removeAttribute('data-simple-editable')
  }
  const blocks = root.querySelectorAll('.preview-source-block')
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index] as HTMLElement
    block.removeAttribute('contenteditable')
    block.removeAttribute('aria-label')
    block.removeAttribute('data-edit-locked')
    const type = block.dataset.sourceType ?? ''
    const supported = type === 'paragraph' || type === 'heading' || type === 'list' || type === 'blockquote'
    if (!editable) continue
    if (!supported || containsLockedSyntax(block)) {
      block.dataset.editLocked = 'true'
      block.setAttribute('aria-label', '此内容请在专业模式编辑')
      continue
    }
    if (editableElementFor(block)) {
      block.setAttribute('contenteditable', 'true')
      block.setAttribute('data-simple-editable', 'true')
      block.setAttribute('aria-label', '可编辑正文')
    }
  }

  let empty = root.querySelector('.empty') as HTMLElement | null
  if (editable && !empty && root.querySelector('.preview-source-block') === null) {
    empty = document.createElement('div')
    empty.className = 'empty'
    empty.dataset.placeholder = '在此输入正文'
    empty.dataset.simpleGenerated = 'true'
    root.appendChild(empty)
  } else if (!editable && empty?.dataset.simpleGenerated === 'true') {
    empty.remove()
    return
  }
  if (empty && editable) {
    empty.setAttribute('contenteditable', 'true')
    empty.setAttribute('data-simple-editable', 'true')
    empty.dataset.sourceFrom = String(bodyOffset)
    empty.dataset.sourceTo = String(sourceText.length)
    empty.dataset.sourceType = 'paragraph'
  } else if (empty) {
    empty.removeAttribute('contenteditable')
    empty.removeAttribute('data-simple-editable')
    delete empty.dataset.sourceFrom
    delete empty.dataset.sourceTo
    delete empty.dataset.sourceType
  }
}

function replaceSourceBlock(block: HTMLElement): void {
  const from = Number(block.dataset.sourceFrom)
  const to = Number(block.dataset.sourceTo)
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from || to > sourceText.length) return
  const previous = sourceText.slice(from, to)
  const suffix = /(?:\r?\n)*$/.exec(previous)?.[0] ?? ''
  const replacement = serializeEditedBlock(block).replace(/(?:\r?\n)*$/, '') + suffix
  sourceText = sourceText.slice(0, from) + replacement + sourceText.slice(to)
  const delta = replacement.length - (to - from)
  block.dataset.sourceTo = String(from + replacement.length)
  const blocks = document.querySelectorAll('.preview-source-block, .empty[data-source-from]')
  for (let index = 0; index < blocks.length; index++) {
    const other = blocks[index] as HTMLElement
    if (other === block) continue
    const otherFrom = Number(other.dataset.sourceFrom)
    const otherTo = Number(other.dataset.sourceTo)
    if (otherFrom >= to) {
      other.dataset.sourceFrom = String(otherFrom + delta)
      other.dataset.sourceTo = String(otherTo + delta)
    }
  }
  notifyEditableContentChange()
}

contentElement.addEventListener('compositionstart', (): void => {
  if (!editable) return
  editableComposing = true
  const arkts = window.__arkts
  if (arkts && typeof arkts.onCompositionChange === 'function') arkts.onCompositionChange('start')
})
contentElement.addEventListener('compositionend', (): void => {
  if (!editable) return
  editableComposing = false
  const arkts = window.__arkts
  if (arkts && typeof arkts.onCompositionChange === 'function') arkts.onCompositionChange('end')
  const target = sourceBlockForNode(window.getSelection()?.anchorNode ?? document.activeElement)
  if (target) replaceSourceBlock(target)
  else notifyEditableContentChange()
})
contentElement.addEventListener('beforeinput', (event: InputEvent): void => {
  if (!editable) return
  const selection = window.getSelection()
  if (!selection || selection.rangeCount === 0) return
  const range = selection.getRangeAt(0)
  const startBlock = sourceBlockForNode(range.startContainer)
  const endBlock = sourceBlockForNode(range.endContainer)
  if (startBlock !== endBlock) event.preventDefault()
})
contentElement.addEventListener('input', (event: Event): void => {
  if (!editable || editableComposing) return
  const target = event.target instanceof HTMLElement
    ? event.target.closest('.preview-source-block, .empty[data-source-from]') as HTMLElement | null : null
  if (target) replaceSourceBlock(target)
})
document.addEventListener('selectionchange', (): void => {
  if (!editable) {
    setActiveLockedBlocks(contentElement, [])
    publishLockedBlockAnchor(null)
    return
  }
  const selection = window.getSelection()
  if (!selection || selection.rangeCount === 0) {
    setActiveLockedBlocks(contentElement, [])
    publishLockedBlockAnchor(null)
    return
  }
  const range = selection.getRangeAt(0)
  if (sourceBlockForNode(range.startContainer)) {
    savedEditableSelection = range.cloneRange()
  }
  const lockedBlocks = contentElement.querySelectorAll('.preview-source-block[data-edit-locked="true"]')
  setActiveLockedBlocks(
    contentElement,
    selectedLockedBlocks(lockedBlocks, selection, sourceBlockForNode)
  )
  publishLockedBlockAnchor(toolbarBlockForSelection(lockedBlocks, selection, sourceBlockForNode))
})

contentElement.addEventListener('click', (event: MouseEvent): void => {
  if (!editable || !(event.target instanceof HTMLElement)) return
  const lockedBlock = event.target.closest(
    '.preview-source-block[data-edit-locked="true"]'
  ) as HTMLElement | null
  setActiveLockedBlocks(contentElement, lockedBlock ? [lockedBlock] : [])
  publishLockedBlockAnchor(lockedBlock)
  if (event.target.closest('a, input, img, button')) return
  const arkts = window.__arkts
  if (lockedBlock && arkts && typeof arkts.onLockedContentTap === 'function') {
    arkts.onLockedContentTap()
  }
})
contentElement.addEventListener('scroll', (): void => {
  if (activeToolbarBlock) publishLockedBlockAnchor(activeToolbarBlock)
}, { passive: true })
window.addEventListener('resize', (): void => {
  if (activeToolbarBlock) publishLockedBlockAnchor(activeToolbarBlock)
})

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
  setContent(b64: string, sourceB64?: string, sourceMapB64?: string): void {
    const text = b64decode(b64)
    sourceText = sourceB64 === undefined ? text : b64decode(sourceB64)
    try {
      sourceEdits = sourceMapB64 === undefined ? [] : JSON.parse(b64decode(sourceMapB64))
    } catch {
      sourceEdits = []
    }
    const el = document.getElementById('content') as HTMLElement
    workspaceScrollRestoreGeneration++
    workspaceScrollRestorePending = false
    if (workspaceScrollTimer !== undefined) {
      window.clearTimeout(workspaceScrollTimer)
      workspaceScrollTimer = undefined
    }
    const split = splitFrontmatter(text)
    const sourceSplit = splitFrontmatter(sourceText)
    const tagsHtml = renderNoteTags(text)
    const bodyOffset = text.length - split.body.length
    const bodyLineOffset = text.substring(0, bodyOffset).split('\n').length - 1
    const sourceBodyOffset = sourceText.length - sourceSplit.body.length
    const renderedBody = split.body.trim().length === 0
      ? { html: '', blocks: [] }
      : renderMarkdownWithSourceBlocks(split.body, bodyLineOffset, sourceBodyOffset, sourceEdits, bodyOffset)
    const bodyHtml = renderedBody.html
    if (tagsHtml.length === 0 && bodyHtml.length === 0) {
      mermaidRenderGeneration++
      mermaidRender = Promise.resolve()
      el.innerHTML = '<div class="preview-body"><div class="empty" data-placeholder="空笔记"></div></div>'
      sourceBlockGeometry = []
      observeSourceBlocks()
      configureEditableBlocks(el, bodyOffset)
      updateImageBounds()
      console.log('[mdpreview] setContent: empty')
      return
    }
    el.innerHTML = `<div class="preview-body">${tagsHtml}${bodyHtml}</div>`
    const sourceBlocks = el.querySelectorAll('.preview-source-block')
    for (let index = 0; index < sourceBlocks.length && index < renderedBody.blocks.length; index++) {
      const block = sourceBlocks[index] as HTMLElement
      const source = renderedBody.blocks[index]
      block.dataset.sourceFrom = String(source.sourceStart)
      block.dataset.sourceTo = String(source.sourceEnd)
      block.dataset.sourceType = source.type
    }
    observeSourceBlocks()
    configureEditableBlocks(el, bodyOffset)
    const headings = el.querySelectorAll('h1,h2,h3,h4,h5,h6')
    for (let i = 0; i < headings.length; i++) {
      headings[i].setAttribute('data-chapter-index', String(i))
    }
    const generation = ++mermaidRenderGeneration
    mermaidRender = renderMermaidBlocks(el, generation)
    localizeImages(el)
    updateImageBounds()
    console.log('[mdpreview] setContent: rendered')
  },

  setNoteDir(b64: string): void {
    noteDir = b64decode(b64)
  },

  setEditable(value: boolean): void {
    editable = value
    const split = splitFrontmatter(sourceText)
    const bodyOffset = sourceText.length - split.body.length
    configureEditableBlocks(contentElement, bodyOffset)
  },

  applyFormat(kind: string): void {
    if (!editable || editableComposing) return
    const allowed = ['paragraph', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'bold', 'italic', 'list', 'ordered', 'task', 'quote']
    if (!allowed.includes(kind)) return
    const selection = window.getSelection()
    if (!selection) return
    if (savedEditableSelection) {
      selection.removeAllRanges()
      selection.addRange(savedEditableSelection)
    }
    const range = selection.rangeCount > 0 ? selection.getRangeAt(0) : null
    const start = range?.startContainer instanceof HTMLElement ? range.startContainer : range?.startContainer.parentElement
    const block = sourceBlockForNode(start ?? null)
    const target = block ? editableElementFor(block) : null
    if (!block || !target || !target.isContentEditable) return
    const commands: Record<string, string> = {
      paragraph: 'P', h1: 'H1', h2: 'H2', h3: 'H3', h4: 'H4', h5: 'H5', h6: 'H6', quote: 'BLOCKQUOTE'
    }
    if (kind === 'task') {
      let item = start?.closest('li') as HTMLElement | null
      if (!item) {
        document.execCommand('insertUnorderedList')
        const current = window.getSelection()?.anchorNode
        item = (current instanceof HTMLElement ? current : current?.parentElement)?.closest('li') as HTMLElement | null
      }
      if (item) {
        let checkbox = item.querySelector(':scope > input[type="checkbox"]') as HTMLInputElement | null
        if (!checkbox) {
          checkbox = document.createElement('input')
          checkbox.type = 'checkbox'
          checkbox.disabled = true
          item.insertBefore(checkbox, item.firstChild)
        } else {
          checkbox.checked = !checkbox.checked
        }
      }
    } else if (kind === 'bold') document.execCommand('bold')
    else if (kind === 'italic') document.execCommand('italic')
    else if (kind === 'list') document.execCommand('insertUnorderedList')
    else if (kind === 'ordered') document.execCommand('insertOrderedList')
    else document.execCommand('formatBlock', false, commands[kind])
    const updatedTarget = editableElementFor(block)
    replaceSourceBlock(block)
    if (updatedTarget) block.focus()
  },

  insertText(b64: string): void {
    if (!editable || editableComposing) return
    const text = b64decode(b64)
    const selection = window.getSelection()
    if (!selection) return
    if (savedEditableSelection) {
      selection.removeAllRanges()
      selection.addRange(savedEditableSelection)
    }
    if (selection.rangeCount === 0) return
    const range = selection.getRangeAt(0)
    const block = sourceBlockForNode(range.startContainer)
    const target = block ? editableElementFor(block) : null
    if (!block || !target || !target.isContentEditable) return
    const imageMatch = /^!\[([^\]]*)\]\((.+)\)$/.exec(text)
    if (imageMatch) {
      range.deleteContents()
      const wrapper = document.createElement('span')
      wrapper.className = 'preview-simple-inserted-image'
      wrapper.contentEditable = 'false'
      wrapper.dataset.sourceMarkdown = text
      const image = document.createElement('img')
      image.alt = imageMatch[1]
      image.src = imageMatch[2]
      wrapper.appendChild(image)
      range.insertNode(wrapper)
      range.setStartAfter(wrapper)
      range.collapse(true)
      selection.removeAllRanges()
      selection.addRange(range)
      localizeImages(block)
      replaceSourceBlock(block)
      return
    }
    range.deleteContents()
    const node = document.createTextNode(text)
    range.insertNode(node)
    range.setStartAfter(node)
    range.collapse(true)
    selection.removeAllRanges()
    selection.addRange(range)
    replaceSourceBlock(block)
  },

  flushEditableContent(id: number): void {
    if (editableChangeTimer !== undefined) {
      window.clearTimeout(editableChangeTimer)
      editableChangeTimer = undefined
    }
    const arkts = window.__arkts
    if (arkts && typeof arkts.onEditableContent === 'function') {
      arkts.onEditableContent(id, b64encode(sourceText))
    }
  },

  setTheme(theme: string): void {
    document.documentElement.setAttribute('data-theme', theme === 'dark' ? 'dark' : 'light')
  },

  setPreviewZoomPercent(percent: number): void {
    setPreviewZoomPercent(percent)
  },

  setPreviewZoomControlsVisible(visible: boolean): void {
    setPreviewZoomControlsVisible(visible)
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
