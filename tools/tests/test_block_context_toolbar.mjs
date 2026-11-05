import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { readSourceFile } from './lib/source.mjs'

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url))
const start = source.indexOf('  private hasBlockToolbarForPane(pane: string): boolean {')
const end = source.indexOf('\n  private calculateAnchoredPopupLayout(', start)
const anchorChangeStart = source.indexOf('  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {')
const anchorChangeEnd = source.indexOf('\n  private recordBlockToolbarPaneArea(', anchorChangeStart)
const builderStart = source.indexOf('  BlockToolbarContent() {')
const builderEnd = source.indexOf('\n  @Builder\n  PreviewBlockToolbar(', builderStart)
const toggleStart = source.indexOf('  private toggleFormatMenu(pane: string): void {')
const toggleEnd = source.indexOf('\n  private onFormatMenuKey(', toggleStart)
assert.ok(start >= 0 && end > start, 'could not find Index.hasBlockToolbarForPane')
assert.ok(anchorChangeStart >= 0 && anchorChangeEnd > anchorChangeStart, 'could not find Index.onBlockAnchorChange')
assert.ok(builderStart >= 0 && builderEnd > builderStart, 'could not find Index.BlockToolbarContent')
assert.ok(toggleStart >= 0 && toggleEnd > toggleStart, 'could not find Index.toggleFormatMenu')

const code = transformSync(
  `class BlockToolbarHarness { ${source.slice(start, end).trim()} ${source.slice(anchorChangeStart, anchorChangeEnd).trim()} }; module.exports = BlockToolbarHarness;`,
  { loader: 'ts', format: 'cjs' }
).code
const context = vmContext()

function vmContext() {
  const vm = require('node:vm')
  const result = vm.createContext({ module: { exports: {} } })
  vm.runInContext(code, result)
  return result
}

function isVisible(options) {
  const app = new context.module.exports()
  Object.assign(app, {
    experienceMode: options.mode ?? 'simple',
    topView: options.view ?? 'note',
    activePane: options.activePane ?? 'left',
    formatMenuOpen: options.formatMenuOpen ?? false,
    isPaneEditable: () => options.editable ?? true,
    notePaneVisible: () => options.rightVisible ?? true,
    leftBlockAnchor: options.leftAnchor === false ? null : { type: 'table' },
    rightBlockAnchor: options.rightAnchor === false ? null : { type: 'table' },
    blockToolbarActions: options.actions ?? []
  })
  return app.hasBlockToolbarForPane(options.pane ?? 'left')
}

test('block toolbar stays hidden without an anchor or a registered action', () => {
  assert.equal(isVisible({ leftAnchor: false, actions: [{}] }), false)
  assert.equal(isVisible({ actions: [] }), false)
})

test('block toolbar is limited to the active editable simple-preview pane', () => {
  assert.equal(isVisible({ actions: [{}] }), true)
  assert.equal(isVisible({ actions: [{}], mode: 'professional' }), false)
  assert.equal(isVisible({ actions: [{}], view: 'settings' }), false)
  assert.equal(isVisible({ actions: [{}], activePane: 'right' }), false)
  assert.equal(isVisible({ actions: [{}], editable: false }), false)
  assert.equal(isVisible({ pane: 'right', activePane: 'right', rightVisible: false, actions: [{}] }), false)
})

test('an inactive preview cannot take ownership of the active pane toolbar', () => {
  const app = new context.module.exports()
  const layoutUpdates = []
  Object.assign(app, {
    activePane: 'right',
    blockToolbarPane: 'right',
    leftBlockAnchor: null,
    rightBlockAnchor: { type: 'table' },
    updateBlockToolbarLayout: (pane) => layoutUpdates.push(pane)
  })

  app.onBlockAnchorChange('left', { type: 'link' })
  assert.equal(app.leftBlockAnchor.type, 'link')
  assert.equal(app.blockToolbarPane, 'right')
  assert.deepEqual(layoutUpdates, [])

  app.onBlockAnchorChange('right', null)
  assert.equal(app.rightBlockAnchor, null)
  assert.deepEqual(layoutUpdates, ['right'])
})

test('the rendered toolbar is bounded to four registered actions and remains separate from Aa', () => {
  const eligibility = source.slice(start, end)
  const builder = source.slice(builderStart, builderEnd)
  const toggle = source.slice(toggleStart, toggleEnd)
  assert.match(builder, /ForEach\(this\.blockToolbarActions\.slice\(0,\s*4\)/)
  assert.match(eligibility, /this\.blockToolbarActions\.length > 0/)
  assert.match(builder, /if \(this\.blockToolbarActions\.length > 0\)/)
  assert.match(builder, /this\.openBlockPropertyPanel\(this\.blockToolbarPane\)/)
  assert.match(builder, /this\.closeBlockToolbar\(true\)/)
  assert.match(toggle, /this\.blockToolbarOpen = false;/)
})
