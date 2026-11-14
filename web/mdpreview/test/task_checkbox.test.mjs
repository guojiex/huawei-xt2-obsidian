import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const source = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')

/**
 * 2026-11-14 真机问题：简单模式里点任务复选框「完全没反应」，但格式栏「任务」按钮能用。
 * 根因有两层：
 *  1. marked 默认把任务项渲染成 `<input disabled type="checkbox">` —— disabled 的表单控件
 *     连事件都不派发，手指点上去浏览器直接忽略。
 *  2. 格式栏按钮走的是 `checkbox.checked = !checkbox.checked` 程序赋值，不受 disabled 限制，
 *     所以看起来「按钮能用、直接点框不行」。
 * 修复：可编辑块内解除 disabled，并在捕获阶段接管 pointerdown 自己翻转 + 重新序列化源码；
 * 只读态与锁定块保持 disabled。下面把这些接线钉死。
 */
test('可编辑块解除任务复选框的 disabled，只读态保持禁用', () => {
  assert.match(
    source,
    /const allTaskBoxes = root\.querySelectorAll\('input\[type="checkbox"\]'\)[\s\S]{0,220}?\.disabled = true/,
    '配置可编辑块时必须先把所有任务框复位成 disabled'
  )
  assert.match(
    source,
    /taskBox\.disabled = false/,
    '可编辑块内的任务框必须解除 disabled，否则点不动'
  )
  assert.match(
    source,
    /taskBox\.setAttribute\('aria-label', taskBox\.checked \? '已完成待办' : '未完成待办'\)/,
    '任务框要带可读的勾选状态'
  )
})

test('任务复选框自带点击切换，且把结果写回源码', () => {
  assert.match(source, /function handleTaskCheckboxPointerDown\(event: PointerEvent\)/)
  assert.match(
    source,
    /contentElement\.addEventListener\('pointerdown', handleTaskCheckboxPointerDown, true\)/,
    '必须在捕获阶段接管，抢在可编辑容器处理光标之前'
  )
  const handler = source.slice(
    source.indexOf('function handleTaskCheckboxPointerDown'),
    source.indexOf("contentElement.addEventListener('pointerdown'")
  )
  assert.match(handler, /block\.dataset\.simpleEditable !== 'true'/, '锁定块不接管，保留打开专业模式的入口')
  assert.match(handler, /event\.preventDefault\(\)/, '要拦住光标与原生激活，避免焦点动画挪走点击位置')
  assert.match(handler, /target\.checked = !target\.checked/)
  assert.match(handler, /replaceSourceBlock\(block\)/, '翻转后必须重新序列化该块，否则源码不落盘')
  // 兜底：平台若仍派发原生 click 激活，会把刚翻好的状态再翻回去。
  assert.match(
    source,
    /contentElement\.addEventListener\('click', \(event: MouseEvent\): void => \{[\s\S]{0,200}?event\.target\.type !== 'checkbox'\) return\s*\n\s*event\.preventDefault\(\)/,
    '原生 click 激活必须被撤销，保证一次点击只翻一次'
  )
})

test('格式栏「任务」按钮新建的复选框在可编辑态也是可点的', () => {
  const button = source.slice(source.indexOf("if (kind === 'task')"))
  assert.match(button, /checkbox\.disabled = !editable/, '新建任务框不能写死 disabled')
})
