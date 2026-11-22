/*
 * v2.5 文件树深层级缩进封顶 —— 源级契约测试。
 *
 * 锁住的约定：文件夹层级再深，视觉缩进也停在 min(depth, --tree-depth-cap) × --tree-indent，
 * 笔记名不再被缩进挤没；原型与原生（FileTreeView.levelsOf × Size.treeDepthCap）必须同一封顶值。
 *
 * 回归背景：修复前缩进按每级 24px/vp 线性增长，原型行宽下限还随层级撑出横向滚动，
 * 深层笔记名只剩省略号（用户 2026-11-22 反馈）。
 */
import assert from 'node:assert/strict'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { readSourceFile } from './lib/source.mjs'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const prototypeHtml = readSourceFile(path.join(root, 'docs/prototype/v2/index.html'))
const tokens = readSourceFile(path.join(root, 'entry/src/main/ets/common/Tokens.ets'))
const fileTreeView = readSourceFile(path.join(root, 'entry/src/main/ets/components/FileTreeView.ets'))

function rootTokens() {
  const block = prototypeHtml.match(/:root\{[^\r\n]*\}/)?.[0]
  assert.ok(block, 'Missing :root token block')
  return Object.fromEntries([...block.matchAll(/(--[\w-]+):([^;]+);?/g)].map(([, key, value]) => [key, value.trim()]))
}

test('prototype caps tree row indent at --tree-depth-cap levels', () => {
  const vars = rootTokens()
  assert.equal(vars['--tree-depth-cap'], '4', '--tree-depth-cap must stay 4 (v2.5)')
  // 行内边距封顶：第 4 级起缩进不再增长
  assert.match(prototypeHtml,
    /\.tree-row\{[^}]*padding:var\(--s2\) var\(--s2\) var\(--s2\) calc\(var\(--s2\) \+ min\(var\(--depth\), var\(--tree-depth-cap\)\) \* var\(--tree-indent\)\)/)
  // 引导线位置同步封顶（封顶档合并为最深一条引导线）
  assert.match(prototypeHtml,
    /\.tree-children::before\{[^}]*left:calc\(var\(--s2\) \+ min\(var\(--parent-depth\), calc\(var\(--tree-depth-cap\) - 1\)\) \* var\(--tree-indent\)/)
})

test('prototype no longer grows row min-width with tree depth', () => {
  // 深层行不得再按 depth 撑 min-width 挤出横向滚动；--tree-text-min 仅保留 .pane-more-menu 一处引用
  assert.doesNotMatch(prototypeHtml, /min-width:calc\(var\(--tree-text-min\) \+ var\(--depth\)/)
  const uses = [...prototypeHtml.matchAll(/var\(--tree-text-min\)/g)]
  assert.equal(uses.length, 1, '--tree-text-min should only remain on .pane-more-menu')
  assert.match(prototypeHtml, /\.pane-more-menu\{[^}]*min-width:var\(--tree-text-min\)/)
})

test('native levelsOf caps at Size.treeDepthCap and tokens stay in sync', () => {
  assert.match(tokens, /static readonly treeDepthCap: number = 4/)
  assert.match(fileTreeView,
    /private levelsOf\(depth: number\): number\[\] \{\s*\n\s*const capped: number = Math\.min\(depth, Size\.treeDepthCap\)/,
    'levelsOf must cap depth at Size.treeDepthCap')
  // 封顶值与原型 token 同源（test_v2_token_sync 也映射该对，这里显式锁数值）
  assert.equal(rootTokens()['--tree-depth-cap'], '4')
})
