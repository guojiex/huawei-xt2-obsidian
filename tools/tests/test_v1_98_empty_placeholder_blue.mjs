import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const buildSource = fs.readFileSync(path.join(repoRoot, 'web', 'mdpreview', 'build.mjs'), 'utf8')
const rawfile = fs.readFileSync(path.join(
  repoRoot, 'entry', 'src', 'main', 'resources', 'rawfile', 'mdpreview', 'index.html'), 'utf8')

test('v1.98: 可编辑空态占位 ::before 用品牌蓝（打字起点提示）', () => {
  assert.match(
    buildSource,
    /#content \.empty\[contenteditable="true"\]:empty::before \{ color: var\(--blue\); \}/,
    '可编辑空态占位文字必须是 var(--blue)（用户拍板「输入栏才需要变蓝提示」）')
})

test('v1.98: 实际输入文字仍为 --ink，占位只在 :empty 时出现', () => {
  assert.match(
    buildSource,
    /#content \.empty\[contenteditable="true"\] \{ color: var\(--ink\); font-size: var\(--body\); line-height: var\(--leading\); min-height: var\(--body\); \}/,
    '可编辑空态元素级颜色保持 --ink：开始输入后文字是正文色，不是蓝色')
  assert.match(buildSource, /#content \.empty:empty::before \{ content: attr\(data-placeholder\); \}/)
})

test('v1.98: 只读空态档保持 muted + 14px，两档字号不变', () => {
  assert.match(
    buildSource,
    /#content \.empty \{ color: var\(--muted\); font-size: var\(--small\); text-align: left; \}/,
    '只读（预览栏）空态保持 muted 提示，不改蓝')
})

test('v1.98: 重建后的 rawfile 产物同步携带品牌蓝占位规则', () => {
  assert.match(rawfile, /\.empty\[contenteditable="true"\]:empty::before\s*\{[^}]*color:\s*var\(--blue\)/)
  assert.match(rawfile, /\.empty\[contenteditable="true"\]:empty::before\s*\{[^}]*color:\s*var\(--blue\)[^}]*\}/)
  assert.doesNotMatch(rawfile, /\.empty\[contenteditable="true"\]:empty::before\s*\{[^}]*var\(--muted\)/,
    '产物中可编辑占位不得再残留 muted')
})
