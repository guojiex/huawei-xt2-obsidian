import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  stdin: {
    contents: `
      import { EditorState } from '@codemirror/state'
      import { markdown } from '@codemirror/lang-markdown'
      import { collectBlockRanges, customBlockRanges, findBlockAt, findBlockInSelection,
        isBlockRegistryReady, BLOCK_TYPE_LABELS } from '../src/blockRegistry.ts'
      import { applyBlockEdit, applyBlockText, blockEditKeepsOutside, parseBlock, stringifyBlock,
        registerBlockCodec, codecFor } from '../src/blockModel.ts'
      import { collectSimpleModeRanges } from '../src/simpleMode.ts'

      function state(source) {
        return EditorState.create({ doc: source, extensions: [markdown()] })
      }
      export function blocks(source) {
        return collectBlockRanges(state(source))
      }
      export function customBlocks(source) {
        return customBlockRanges(source)
      }
      export function ready(source) {
        return isBlockRegistryReady(state(source))
      }
      export function unready(source) {
        const editor = EditorState.create({ doc: source })
        const simple = collectSimpleModeRanges(editor)
        return {
          ready: isBlockRegistryReady(editor),
          blocks: collectBlockRanges(editor),
          protected: simple.protected.map((range) => [range.from, range.to]),
          hints: simple.decorations.filter((range) => range.kind === 'protected-hint').map((range) => range.value)
        }
      }
      export function labels() {
        return BLOCK_TYPE_LABELS
      }
      export function find(pos, source) {
        return findBlockAt(collectBlockRanges(state(source)), pos)
      }
      export function findSelection(from, to, source) {
        return findBlockInSelection(collectBlockRanges(state(source)), from, to)
      }
      export function protectedRanges(source) {
        return collectSimpleModeRanges(state(source)).protected.map((range) => [range.from, range.to])
      }
      export function decorationKinds(source) {
        return collectSimpleModeRanges(state(source)).decorations
          .map((range) => ({ kind: range.kind, from: range.from }))
      }
      export function parseFirst(type, source) {
        const range = collectBlockRanges(state(source)).find((item) => item.type === type)
        return range ? parseBlock(source, range) : 'no-block'
      }
      export function editFirst(type, source, op) {
        const editor = state(source)
        const range = collectBlockRanges(editor).find((item) => item.type === type)
        if (!range) return null
        const applied = applyBlockEdit(editor, range, op)
        if (!applied) return null
        const after = applyBlockText(source, applied)
        return {
          result: applied,
          after: after,
          outsideIntact: blockEditKeepsOutside(source, after, range, applied.changes.insert.length)
        }
      }
      export function editRange(source, range, op) {
        return applyBlockEdit(state(source), range, op)
      }
      export function editWithCodec(source, op) {
        registerBlockCodec({
          type: 'comment',
          parse(text, range) {
            const body = text.slice(range.from, range.to)
            return body.startsWith('%%') ? { body: body } : null
          },
          stringify(model) {
            return model.body
          },
          apply(model, operation) {
            return operation.type === 'upper' ? { body: model.body.toUpperCase() } : null
          }
        })
        const editor = state(source)
        const range = collectBlockRanges(editor).find((item) => item.type === 'comment')
        if (!range) return null
        const applied = applyBlockEdit(editor, range, op)
        return applied ? { applied: applied, after: applyBlockText(source, applied) } : null
      }
      export function codecForType(type) {
        return codecFor(type) === null ? null : true
      }
      export function stringifyWithCodec(type, model) {
        return stringifyBlock(type, model)
      }
    `,
    resolveDir: here,
    sourcefile: 'block_base_harness.ts',
    loader: 'ts'
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const base = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`)

function assertNonOverlapping(ranges) {
  for (let index = 1; index < ranges.length; index++) {
    assert.ok(ranges[index].from >= ranges[index - 1].to,
      `blocks overlap: ${JSON.stringify(ranges[index - 1])} / ${JSON.stringify(ranges[index])}`)
  }
}

test('18.1 注册表给每类块带上身份，且区间互不重叠', () => {
  const source = [
    '---',
    'title: 演示',
    '---',
    '',
    '正文段落。',
    '',
    '| 列 A | 列 B |',
    '| --- | --- |',
    '| 1 | 2 |',
    '',
    '```ts',
    'const a = 1',
    '```',
    '',
    '> [!note] 提示',
    '> 内容',
    '',
    '$$',
    'x^2',
    '$$',
    '',
    ':::tip',
    '指令内容',
    ':::',
    ''
  ].join('\n')
  const ranges = base.blocks(source)
  const types = ranges.map((range) => range.type)
  for (const expected of ['frontmatter', 'table', 'fenced-code', 'callout', 'math-block', 'directive']) {
    assert.ok(types.includes(expected), `expected block type ${expected}, got ${types.join(',')}`)
  }
  assertNonOverlapping(ranges)
  for (const range of ranges) {
    assert.ok(range.id.includes(range.type), `id should carry the block type: ${range.id}`)
    assert.ok(range.to > range.from)
  }
})

test('18.1 行内块与双链也有身份，行模式与语法树结果不重复计数', () => {
  const source = '正文 `code` 与 [[双链]] 和 $x^2$ 以及 ==高亮== 与 ~~删除~~ 脚注[^1] 块ID ^abc123\n'
  const types = base.blocks(source).map((range) => range.type)
  for (const expected of ['inline-code', 'wikilink', 'math-inline', 'highlight', 'strikethrough']) {
    assert.ok(types.includes(expected), `expected ${expected}, got ${types.join(',')}`)
  }
  assert.ok(types.includes('footnote-ref'))
  assert.ok(types.includes('block-id'))
})

test('18.1 与 v1.7 的保护范围同源：注册表区间覆盖与 simpleMode 受保护区间一致', () => {
  const sources = [
    '正文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n',
    '> [!warning] 注意\n> 内容\n\n正文\n',
    '```\ncode\n```\n',
    ':::note\n内容\n:::\n',
    '正文 [[链接]] 与 $a$ 与 %%注释%%\n'
  ]
  for (const source of sources) {
    const protectedRanges = base.protectedRanges(source)
    const blocks = base.blocks(source)
    assert.ok(blocks.length > 0, `no block recognised: ${source}`)
    for (const range of blocks) {
      const covered = protectedRanges.some((item) => item[0] <= range.from && item[1] >= range.to)
      assert.ok(covered, `block ${range.type} [${range.from},${range.to}] not protected in ${JSON.stringify(source)}`)
    }
  }
})

test('18.1 光标与选区能命中块，落在块外返回 null', () => {
  const source = '正文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n结尾\n'
  const table = base.blocks(source).find((range) => range.type === 'table')
  assert.ok(table)
  assert.equal(base.find(table.from, source).type, 'table')
  assert.equal(base.find(table.from + 3, source).id, table.id)
  assert.equal(base.find(table.to, source).id, table.id)
  assert.equal(base.find(table.to + 1, source), null)
  assert.equal(base.findSelection(table.from + 1, table.to - 1, source).id, table.id)
})

test('18.1 语法树未就绪时注册表不给块，simpleMode 整篇只读并提示', () => {
  const source = '| a | b |\n| --- | --- |\n| 1 | 2 |\n'
  const result = base.unready(source)
  assert.equal(result.ready, false)
  assert.deepEqual(result.blocks, [])
  assert.deepEqual(result.protected, [[0, source.length]])
  assert.deepEqual(result.hints, ['正在安全解析，请稍后继续编辑'])
})

test('18.2 没有注册的块 parse 返回 null（降级只读，不静默转换）', () => {
  const source = '| a | b |\n| --- | --- |\n| 1 | 2 |\n'
  assert.equal(base.parseFirst('table', source), null)
  assert.equal(base.codecForType('table'), null)
})

test('18.2 / 18.3 注册的 codec 走 parse → apply → stringify，且只改写本块', () => {
  const source = '前缀 %%hello%% 后缀\n'
  const edited = base.editWithCodec(source, { type: 'upper' })
  assert.ok(edited, 'codec op should be applied')
  assert.equal(edited.after, '前缀 %%HELLO%% 后缀\n')
  assert.ok(edited.applied.changes.from >= source.indexOf('%%'))
  assert.ok(edited.applied.changes.to <= source.indexOf('%%') + 9)
  assert.equal(base.stringifyWithCodec('comment', { body: '%%x%%' }), '%%x%%')
  assert.equal(base.editWithCodec(source, { type: 'unknown' }), null)
})

test('18.3 整块源码替换只改目标区间，区间外逐字不变', () => {
  const source = '前缀\n\n```ts\nconst a = 1\n```\n\n后缀\n'
  const edited = base.editFirst('fenced-code', source, { type: 'replaceSource', text: '```js\nlet b = 2\n```' })
  assert.ok(edited)
  assert.equal(edited.after, '前缀\n\n```js\nlet b = 2\n```\n\n后缀\n')
  assert.equal(edited.outsideIntact, true)
  assert.deepEqual(edited.result.selection, { from: edited.result.changes.from + edited.result.changes.insert.length,
    to: edited.result.changes.from + edited.result.changes.insert.length })
})

test('18.3 指定选区时落在块内，越界即拒绝', () => {
  const source = '前缀\n\n```ts\nconst a = 1\n```\n\n后缀\n'
  const inside = base.editFirst('fenced-code', source,
    { type: 'replaceSource', text: '```ts\nx\n```', selection: { from: 6, to: 6 } })
  assert.ok(inside)
  assert.deepEqual(inside.result.selection, { from: 6, to: 6 })
  assert.equal(base.editFirst('fenced-code', source,
    { type: 'replaceSource', text: '```ts\nx\n```', selection: { from: 0, to: 999 } }), null)
})

test('18.3 区间越界或不支持的操作一律拒绝，返回 null', () => {
  const source = '正文\n'
  assert.equal(base.editRange(source, { from: 0, to: 9999, type: 'table', id: 'x' },
    { type: 'replaceSource', text: 'y' }), null)
  assert.equal(base.editRange(source, { from: -1, to: 2, type: 'table', id: 'x' },
    { type: 'replaceSource', text: 'y' }), null)
  assert.equal(base.editRange(source, { from: 2, to: 1, type: 'table', id: 'x' },
    { type: 'replaceSource', text: 'y' }), null)
  assert.equal(base.editRange('正文\n', { from: 0, to: 2, type: 'table', id: 'x' },
    { type: 'insertColumn', payload: { side: 'right' } }), null)
})

test('18.3 CRLF 与 BOM 下区间与回写仍逐字对齐', () => {
  const source = '\uFEFF---\r\ntitle: 演示\r\n---\r\n\r\n正文\r\n'
  const ranges = base.blocks(source)
  const frontmatter = ranges.find((range) => range.type === 'frontmatter')
  assert.ok(frontmatter)
  assert.equal(frontmatter.from, 0)
  assert.equal(source.slice(frontmatter.from, frontmatter.to).includes('title: 演示'), true)
  const edited = base.editRange(source, frontmatter,
    { type: 'replaceSource', text: '---\r\ntitle: 演示\r\ntags: [a]\r\n---\r\n' })
  assert.ok(edited)
  assert.equal(base.editRange(source, frontmatter, { type: 'replaceSource', text: '' }).changes.to, frontmatter.to)
})

test('段距：普通段落之间的空行给到 blank 装饰，受保护块内的空行不动', () => {
  // 文件末尾没有后续段落，不应把尾随空行当作段距。
  const source = '第一段\n\n第二段'
  const blanks = base.decorationKinds(source).filter((item) => item.kind === 'blank')
  assert.equal(blanks.length, 1)
  assert.equal(blanks[0].from, '第一段\n'.length)

  const trailingBlanks = base.decorationKinds('第一段\n\n').filter((item) => item.kind === 'blank')
  assert.equal(trailingBlanks.length, 0)

  const code = '```\n\n```\n'
  assert.equal(base.decorationKinds(code).filter((item) => item.kind === 'blank').length, 0)

  const table = '| a |\n| --- |\n| 1 |\n\n正文'
  const tableBlanks = base.decorationKinds(table).filter((item) => item.kind === 'blank')
  assert.equal(tableBlanks.length, 1)
  assert.equal(tableBlanks[0].from, table.indexOf('\n\n') + 1)
})

test('块类型名有中文标签，面板与源码抽屉标题不用硬编码', () => {
  const labels = base.labels()
  assert.equal(labels.table, '表格')
  assert.equal(labels['fenced-code'], '代码块')
  assert.equal(labels.link, '链接')
  assert.equal(labels.image, '图片')
  assert.equal(labels.frontmatter, '属性')
  assert.equal(labels.mixed, '混合语法')
})
