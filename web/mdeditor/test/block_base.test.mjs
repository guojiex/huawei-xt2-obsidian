import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { prepareCodeBodyEdit, prepareCodeLanguageEdit, prepareInlineCodeUnwrap } from '../../mdpreview/src/codeBlock.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  stdin: {
    contents: `
      import { EditorState } from '@codemirror/state'
      import { markdown } from '@codemirror/lang-markdown'
      import { history, redo, undo } from '@codemirror/commands'
      import { blockSourceEditRange, isBlockSourceEditTransaction, prepareBlockSourceEdit,
        applyBlockEdit, applyBlockText, blockEditKeepsOutside, parseBlock, stringifyBlock,
        registerBlockCodec, codecFor } from '../src/blockModel.ts'
      import { collectBlockRanges, customBlockRanges, findBlockAt, findBlockInSelection,
        isBlockRegistryReady, BLOCK_TYPE_LABELS } from '../src/blockRegistry.ts'
      import { collectSimpleModeRanges } from '../src/simpleMode.ts'

      function state(source) {
        return EditorState.create({ doc: source, extensions: [markdown()] })
      }
      function sourceEditState(source) {
        return EditorState.create({
          doc: source,
          extensions: [
            markdown(),
            history(),
            EditorState.changeFilter.of((transaction) => transaction.annotation(blockSourceEditRange)
              ? isBlockSourceEditTransaction(transaction) : true)
          ]
        })
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
      export function prepareSourceEdit(source, from, to, expected, replacement, lineEnding = '\\n') {
        return prepareBlockSourceEdit(state(source), from, to, expected, replacement, lineEnding)
      }
      export function replaceSourceWithHistory(source, from, to, expected, replacement, lineEnding = '\\n') {
        let editor = sourceEditState(source)
        const edit = prepareBlockSourceEdit(editor, from, to, expected, replacement, lineEnding)
        if (!edit) return null
        editor = editor.update({
          changes: edit.changes,
          selection: { anchor: edit.selection.from, head: edit.selection.to },
          annotations: [blockSourceEditRange.of({ from: edit.changes.from, to: edit.changes.to })],
          userEvent: 'input'
        }).state
        const serialize = (current) => lineEnding === '\\r\\n'
          ? current.doc.toString().replace(/\\n/g, '\\r\\n') : current.doc.toString()
        const after = serialize(editor)
        const outsideIntact = source.slice(0, from) + replacement + source.slice(to) === after
        const edited = after
        const undoApplied = undo({ state: editor, dispatch: (transaction) => { editor = editor.update(transaction).state } })
        const undone = serialize(editor)
        const redoApplied = redo({ state: editor, dispatch: (transaction) => { editor = editor.update(transaction).state } })
        return { after, outsideIntact, edited, undoApplied, undone, redoApplied, redone: serialize(editor) }
      }
      export function applyInputPatchesWithHistory(source, inputs) {
        let editor = sourceEditState(source)
        let currentSource = source
        for (const patch of inputs) {
          const edit = prepareBlockSourceEdit(editor, patch.from, patch.to,
            patch.expected, patch.replacement, '\\n')
          if (!edit) return null
          editor = editor.update({
            changes: edit.changes,
            selection: { anchor: edit.selection.from, head: edit.selection.to },
            annotations: [blockSourceEditRange.of({ from: edit.changes.from, to: edit.changes.to })],
            userEvent: 'input.type'
          }).state
          currentSource = editor.doc.toString()
        }
        const after = currentSource
        const undoApplied = undo({ state: editor, dispatch: (transaction) => { editor = editor.update(transaction).state } })
        const undone = editor.doc.toString()
        const redoApplied = redo({ state: editor, dispatch: (transaction) => { editor = editor.update(transaction).state } })
        return { after, undoApplied, undone, redoApplied, redone: editor.doc.toString() }
      }
      export function applyPatchesAndUndo(source, patches, undoCount) {
        let editor = sourceEditState(source)
        for (const patch of patches) {
          const edit = prepareBlockSourceEdit(editor, patch.from, patch.to,
            patch.expected, patch.replacement, '\\n')
          if (!edit) return null
          editor = editor.update({
            changes: edit.changes,
            selection: { anchor: edit.selection.from, head: edit.selection.to },
            annotations: [blockSourceEditRange.of({ from: edit.changes.from, to: edit.changes.to })],
            userEvent: patch.userEvent
          }).state
        }
        const after = editor.doc.toString()
        const undoSources = []
        for (let index = 0; index < undoCount; index++) {
          let applied = false
          undo({ state: editor, dispatch: (transaction) => {
            editor = editor.update(transaction).state
            applied = true
          } })
          undoSources.push({ applied, source: editor.doc.toString() })
        }
        return { after, undoSources }
      }
      export function rejectsMismatchedSourceEdit(source, from, to, replacement, declaredRange) {
        const editor = sourceEditState(source)
        return editor.update({
          changes: [
            { from, to, insert: replacement },
            { from: editor.doc.length, to: editor.doc.length, insert: 'outside' }
          ],
          annotations: [blockSourceEditRange.of(declaredRange)]
        }).state.doc.toString() === editor.doc.toString()
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

test('18.7 源码抽屉只替换目标区间，撤销与重做各一步', () => {
  const source = '前缀\n\n```ts\nconst a = 1\n```\n\n后缀'
  const from = source.indexOf('```ts')
  const to = source.indexOf('\n\n后缀')
  const expected = source.slice(from, to)
  const replacement = '```js\nlet b = 2\n```'
  const result = base.replaceSourceWithHistory(source, from, to, expected, replacement)
  assert.ok(result)
  assert.equal(result.after, '前缀\n\n```js\nlet b = 2\n```\n\n后缀')
  assert.equal(result.outsideIntact, true)
  assert.equal(result.undoApplied, true)
  assert.equal(result.undone, source)
  assert.equal(result.redoApplied, true)
  assert.equal(result.redone, result.after)
})

test('18.7 CRLF 源码区间精确映射到 CodeMirror，并保留区间外字节', () => {
  const source = '前缀\r\n\r\n| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\n后缀\r\n'
  const from = source.indexOf('| a | b |')
  const to = source.indexOf('\r\n\r\n后缀')
  const expected = source.slice(from, to)
  const replacement = '| a | b |\r\n| --- | --- |\r\n| 3 | 4 |'
  const result = base.replaceSourceWithHistory(source, from, to, expected, replacement, '\r\n')
  assert.ok(result)
  assert.equal(result.after, '前缀\r\n\r\n| a | b |\r\n| --- | --- |\r\n| 3 | 4 |\r\n\r\n后缀\r\n')
  assert.equal(result.outsideIntact, true)
  assert.equal(result.undone, source)
  assert.equal(result.redone, result.after)
})

test('19.1 空代码块首输可零长度回写，连续输入一次撤销还原原文', () => {
  const source = '```js\n```\nafter'
  const from = '```js\n'.length
  const result = base.applyInputPatchesWithHistory(source, [
    { from, to: from, expected: '', replacement: 'a\n' },
    { from: from + 1, to: from + 1, expected: '', replacement: 'b' }
  ])

  assert.deepEqual(result, {
    after: '```js\nab\n```\nafter',
    undoApplied: true,
    undone: source,
    redoApplied: true,
    redone: '```js\nab\n```\nafter'
  })
})

test('19.6 语言切换和连续块内输入分别形成撤销步', () => {
  const source = '```javascript\nx\n```\n'
  const bodyEdit = prepareCodeBodyEdit(source, 0, source.lastIndexOf('\n'), 'typed')
  assert.ok(bodyEdit)
  const afterTyping = source.slice(0, bodyEdit.from) + bodyEdit.replacement + source.slice(bodyEdit.to)
  const languageEdit = prepareCodeLanguageEdit(afterTyping, 0, afterTyping.lastIndexOf('\n'), 'python')
  assert.ok(languageEdit)

  const result = base.applyPatchesAndUndo(source, [
    { ...bodyEdit, userEvent: 'input.type' },
    { ...languageEdit, userEvent: 'input' }
  ], 2)

  assert.deepEqual(result, {
    after: '```python\ntyped\n```\n',
    undoSources: [
      { applied: true, source: '```javascript\ntyped\n```\n' },
      { applied: true, source }
    ]
  })
})

test('20.5 链接、双链与图片属性的每次提交各占一个撤销步', () => {
  const source = '前 [旧文字](https://old.test) / [[old.md|旧别名]] / ![旧图|240](attachments/old.png) 后'
  let current = source
  const patches = []
  const checkpoints = []
  const replace = (expected, replacement) => {
    const from = current.indexOf(expected)
    assert.notEqual(from, -1, `missing source range: ${expected}`)
    const to = from + expected.length
    patches.push({ from, to, expected, replacement, userEvent: 'input' })
    current = current.slice(0, from) + replacement + current.slice(to)
    checkpoints.push(current)
  }

  replace('[旧文字](https://old.test)', '[新文字](https://old.test)')
  replace('[新文字](https://old.test)', '[新文字](https://new.test)')
  replace('[[old.md|旧别名]]', '[[new.md|旧别名]]')
  replace('[[new.md|旧别名]]', '[[new.md|新别名]]')
  replace('![旧图|240](attachments/old.png)', '![新图|240](attachments/old.png)')
  replace('![新图|240](attachments/old.png)', '![新图|480](attachments/old.png)')
  replace('![新图|480](attachments/old.png)', '![新图|480](attachments/new.png)')

  const result = base.applyPatchesAndUndo(source, patches, patches.length)

  assert.equal(result.after, current)
  assert.deepEqual(result.undoSources.map((step) => step.source),
    [...checkpoints.slice(0, -1).reverse(), source])
  assert.ok(result.undoSources.every((step) => step.applied))
})

test('19.6 转为纯文本是独立撤销步，撤销后逐字恢复反引号和内容', () => {
  const source = 'before `x` after'
  const contentFrom = source.indexOf('x')
  const afterTyping = source.slice(0, contentFrom) + 'xy' + source.slice(contentFrom + 1)
  const inlineFrom = afterTyping.indexOf('`')
  const unwrap = prepareInlineCodeUnwrap(afterTyping, inlineFrom, afterTyping.indexOf('`', inlineFrom + 1) + 1)
  assert.ok(unwrap)

  const result = base.applyPatchesAndUndo(source, [
    { from: contentFrom, to: contentFrom + 1, expected: 'x', replacement: 'xy', userEvent: 'input.type' },
    { ...unwrap, userEvent: 'input' }
  ], 2)

  assert.deepEqual(result, {
    after: 'before xy after',
    undoSources: [
      { applied: true, source: 'before `xy` after' },
      { applied: true, source }
    ]
  })
})

test('18.7 打开后目标区间变化或偏移落在 CRLF 中间时拒绝回写', () => {
  const original = '前缀\r\n```js\r\nx\r\n```\r\n后缀'
  const from = original.indexOf('```js')
  const to = original.indexOf('\r\n后缀')
  const expected = original.slice(from, to)
  const changed = original.replace('x', 'y')
  assert.equal(base.prepareSourceEdit(changed, from, to, expected, '```js\r\nz\r\n```', '\r\n'), null)
  const splitCRLF = original.indexOf('\r\n') + 1
  assert.equal(base.prepareSourceEdit(original, splitCRLF, original.length,
    original.slice(splitCRLF), 'suffix', '\r\n'), null)
})

test('18.7 注解不能授权跨越源码抽屉区间的多处改动', () => {
  const source = '```js\nx\n```'
  assert.equal(base.rejectsMismatchedSourceEdit(source, 0, 3, '~~~', { from: 0, to: 3 }), true)
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
