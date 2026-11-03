import { EditorState, Transaction } from '@codemirror/state'
import { ensureSyntaxTree } from '@codemirror/language'
// ⚠️ 必须带 `.ts` 后缀：`web/mdeditor/test/*.test.mjs` 有一部分直接用 Node 的类型剥离
// 导入本文件，Node 的 ESM 解析不允许省略扩展名（ERR_MODULE_NOT_FOUND）。
import { customBlockRanges } from './blockRegistry.ts'

export interface SimpleRange {
  from: number
  to: number
  kind: string
  value?: string
  alt?: string
}

export interface SimpleModeRanges {
  protected: SimpleRange[]
  decorations: SimpleRange[]
}

/**
 * 受保护块的提示文案（v1.7 17.4：限制须在相关内容附近清楚说明）。
 * 只写「后续版本」不写版本号，避免版本重排后文案过期。
 * - 表格：v1.14「简单模式表格编辑」已立项，可以承诺后续开放。
 * - 其余：需求池没有排期，属简单模式的长期边界，只说清「不支持」，
 *   不承诺会支持，也不让用户干等。
 */
export const PROTECTED_HINT_TABLE: string = '表格编辑将在后续版本开放，当前请在专业模式修改'
export const PROTECTED_HINT_DEFAULT: string = '此内容不支持在简单模式编辑，请在专业模式修改'

function mergeProtected(ranges: SimpleRange[]): SimpleRange[] {
  const sorted = ranges.filter((range) => range.to > range.from)
    .sort((left, right) => left.from - right.from || left.to - right.to)
  const merged: SimpleRange[] = []
  for (const range of sorted) {
    const last = merged[merged.length - 1]
    if (last && range.from <= last.to) {
      last.to = Math.max(last.to, range.to)
    } else {
      merged.push({ from: range.from, to: range.to, kind: 'protected' })
    }
  }
  return merged
}

/** 与 mergeProtected 同逻辑，但保留提示文案：合并到一起的不同类型块退回默认文案。 */
function mergeHints(ranges: SimpleRange[]): SimpleRange[] {
  const sorted = ranges.filter((range) => range.to > range.from)
    .sort((left, right) => left.from - right.from || left.to - right.to)
  const merged: SimpleRange[] = []
  for (const range of sorted) {
    const last = merged[merged.length - 1]
    if (last && range.from <= last.to) {
      last.to = Math.max(last.to, range.to)
      if (last.value !== range.value) {
        last.value = undefined
      }
    } else {
      merged.push({ from: range.from, to: range.to, kind: 'protected-hint', value: range.value })
    }
  }
  return merged
}

function frontmatterRange(source: string): SimpleRange | null {
  const match = /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(source)
  return match ? { from: 0, to: match[0].length, kind: 'protected' } : null
}

/**
 * 行模式受保护块：识别逻辑已迁到 `blockRegistry.ts`（v1.18 18.1），这里只把它投影成
 * simpleMode 的区间 —— 两处共用同一份识别，避免块身份与保护范围各自漂移。
 */
function customProtectedRanges(source: string): SimpleRange[] {
  return customBlockRanges(source).map((block) => ({
    from: block.from,
    to: block.to,
    kind: 'protected',
    value: block.type === 'table' ? PROTECTED_HINT_TABLE : undefined
  }))
}

function overlapsProtected(from: number, to: number, ranges: SimpleRange[]): boolean {
  return ranges.some((range) => from < range.to && to > range.from)
}

function containsProtectedPosition(position: number, ranges: SimpleRange[]): boolean {
  return ranges.some((range) => position >= range.from && position < range.to)
}

function isTaskCheckboxReference(state: EditorState, from: number, to: number): boolean {
  const line = state.doc.lineAt(from)
  const list = /^(\s*)([-+*]|\d+\.)[ \t]+(\[[ xX]\][ \t]+)?/.exec(line.text)
  if (!list || !list[3]) {
    return false
  }
  const checkboxStart = line.from + list[0].indexOf('[')
  return from === checkboxStart && to === checkboxStart + 3
}

/** Resolve a Markdown image destination to a safe, vault-relative path. */
export function resolveSimpleModeImagePath(noteDir: string, markdownUrl: string): string {
  let source = markdownUrl.trim()
  if (source.startsWith('<') && source.endsWith('>')) {
    source = source.substring(1, source.length - 1)
  }
  source = source.replace(/\\(.)/g, '$1')
  try {
    source = decodeURIComponent(source)
  } catch {
    // Keep malformed percent escapes intact; the vault read will report it missing.
  }
  if (source.length === 0 || source.indexOf('\0') >= 0 || source.startsWith('/') ||
    source.startsWith('\\\\') || source.startsWith('//') || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(source)) {
    return ''
  }

  const segments: string[] = []
  const combined = noteDir.length > 0 ? noteDir + '/' + source : source
  const parts = combined.split('/')
  for (let index = 0; index < parts.length; index++) {
    const segment = parts[index]
    if (segment.length === 0 || segment === '.') {
      continue
    }
    if (segment === '..') {
      if (segments.length === 0) {
        return ''
      }
      segments.pop()
      continue
    }
    segments.push(segment)
  }
  return segments.join('/')
}

function imageAltText(source: string, from: number, to: number): string {
  if (source.slice(from, from + 2) !== '![') {
    return '图片'
  }
  let depth = 0
  let escaped = false
  for (let index = from + 2; index < to; index++) {
    const character = source[index]
    if (escaped) {
      escaped = false
      continue
    }
    if (character === '\\') {
      escaped = true
    } else if (character === '[') {
      depth++
    } else if (character === ']') {
      if (depth === 0) {
        const alt = source.slice(from + 2, index).replace(/\\(.)/g, '$1')
        return alt.length > 0 ? alt : '图片'
      }
      depth--
    }
  }
  return '图片'
}

export function collectSimpleModeRanges(state: EditorState): SimpleModeRanges {
  const source = state.doc.toString()
  const protectedRanges: SimpleRange[] = []
  const hintRanges: SimpleRange[] = []
  const imageRanges: SimpleRange[] = []
  const opaqueSyntaxRanges: SimpleRange[] = []
  const customRanges = customProtectedRanges(source)
  const frontmatter = frontmatterRange(source)
  if (frontmatter) {
    protectedRanges.push(frontmatter)
    hintRanges.push(frontmatter)
    opaqueSyntaxRanges.push(frontmatter)
  }
  const tree = ensureSyntaxTree(state, state.doc.length, 100)
  if (!tree) {
    const protectedRange: SimpleRange = { from: 0, to: source.length, kind: 'protected' }
    return {
      protected: source.length > 0 ? [protectedRange] : [],
      decorations: source.length > 0
        ? [{ from: 0, to: 0, kind: 'protected-hint', value: '正在安全解析，请稍后继续编辑' }]
        : []
    }
  }
  tree.iterate({
    enter(node) {
      if (node.name === 'FencedCode' || node.name === 'InlineCode' || node.name === 'Link' ||
        node.name === 'Image' || node.name === 'LinkReference' || node.name === 'Table' ||
        node.name === 'HTMLBlock' || node.name === 'HTMLTag') {
        if (node.name === 'Link' && isTaskCheckboxReference(state, node.from, node.to)) {
          return
        }
        const range: SimpleRange = { from: node.from, to: node.to, kind: 'protected' }
        protectedRanges.push(range)
        opaqueSyntaxRanges.push(range)
        if (node.name === 'Image') {
          let imageNode = tree.resolve(node.from + 1, 1)
          while (imageNode.name !== 'Image' && imageNode.parent !== null) {
            imageNode = imageNode.parent
          }
          const destination = imageNode.name === 'Image' ? imageNode.getChild('URL') : null
          if (destination) {
            imageRanges.push({ from: node.from, to: node.to, kind: 'image',
              value: state.sliceDoc(destination.from, destination.to), alt: imageAltText(source, node.from, node.to) })
          } else {
            hintRanges.push(range)
          }
        } else if (node.name === 'Table') {
          hintRanges.push({ from: range.from, to: range.to, kind: range.kind, value: PROTECTED_HINT_TABLE })
        } else {
          hintRanges.push(range)
        }
      }
    }
  })
  const applicableCustomRanges = customRanges.filter((range) => {
    return !opaqueSyntaxRanges.some((opaque) => range.from >= opaque.from && range.from < opaque.to &&
      (range.to <= opaque.to || range.from > opaque.from))
  })
  protectedRanges.push(...applicableCustomRanges)
  hintRanges.push(...applicableCustomRanges)
  const mergedProtected = mergeProtected(protectedRanges)
  const decorations: SimpleRange[] = []
  tree.iterate({
    enter(node) {
      if (node.name === 'ATXHeading1' || node.name === 'ATXHeading2' || node.name === 'ATXHeading3' ||
        node.name === 'ATXHeading4' || node.name === 'ATXHeading5' || node.name === 'ATXHeading6') {
        decorations.push({ from: state.doc.lineAt(node.from).from, to: state.doc.lineAt(node.from).from, kind: 'heading-' + node.name.slice(-1) })
      } else if (node.name === 'SetextHeading1' || node.name === 'SetextHeading2') {
        decorations.push({ from: state.doc.lineAt(node.from).from, to: state.doc.lineAt(node.from).from,
          kind: node.name === 'SetextHeading1' ? 'heading-1' : 'heading-2' })
      } else if (node.name === 'StrongEmphasis') {
        decorations.push({ from: node.from, to: node.to, kind: 'strong' })
      } else if (node.name === 'Emphasis') {
        decorations.push({ from: node.from, to: node.to, kind: 'emphasis' })
      } else if (node.name === 'HeaderMark' || node.name === 'EmphasisMark') {
        if (!overlapsProtected(node.from, node.to, mergedProtected)) {
          decorations.push({ from: node.from, to: node.to, kind: 'hide' })
        }
      } else if (node.name === 'QuoteMark') {
        const start = state.doc.lineAt(node.from).from
        decorations.push({ from: start, to: start, kind: 'quote' })
        if (!overlapsProtected(node.from, node.to, mergedProtected)) {
          const afterMarker = state.sliceDoc(node.to, Math.min(node.to + 1, state.doc.length))
          decorations.push({ from: node.from, to: node.to + (afterMarker === ' ' ? 1 : 0), kind: 'hide' })
        }
      }
    }
  })

  let lastContentLine = state.doc.lines
  while (lastContentLine > 0 && state.doc.line(lastContentLine).text.trim().length === 0) {
    lastContentLine--
  }

  for (let number = 1; number <= state.doc.lines; number++) {
    const line = state.doc.line(number)
    const list = /^(\s*)([-+*]|\d+\.)[ \t]+(\[[ xX]\][ \t]+)?/.exec(line.text)
    if (list) {
      const markerStart = line.from + list[1].length
      const markerEnd = line.from + list[0].length
      if (!overlapsProtected(markerStart, markerEnd, mergedProtected)) {
        const checkbox = list[3]
        decorations.push({ from: markerStart, to: markerEnd, kind: checkbox ? 'task' : 'list-marker',
          value: checkbox ? (checkbox.includes('x') || checkbox.includes('X') ? '☑' : '☐') :
            (/^\d/.test(list[2]) ? list[2] : '•') })
      }
    } else if (line.text.trim().length === 0 && number < lastContentLine &&
      !containsProtectedPosition(line.from, mergedProtected)) {
      // 段距：编辑器没有段落元素，间隔落在源码空行上（样式见 build.mjs 的 .cm-simple-blank）。
      // 受保护块（表格 / 代码块 / 公式…）内的空行不动，避免影响块内对齐与行号。
      decorations.push({ from: line.from, to: line.from, kind: 'blank' })
    }
  }
  decorations.push(...imageRanges)
  for (const range of mergeHints(hintRanges)) {
    decorations.push({ from: range.from, to: range.from, kind: 'protected-hint',
      value: range.value ?? PROTECTED_HINT_DEFAULT })
  }
  return { protected: mergedProtected, decorations }
}

export function allowsSimpleModeTransaction(state: EditorState, transaction: Transaction,
  protectedRanges: SimpleRange[] = collectSimpleModeRanges(state).protected): boolean {
  let allowed = true
  transaction.changes.iterChangedRanges((from, to) => {
    for (const range of protectedRanges) {
      const touches = from === to ? from > range.from && from < range.to : from < range.to && to > range.from
      if (touches) {
        allowed = false
        break
      }
    }
  })
  return allowed
}
