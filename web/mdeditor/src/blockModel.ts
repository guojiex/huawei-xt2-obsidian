import { Annotation, EditorState, Transaction } from '@codemirror/state'
// 仅类型导入：Node 的类型剥离不解析 .d.ts，值位置导入类型名会在运行时抛
// "does not provide an export named"（esbuild 则能剥离，故仅测试链暴露）。
import type { BlockRange, BlockType } from './blockRegistry.ts'

/**
 * 块模型与回写（v1.18 18.2 / 18.3）。
 *
 * 每类块提供一对纯函数，这是「不破坏源码」的关键：
 *   parse(source, range) → Model | null    解析失败返回 null → 该块降级只读 + 明确说明
 *   stringify(model)     → string          只产出该块的源码片段
 *
 * 本版**只落接口与回写校验，不注册任何具体块**（表格 v1.14 / 代码 v1.19 /
 * 链接图片 v1.20 / 公式等 v1.21 各自注册自己的 codec）。所以现在所有块的
 * `parse` 都返回 null —— 全部分类只能走「以源码编辑此块」（18.7）。
 */

export interface BlockCodec<M = unknown> {
  type: BlockType

  parse(source: string, range: BlockRange): M | null

  stringify(model: M): string

  /** 结构操作（v1.14 起由各块实现）：改模型，不动源码区间外的任何字符。 */
  apply?(model: M, op: BlockOp): M | null
}

const codecs = new Map<BlockType, BlockCodec<any>>()

export function registerBlockCodec<M>(codec: BlockCodec<M>): void {
  codecs.set(codec.type, codec as BlockCodec<any>)
}

export function codecFor(type: BlockType): BlockCodec<any> | null {
  return codecs.get(type) ?? null
}

/** 解析失败（无 codec / 区间非法 / codec 返回 null）统一返回 null —— 调用方降级只读。 */
export function parseBlock<M = unknown>(source: string, range: BlockRange): M | null {
  if (!isRangeInside(source, range)) {
    return null
  }
  const codec = codecFor(range.type)
  if (!codec) {
    return null
  }
  return codec.parse(source, range) as M | null
}

export function stringifyBlock(type: BlockType, model: unknown): string | null {
  const codec = codecFor(type)
  return codec ? codec.stringify(model) : null
}

function isRangeInside(source: string, range: BlockRange): boolean {
  return Number.isInteger(range.from) && Number.isInteger(range.to) &&
    range.from >= 0 && range.to <= source.length && range.to >= range.from
}

export interface BlockSelection {
  from: number
  to: number
}

export interface BlockChange {
  from: number
  to: number
  insert: string
}

export interface BlockEditResult {
  changes: BlockChange
  selection: BlockSelection
}

export const blockSourceEditRange = Annotation.define<BlockSelection>()

/** Convert a preview source interval into the normalized CodeMirror document coordinates. */
export function prepareBlockSourceEdit(state: EditorState, from: number, to: number,
  expectedSource: string, replacement: string, lineEnding: '\n' | '\r\n'): BlockEditResult | null {
  const source = lineEnding === '\r\n' ? state.doc.toString().replace(/\n/g, '\r\n') : state.doc.toString()
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from || to > source.length ||
    (source[from - 1] === '\r' && source[from] === '\n') ||
    (source[to - 1] === '\r' && source[to] === '\n') ||
    source.slice(from, to) !== expectedSource) {
    return null
  }
  const docFrom = source.slice(0, from).replace(/\r\n/g, '\n').length
  const docTo = source.slice(0, to).replace(/\r\n/g, '\n').length
  return applyBlockEdit(state, {
    from: docFrom,
    to: docTo,
    type: 'mixed',
    id: 'source-drawer'
  }, {
    type: 'replaceSource',
    text: replacement.replace(/\r\n/g, '\n')
  })
}

/** The exception for a source-drawer edit permits exactly one replacement of its declared interval. */
export function isBlockSourceEditTransaction(transaction: Transaction): boolean {
  const range = transaction.annotation(blockSourceEditRange)
  if (!range || !transaction.docChanged) {
    return false
  }
  let count = 0
  let exactRange = true
  transaction.changes.iterChangedRanges((from: number, to: number): void => {
    count++
    if (from !== range.from || to !== range.to) {
      exactRange = false
    }
  })
  return count === 1 && exactRange
}

/**
 * 块操作。本版只内置 `replaceSource`（18.7 源码抽屉用它整块替换）；
 * 结构操作（如表格加列）由各块的 codec.apply 提供，未注册即返回 null = 拒绝。
 */
export type BlockOp =
  | { type: 'replaceSource'; text: string; selection?: BlockSelection }
    | { type: string; payload?: unknown; selection?: BlockSelection }

function selectionInside(selection: BlockSelection, from: number, to: number): boolean {
  return selection.from >= from && selection.to <= to && selection.from <= selection.to
}

/**
 * 只产出落在 `range` 内的 changes；越界或该块不支持该操作返回 null（拒绝，不静默改）。
 * 返回值的 selection 保证落在替换后的块区间内，避免回写后光标丢失。
 */
export function applyBlockEdit(state: EditorState, range: BlockRange, op: BlockOp): BlockEditResult | null {
  const source = state.doc.toString()
  if (!isRangeInside(source, range)) {
    return null
  }
  if (op.type === 'replaceSource') {
    const text = op.text
    const end = range.from + text.length
    const selection: BlockSelection = op.selection ?? { from: end, to: end }
    if (!selectionInside(selection, range.from, end)) {
      return null
    }
    return { changes: { from: range.from, to: range.to, insert: text }, selection: selection }
  }
  const codec = codecFor(range.type)
  if (!codec || typeof codec.apply !== 'function') {
    return null
  }
  const model = codec.parse(source, range)
  if (model === null) {
    return null
  }
  const next = codec.apply(model, op)
  if (next === null) {
    return null
  }
  const text = codec.stringify(next)
  const end = range.from + text.length
  const selection: BlockSelection = op.selection ?? { from: end, to: end }
  if (!selectionInside(selection, range.from, end)) {
    return null
  }
  return { changes: { from: range.from, to: range.to, insert: text }, selection: selection }
}

/** 把回写结果应用到源码字符串（供调用方与单测模拟 CodeMirror 的 changes）。 */
export function applyBlockText(source: string, result: BlockEditResult): string {
  return source.slice(0, result.changes.from) + result.changes.insert + source.slice(result.changes.to)
}

/** 回写是否只改写了目标区间：区间外前后缀必须逐字相等（安全不变式，18.8 断言用）。 */
export function blockEditKeepsOutside(before: string, after: string, range: BlockRange,
  insertLength: number): boolean {
  return after.slice(0, range.from) === before.slice(0, range.from) &&
    after.slice(range.from + insertLength) === before.slice(range.to)
}
