import { markdown } from '@codemirror/lang-markdown'
import { EditorState } from '@codemirror/state'
import { EditorView, keymap } from '@codemirror/view'
import { basicSetup } from 'codemirror'

type Mode = 'cm' | 'textarea'

const sampleText = Array.from({ length: 500 }, (_, index) =>
  `第 ${index + 1} 行：中文输入法、光标位置与长文滚动验证。`)
  .join('\n')

const eventList = document.getElementById('event-list') as HTMLOListElement
const cmBox = document.getElementById('cm-box') as HTMLDivElement
const textareaBox = document.getElementById('textarea-box') as HTMLDivElement
const textarea = document.getElementById('test-textarea') as HTMLTextAreaElement
const cursorText = document.getElementById('cursor') as HTMLSpanElement
const viewportText = document.getElementById('viewport') as HTMLSpanElement
const loadedText = document.getElementById('loaded-at') as HTMLSpanElement
const modeText = document.getElementById('active-mode') as HTMLSpanElement
const cmButton = document.getElementById('mode-cm') as HTMLButtonElement
const textareaButton = document.getElementById('mode-textarea') as HTMLButtonElement
const cmEditor = new EditorView({
  state: EditorState.create({
    doc: sampleText,
    extensions: [
      basicSetup,
      markdown(),
      keymap.of([]),
      EditorView.updateListener.of((update) => {
        if (update.docChanged) {
          appendLog('CodeMirror', '文档变化', `长度=${update.state.doc.length}`)
        }
        if (update.selectionSet || update.docChanged) {
          updateCursor()
        }
      })
    ]
  }),
  parent: cmBox
})

let activeMode: Mode = 'cm'

function timeLabel(): string {
  return new Date().toLocaleTimeString()
}

function appendLog(source: string, type: string, detail: string): void {
  const item = document.createElement('li')
  item.textContent = `${timeLabel()} [${source}] ${type}${detail.length > 0 ? ` · ${detail}` : ''}`
  eventList.appendChild(item)
  while (eventList.children.length > 80) {
    eventList.removeChild(eventList.firstElementChild as HTMLLIElement)
  }
  eventList.scrollTop = eventList.scrollHeight
}

function eventDetail(event: Event): string {
  const fields: string[] = []
  const inputEvent = event as InputEvent
  if (typeof inputEvent.data === 'string' && inputEvent.data.length > 0) {
    fields.push(`data=${JSON.stringify(inputEvent.data.slice(0, 12))}`)
  }
  if (typeof inputEvent.inputType === 'string' && inputEvent.inputType.length > 0) {
    fields.push(`inputType=${inputEvent.inputType}`)
  }
  if (typeof inputEvent.isComposing === 'boolean') {
    fields.push(`isComposing=${inputEvent.isComposing}`)
  }
  const keyboardEvent = event as KeyboardEvent
  if (typeof keyboardEvent.key === 'string' && keyboardEvent.key.length > 0) {
    fields.push(`key=${keyboardEvent.key}`)
  }
  fields.push(`trusted=${event.isTrusted}`)
  return fields.join(' ')
}

function trackEvents(target: HTMLElement, source: string): void {
  const eventNames = [
    'compositionstart', 'compositionupdate', 'compositionend',
    'beforeinput', 'input', 'keydown', 'keyup', 'click'
  ]
  for (const eventName of eventNames) {
    target.addEventListener(eventName, (event: Event) => {
      appendLog(source, event.type, eventDetail(event))
      updateCursor()
    })
  }
}

function cursorForText(value: string, offset: number): string {
  const prefix = value.slice(0, offset)
  const line = prefix.split('\n').length
  const lastNewline = prefix.lastIndexOf('\n')
  const column = prefix.length - lastNewline
  return `行 ${line} · 列 ${column} · offset ${offset}`
}

function updateCursor(): void {
  if (activeMode === 'cm') {
    const offset = cmEditor.state.selection.main.head
    const line = cmEditor.state.doc.lineAt(offset)
    cursorText.textContent = `CodeMirror：行 ${line.number} · 列 ${offset - line.from + 1} · offset ${offset}`
  } else {
    cursorText.textContent = `TextArea：${cursorForText(textarea.value, textarea.selectionStart)}`
  }
}

function updateViewport(): void {
  const box = document.getElementById('editors') as HTMLDivElement
  const rect = box.getBoundingClientRect()
  viewportText.textContent = `窗口 ${window.innerWidth}×${window.innerHeight} · 编辑区 ${Math.round(rect.width)}×${Math.round(rect.height)} · resize ${resizeCount}`
}

function setMode(mode: Mode): void {
  activeMode = mode
  const showCm = mode === 'cm'
  cmBox.hidden = !showCm
  textareaBox.hidden = showCm
  cmButton.setAttribute('aria-pressed', String(showCm))
  textareaButton.setAttribute('aria-pressed', String(!showCm))
  modeText.textContent = showCm ? 'CodeMirror 6 · contenteditable' : 'HTML TextArea · 原生 textarea'
  updateCursor()
  updateViewport()
  appendLog('页面', '切换编辑器', modeText.textContent)
}

let resizeCount = 0
trackEvents(cmEditor.contentDOM, 'CodeMirror')
trackEvents(textarea, 'TextArea')
textarea.value = sampleText
textarea.addEventListener('input', () => updateCursor())
textarea.addEventListener('keyup', () => updateCursor())
textarea.addEventListener('click', () => updateCursor())
cmButton.addEventListener('click', () => setMode('cm'))
textareaButton.addEventListener('click', () => setMode('textarea'))
document.getElementById('reset-sample')?.addEventListener('click', () => {
  cmEditor.dispatch({ changes: { from: 0, to: cmEditor.state.doc.length, insert: sampleText } })
  textarea.value = sampleText
  updateCursor()
  appendLog('页面', '重置样例', '两个编辑器各 500 行')
})
document.getElementById('clear-log')?.addEventListener('click', () => {
  eventList.replaceChildren()
})
window.addEventListener('resize', () => {
  resizeCount += 1
  updateViewport()
  appendLog('页面', 'window.resize', `次数=${resizeCount}`)
})
new ResizeObserver(() => {
  updateViewport()
  appendLog('页面', '编辑区尺寸变化', '')
}).observe(document.getElementById('editors') as HTMLDivElement)

loadedText.textContent = new Date().toLocaleString()
updateViewport()
updateCursor()
appendLog('页面', '载入完成', '折叠切换后检查载入时间是否变化')
