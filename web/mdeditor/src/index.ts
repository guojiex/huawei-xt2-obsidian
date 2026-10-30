/**
 * mdeditor/src/index.ts —— M0.5 spike：Web 组件内的 CodeMirror 6 Markdown 编辑器。
 *
 * 打包：esbuild → 单文件 IIFE → 内联进 index.html → rawfile/mdeditor/index.html
 *      （照抄 web/gitbridge/build.mjs 的链路，见 AGENTS.md §Web 打包约定）
 *
 * 桥接协议（与 gitbridge 一致，JSON over javaScriptProxy.postMessage）：
 *   ArkTS → Web：window.__mdeditor.setContent(b64) / requestContent(id) / focus() / setTheme(t)
 *   Web → ArkTS：postMessage(JSON)
 *     - {type:'event', name:'ready'}                 页面就绪，可以收内容了
 *     - {type:'event', name:'change', len:N}          内容变化（debounce 300ms，只报长度）
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
import { EditorView } from '@codemirror/view'
import { Compartment, EditorState } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language'
import { oneDark } from '@codemirror/theme-one-dark'
import { preservedScrollTop } from './scrollAnchor'
import { clampWorkspaceScrollTop, editorWorkspaceScrollContainer } from './workspaceScroll'
import {
  hasCodeBlockSelection,
  normalizeEditorText,
  serializeEditorText,
  toggleCodeBlock
} from './codeBlockFormat'

declare global {
  interface Window {
    __mdeditor: MdEditorApi
    __arkts?: { postMessage: (msg: string) => void }
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
  setContent(b64: string): void
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
    '.cm-content': { fontFamily: 'var(--mono)', lineHeight: 'var(--leading)', padding: 'var(--s2) 0' },
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
    '.cm-content': { fontFamily: 'var(--mono)', lineHeight: 'var(--leading)', padding: 'var(--s2) 0' },
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
let changeTimer: number | undefined = undefined
let isComposing = false
let applyingContent = false
let documentLineEnding = '\n'
const editableCompartment = new Compartment()
const readOnlyCompartment = new Compartment()
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
  const contentRect = editor.contentDOM.getBoundingClientRect()
  const offset: number = editor.posAtCoords({ x: contentRect.left + 1, y: scrollRect.top + 1 }, false) ?? 0
  const line = editor.state.doc.lineAt(offset)
  const lineLength: number = Math.max(1, line.to - line.from)
  const documentScroller = document.scrollingElement ?? document.documentElement
  const scrollContainer = editorWorkspaceScrollContainer(editor.scrollDOM, documentScroller)
  const maxScrollTop: number = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight)
  const scrollTop: number = Math.max(0, scrollContainer.scrollTop)
  return {
    line: line.number,
    lineProgress: Math.max(0, Math.min(1, (offset - line.from) / lineLength)),
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
      if (changeTimer !== undefined) {
        window.clearTimeout(changeTimer)
      }
      changeTimer = window.setTimeout(() => {
        changeTimer = undefined
        postToArkts({ type: 'event', name: 'change', len: update.state.doc.length })
      }, 300)
    })
  ]
}

function setLineNumberVisibility(show: boolean): void {
  lineNumbersVisible = show
  view?.dom.classList.toggle('cm-show-line-numbers', show)
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
  setLineNumberVisibility(lineNumbersVisible)
  observeEditorSize(view)
  view.dom.addEventListener('compositionstart', () => {
    isComposing = true
    if (changeTimer !== undefined) {
      window.clearTimeout(changeTimer)
      changeTimer = undefined
    }
    postToArkts({ type: 'event', name: 'composition', composing: true })
  })
  view.dom.addEventListener('compositionend', () => {
    isComposing = false
    postToArkts({ type: 'event', name: 'composition', composing: false })
    if (changeTimer !== undefined) {
      window.clearTimeout(changeTimer)
    }
    changeTimer = window.setTimeout(() => {
      changeTimer = undefined
      if (view) {
        postToArkts({ type: 'event', name: 'change', len: view.state.doc.length })
      }
    }, 300)
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
  const state = view.state
  const value = state.doc.toString()
  const selection = state.selection.main
  let start = selection.from
  let end = selection.to
  const selected = state.sliceDoc(start, end)
  let replacement = ''
  let selectionStart = start
  let selectionEnd = end
  const inlineFormats: Record<string, [string, string, string]> = {
    bold: ['**', '**', '粗体文字'],
    italic: ['*', '*', '斜体文字'],
    inlineCode: ['`', '`', '代码'],
    link: ['[', '](https://example.com)', '链接文字']
  }
  const inline = inlineFormats[kind]
  if (inline) {
    const text = selected || inline[2]
    replacement = inline[0] + text + inline[1]
    selectionStart = start + inline[0].length
    selectionEnd = selectionStart + text.length
  } else if (kind === 'paragraph' || /^h[1-6]$/.test(kind)) {
    const lineStart = state.doc.lineAt(start).from
    const lineEnd = state.doc.lineAt(end).to
    const prefix = kind === 'paragraph' ? '' : '#'.repeat(Number(kind.substring(1))) + ' '
    const lines = state.sliceDoc(lineStart, lineEnd).split('\n')
    replacement = lines.map((line: string): string =>
      prefix + line.replace(/^#{1,6} +/, '')).join('\n')
    start = lineStart
    end = lineEnd
    selectionStart = start
    selectionEnd = start + replacement.length
  } else {
    const prefixes: Record<string, string> = {
      list: '- ',
      ordered: '1. ',
      task: '- [ ] ',
      quote: '> '
    }
    let prefix = prefixes[kind]
    if (prefix) {
      replacement = (selected || (kind === 'quote' ? '引用文字' : '列表项'))
        .split('\n').map((line: string, index: number): string =>
          (kind === 'ordered' ? (index + 1).toString() + '. ' : prefix) + line).join('\n')
      if (start > 0 && value[start - 1] !== '\n') {
        replacement = '\n' + replacement
        selectionStart += 1
      }
      if (end < value.length && value[end] !== '\n') {
        replacement += '\n'
      }
      selectionEnd = selectionStart + replacement.length - (start > 0 && value[start - 1] !== '\n' ? 1 : 0) -
        (end < value.length && value[end] !== '\n' ? 1 : 0)
    } else {
      return
    }
  }
  view.dispatch({
    changes: { from: start, to: end, insert: replacement },
    selection: { anchor: selectionStart, head: selectionEnd },
    scrollIntoView: true,
    userEvent: 'input'
  })
  view.focus()
}

const api: MdEditorApi = {
  setContent(b64: string): void {
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
    // 诊断：证明 ArkTS→JS 内容下发成功（经 onConsole 进 hilog，tag=EditorWebView）
    console.log('[mdeditor] setContent len=' + text.length)
    const v = ensureView()
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

  getContent(): string {
    const v = ensureView()
    return b64encode(serializeEditorText(v.state.doc.toString(), documentLineEnding))
  },

  /** ArkTS 侧内容拉取入口：把全量内容 base64 后经 content 事件回传（不走 runJavaScript 返回值） */
  requestContent(reqId: number): void {
    const v = ensureView()
    const b64 = b64encode(serializeEditorText(v.state.doc.toString(), documentLineEnding))
    console.log('[mdeditor] requestContent id=' + reqId + ' len=' + v.state.doc.length)
    postToArkts({ type: 'event', name: 'content', id: reqId, b64: b64 })
  },

  insertText(b64: string): void {
    const v = ensureView()
    const inserted = b64decode(b64)
    const selection = v.state.selection.main
    v.dispatch({
      changes: { from: selection.from, to: selection.to, insert: inserted },
      selection: { anchor: selection.from + inserted.length }
    })
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
