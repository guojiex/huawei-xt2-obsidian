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
import { syntaxHighlighting, defaultHighlightStyle, syntaxTree } from '@codemirror/language'
import { oneDark } from '@codemirror/theme-one-dark'

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
  setEditable(editable: boolean): void
  setLinkCandidatesResult(id: number, b64: string): void
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

// ---------- 实例 ----------
let view: EditorView | null = null
let changeTimer: number | undefined = undefined
let isComposing = false
let applyingContent = false
let documentLineEnding = '\n'
const editableCompartment = new Compartment()
const readOnlyCompartment = new Compartment()
let isEditable = true

interface FencedCodeBlock {
  from: number
  bodyFrom: number
  closeLineFrom: number
  removeTo: number
  closed: boolean
  closeLineEnding: string
}

function enclosingFencedCodeNode(state: EditorState, position: number, bias: -1 | 1) {
  const safePosition = Math.max(0, Math.min(position, state.doc.length))
  let node = syntaxTree(state).resolveInner(safePosition, bias)
  while (node) {
    if (node.name === 'FencedCode') {
      return node
    }
    node = node.parent
  }
  return null
}

function selectedFencedCodeNode(state: EditorState) {
  const selection = state.selection.main
  if (selection.empty) {
    return enclosingFencedCodeNode(state, selection.from, 1) ??
      (selection.from > 0 ? enclosingFencedCodeNode(state, selection.from - 1, 1) : null)
  }
  const first = enclosingFencedCodeNode(state, selection.from, 1)
  const last = enclosingFencedCodeNode(state, selection.to - 1, -1)
  return first && last && first.from === last.from && first.to === last.to ? first : null
}

function lineEndingAfter(state: EditorState, lineEnd: number): { text: string, end: number } {
  const next = state.doc.sliceString(lineEnd, lineEnd + 2)
  if (next.startsWith('\r\n')) {
    return { text: '\r\n', end: lineEnd + 2 }
  }
  if (next.startsWith('\n')) {
    return {
      text: state.doc.sliceString(lineEnd - 1, lineEnd) === '\r' ? '\r\n' : '\n',
      end: lineEnd + 1
    }
  }
  return { text: '', end: lineEnd }
}

function selectedFencedCodeBlock(state: EditorState): FencedCodeBlock | null {
  const node = selectedFencedCodeNode(state)
  if (!node) {
    return null
  }
  let openingMark: typeof node | null = null
  let closingMark: typeof node | null = null
  let child = node.firstChild
  while (child) {
    if (child.name === 'CodeMark') {
      if (openingMark === null) {
        openingMark = child
      } else {
        closingMark = child
      }
    }
    child = child.nextSibling
  }
  if (openingMark === null) {
    return null
  }
  const openingLine = state.doc.lineAt(openingMark.from)
  const openingPrefix = state.doc.sliceString(openingLine.from, openingMark.from)
  if (!/^ {0,3}$/.test(openingPrefix)) {
    return null
  }
  const bodyFrom = lineEndingAfter(state, openingLine.to).end
  if (closingMark === null) {
    return {
      from: openingLine.from,
      bodyFrom: bodyFrom,
      closeLineFrom: state.doc.length,
      removeTo: bodyFrom,
      closed: false,
      closeLineEnding: ''
    }
  }
  const closingLine = state.doc.lineAt(closingMark.from)
  const closingPrefix = state.doc.sliceString(closingLine.from, closingMark.from)
  if (!/^ {0,3}$/.test(closingPrefix)) {
    return null
  }
  const closeEnding = lineEndingAfter(state, closingLine.to)
  return {
    from: openingLine.from,
    bodyFrom: bodyFrom,
    closeLineFrom: closingLine.from,
    removeTo: closeEnding.end,
    closed: true,
    closeLineEnding: closeEnding.text
  }
}

let reportedCodeBlockState = false

function reportCodeBlockSelection(state: EditorState): void {
  const active = selectedFencedCodeBlock(state) !== null
  if (active === reportedCodeBlockState) {
    return
  }
  reportedCodeBlockState = active
  postToArkts({ type: 'event', name: 'codeBlockState', active: active })
}

function preferredLineEnding(): string {
  return '\n'
}

function serializeEditorText(text: string): string {
  return documentLineEnding === '\r\n' ? text.replace(/\n/g, '\r\n') : text
}

function applyCodeBlockFormat(): void {
  if (!view || !isEditable) {
    return
  }
  const state = view.state
  const selection = state.selection.main
  const block = selectedFencedCodeBlock(state)
  if (block) {
    const bodyEnd = block.closed ? block.closeLineFrom : state.doc.length
    const rawBody = state.sliceDoc(block.bodyFrom, bodyEnd)
    const content = block.closed
      ? (rawBody.endsWith('\r\n') ? rawBody.slice(0, -2) :
        rawBody.endsWith('\n') ? rawBody.slice(0, -1) : rawBody)
      : rawBody
    const replacement = block.closed ? content + block.closeLineEnding : content
    const replaceTo = block.closed ? block.removeTo : block.bodyFrom
    view.dispatch({
      changes: { from: block.from, to: replaceTo, insert: replacement },
      selection: { anchor: block.from, head: block.from + content.length },
      scrollIntoView: true,
      userEvent: 'input'
    })
    view.focus()
    return
  }

  const selected = state.sliceDoc(selection.from, selection.to)
  const content = selected || '代码'
  const lineEnding = preferredLineEnding()
  const runs = content.match(/`+/g) ?? []
  let fenceLength = 2
  for (const run of runs) {
    fenceLength = Math.max(fenceLength, run.length)
  }
  const fence = '`'.repeat(fenceLength + 1)
  const prefix = selection.from > 0 && state.sliceDoc(selection.from - 1, selection.from) !== '\n'
    ? lineEnding : ''
  const suffix = selection.to < state.doc.length && state.sliceDoc(selection.to, selection.to + 1) !== '\n'
    ? lineEnding : ''
  const opening = fence + lineEnding
  const closingBreak = content.endsWith('\n') ? '' : lineEnding
  const replacement = prefix + opening + content + closingBreak + fence + suffix
  const contentStart = selection.from + prefix.length + opening.length
  view.dispatch({
    changes: { from: selection.from, to: selection.to, insert: replacement },
    selection: { anchor: contentStart, head: contentStart + content.length },
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
    const sourceText = b64decode(b64)
    documentLineEnding = sourceText.includes('\r\n') ? '\r\n' : '\n'
    const text = sourceText.replace(/\r\n/g, '\n')
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
    return b64encode(serializeEditorText(v.state.doc.toString()))
  },

  /** ArkTS 侧内容拉取入口：把全量内容 base64 后经 content 事件回传（不走 runJavaScript 返回值） */
  requestContent(reqId: number): void {
    const v = ensureView()
    const b64 = b64encode(serializeEditorText(v.state.doc.toString()))
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
    }
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
