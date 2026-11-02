/**
 * mdeditor/src/index.ts —— M0.5 spike：Web 组件内的 CodeMirror 6 Markdown 编辑器。
 *
 * 打包：esbuild → 单文件 IIFE → 内联进 index.html → rawfile/mdeditor/index.html
 *      （照抄 web/gitbridge/build.mjs 的链路，见 AGENTS.md §Web 打包约定）
 *
 * 桥接协议（与 gitbridge 一致，JSON over javaScriptProxy.postMessage）：
 *   ArkTS → Web：window.__mdeditor.setContent(b64, revision, vaultIdB64, noteDirB64) / requestContent(id) / focus() / setTheme(t)
 *   Web → ArkTS：postMessage(JSON)
 *     - {type:'event', name:'ready'}                 页面就绪，可以收内容了
 *     - {type:'event', name:'change', len:N, revision:R} 内容变化（debounce 300ms，只报长度与文档代次）
 *     - {type:'event', name:'content', id:N, b64:S}   requestContent 的回复（全量内容）
 *
 * ⚠️ 为什么 change 只报长度不报内容：编辑中每次击键都过桥会把大文本反复序列化，
 * 内容统一由 ArkTS 在需要时（保存/切走）主动 getContent() 拉。硬约束 7 的同款思路。
 *
 * ⚠️ spike 的核心待验项：**中文输入法在 contenteditable 里能不能用**。
 * CodeMirror 6 是标准 contenteditable + composition 事件实现，鸿蒙 WebView 是否完整
 * 实现 composition 事件官方无记载 —— 这正是要人上真机敲键盘验证的东西（真机清单 §2）。
 */

import { basicSetup } from 'codemirror'
import { autocompletion } from '@codemirror/autocomplete'
import { Compartment, EditorState, Range, StateField } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language'
import { Decoration, DecorationSet, EditorView, Extension, ViewPlugin, ViewUpdate, WidgetType } from '@codemirror/view'
import { oneDark } from '@codemirror/theme-one-dark'
import { preservedScrollTop } from './scrollAnchor'
import { clampWorkspaceScrollTop, editorWorkspaceScrollContainer } from './workspaceScroll'
import { allowsSimpleModeTransaction, collectSimpleModeRanges, resolveSimpleModeImagePath,
  SimpleModeRanges, SimpleRange } from './simpleMode'
import {
  hasCodeBlockSelection,
  normalizeEditorText,
  serializeEditorText,
  toggleCodeBlock
} from './codeBlockFormat'
import { toggleMarkdownFormat, toggleTaskStatus } from './markdownFormat'
import { createChangeNotificationTimer } from './changeNotification'

declare global {
  interface Window {
    __mdeditor: MdEditorApi
    __arkts?: {
      postMessage: (msg: string) => void
      readAsset?: (requestB64: string) => string
    }
  }
}

/**
 * ⚠️ 踩坑（2026-10-18 模拟器实测定位，重要）：
 * runJavaScript 的**返回值不能当数据通道**：ArkWeb（Chromium）的字符串返回值带
 * JSON 编码痕迹（含引号等非 base64 字符），ArkTS 侧 decodeSync 直接抛
 * "The input string contains unsupported characters"。官方 FAQ（faqs-arkweb-146）
 * 的推荐做法：runJavaScript 只触发，Web 侧拿结果后经 __arkts.postMessage 回传。
 * 故内容拉取走 requestContent(reqId) → content 事件往返，不走返回值。
 */
interface MdEditorApi {
  setContent(b64: string, documentRevision: number, vaultIdB64: string, noteDirB64: string): void
  replaceContentFromPreview(b64: string, expectedRevision: number): void
  /** ArkTS 侧不再直接用 getContent 的返回值（见上），保留仅供调试控制台用 */
  getContent(): string
  requestContent(reqId: number): void
  insertText(b64: string): void
  applyFormat(kind: string): void
  scrollToOffset(offset: number): void
  focus(): void
  blur(): void
  setTheme(theme: string): void
  setLineNumbers(show: boolean): void
  reportVisibleSourceAnchor(): void
  setEditable(editable: boolean): void
  setExperience(mode: string): void
  setLinkCandidatesResult(id: number, b64: string): void
  restoreScrollTop(top: number): void
  onArktsReady(): void
}

interface WikiLinkCandidate {
  path: string
  insertTarget: string
}

const linkCompletionWaiters = new Map<number, (candidates: WikiLinkCandidate[]) => void>()
let nextLinkCompletionId = 1
let documentRevision = 0

function wikiLinkCompletion(context: any): Promise<any> | null {
  const before = context.matchBefore(/\[\[[^\]\n]*/)
  if (!before || before.text.includes('|') || before.text.includes('#') || before.text.includes('\\')) {
    return null
  }
  if (before.from > 0) {
    const previous = context.state.sliceDoc(before.from - 1, before.from)
    if (previous === '!') {
      return null
    }
  }
  let slashCount = 0
  for (let i = before.from - 1; i >= 0 && context.state.sliceDoc(i, i + 1) === '\\'; i--) {
    slashCount++
  }
  if (slashCount % 2 === 1) {
    return null
  }
  const id = nextLinkCompletionId++
  const query = before.text.substring(2)
  postToArkts({ type: 'event', name: 'linkCompletion', id: id, query: query })
  return new Promise((resolve) => {
    const timer = window.setTimeout(() => {
      linkCompletionWaiters.delete(id)
      resolve(null)
    }, 800)
    linkCompletionWaiters.set(id, (candidates: WikiLinkCandidate[]) => {
      window.clearTimeout(timer)
      if (candidates.length === 0) {
        resolve(null)
        return
      }
      resolve({
        from: before.from + 2,
        options: candidates.map((candidate: WikiLinkCandidate) => ({
          label: candidate.path,
          apply: (view: EditorView, _completion: unknown, _from: number, to: number) => {
            const closeEnd = view.state.sliceDoc(to, to + 2) === ']]' ? to + 2 : to
            const start = before.from
            const inserted = '[[' + candidate.insertTarget + ']]'
            view.dispatch({
              changes: { from: start, to: closeEnd, insert: inserted },
              selection: { anchor: start + inserted.length }
            })
          }
        }))
      })
    })
  })
}

// ---------- base64（浏览器侧，处理 UTF-8） ----------
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

/**
 * ⚠️ 踩坑（2026-10-18 实测定位，重要）：
 * ArkWeb 的桥接方法**必须挂在注入对象上直接调用** ——
 * `window.__arkts.postMessage(x)` ✅；`const fn = window.__arkts.postMessage; fn(x)` ❌。
 * 后者会把方法从对象上 detach，Chromium 桥接方法依赖接收者（this）做注入校验，
 * 脱离对象调用一律抛 `Javascript bridge method can't be invoked on a non-injected object`
 * （与 Android @JavascriptInterface 同款机制，crbug 514628）。
 * 曾按「typeof 是 function 却调用失败」误判成「未注入的壳」，白排查一轮。
 */
function postToArkts(msg: object): boolean {
  try {
    if (window.__arkts && typeof window.__arkts.postMessage === 'function') {
      window.__arkts.postMessage(JSON.stringify(msg))
      return true
    }
    console.log('[mdeditor] postToArkts: no fn, typeof=' + typeof window.__arkts)
  } catch (error) {
    console.log('[mdeditor] postToArkts threw: ' + String(error))
  }
  return false
}

// 页面脚本执行时代理对象可能还没注入（取决于注册时机），轮询等待最多 10 秒；
// ArkTS 侧注册走 onControllerAttached（页面加载前）时通常头几轮就能命中。
let readyTries = 0
function announceReady(): void {
  const hasArkts = typeof window.__arkts?.postMessage === 'function'
  // 诊断日志：ArkTS 侧用 Web 的 onConsole 捕获（见 EditorWebView.ets）
  if (readyTries < 3 || readyTries % 20 === 0) {
    console.log('[mdeditor] announceReady try=' + readyTries + ' arkts=' + (hasArkts ? 'yes' : 'no'))
  }
  if (postToArkts({ type: 'event', name: 'ready' })) {
    console.log('[mdeditor] ready sent to ArkTS at try=' + readyTries)
    return
  }
  readyTries++
  if (readyTries < 200) {
    window.setTimeout(announceReady, 50)
  } else {
    console.log('[mdeditor] GAVE UP waiting for __arkts after 10s')
  }
}
announceReady()

// ---------- 主题 ----------
// 颜色、字号、行高和字体直接使用 build.mjs 注入的 v2 CSS token。
const LIGHT_THEME = EditorView.theme(
  {
    '&': { backgroundColor: 'var(--paper)', color: 'var(--ink)', fontSize: 'var(--body)' },
    '.cm-content': {
      fontFamily: 'var(--mono)', lineHeight: 'var(--leading)',
      padding: 'var(--s2) 0 calc(var(--touch) + var(--s8) + var(--s5))'
    },
    '.cm-gutters': { backgroundColor: 'var(--paper)', border: 'none', color: 'var(--muted)' },
    '.cm-activeLine': { backgroundColor: 'rgba(0, 0, 0, 0.04)' },
    '.cm-activeLineGutter': { backgroundColor: 'rgba(0, 0, 0, 0.04)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'var(--blue-soft)' },
    '.cm-cursor': { borderLeftColor: 'var(--blue)' }
  },
  { dark: false }
)

const DARK_THEME = EditorView.theme(
  {
    '&': { backgroundColor: 'var(--paper)', color: 'var(--ink)', fontSize: 'var(--body)' },
    '.cm-content': {
      fontFamily: 'var(--mono)', lineHeight: 'var(--leading)',
      padding: 'var(--s2) 0 calc(var(--touch) + var(--s8) + var(--s5))'
    },
    '.cm-gutters': { backgroundColor: 'var(--paper)', border: 'none', color: 'var(--muted)' },
    '.cm-activeLine': { backgroundColor: 'rgba(255, 255, 255, 0.12)' },
    '.cm-activeLineGutter': { backgroundColor: 'rgba(255, 255, 255, 0.12)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'var(--blue-soft)' },
    '.cm-cursor': { borderLeftColor: 'var(--blue)' }
  },
  { dark: true }
)

let themeMode = 'light'
let lineNumbersVisible = false
let simpleExperience = false

// ---------- 实例 ----------
let view: EditorView | null = null
interface EditorScrollAnchor {
  offset: number
  viewportY: number
}

let editorScrollAnchor: EditorScrollAnchor = { offset: 0, viewportY: 0 }
let scrollResizePending = false
let observedEditorWidth = 0
let observedEditorHeight = 0
let anchorCaptureFrame = 0
let anchorRestoreFrame = 0
let scrollResizeGeneration = 0
let editorResizeObserver: ResizeObserver | null = null
let userScrollIntent = false
let userScrollIntentTimer: number | undefined = undefined
let sourceScrollReportFrame = 0
let sourceScrollReportForced = false
let scrollReportTimer: number | undefined = undefined
let workspaceScrollReportSuppressedUntil = 0
let workspaceScrollRestoreGeneration = 0
const changeNotification = createChangeNotificationTimer(
  (callback: () => void, delayMs: number): number => window.setTimeout(callback, delayMs),
  (timerId: number): void => window.clearTimeout(timerId)
)
let isComposing = false
let applyingContent = false
let documentLineEnding = '\n'
const editableCompartment = new Compartment()
const readOnlyCompartment = new Compartment()
const experienceCompartment = new Compartment()
let simpleModeVaultId = ''
let simpleModeNoteDir = ''

class SimpleModeWidget extends WidgetType {
  constructor(private kind: string, private text: string, private from: number, private to: number,
    private alt: string = '', private vaultId: string = '', private noteDir: string = '') {
    super()
  }

  eq(other: WidgetType): boolean {
    if (!(other instanceof SimpleModeWidget)) {
      return false
    }
    const samePosition = this.kind === 'image' || (other.from === this.from && other.to === this.to)
    return other.kind === this.kind && other.text === this.text &&
      samePosition && other.alt === this.alt &&
      other.vaultId === this.vaultId && other.noteDir === this.noteDir
  }

  toDOM(): HTMLElement {
    if (this.kind === 'image') {
      return this.imageDom()
    }
    const node = document.createElement('span')
    node.className = 'cm-simple-' + this.kind
    node.textContent = this.text
    if (this.kind === 'task') {
      node.setAttribute('role', 'checkbox')
      node.setAttribute('aria-checked', String(this.text === '☑'))
      node.setAttribute('aria-label', this.text === '☑' ? '已完成待办' : '未完成待办')
      node.setAttribute('tabindex', '0')
      node.dataset.simpleTaskFrom = String(this.from)
      node.dataset.simpleTaskTo = String(this.to)
    } else if (this.kind === 'protected-hint') {
      node.setAttribute('role', 'note')
    }
    return node
  }

  private imageDom(): HTMLElement {
    const node = document.createElement('span')
    node.className = 'cm-simple-image'
    const label = this.alt.length > 0 ? this.alt : '图片'
    node.setAttribute('role', 'img')
    node.setAttribute('aria-label', label)
    const relPath = resolveSimpleModeImagePath(this.noteDir, this.text)
    const readAsset = window.__arkts?.readAsset
    if (relPath.length > 0 && this.vaultId.length > 0 && typeof readAsset === 'function') {
      try {
        const requestB64 = b64encode(JSON.stringify({ vaultId: this.vaultId, relPath: relPath }))
        const dataUri = window.__arkts?.readAsset?.(requestB64) ?? ''
        if (/^data:image\/(?:png|jpeg|gif|webp|svg\+xml);base64,/i.test(dataUri)) {
          const image = document.createElement('img')
          image.alt = label
          image.draggable = false
          image.src = dataUri
          node.appendChild(image)
          return node
        }
      } catch {
        // Missing or unreadable vault images remain visible as an accessible placeholder.
      }
    }
    const fallback = document.createElement('span')
    fallback.className = 'cm-simple-image-fallback'
    fallback.textContent = this.alt.length > 0 ? this.alt + '（图片无法加载）' : '图片无法加载'
    node.appendChild(fallback)
    return node
  }

  ignoreEvent(): boolean {
    return this.kind !== 'task'
  }
}

const simpleModeRangesField = StateField.define<SimpleModeRanges>({
  create(state: EditorState): SimpleModeRanges {
    return collectSimpleModeRanges(state)
  },
  update(value: SimpleModeRanges, transaction): SimpleModeRanges {
    return transaction.docChanged || transaction.selectionSet
      ? collectSimpleModeRanges(transaction.state) : value
  }
})

function simpleModeDecorations(view: EditorView): DecorationSet {
  const model: SimpleModeRanges = view.state.field(simpleModeRangesField)
  const decorations: Range<Decoration>[] = []
  for (const range of model.decorations) {
    if (range.kind.startsWith('heading-') || range.kind === 'quote') {
      decorations.push(Decoration.line({ attributes: { class: 'cm-simple-' + range.kind } }).range(range.from))
    } else if (range.kind === 'strong' || range.kind === 'emphasis') {
      decorations.push(Decoration.mark({ class: 'cm-simple-' + range.kind }).range(range.from, range.to))
    } else if (range.kind === 'hide') {
      decorations.push(Decoration.replace({}).range(range.from, range.to))
    } else if (range.kind === 'list-marker' || range.kind === 'task' || range.kind === 'protected-hint' ||
      range.kind === 'image') {
      const widget = new SimpleModeWidget(range.kind, range.value ?? '', range.from, range.to, range.alt ?? '',
        range.kind === 'image' ? simpleModeVaultId : '', range.kind === 'image' ? simpleModeNoteDir : '')
      const decoration = range.kind === 'protected-hint'
        ? Decoration.widget({ widget: widget, side: -1 })
        : Decoration.replace({ widget: widget })
      decorations.push(decoration.range(range.from, range.to))
    }
  }
  return Decoration.set(decorations, true)
}

const simpleModePlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet

  constructor(view: EditorView) {
    this.decorations = simpleModeDecorations(view)
  }

  update(update: ViewUpdate): void {
    if (update.docChanged || update.selectionSet || update.viewportChanged) {
      this.decorations = simpleModeDecorations(update.view)
    }
  }
}, { decorations: (plugin) => plugin.decorations })

function simpleModeExtensions(): Extension[] {
  return [
    simpleModeRangesField,
    EditorState.changeFilter.of((transaction) => {
      const model = transaction.startState.field(simpleModeRangesField)
      return allowsSimpleModeTransaction(transaction.startState, transaction, model.protected)
    }),
    simpleModePlugin,
    EditorView.domEventHandlers({
      click(event: MouseEvent, view: EditorView): boolean {
        const target = event.target
        if (!(target instanceof HTMLElement)) {
          return false
        }
        const task = target.closest('.cm-simple-task') as HTMLElement | null
        return task ? toggleSimpleTask(task, view) : false
      },
      keydown(event: KeyboardEvent, view: EditorView): boolean {
        if (event.key !== 'Enter' && event.key !== ' ') {
          return false
        }
        const target = event.target
        if (!(target instanceof HTMLElement)) {
          return false
        }
        const task = target.closest('.cm-simple-task') as HTMLElement | null
        if (!task) {
          return false
        }
        event.preventDefault()
        return toggleSimpleTask(task, view)
      }
    })
  ]
}

function toggleSimpleTask(task: HTMLElement, view: EditorView): boolean {
  const from = Number(task.dataset.simpleTaskFrom)
  const to = Number(task.dataset.simpleTaskTo)
  const change = toggleTaskStatus(view.state, from, to)
  if (!change) {
    return false
  }
  view.dispatch({ changes: change.changes, selection: change.selection, userEvent: 'input' })
  view.focus()
  return true
}
let isEditable = true

let reportedCodeBlockState = false

function readEditorScrollAnchor(editor: EditorView): EditorScrollAnchor {
  const scrollRect = editor.scrollDOM.getBoundingClientRect()
  const contentRect = editor.contentDOM.getBoundingClientRect()
  const offset = editor.posAtCoords({ x: contentRect.left + 1, y: scrollRect.top + 1 }, false) ?? 0
  const block = editor.lineBlockAt(offset)
  const anchor = editor.coordsAtPos(offset)
  return {
    offset: offset,
    viewportY: (anchor?.top ?? editor.documentTop + block.top) - scrollRect.top
  }
}

function restoreEditorScrollAnchor(editor: EditorView): void {
  const scrollRect = editor.scrollDOM.getBoundingClientRect()
  const offset: number = Math.max(0, Math.min(editorScrollAnchor.offset, editor.state.doc.length))
  const block = editor.lineBlockAt(offset)
  const anchor = editor.coordsAtPos(offset)
  const anchorScreenTop: number = anchor?.top ?? editor.documentTop + block.top
  const nextScrollTop: number = preservedScrollTop(
    editor.scrollDOM.scrollTop,
    anchorScreenTop,
    scrollRect.top,
    editorScrollAnchor.viewportY,
    editor.scrollDOM.scrollHeight,
    editor.scrollDOM.clientHeight
  )
  editor.scrollDOM.scrollTop = nextScrollTop
}

function scheduleEditorScrollAnchorCapture(): void {
  const editor: EditorView | null = view
  if (!editor || scrollResizePending || anchorCaptureFrame !== 0) {
    return
  }
  anchorCaptureFrame = window.requestAnimationFrame((): void => {
    anchorCaptureFrame = 0
    if (!view || scrollResizePending ||
      view.scrollDOM.clientWidth !== observedEditorWidth ||
      view.scrollDOM.clientHeight !== observedEditorHeight) {
      return
    }
    editorScrollAnchor = readEditorScrollAnchor(view)
  })
}

function readVisibleSourceAnchor(editor: EditorView): {
  line: number; lineProgress: number; viewportRatio: number; atStart: boolean; atEnd: boolean
} {
  const scrollRect = editor.scrollDOM.getBoundingClientRect()
  const documentScroller = document.scrollingElement ?? document.documentElement
  const scrollContainer = editorWorkspaceScrollContainer(editor.scrollDOM, documentScroller)
  const viewportTop: number = scrollContainer === editor.scrollDOM ? scrollRect.top : 0
  const documentOffset: number = Math.max(0, viewportTop + 1 - editor.documentTop)
  const block = editor.lineBlockAtHeight(documentOffset)
  const offset: number = block.from
  const line = editor.state.doc.lineAt(offset)
  const maxScrollTop: number = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight)
  const scrollTop: number = Math.max(0, scrollContainer.scrollTop)
  const blockHeight: number = Math.max(1, block.bottom - block.top)
  return {
    line: line.number,
    lineProgress: Math.max(0, Math.min(1, (documentOffset - block.top) / blockHeight)),
    viewportRatio: 0,
    atStart: scrollTop <= 1,
    atEnd: maxScrollTop > 1 && scrollTop >= maxScrollTop - 1
  }
}

function scheduleSourceScrollReport(force: boolean = false): void {
  if (force) {
    sourceScrollReportForced = true
  }
  if (sourceScrollReportFrame !== 0) {
    return
  }
  sourceScrollReportFrame = window.requestAnimationFrame((): void => {
    sourceScrollReportFrame = 0
    const forced: boolean = sourceScrollReportForced
    sourceScrollReportForced = false
    const editor: EditorView | null = view
    if (!editor || (!forced && (!userScrollIntent || Date.now() < workspaceScrollReportSuppressedUntil))) {
      return
    }
    const anchor = readVisibleSourceAnchor(editor)
    postToArkts({ type: 'event', name: 'sourceScroll', line: anchor.line,
      lineProgress: anchor.lineProgress, viewportRatio: anchor.viewportRatio,
      atStart: anchor.atStart, atEnd: anchor.atEnd })
  })
}

function handleEditorScroll(event: Event): void {
  const editor: EditorView | null = view
  if (!editor) {
    return
  }
  const eventTarget: EventTarget | null = event.target
  const documentScroller: HTMLElement = document.scrollingElement ?? document.documentElement
  const isDocumentScroll: boolean = eventTarget === document || eventTarget === documentScroller ||
    eventTarget === document.documentElement || eventTarget === document.body
  if (!isDocumentScroll && eventTarget !== editor.scrollDOM) {
    return
  }
  const scrollContainer = isDocumentScroll ? documentScroller : editor.scrollDOM
  const top: number = Math.max(0, scrollContainer.scrollTop)
  if (scrollReportTimer !== undefined) {
    window.clearTimeout(scrollReportTimer)
    scrollReportTimer = undefined
  }
  if (Date.now() < workspaceScrollReportSuppressedUntil) {
    return
  }
  scrollReportTimer = window.setTimeout((): void => {
    scrollReportTimer = undefined
    if (view) {
      postToArkts({ type: 'event', name: 'scroll', top: top })
    }
  }, 200)
  if (!userScrollIntent) {
    return
  }
  scheduleEditorScrollAnchorCapture()
  scheduleSourceScrollReport()
  if (userScrollIntentTimer !== undefined) {
    window.clearTimeout(userScrollIntentTimer)
  }
  userScrollIntentTimer = window.setTimeout((): void => {
    userScrollIntent = false
    userScrollIntentTimer = undefined
  }, 200)
}

function markEditorScrollIntent(event?: Event): void {
  if (event?.type === 'keydown') {
    const key = (event as KeyboardEvent).key
    if (!['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(key)) {
      return
    }
  }
  userScrollIntent = true
  if (userScrollIntentTimer !== undefined) {
    window.clearTimeout(userScrollIntentTimer)
  }
  userScrollIntentTimer = window.setTimeout((): void => {
    userScrollIntent = false
    userScrollIntentTimer = undefined
  }, 200)
}

function observeEditorSize(editor: EditorView): void {
  observedEditorWidth = editor.scrollDOM.clientWidth
  observedEditorHeight = editor.scrollDOM.clientHeight
  document.addEventListener('scroll', handleEditorScroll, { passive: true, capture: true })
  editorResizeObserver = new ResizeObserver((entries: ResizeObserverEntry[]): void => {
    const width: number = editor.scrollDOM.clientWidth
    const height: number = editor.scrollDOM.clientHeight
    const scrollSizeChanged: boolean = width !== observedEditorWidth || height !== observedEditorHeight
    const contentResized: boolean = entries.some((entry: ResizeObserverEntry): boolean =>
      entry.target === editor.contentDOM)
    if (!scrollSizeChanged && (!scrollResizePending || !contentResized)) {
      return
    }
    if (scrollSizeChanged) {
      observedEditorWidth = width
      observedEditorHeight = height
      scrollResizePending = true
      userScrollIntent = false
      if (userScrollIntentTimer !== undefined) {
        window.clearTimeout(userScrollIntentTimer)
        userScrollIntentTimer = undefined
      }
    }
    const resizeGeneration: number = ++scrollResizeGeneration
    if (anchorRestoreFrame !== 0) {
      window.cancelAnimationFrame(anchorRestoreFrame)
    }
    anchorRestoreFrame = window.requestAnimationFrame((): void => {
      anchorRestoreFrame = window.requestAnimationFrame((): void => {
        anchorRestoreFrame = 0
        if (view === editor) {
          restoreEditorScrollAnchor(editor)
        }
        window.requestAnimationFrame((): void => {
          if (resizeGeneration === scrollResizeGeneration) {
            scrollResizePending = false
          }
        })
      })
    })
  })
  editorResizeObserver.observe(editor.scrollDOM)
  editorResizeObserver.observe(editor.contentDOM)
  document.addEventListener('touchstart', markEditorScrollIntent, { passive: true, capture: true })
  document.addEventListener('touchmove', markEditorScrollIntent, { passive: true, capture: true })
  document.addEventListener('wheel', markEditorScrollIntent, { passive: true, capture: true })
  document.addEventListener('keydown', markEditorScrollIntent, { capture: true })
}

function reportCodeBlockSelection(state: EditorState): void {
  const active = hasCodeBlockSelection(state)
  if (active === reportedCodeBlockState) {
    return
  }
  reportedCodeBlockState = active
  postToArkts({ type: 'event', name: 'codeBlockState', active: active })
}

function applyCodeBlockFormat(): void {
  if (!view || !isEditable) {
    return
  }
  view.dispatch({
    ...toggleCodeBlock(view.state),
    scrollIntoView: true,
    userEvent: 'input'
  })
  view.focus()
}

function extensionsFor(theme: string) {
  return [
    basicSetup,
    markdown(),
    syntaxHighlighting(defaultHighlightStyle),
    theme === 'dark' ? [DARK_THEME, oneDark] : [LIGHT_THEME],
    editableCompartment.of(EditorView.editable.of(isEditable)),
    readOnlyCompartment.of(EditorState.readOnly.of(!isEditable)),
    experienceCompartment.of(simpleExperience ? simpleModeExtensions() : []),
    EditorView.lineWrapping,
    autocompletion({ override: [wikiLinkCompletion], closeOnBlur: true }),
    // ⚠️ change 上报监听必须放进 extensionsFor 跟着每次 state 重建（2026-10-18 崩溃排查
    // 实证）：最初放在 ensureView 的 concat 里，setTheme 热切换用 extensionsFor 重建 state
    // 时把它丢了 → docChanged 无人监听 → change 事件从此绝迹、防抖自动保存/预览联动全失效。
    EditorView.updateListener.of((update) => {
      if (update.docChanged || update.selectionSet) {
        scheduleEditorScrollAnchorCapture()
      }
      if (update.selectionSet || update.docChanged) {
        reportCodeBlockSelection(update.state)
      }
      if (!update.docChanged || applyingContent) {
        return
      }
      if (isComposing) {
        return
      }
      // debounce：连续击键不逐帧过桥（保存/切走时 ArkTS 会主动拉全量）
      changeNotification.schedule(
        () => update.state.doc.length,
        documentRevision,
        (len: number, revision: number): void => postToArkts({
          type: 'event', name: 'change', len: len, revision: revision
        })
      )
    })
  ]
}

function setLineNumberVisibility(show: boolean): void {
  lineNumbersVisible = show
  // CodeMirror may rewrite the EditorView root classes while processing document
  // updates. Keep this preference class on our stable host instead.
  document.getElementById('editor')?.classList.toggle('cm-show-line-numbers', show)
}

function ensureView(): EditorView {
  if (view) {
    return view
  }
  const parent = document.getElementById('editor') as HTMLElement
  const state = EditorState.create({
    doc: '',
    extensions: extensionsFor(themeMode)
  })
  view = new EditorView({ state, parent })
  parent.classList.toggle('cm-experience-simple', simpleExperience)
  setLineNumberVisibility(lineNumbersVisible)
  observeEditorSize(view)
  view.dom.addEventListener('compositionstart', () => {
    isComposing = true
    changeNotification.cancel()
    postToArkts({ type: 'event', name: 'composition', composing: true })
  })
  view.dom.addEventListener('compositionend', () => {
    isComposing = false
    postToArkts({ type: 'event', name: 'composition', composing: false })
    changeNotification.schedule(
      () => view?.state.doc.length ?? 0,
      documentRevision,
      (len: number, revision: number): void => postToArkts({
        type: 'event', name: 'change', len: len, revision: revision
      })
    )
  })
  return view
}

function applyMarkdownFormat(kind: string): void {
  if (!view || !isEditable) {
    return
  }
  if (kind === 'code') {
    applyCodeBlockFormat()
    return
  }
  const change = toggleMarkdownFormat(view.state, kind)
  if (!change) {
    view.focus()
    return
  }
  view.dispatch({
    changes: change.changes,
    selection: change.selection,
    scrollIntoView: true,
    userEvent: 'input'
  })
  view.focus()
}

const api: MdEditorApi = {
  setContent(b64: string, revision: number, vaultIdB64: string, noteDirB64: string): void {
    documentRevision = Number.isInteger(revision) && revision >= 0 ? revision : 0
    simpleModeVaultId = b64decode(vaultIdB64)
    simpleModeNoteDir = b64decode(noteDirB64)
    workspaceScrollRestoreGeneration++
    if (sourceScrollReportFrame !== 0) {
      window.cancelAnimationFrame(sourceScrollReportFrame)
      sourceScrollReportFrame = 0
    }
    sourceScrollReportForced = false
    userScrollIntent = false
    if (userScrollIntentTimer !== undefined) {
      window.clearTimeout(userScrollIntentTimer)
      userScrollIntentTimer = undefined
    }
    const normalizedText = normalizeEditorText(b64decode(b64))
    documentLineEnding = normalizedText.lineEnding
    const text = normalizedText.text
    const v = ensureView()
    // A pending edit notification belongs to the document being replaced. Do not let it
    // mark the newly selected workspace target dirty after this programmatic replacement.
    changeNotification.cancel()
    // setDoc 会走 undo 栈：用 effects 直接替换，避免用户一次 ctrl+z 撤回到「设置前」
    applyingContent = true
    try {
      v.dispatch({
        changes: { from: 0, to: v.state.doc.length, insert: text },
        // 设置内容不是用户编辑，不进 undo 历史
        annotations: []
      })
    } finally {
      applyingContent = false
    }
  },

  replaceContentFromPreview(b64: string, expectedRevision: number): void {
    if (expectedRevision !== documentRevision) return
    const normalizedText = normalizeEditorText(b64decode(b64))
    documentLineEnding = normalizedText.lineEnding
    const v = ensureView()
    changeNotification.cancel()
    applyingContent = true
    try {
      v.dispatch({
        changes: { from: 0, to: v.state.doc.length, insert: normalizedText.text },
        annotations: []
      })
    } finally {
      applyingContent = false
    }
  },

  getContent(): string {
    const v = ensureView()
    return b64encode(serializeEditorText(v.state.doc.toString(), documentLineEnding))
  },

  /** ArkTS 侧内容拉取入口：把全量内容 base64 后经 content 事件回传（不走 runJavaScript 返回值） */
  requestContent(reqId: number): void {
    const v = ensureView()
    const b64 = b64encode(serializeEditorText(v.state.doc.toString(), documentLineEnding))
    postToArkts({ type: 'event', name: 'content', id: reqId, b64: b64 })
  },

  insertText(b64: string): void {
    const v = ensureView()
    const inserted = b64decode(b64)
    const selection = v.state.selection.main
    v.dispatch({
      changes: { from: selection.from, to: selection.to, insert: inserted },
      selection: { anchor: selection.from + inserted.length },
      scrollIntoView: true,
      userEvent: 'input'
    })
    v.focus()
  },

  applyFormat(kind: string): void {
    applyMarkdownFormat(kind)
  },

  scrollToOffset(offset: number): void {
    const v = ensureView()
    const safeOffset = Math.max(0, Math.min(offset, v.state.doc.length))
    v.dispatch({ selection: { anchor: safeOffset }, scrollIntoView: true })
    v.focus()
  },

  restoreScrollTop(top: number): void {
    const generation = ++workspaceScrollRestoreGeneration
    const target: number = Number.isFinite(top) ? Math.max(0, top) : 0
    const editor = ensureView()
    if (scrollReportTimer !== undefined) {
      window.clearTimeout(scrollReportTimer)
      scrollReportTimer = undefined
    }
    window.requestAnimationFrame((): void => {
      window.requestAnimationFrame((): void => {
        if (view !== editor || generation !== workspaceScrollRestoreGeneration) {
          return
        }
        const documentScroller = document.scrollingElement ?? document.documentElement
        const scrollElement = editorWorkspaceScrollContainer(editor.scrollDOM, documentScroller)
        workspaceScrollReportSuppressedUntil = Date.now() + 250
        scrollElement.scrollTop = clampWorkspaceScrollTop(scrollElement, target)
        scheduleSourceScrollReport(true)
      })
    })
  },

  focus(): void {
    ensureView().focus()
  },

  blur(): void {
    view?.contentDOM.blur()
  },

  setTheme(theme: string): void {
    themeMode = theme === 'dark' ? 'dark' : 'light'
    document.documentElement.setAttribute('data-theme', themeMode)
    if (view) {
      // 热切换主题：整组 extensions 重建
      view.setState(EditorState.create({
        doc: view.state.doc,
        selection: view.state.selection,
        extensions: extensionsFor(themeMode)
      }))
      setLineNumberVisibility(lineNumbersVisible)
    }
  },

  setLineNumbers(show: boolean): void {
    setLineNumberVisibility(show)
  },

  setExperience(mode: string): void {
    simpleExperience = mode === 'simple'
    const editor = ensureView()
    editor.dom.parentElement?.classList.toggle('cm-experience-simple', simpleExperience)
    editor.dispatch({ effects: experienceCompartment.reconfigure(simpleExperience ? simpleModeExtensions() : []) })
  },

  reportVisibleSourceAnchor(): void {
    scheduleSourceScrollReport(true)
  },

  setEditable(editable: boolean): void {
    isEditable = editable
    if (view) {
      view.dispatch({ effects: [
        editableCompartment.reconfigure(EditorView.editable.of(editable)),
        readOnlyCompartment.reconfigure(EditorState.readOnly.of(!editable))
      ] })
    }
  },

  setLinkCandidatesResult(id: number, b64: string): void {
    const waiter = linkCompletionWaiters.get(id)
    if (!waiter) {
      return
    }
    linkCompletionWaiters.delete(id)
    try {
      waiter(JSON.parse(b64decode(b64)) as WikiLinkCandidate[])
    } catch (error) {
      waiter([])
    }
  },

  /**
   * ArkTS 在 onPageEnd 主动调这个（javaScriptProxy 那时才真正注入）：
   * 立刻重试一次 ready 上报。找不到 __arkts 时静默返回，交给轮询兜底。
   */
  onArktsReady(): void {
    postToArkts({ type: 'event', name: 'ready' })
  }
}

window.__mdeditor = api

// ready 事件的发送在 postToArkts 上方的 announceReady() 里（要等 __arkts 注入）
