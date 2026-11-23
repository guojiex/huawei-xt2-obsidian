/*
 * v2.5 文件树深层级缩进封顶 + 行尾收纳（闭环方案 A）—— 源级契约测试。
 *
 * 锁住的约定：
 *  1. 缩进封顶：文件夹层级再深，视觉缩进也停在 min(depth, --tree-depth-cap) × --tree-indent；
 *  2. 行尾收纳（2026-11-23 方案 A）：窄侧栏（XT2 三栏 nav 200-248vp）下行尾 48vp 星标按钮
 *     与跨栏按钮合计 ~96vp，叠加封顶 4 级缩进（96vp）后深层笔记名宽归零——真机验收缺陷。
 *     闭环：封顶降到 2 级；星标降为名字尾 12px 状态标记；跨栏按钮在树宽 < --narrow-nav 时隐藏
 *     （拖拽到栏内打开为替代路径）。
 *
 * 回归背景：修复前缩进按每级 24px/vp 线性增长，行宽下限随层级撑出横向滚动（用户 2026-11-22
 * 反馈）；v2.5 首轮只封缩进（cap=4），真机目视发现行尾按钮开销未被计入，名字仍不可见
 * （用户 2026-11-23 反馈）。
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
  assert.equal(vars['--tree-depth-cap'], '2', '--tree-depth-cap must stay 2 (v2.5 闭环方案 A)')
  // 行内边距封顶：第 2 级起缩进不再增长
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
  assert.match(tokens, /static readonly treeDepthCap: number = 2/)
  assert.match(fileTreeView,
    /private levelsOf\(depth: number\): number\[\] \{\s*\n\s*const capped: number = Math\.min\(depth, Size\.treeDepthCap\)/,
    'levelsOf must cap depth at Size.treeDepthCap')
  // 封顶值与原型 token 同源（test_v2_token_sync 也映射该对，这里显式锁数值）
  assert.equal(rootTokens()['--tree-depth-cap'], '2')
})

test('prototype hides the cross-pane button on narrow sidebars (--narrow-nav)', () => {
  const vars = rootTokens()
  assert.equal(vars['--narrow-nav'], '280px', '--narrow-nav token must exist (方案 A)')
  // 原型按形态近似：桌面三栏（nav 240 < 280）与 phone 藏，double（sidebar 38% ≈ 312）显
  assert.match(prototypeHtml, /\.window:not\(\.double\) \.file-reference\{display:none\}/)
  assert.doesNotMatch(prototypeHtml, /\.window\.phone \.file-reference\{display:none\}/)
})

test('native hides the cross-pane button below Size.narrowNavW via measured tree width', () => {
  assert.match(tokens, /static readonly narrowNavW: number = 280/)
  assert.match(fileTreeView, /@State treeWidthVp: number = 0;/)
  assert.match(fileTreeView,
    /private isNarrowNav\(\): boolean \{\s*\n\s*return this\.treeWidthVp < Size\.narrowNavW;\s*\n\s*\}/)
  // List 实测宽回填（onAreaChange 的 Area.width，vp）
  assert.match(fileTreeView,
    /\.onAreaChange\(\(oldArea: Area, newArea: Area\) => \{\s*\n\s*if \(typeof newArea\.width === 'number'\) \{\s*\n\s*this\.treeWidthVp = newArea\.width;/)
  // 跨栏按钮渲染条件纳入窄栏判断
  assert.match(fileTreeView,
    /\} else if \(!n\.isDir && !this\.referenceOnly && !this\.hideOtherPane &&\s*\n\s*!this\.isNarrowNav\(\)\) \{/)
})
