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
import { inlineItemsForBlock, lockedBlockAnchor, selectedLockedBlocks, toolbarBlockForSelection } from './blockSelection.mjs'
import { appendShareWatermark } from './shareWatermark.mjs'
import { COMMON_CODE_LANGUAGES, inspectCodeFence, prepareCodeBodyEdit } from './codeBlock.mjs'

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
      onLockedContentTap?: (payload: string) => void
      onLockedBlockSelection?: (payload: string) => void
      onPreviewZoomChange?: (percent: number) => void
      onCodeBlockEdit?: (id: number, from: number, to: number, expectedB64: string,
        replacementB64: string, userEvent: string) => void
      onCodeBlockEditingChange?: (editing: boolean) => void
    }
  }
}

/** 给 ArkTS 侧看的 API 面（setContent/setNoteDir 走 base64，避免引号/换行转义地狱） */
interface MdPreviewApi {
  setContent(b64: string, sourceB64?: string, sourceMapB64?: string): void
  isEditable(): boolean
  isLockedTapActivation(): boolean
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
  focusLockedBlock(from: number, to: number): void
  activateLockedContent(from: number, to: number, inlineIndex?: number): void
  scrollToHeading(index: number): void
  scrollToSourceLine(line: number, lineProgress: number, viewportRatio: number, atStart: boolean, atEnd: boolean): void
  cancelSourceFollow(): void
  restoreScrollTop(top: number): void
  completeCodeBlockEdit(id: number, applied: boolean): void
  requestShareCaptureMetrics(id: number): void
  appendShareWatermark(id: number): void
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
let lastLockedTapTarget: HTMLElement | null = null
let replayingLockedTap = false
let mermaidRender: Promise<void> = Promise.resolve()
let mermaidRenderGeneration = 0
interface CodeEditSession {
  block: HTMLElement;
  target: HTMLElement;
  committedText: string;
  pendingText: string;
  inFlight: boolean;
  exiting: boolean;
}

interface PendingCodeEdit {
  id: number;
  from: number;
  to: number;
  expected: string;
  replacement: string;
  bodyText: string;
  block: HTMLElement;
  session: CodeEditSession;
}

let codeEditSession: CodeEditSession | null = null
let pendingCodeEdit: PendingCodeEdit | null = null
let nextCodeEditId = 1
const codeEditFlushWaiters: number[] = []

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
          img.addEventListener('click', () => {
            if (!editable) openImage(img)
          })
          img.addEventListener('keydown', (event: KeyboardEvent) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault()
              if (editable) img.click()
              else openImage(img)
            }
          })
        } else {
          img.dataset.shareMissing = 'true'
          img.alt = src + '（图片不存在）'
        }
      } else {
        img.dataset.shareMissing = 'true'
      }
    } catch (error) {
      img.dataset.shareMissing = 'true'
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
  lastLockedTapTarget = null
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
  const missingImages = root.querySelectorAll<HTMLImageElement>('img[data-share-missing="true"]')
  if (missingImages.length > 0) {
    throw new Error('笔记中的本地图片缺失或无法读取，请补齐附件后重试')
  }
  const images = root.querySelectorAll<HTMLImageElement>('img[data-share-local="true"]')
  for (let i = 0; i < images.length; i++) {
    const image = images[i]
    try {
      await image.decode()
    } catch (error) {
      throw new Error('笔记中的本地图片无法解码，请检查附件后重试')
    }
    if (image.naturalWidth <= 0 || image.naturalHeight <= 0) {
      throw new Error('笔记中的本地图片无法解码，请检查附件后重试')
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

function codeElementForBlock(block: HTMLElement): HTMLElement | null {
  const pre = block.querySelector('pre') as HTMLElement | null
  if (!pre) return null
  return pre.querySelector('code') as HTMLElement | null ?? pre
}

function clearCodeBlockToolbar(block: HTMLElement): void {
  const pre = block.querySelector('pre') as HTMLElement | null
  if (!pre) return
  const container = pre.closest('.md-code') as HTMLElement | null
  if (!container) return
  container.querySelector('.md-code-bar')?.remove()
  if (container.classList.contains('mermaid-block')) {
    container.classList.remove('md-code')
  } else if (container.dataset.simpleCodeToolbarWrapper === 'true') {
    container.replaceWith(pre)
  }
}

function attachCodeBlockLanguageButton(block: HTMLElement, pre: HTMLElement, language: string,
  closed: boolean): void {
  let container = pre.closest('.mermaid-block') as HTMLElement | null
  if (container) {
    container.classList.add('md-code')
  } else if (pre.parentElement?.classList.contains('md-code')) {
    container = pre.parentElement
  } else {
    container = document.createElement('div')
    container.className = 'md-code'
    container.dataset.simpleCodeToolbarWrapper = 'true'
    pre.replaceWith(container)
    container.appendChild(pre)
  }

  const bar = document.createElement('div')
  bar.className = 'md-code-bar'
  const languageButton = document.createElement('button')
  languageButton.type = 'button'
  languageButton.className = 'md-code-language'
  languageButton.textContent = `${closed ? (language || '纯文本') : '源码'} ▾`
  languageButton.title = '选择代码语言'
  languageButton.setAttribute('aria-label', `代码块语言：${closed ? (language || '纯文本') : '源码'}`)
  languageButton.addEventListener('click', (event: MouseEvent): void => {
    event.preventDefault()
    event.stopPropagation()
    const payload = publishLockedBlockAnchor(block)
    const arkts = window.__arkts
    if (payload.length > 0 && arkts && typeof arkts.onLockedContentTap === 'function') {
      arkts.onLockedContentTap(payload)
    }
  })
  bar.appendChild(languageButton)
  container.insertBefore(bar, pre)
}

function notifyCodeBlockEditingChange(editing: boolean): void {
  const arkts = window.__arkts
  if (arkts && typeof arkts.onCodeBlockEditingChange === 'function') {
    arkts.onCodeBlockEditingChange(editing)
  }
}

function notifyCodeEditWaiters(): void {
  if (pendingCodeEdit !== null ||
    (codeEditSession !== null && codeEditSession.pendingText !== codeEditSession.committedText)) {
    return
  }
  const waiters = codeEditFlushWaiters.splice(0)
  for (const id of waiters) postEditableContent(id)
}

function postEditableContent(id: number): void {
  const arkts = window.__arkts
  if (arkts && typeof arkts.onEditableContent === 'function') {
    arkts.onEditableContent(id, b64encode(sourceText))
  }
}

function finishCodeEditSession(session: CodeEditSession): void {
  if (codeEditSession !== session || session.inFlight ||
    session.pendingText !== session.committedText || !session.exiting) {
    return
  }
  codeEditSession = null
  notifyCodeBlockEditingChange(false)
  notifyCodeEditWaiters()
}

function applyCodeSourcePatch(patch: PendingCodeEdit): boolean {
  if (sourceText.slice(patch.from, patch.to) !== patch.expected) return false
  const delta = patch.replacement.length - (patch.to - patch.from)
  sourceText = sourceText.slice(0, patch.from) + patch.replacement + sourceText.slice(patch.to)
  const blocks = contentElement.querySelectorAll('.preview-source-block, .empty[data-source-from]')
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index] as HTMLElement
    const from = Number(block.dataset.sourceFrom)
    const to = Number(block.dataset.sourceTo)
    if (!Number.isInteger(from) || !Number.isInteger(to)) continue
    if (block === patch.block) {
      block.dataset.sourceTo = String(to + delta)
    } else if (from >= patch.to) {
      block.dataset.sourceFrom = String(from + delta)
      block.dataset.sourceTo = String(to + delta)
    }
  }
  return true
}

function submitCodeBodyEdit(session: CodeEditSession): void {
  if (codeEditSession !== session || session.inFlight || editableComposing) return
  if (session.pendingText === session.committedText) {
    finishCodeEditSession(session)
    notifyCodeEditWaiters()
    return
  }
  const from = Number(session.block.dataset.sourceFrom)
  const to = Number(session.block.dataset.sourceTo)
  const patch = prepareCodeBodyEdit(sourceText, from, to, session.pendingText)
  if (!patch) {
    session.target.textContent = session.committedText
    session.pendingText = session.committedText
    session.exiting = true
    finishCodeEditSession(session)
    notifyCodeEditWaiters()
    return
  }
  const id = nextCodeEditId++
  const request: PendingCodeEdit = {
    id,
    from: patch.from,
    to: patch.to,
    expected: patch.expected,
    replacement: patch.replacement,
    bodyText: session.pendingText,
    block: session.block,
    session
  }
  session.inFlight = true
  pendingCodeEdit = request
  const arkts = window.__arkts
  if (!arkts || typeof arkts.onCodeBlockEdit !== 'function') {
    api.completeCodeBlockEdit(id, false)
    return
  }
  try {
    arkts.onCodeBlockEdit(id, request.from, request.to, b64encode(request.expected),
      b64encode(request.replacement), 'input.type')
  } catch {
    api.completeCodeBlockEdit(id, false)
  }
}

function startCodeEditSession(target: HTMLElement): void {
  const block = sourceBlockForNode(target)
  if (!block || target.dataset.simpleCodeEditable !== 'true') return
  if (codeEditSession?.target === target) return
  if (codeEditSession !== null) {
    codeEditSession.exiting = true
    submitCodeBodyEdit(codeEditSession)
  }
  const text = target.textContent ?? ''
  codeEditSession = {
    block,
    target,
    committedText: text,
    pendingText: text,
    inFlight: false,
    exiting: false
  }
  notifyCodeBlockEditingChange(true)
}

function updateCodeEditSessionFromDom(target: HTMLElement): void {
  const session = codeEditSession
  if (!session || session.target !== target) return
  session.pendingText = target.textContent ?? ''
  submitCodeBodyEdit(session)
}

function insertPlainTextAtSelection(target: HTMLElement, text: string): boolean {
  const selection = window.getSelection()
  if (!selection || selection.rangeCount === 0) return false
  const range = selection.getRangeAt(0)
  if (!target.contains(range.startContainer) || !target.contains(range.endContainer)) return false
  range.deleteContents()
  const node = document.createTextNode(text)
  range.insertNode(node)
  range.setStartAfter(node)
  range.collapse(true)
  selection.removeAllRanges()
  selection.addRange(range)
  updateCodeEditSessionFromDom(target)
  return true
}

function resetCodeEditSession(): void {
  const session = codeEditSession
  codeEditSession = null
  if (session) notifyCodeBlockEditingChange(false)
}

function sourceBlockForNode(node: Node | null): HTMLElement | null {
  const element = node instanceof HTMLElement ? node : node?.parentElement
  return element?.closest('.preview-source-block, .empty[data-source-from]') as HTMLElement | null;
}

function annotateInlineItems(block: HTMLElement, source: {
  inlineItems?: Array<{ index: number; type: string; from: number; to: number }>;
  inlineSafe?: boolean;
}): void {
  const items = source.inlineItems ?? []
  block.dataset.inlineItemsReady = 'false'
  if (source.inlineSafe !== true || items.length === 0) return
  const candidates: Record<string, HTMLElement[]> = {
    link: Array.from(block.querySelectorAll('a')),
    image: Array.from(block.querySelectorAll('img')),
    inlinecode: Array.from(block.querySelectorAll('code')).filter((node) => node.closest('pre') === null),
    mathInline: Array.from(block.querySelectorAll('.katex'))
      .filter((node) => node.closest('.katex-display') === null)
  }
  const cursors: Record<string, number> = { link: 0, image: 0, inlinecode: 0, mathInline: 0 }
  const targets: Array<{ node: HTMLElement; item: { index: number; type: string; from: number; to: number } }> = []
  for (const item of items) {
    const nodes = candidates[item.type]
    const target = nodes?.[cursors[item.type]]
    if (!target || !Number.isInteger(item.from) || !Number.isInteger(item.to) || item.to <= item.from) return
    cursors[item.type]++
    targets.push({ node: target, item })
  }
  for (const [type, nodes] of Object.entries(candidates)) {
    if (cursors[type] !== nodes.length) return
  }
  for (const entry of targets) {
    const { node, item } = entry
    const type = item.type === 'link' &&
      (node as HTMLAnchorElement).getAttribute('href')?.indexOf('#wikilink:') === 0
      ? 'wikilink' : item.type
    node.dataset.previewInlineIndex = String(item.index)
    node.dataset.previewInlineType = type
    node.dataset.previewInlineFrom = String(item.from)
    node.dataset.previewInlineTo = String(item.to)
  }
  block.dataset.inlineItemsReady = 'true'
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

function publishLockedBlockAnchor(block: HTMLElement | null): string {
  activeToolbarBlock = block
  const rect = block?.getBoundingClientRect()
  const anchor = rect ? lockedBlockAnchor(block, rect, window.innerWidth, window.innerHeight) : null
  const payload = anchor ? JSON.stringify(anchor) : ''
  const arkts = window.__arkts
  if (arkts && typeof arkts.onLockedBlockSelection === 'function') {
    arkts.onLockedBlockSelection(payload)
  }
  return payload
}

function focusLockedBlock(from: number, to: number): void {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from) return
  const blocks = contentElement.querySelectorAll('.preview-source-block, .empty[data-source-from]')
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index] as HTMLElement
    if (Number(block.dataset.sourceFrom) !== from || Number(block.dataset.sourceTo) !== to) continue
    block.setAttribute('tabindex', '-1')
    block.focus({ preventScroll: true })
    if (savedEditableSelection && block.contains(savedEditableSelection.commonAncestorContainer)) {
      const selection = window.getSelection()
      if (selection) {
        selection.removeAllRanges()
        selection.addRange(savedEditableSelection)
      }
    }
    return
  }
}

function activateLockedContent(from: number, to: number, inlineIndex: number = -1): void {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from) return
  const blocks = contentElement.querySelectorAll('.preview-source-block, .empty[data-source-from]')
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index] as HTMLElement
    if (Number(block.dataset.sourceFrom) !== from || Number(block.dataset.sourceTo) !== to) continue
    let target: HTMLElement | null = null
    if (Number.isInteger(inlineIndex) && inlineIndex >= 0) {
      const items = block.querySelectorAll('[data-preview-inline-index]')
      for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
        const item = items[itemIndex] as HTMLElement
        if (Number(item.dataset.previewInlineIndex) === inlineIndex) {
          target = item
          break
        }
      }
      if (!target) return
    } else {
      target = lastLockedTapTarget && block.contains(lastLockedTapTarget)
        ? lastLockedTapTarget
        : block.querySelector('a, img') as HTMLElement | null
    }
    if (!target) return
    if (target.tagName === 'IMG') {
      openImage(target as HTMLImageElement)
      return
    }
    replayingLockedTap = true
    try {
      target.click()
    } finally {
      replayingLockedTap = false
    }
    return
  }
}

function configureEditableBlocks(root: HTMLElement, bodyOffset: number): void {
  setActiveLockedBlocks(root, [])
  publishLockedBlockAnchor(null)
  const previousEditables = root.querySelectorAll(
    '[data-simple-editable="true"], [data-simple-code-editable="true"]'
  )
  for (let index = 0; index < previousEditables.length; index++) {
    const element = previousEditables[index] as HTMLElement
    element.removeAttribute('contenteditable')
    element.removeAttribute('aria-label')
    element.removeAttribute('data-simple-editable')
    element.removeAttribute('data-simple-code-editable')
  }
  const blocks = root.querySelectorAll('.preview-source-block')
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index] as HTMLElement
    block.removeAttribute('contenteditable')
    block.removeAttribute('aria-label')
    block.removeAttribute('data-edit-locked')
    const type = block.dataset.sourceType ?? ''
    const supported = type === 'paragraph' || type === 'heading' || type === 'list' || type === 'blockquote'
    if (type === 'code') {
      clearCodeBlockToolbar(block)
      if (!editable) continue
      block.dataset.editLocked = 'true'
      const target = codeElementForBlock(block)
      const pre = target?.closest('pre') as HTMLElement | null
      const from = Number(block.dataset.sourceFrom)
      const to = Number(block.dataset.sourceTo)
      const raw = Number.isInteger(from) && Number.isInteger(to) && from >= 0 && to <= sourceText.length
        ? sourceText.slice(from, to) : ''
      const model = target ? inspectCodeFence(raw, target.textContent ?? '') : null
      block.dataset.codeEditable = String(model?.editable === true)
      block.dataset.codeLanguage = model?.language ?? ''
      block.dataset.codeLanguageFrom = model ? String(from + model.languageFrom) : '-1'
      block.dataset.codeLanguageTo = model ? String(from + model.languageTo) : '-1'
      block.dataset.codeLanguageSelectable = String(model?.languageSelectable === true)
      block.dataset.codeLanguages = JSON.stringify(COMMON_CODE_LANGUAGES)
      block.setAttribute('aria-label', model?.editable
        ? '可编辑代码块' : '此代码块请以源码编辑')
      if (target && model?.editable) {
        target.textContent = model.logicalBody
        target.setAttribute('contenteditable', 'plaintext-only')
        target.setAttribute('data-simple-code-editable', 'true')
        target.setAttribute('aria-label', '编辑代码块内容')
        target.spellcheck = false
      }
      if (pre && model) {
        attachCodeBlockLanguageButton(block, pre, model.language, model.closed)
      }
      continue
    }
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
  const codeTarget = document.activeElement instanceof HTMLElement
    ? document.activeElement.closest('[data-simple-code-editable="true"]') as HTMLElement | null : null
  const sessionTarget = codeEditSession?.target.isConnected ? codeEditSession.target : null
  const committedCodeTarget = sessionTarget ?? codeTarget
  if (committedCodeTarget) {
    updateCodeEditSessionFromDom(committedCodeTarget)
    return
  }
  const target = sourceBlockForNode(window.getSelection()?.anchorNode ?? document.activeElement)
  if (target) replaceSourceBlock(target)
  else notifyEditableContentChange()
})
contentElement.addEventListener('focusin', (event: FocusEvent): void => {
  if (!editable || !(event.target instanceof HTMLElement)) return
  const target = event.target.closest('[data-simple-code-editable="true"]') as HTMLElement | null
  if (target) startCodeEditSession(target)
})
contentElement.addEventListener('focusout', (event: FocusEvent): void => {
  const session = codeEditSession
  if (!session || event.target !== session.target) return
  const next = event.relatedTarget
  if (next instanceof Node && session.block.contains(next)) return
  session.pendingText = session.target.textContent ?? ''
  session.exiting = true
  submitCodeBodyEdit(session)
})
contentElement.addEventListener('keydown', (event: KeyboardEvent): void => {
  if (!editable || !(event.target instanceof HTMLElement)) return
  const target = event.target.closest('[data-simple-code-editable="true"]') as HTMLElement | null
  if (!target) return
  if (event.key === 'Tab') {
    event.preventDefault()
    insertPlainTextAtSelection(target, '  ')
  } else if (event.key === 'Escape') {
    event.preventDefault()
    target.blur()
  }
})
contentElement.addEventListener('beforeinput', (event: InputEvent): void => {
  if (!editable) return
  const codeTarget = event.target instanceof HTMLElement
    ? event.target.closest('[data-simple-code-editable="true"]') as HTMLElement | null : null
  if (codeTarget && (event.inputType === 'insertParagraph' || event.inputType === 'insertLineBreak')) {
    event.preventDefault()
    insertPlainTextAtSelection(codeTarget, '\n')
    return
  }
  const selection = window.getSelection()
  if (!selection || selection.rangeCount === 0) return
  const range = selection.getRangeAt(0)
  const startBlock = sourceBlockForNode(range.startContainer)
  const endBlock = sourceBlockForNode(range.endContainer)
  if (startBlock !== endBlock) event.preventDefault()
})
contentElement.addEventListener('input', (event: Event): void => {
  if (!editable || editableComposing) return
  const codeTarget = event.target instanceof HTMLElement
    ? event.target.closest('[data-simple-code-editable="true"]') as HTMLElement | null : null
  if (codeTarget) {
    updateCodeEditSessionFromDom(codeTarget)
    return
  }
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
  if (replayingLockedTap) return
  const lockedBlock = event.target.closest(
    '.preview-source-block[data-edit-locked="true"]'
  ) as HTMLElement | null
  const payload = publishLockedBlockAnchor(lockedBlock)
  lastLockedTapTarget = null
  if (event.target.closest('[data-simple-code-editable="true"]')) return
  if (event.target.closest('input, button')) return
  const tapTarget = event.target.closest('a, img') as HTMLElement | null
  const inlineTarget = event.target.closest('[data-preview-inline-index]') as HTMLElement | null
  let tapPayload = payload
  if (lockedBlock && payload.length > 0 && (tapTarget || inlineTarget)) {
    if (tapTarget) lastLockedTapTarget = tapTarget
    if (payload.length > 0) {
      const anchor = JSON.parse(payload) as Record<string, string | number | Array<Object>>
      if (inlineTarget) {
        anchor.tapType = inlineTarget.dataset.previewInlineType ?? ''
        anchor.inlineIndex = Number(inlineTarget.dataset.previewInlineIndex)
        anchor.itemFrom = Number(inlineTarget.dataset.previewInlineFrom)
        anchor.itemTo = Number(inlineTarget.dataset.previewInlineTo)
      } else if (tapTarget?.tagName === 'IMG') {
        anchor.tapType = 'image'
      } else if (tapTarget) {
        const href = (tapTarget as HTMLAnchorElement).getAttribute('href') ?? ''
        anchor.tapType = href.indexOf('#wikilink:') === 0 ? 'wikilink' : 'link'
      }
      tapPayload = JSON.stringify(anchor)
    }
  }
  if (tapTarget) {
    event.preventDefault()
    event.stopPropagation()
  }
  const arkts = window.__arkts
  if (lockedBlock && arkts && typeof arkts.onLockedContentTap === 'function') {
    arkts.onLockedContentTap(tapPayload)
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
  isEditable(): boolean {
    return editable
  },

  isLockedTapActivation(): boolean {
    return replayingLockedTap
  },

  setContent(b64: string, sourceB64?: string, sourceMapB64?: string): void {
    const text = b64decode(b64)
    resetCodeEditSession()
    pendingCodeEdit = null
    lastLockedTapTarget = null
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
      annotateInlineItems(block, source)
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
    if (!editable && codeEditSession !== null) {
      codeEditSession.exiting = true
      submitCodeBodyEdit(codeEditSession)
    }
    if (!editable) lastLockedTapTarget = null
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
    if (pendingCodeEdit !== null ||
      (codeEditSession !== null && codeEditSession.pendingText !== codeEditSession.committedText)) {
      codeEditFlushWaiters.push(id)
      return
    }
    postEditableContent(id)
  },

  completeCodeBlockEdit(id: number, applied: boolean): void {
    const pending = pendingCodeEdit
    if (!pending || pending.id !== id) return
    pendingCodeEdit = null
    const session = pending.session
    session.inFlight = false
    if (!applied || !applyCodeSourcePatch(pending)) {
      session.target.textContent = session.committedText
      session.pendingText = session.committedText
      session.exiting = true
      finishCodeEditSession(session)
      notifyCodeEditWaiters()
      return
    }
    session.committedText = pending.bodyText
    if (session.pendingText !== session.committedText) {
      submitCodeBodyEdit(session)
    } else {
      finishCodeEditSession(session)
    }
    notifyCodeEditWaiters()
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

  focusLockedBlock(from: number, to: number): void {
    focusLockedBlock(from, to)
  },

  activateLockedContent(from: number, to: number, inlineIndex: number = -1): void {
    activateLockedContent(from, to, inlineIndex)
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

  async appendShareWatermark(id: number): Promise<void> {
    try {
      appendShareWatermark(document.getElementById('content') as HTMLElement, document)
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
