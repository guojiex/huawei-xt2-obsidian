import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const vm = require('node:vm')
const source = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
const previewSource = fs.readFileSync(new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8')
const anchorChangeStart = source.indexOf('  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {')
const anchorChangeEnd = source.indexOf('\n  private recordBlockToolbarPaneArea(', anchorChangeStart)
const panelStart = source.indexOf('  private hasBlockPropertyPanelForPane(')
const panelEnd = source.indexOf('\n  private calculateAnchoredPopupLayout(', panelStart)
const panelBuilderStart = source.indexOf('  BlockPropertyPanel() {')
const panelBuilderEnd = source.indexOf('\n  @Builder\n  PreviewBlockPanel(', panelBuilderStart)
assert.ok(anchorChangeStart >= 0 && anchorChangeEnd > anchorChangeStart)
assert.ok(panelStart >= 0 && panelEnd > panelStart)
assert.ok(panelBuilderStart >= 0 && panelBuilderEnd > panelBuilderStart)

const code = transformSync(
  `class BlockPanelHarness {
    ${source.slice(anchorChangeStart, anchorChangeEnd).trim()}
    ${source.slice(panelStart, panelEnd).trim()}
  }; module.exports = BlockPanelHarness;`,
  { loader: 'ts', format: 'cjs' }
).code

function makeApp() {
  const context = vm.createContext({
    module: { exports: {} },
    Breakpoint: { SM: 'SM' },
    Placement: { TopLeft: 'top-left', BottomLeft: 'bottom-left' },
    SheetSize: { MEDIUM: 'medium', FIT_CONTENT: 'fit-content' },
    SheetType: { BOTTOM: 'bottom', POPUP: 'popup' },
    KeyType: { Down: 'down' },
    KeyCode: { KEYCODE_ESCAPE: 27 },
    Color: { Transparent: 'transparent' },
    Size: { blockPanelW: 380, blockSourceW: 480, menuMaxH: 560, touch: 48 },
    Space: { s1: 4, s2: 8 }
  })
  vm.runInContext(code, context)
  const app = new context.module.exports()
  Object.assign(app, {
    experienceMode: 'simple',
    topView: 'note',
    breakpoint: 'MD',
    activePane: 'left',
    currentVaultId: 'vault-a',
    leftBlockPanelOpen: false,
    rightBlockPanelOpen: false,
    blockPanelPlacement: 'bottom-left',
    leftBlockAnchor: null,
    rightBlockAnchor: null,
    leftBlockToolbarPaneArea: [0, 0, 400, 600],
    rightBlockToolbarPaneArea: [400, 0, 400, 600],
    setActivePane(pane) { this.activePane = pane },
    isPaneEditable() { return true },
    notePaneVisible() { return true },
    paneFilePath() { return 'note.md' },
    updateBlockToolbarLayout() {},
    calculateAnchoredPopupLayout(_pane, _paneArea, _anchorArea, width) {
      return { placement: 'top-left', offsetX: -120, offsetY: -8, width, maxHeight: 240 }
    },
    previewBridgeForPane() { return this.previewBridge }
  })
  app.previewBridge = { focused: [], activated: [], focusBlock(from, to) {
    this.focused.push([from, to])
  }, activateLockedContent(from, to) {
    this.activated.push([from, to])
  } }
  return app
}

const linkAnchor = {
  type: 'paragraph', tapType: 'link', from: 12, to: 32,
  x: 160, y: 200, width: 40, height: 20
}

test('a tapped anchor opens its pane panel and clamps the popup host inside that pane', () => {
  const app = makeApp()
  app.openBlockPropertyPanel('left', linkAnchor)

  assert.equal(app.leftBlockPanelOpen, true)
  assert.equal(app.rightBlockPanelOpen, false)
  assert.equal(app.blockPanelTitle, '链接')
  assert.equal(app.blockPanelActionLabel(), '打开链接')
  assert.equal(app.blockPanelHostX, 12)
  assert.equal(app.blockPanelHostY, 192)
  assert.equal(app.blockPanelPlacement, 'top-left')
  assert.deepEqual(Array.from(app.blockPanelAnchorGeometry('left')), [12, 192, 4, 4])
})

test('source editing widens the anchored panel to the source-drawer token', () => {
  const app = makeApp()
  app.openBlockPropertyPanel('left', linkAnchor)
  assert.equal(app.blockPanelWidth, 380)
  app.blockSourceEditing = true
  app.updateBlockPropertyPanelLayout('left')
  assert.equal(app.blockPanelWidth, 480)
})

test('selection refresh preserves the tap action and a cleared selection does not dismiss the panel', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.leftBlockPanelOpen = true

  app.onBlockAnchorChange('left', {
    type: 'paragraph', tapType: '', from: 12, to: 32,
    x: 170, y: 220, width: 40, height: 20
  })
  assert.equal(app.blockPanelAnchor.tapType, 'link')
  assert.equal(app.blockPanelAnchor.y, 220)
  assert.equal(app.blockPanelTitle, '链接')

  app.onBlockAnchorChange('left', null)
  assert.equal(app.leftBlockPanelOpen, true)
})

test('content actions run after dismissal; normal close restores focus only to the current pane', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.blockPanelPendingAction = true
  app.onBlockPropertyPanelDisappear()
  assert.deepEqual(app.previewBridge.activated, [[12, 32]])
  assert.deepEqual(app.previewBridge.focused, [])

  const closeApp = makeApp()
  closeApp.blockPanelPane = 'left'
  closeApp.blockPanelAnchor = linkAnchor
  closeApp.blockPanelSourceVaultId = 'vault-a'
  closeApp.blockPanelSourcePath = 'note.md'
  closeApp.blockPanelRestoreFocus = true
  closeApp.onBlockPropertyPanelDisappear()
  assert.deepEqual(closeApp.previewBridge.focused, [[12, 32]])
  closeApp.activePane = 'right'
  closeApp.onBlockPropertyPanelDisappear()
  assert.deepEqual(closeApp.previewBridge.focused, [[12, 32]])
})

test('changing the anchor closes the panel without restoring focus to the old block', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.blockPanelRestoreFocus = true
  app.leftBlockPanelOpen = true

  app.onBlockAnchorChange('left', {
    type: 'table', tapType: '', from: 40, to: 72,
    x: 170, y: 240, width: 200, height: 80
  })
  app.onBlockPropertyPanelDisappear()

  assert.equal(app.leftBlockPanelOpen, false)
  assert.deepEqual(app.previewBridge.focused, [])
})

test('replacing preview content closes its panel and cancels a pending stale action', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.blockPanelPendingAction = true
  app.blockPanelRestoreFocus = true
  app.leftBlockPanelOpen = true

  app.onPreviewContentReplacing('left')
  app.onBlockPropertyPanelDisappear()

  assert.equal(app.leftBlockPanelOpen, false)
  assert.equal(app.leftBlockAnchor, null)
  assert.deepEqual(app.previewBridge.activated, [])
  assert.deepEqual(app.previewBridge.focused, [])
})

test('content replacement cancels a pending action after dismissal but before disappearance', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.blockPanelPendingAction = true
  app.blockPanelRestoreFocus = false

  app.onPreviewContentReplacing('left')
  app.onBlockPropertyPanelDisappear()

  assert.deepEqual(app.previewBridge.activated, [])
  assert.deepEqual(app.previewBridge.focused, [])
})

test('Escape closes the panel and its disappearance restores focus to the source block', () => {
  const app = makeApp()
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = linkAnchor
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.leftBlockPanelOpen = true
  app.onBlockPropertyPanelKey({ type: 'down', keyCode: 27 })
  assert.equal(app.leftBlockPanelOpen, false)
  app.onBlockPropertyPanelDisappear()
  assert.deepEqual(app.previewBridge.focused, [[12, 32]])
})

test('single-screen uses a bottom sheet and wide screens use an anchored popup', () => {
  const app = makeApp()
  app.blockPanelTitle = '表格'
  app.breakpoint = 'SM'
  const singleScreen = app.blockPanelSheetOptions()
  assert.equal(singleScreen.height, 'medium')
  assert.equal(singleScreen.preferType, 'bottom')
  assert.equal(singleScreen.dragBar, true)

  app.breakpoint = 'MD'
  const wideScreen = app.blockPanelSheetOptions()
  assert.equal(wideScreen.height, 'fit-content')
  assert.equal(wideScreen.preferType, 'popup')
  assert.equal(wideScreen.placement, 'bottom-left')
  assert.equal(wideScreen.dragBar, false)
})

test('both preview panes bind the panel and block taps provide the source anchor', () => {
  const builder = source.slice(panelBuilderStart, panelBuilderEnd)
  assert.match(builder, /this\.blockPanelActionLabel\(\)/)
  assert.match(source, /this\.PreviewBlockPanel\('left'\)/)
  assert.match(source, /this\.PreviewBlockPanel\('right'\)/)
  assert.match(source, /\.bindSheet\(\$\$this\.leftBlockPanelOpen/)
  assert.match(source, /\.bindSheet\(\$\$this\.rightBlockPanelOpen/)
  assert.match(source, /onLockedContentTap: \(anchor: PreviewBlockAnchor \| null\): void => \{\s*this\.openBlockPropertyPanel\('left', anchor\)/)
  assert.match(source, /onLockedContentTap: \(anchor: PreviewBlockAnchor \| null\): void => \{\s*this\.openBlockPropertyPanel\('right', anchor\)/)
})

test('preview bridge signals only actual content replacement', () => {
  const start = previewSource.indexOf('  setContent(text: string, sourceText: string = text, sourceEdits: WikiLinkPreviewEdit[] = []): void {')
  const end = previewSource.indexOf('\n  setEditable(editable: boolean): void {', start)
  assert.ok(start >= 0 && end > start)
  const bridgeCode = transformSync(
    `class PreviewBridgeHarness { ${previewSource.slice(start, end).trim()} }; module.exports = PreviewBridgeHarness;`,
    { loader: 'ts', format: 'cjs' }
  ).code
  const context = vm.createContext({ module: { exports: {} } })
  vm.runInContext(bridgeCode, context)
  const bridge = new context.module.exports()
  let replacements = 0
  Object.assign(bridge, {
    hasContent: true,
    content: 'rendered',
    sourceContent: 'source',
    sourceEdits: [],
    onContentReplacing() { replacements++ }
  })

  bridge.setContent('rendered', 'source')
  assert.equal(replacements, 0)
  bridge.setContent('new rendered', 'source')
  assert.equal(replacements, 1)
  bridge.setContent('new rendered', 'new source')
  assert.equal(replacements, 2)
})
