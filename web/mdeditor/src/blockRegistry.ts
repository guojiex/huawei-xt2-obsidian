import { EditorState } from '@codemirror/state'
import { ensureSyntaxTree } from '@codemirror/language'

/**
 * 块注册表（v1.18 18.1）。
 *
 * v1.7 的 `collectSimpleModeRanges()` 已经在做「识别 + 保护」，但它只产出字符区间，
 * 没有块身份 —— 后续每类块（表格 v1.14 / 代码 v1.19 / 链接图片 v1.20 / 公式等 v1.21）
 * 都要「识别块 → 解析 → 改结构 → 写回」，各造一遍轮子。本模块把身份补上：
 * 每类块一个来源（语法树 / 行模式），统一产出 `{ from, to, type, id }`。
 *
 * 契约：
 * - 区间沿用 simpleMode 的合并逻辑，结果**互不重叠**（重叠的多类块合并为 `mixed`）；
 * - 语法树未就绪时返回空数组 —— 整篇只读仍由 simpleMode 表达（它有自己的提示文案），
 *   注册表不给结构操作，避免「半棵语法树」下给出错误块边界；
 * - 本模块只识别，不改任何编辑行为；v1.18 不启用任何块的结构编辑。
 */

export type BlockType =
  | 'frontmatter'
    | 'table'
    | 'fenced-code'
    | 'inline-code'
    | 'link'
    | 'image'
    | 'html'
    | 'callout'
    | 'math-block'
    | 'math-inline'
    | 'wikilink'
    | 'comment'
    | 'highlight'
    | 'strikethrough'
    | 'subscript'
    | 'superscript'
    | 'footnote-ref'
    | 'footnote-def'
    | 'block-id'
    | 'directive'
    | 'mixed'

export interface BlockRange {
  from: number
  to: number
  type: BlockType
  id: string
}

/** 块属性面板与源码抽屉的标题用；未列出的类型回退到「此块」。 */
export const BLOCK_TYPE_LABELS: Record<BlockType, string> = {
  frontmatter: '属性',
  table: '表格',
  'fenced-code': '代码块',
  'inline-code': '行内代码',
  link: '链接',
  image: '图片',
  html: 'HTML',
  callout: '提示块',
  'math-block': '公式',
  'math-inline': '公式',
  wikilink: '双链',
  comment: '注释',
  highlight: '高亮',
  strikethrough: '删除线',
  subscript: '下标',
  superscript: '上标',
  'footnote-ref': '脚注',
  'footnote-def': '脚注',
  'block-id': '块 ID',
  directive: '指令块',
  mixed: '混合语法'
}

const SYNTAX_BLOCK_TYPES: Record<string, BlockType> = {
  FencedCode: 'fenced-code',
  InlineCode: 'inline-code',
  Link: 'link',
  Image: 'image',
  LinkReference: 'link',
  Table: 'table',
  HTMLBlock: 'html',
  HTMLTag: 'html'
}

function blockId(type: BlockType, from: number, to: number): string {
  return type + ':' + from + '-' + to
}

/** 排序 + 去重合并且互不重叠；重叠的不同类型块合并为 `mixed`（只能走源码抽屉）。 */
function mergeBlockRanges(ranges: BlockRange[]): BlockRange[] {
  const sorted = ranges.filter((range) => range.to > range.from)
    .sort((left, right) => left.from - right.from || left.to - right.to)
  const merged: BlockRange[] = []
  for (const range of sorted) {
    const last = merged[merged.length - 1]
    if (last && range.from < last.to) {
      // 重叠时保留「包住对方」的那个类型：callout 里的链接仍是 callout，
      // 表格里的行内代码仍是表格；只有互相交错的才退化成 mixed（只能走源码抽屉）。
      const lastContainsRange = last.from <= range.from && last.to >= range.to
      const rangeContainsLast = range.from <= last.from && range.to >= last.to
      const type: BlockType = last.type === range.type ? last.type
        : (lastContainsRange ? last.type : (rangeContainsLast ? range.type : 'mixed'))
      last.from = Math.min(last.from, range.from)
      last.to = Math.max(last.to, range.to)
      last.type = type
      last.id = blockId(type, last.from, last.to)
    } else {
      merged.push({
        from: range.from,
        to: range.to,
        type: range.type,
        id: blockId(range.type, range.from, range.to)
      })
    }
  }
  return merged
}

function frontmatterBlock(source: string): BlockRange | null {
  const match = /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(source)
  if (!match) {
    return null
  }
  return {
    from: 0,
    to: match[0].length,
    type: 'frontmatter',
    id: blockId('frontmatter', 0, match[0].length)
  }
}

function appendPatternBlocks(source: string, ranges: BlockRange[], pattern: RegExp, type: BlockType): void {
  const expression = new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g')
  let match: RegExpExecArray | null = expression.exec(source)
  while (match) {
    const from = match.index
    const to = from + match[0].length
    ranges.push({
      from: from,
      to: to,
      type: type,
      id: blockId(type, from, to)
    })
    match = expression.exec(source)
  }
}

function directiveBlocks(source: string): BlockRange[] {
  const ranges: BlockRange[] = []
  const lines = source.split(/\r?\n/)
  let offset = 0
  let blockStart = -1
  let depth = 0
  let blockEnd = -1

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const closing = /^ {0,3}:{3,}[ \t]*$/.test(line)
    const opening = /^ {0,3}:{3,}[ \t]*[A-Za-z][A-Za-z0-9_-]*(?:\b[^\n]*)?$/.test(line)
    if (opening) {
      if (depth === 0) {
        blockStart = offset
      }
      depth++
      blockEnd = offset + line.length
    } else if (closing && depth > 0) {
      depth--
      blockEnd = offset + line.length
      if (depth === 0) {
        ranges.push({
          from: blockStart,
          to: blockEnd,
          type: 'directive',
          id: blockId('directive', blockStart, blockEnd)
        })
        blockStart = -1
      }
    } else if (depth > 0) {
      blockEnd = offset + line.length
    }

    const separatorLength = offset + line.length >= source.length ? 0 :
      (source.startsWith('\r\n', offset + line.length) ? 2 : 1)
    offset += line.length + separatorLength
  }
  if (depth > 0 && blockStart >= 0) {
    const end = Math.max(blockEnd, source.length)
    ranges.push({
      from: blockStart,
      to: end,
      type: 'directive',
      id: blockId('directive', blockStart, end)
    })
  }
  return ranges
}

/**
 * 行模式块（v1.7 的 `customProtectedRanges()` 原样迁移，只补了 type）。
 * 语法树识别不了的（callout、表格、公式、指令块、双链、脚注、块 ID…）都在这里。
 */
export function customBlockRanges(source: string): BlockRange[] {
  const ranges: BlockRange[] = []
  const lines = source.split(/\r?\n/)
  let offset = 0
  let quoteStart = -1
  let quoteEnd = -1
  let callout = false
  let tableStart = -1
  let tableEnd = -1
  let formulaStart = -1
  let formulaEnd = -1

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const quoteLine = /^ {0,3}>/.test(line)
    if (quoteLine) {
      if (quoteStart < 0) {
        quoteStart = offset
        callout = /^ {0,3}>[ \t]*\[![A-Za-z]/.test(line)
      }
      quoteEnd = offset + line.length
    } else if (line.trim().length > 0 && quoteStart >= 0) {
      if (callout) {
        ranges.push({
          from: quoteStart,
          to: quoteEnd,
          type: 'callout',
          id: blockId('callout', quoteStart, quoteEnd)
        })
      }
      quoteStart = -1
      quoteEnd = -1
      callout = false
    }

    const nextLine = index + 1 < lines.length ? lines[index + 1] : ''
    const tableHeader = line.includes('|') && /^\s*\|?\s*:?-{3,}[^\n]*\|/.test(nextLine)
    if (tableHeader && tableStart < 0) {
      tableStart = offset
    }
    if (tableStart >= 0) {
      if (line.includes('|')) {
        tableEnd = offset + line.length
      } else if (line.trim().length > 0) {
        ranges.push({
          from: tableStart,
          to: tableEnd,
          type: 'table',
          id: blockId('table', tableStart, tableEnd)
        })
        tableStart = -1
        tableEnd = -1
      }
    }

    if (/^ {0,3}\\?\$\$[ \t]*$/.test(line)) {
      if (formulaStart < 0) {
        formulaStart = offset
      } else {
        formulaEnd = offset + line.length
        ranges.push({
          from: formulaStart,
          to: formulaEnd,
          type: 'math-block',
          id: blockId('math-block', formulaStart, formulaEnd)
        })
        formulaStart = -1
        formulaEnd = -1
      }
    }
    const separatorLength = offset + line.length >= source.length ? 0 :
      (source.startsWith('\r\n', offset + line.length) ? 2 : 1)
    offset += line.length + separatorLength
  }
  if (quoteStart >= 0 && callout) {
    ranges.push({
      from: quoteStart,
      to: quoteEnd,
      type: 'callout',
      id: blockId('callout', quoteStart, quoteEnd)
    })
  }
  if (tableStart >= 0) {
    ranges.push({
      from: tableStart,
      to: tableEnd,
      type: 'table',
      id: blockId('table', tableStart, tableEnd)
    })
  }
  if (formulaStart >= 0) {
    ranges.push({
      from: formulaStart,
      to: source.length,
      type: 'math-block',
      id: blockId('math-block', formulaStart, source.length)
    })
  }
  ranges.push(...directiveBlocks(source))
  appendPatternBlocks(source, ranges, /!?\[\[(?:\\.|[^\]\r\n])+?\]\]/g, 'wikilink')
  appendPatternBlocks(source, ranges, /\$\$(?!\$)(?:\\.|[^\\$\r\n])+?\$\$/g, 'math-block')
  appendPatternBlocks(source, ranges, /%%[\s\S]*?(?:%%|$)/g, 'comment')
  appendPatternBlocks(source, ranges, /==[^=\r\n]+==/g, 'highlight')
  appendPatternBlocks(source, ranges, /~~[^~\r\n]+~~/g, 'strikethrough')
  appendPatternBlocks(source, ranges, /(?<!~)~[^~\r\n]+~(?!~)/g, 'subscript')
  appendPatternBlocks(source, ranges, /\^[A-Za-z0-9][A-Za-z0-9_-]*\^/g, 'superscript')
  appendPatternBlocks(source, ranges, /\[\^[^\]\r\n]+\]/g, 'footnote-ref')
  appendPatternBlocks(source, ranges, /^\[\^[^\]\r\n]+\]:[^\r\n]*$/gm, 'footnote-def')
  appendPatternBlocks(source, ranges, /\^[A-Za-z0-9][A-Za-z0-9_-]*[ \t]*$/gm, 'block-id')
  appendPatternBlocks(source, ranges, /\$(?!\$)(?:\\.|[^\\$\n])+?\$/g, 'math-inline')
  return ranges
}

function syntaxBlockRanges(state: EditorState): BlockRange[] {
  const ranges: BlockRange[] = []
  const tree = ensureSyntaxTree(state, state.doc.length, 100)
  if (!tree) {
    return ranges
  }
  tree.iterate({
    enter(node) {
      let type = SYNTAX_BLOCK_TYPES[node.name]
      if (!type) {
        return
      }
      // 双链 / 嵌入（`[[x]]`、`![[x]]`）在语法树里是 Link / Image 节点，
      // 但 v1.20 要按双链编辑 —— 更具体的类型优先，不然会被过滤成普通链接。
      if (type === 'link' || type === 'image') {
        const text = state.sliceDoc(node.from, node.to)
        if (/^!?\[\[[\s\S]*\]\]$/.test(text)) {
          type = 'wikilink'
        } else if (/^\[\^[^\]\r\n]+\]$/.test(text)) {
          type = 'footnote-ref'
        }
      }
      ranges.push({
        from: node.from,
        to: node.to,
        type: type,
        id: blockId(type, node.from, node.to)
      })
    }
  })
  return ranges
}

/** 语法树是否就绪：未就绪时不给结构操作（simpleMode 仍按现状整篇只读并提示）。 */
export function isBlockRegistryReady(state: EditorState): boolean {
  return ensureSyntaxTree(state, state.doc.length, 100) !== null
}

/** 全篇块区间：语法树块 + 行模式块（起点落在语法树块内的行模式块被丢弃，与 v1.7 一致）。 */
export function collectBlockRanges(state: EditorState): BlockRange[] {
  if (!isBlockRegistryReady(state)) {
    return []
  }
  const source = state.doc.toString()
  const ranges: BlockRange[] = []
  const frontmatter = frontmatterBlock(source)
  if (frontmatter) {
    ranges.push(frontmatter)
  }
  const syntaxRanges = syntaxBlockRanges(state)
  const custom = customBlockRanges(source).filter((range) => {
    return !syntaxRanges.some((syntax) => range.from >= syntax.from && range.from < syntax.to &&
      (range.to <= syntax.to || range.from > syntax.from))
  })
  ranges.push(...syntaxRanges, ...custom)
  return mergeBlockRanges(ranges)
}

/** 光标或选区命中的块；`pos` 落在块内（含两端）即命中，重叠已由合并不存在。 */
export function findBlockAt(ranges: BlockRange[], pos: number): BlockRange | null {
  for (const range of ranges) {
    if (pos >= range.from && pos <= range.to) {
      return range
    }
  }
  return null
}

/** 当前选区命中的块：主选区任意一端在块内即算命中，优先返回 from 更小的块。 */
export function findBlockInSelection(ranges: BlockRange[], from: number, to: number): BlockRange | null {
  const direct = findBlockAt(ranges, from) ?? findBlockAt(ranges, to)
  if (direct) {
    return direct
  }
  for (const range of ranges) {
    if (from < range.to && to > range.from) {
      return range
    }
  }
  return null
}
