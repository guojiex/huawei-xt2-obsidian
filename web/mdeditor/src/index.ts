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
import { EditorView } from '@codemirror/view'
import { Compartment, EditorState } from '@codemirror/state'
import { markdown } from '@codemirror/lang-markdown'
import { syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language'
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
  focus(): void
  setTheme(theme: string): void
  setEditable(editable: boolean): void
  onArktsReady(): void
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
// 浅色：底色走 App 的 bg_card(#FFFFFF)、文字 text_primary(#E6000000)，与侧栏同源；
// Harmony 色值是 ARGB，CSS 的 8 位 hex 则是 RRGGBBAA，因此半透明色在这里显式写 rgba。
// 深色：oneDark 变体，底色对齐 bg_card(#1C1C1F)。字号/行高与 Tokens.ets 的
// FontSize.body2(14) / LINE_HEIGHT_BODY(1.65) 保持一致 —— Web 内不能引 token，两边手工同步。
const LIGHT_THEME = EditorView.theme(
  {
    '&': { backgroundColor: '#FFFFFF', color: 'rgba(0, 0, 0, 0.9)', fontSize: '14px' },
    '.cm-content': { fontFamily: 'system-ui, sans-serif', lineHeight: '1.65', padding: '8px 0' },
    '.cm-gutters': { backgroundColor: '#FFFFFF', border: 'none', color: 'rgba(0, 0, 0, 0.4)' },
    '.cm-activeLine': { backgroundColor: 'rgba(0, 0, 0, 0.04)' },
    '.cm-activeLineGutter': { backgroundColor: 'rgba(0, 0, 0, 0.04)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'rgba(0, 125, 255, 0.12)' },
    '.cm-cursor': { borderLeftColor: '#007DFF' }
  },
  { dark: false }
)

const DARK_THEME = EditorView.theme(
  {
    '&': { backgroundColor: '#1C1C1F', color: 'rgba(255, 255, 255, 0.92)', fontSize: '14px' },
    '.cm-content': { fontFamily: 'system-ui, sans-serif', lineHeight: '1.65', padding: '8px 0' },
    '.cm-gutters': { backgroundColor: '#1C1C1F', border: 'none', color: 'rgba(255, 255, 255, 0.6)' },
    '.cm-activeLine': { backgroundColor: 'rgba(255, 255, 255, 0.12)' },
    '.cm-activeLineGutter': { backgroundColor: 'rgba(255, 255, 255, 0.12)' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'rgba(78, 161, 255, 0.2)' },
    '.cm-cursor': { borderLeftColor: '#4EA1FF' }
  },
  { dark: true }
)

let themeMode = 'light'

// ---------- 实例 ----------
let view: EditorView | null = null
let changeTimer: number | undefined = undefined
const editableCompartment = new Compartment()
const readOnlyCompartment = new Compartment()
let isEditable = true

function extensionsFor(theme: string) {
  return [
    basicSetup,
    markdown(),
    syntaxHighlighting(defaultHighlightStyle),
    theme === 'dark' ? [DARK_THEME, oneDark] : [LIGHT_THEME],
    editableCompartment.of(EditorView.editable.of(isEditable)),
    readOnlyCompartment.of(EditorState.readOnly.of(!isEditable)),
    EditorView.lineWrapping,
    // ⚠️ change 上报监听必须放进 extensionsFor 跟着每次 state 重建（2026-10-18 崩溃排查
    // 实证）：最初放在 ensureView 的 concat 里，setTheme 热切换用 extensionsFor 重建 state
    // 时把它丢了 → docChanged 无人监听 → change 事件从此绝迹、防抖自动保存/预览联动全失效。
    EditorView.updateListener.of((update) => {
      if (!update.docChanged) {
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
  return view
}

const api: MdEditorApi = {
  setContent(b64: string): void {
    const text = b64decode(b64)
    // 诊断：证明 ArkTS→JS 内容下发成功（经 onConsole 进 hilog，tag=EditorWebView）
    console.log('[mdeditor] setContent len=' + text.length)
    const v = ensureView()
    // setDoc 会走 undo 栈：用 effects 直接替换，避免用户一次 ctrl+z 撤回到「设置前」
    v.dispatch({
      changes: { from: 0, to: v.state.doc.length, insert: text },
      // 设置内容不是用户编辑，不进 undo 历史
      annotations: []
    })
  },

  getContent(): string {
    const v = ensureView()
    return b64encode(v.state.doc.toString())
  },

  /** ArkTS 侧内容拉取入口：把全量内容 base64 后经 content 事件回传（不走 runJavaScript 返回值） */
  requestContent(reqId: number): void {
    const v = ensureView()
    const b64 = b64encode(v.state.doc.toString())
    console.log('[mdeditor] requestContent id=' + reqId + ' len=' + v.state.doc.length)
    postToArkts({ type: 'event', name: 'content', id: reqId, b64: b64 })
  },

  focus(): void {
    ensureView().focus()
  },

  setTheme(theme: string): void {
    themeMode = theme === 'dark' ? 'dark' : 'light'
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
