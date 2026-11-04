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
const mdpreviewSource = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
const anchorChangeStart = source.indexOf('  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {')
const anchorChangeEnd = source.indexOf('\n  private recordBlockToolbarPaneArea(', anchorChangeStart)
const panelStart = source.indexOf('  private hasBlockPropertyPanelForPane(')
const panelEnd = source.indexOf('\n  private calculateAnchoredPopupLayout(', panelStart)
const panelBuilderStart = source.indexOf('  BlockPropertyPanel() {')
const panelBuilderEnd = source.indexOf('\n  @Builder\n  PreviewBlockPanel(', panelBuilderStart)
const copyMethodsStart = source.indexOf('  private async copyCodeTextToPasteboard(')
const copyMethodsEnd = source.indexOf('\n  private async changeBlockCodeLanguage(', copyMethodsStart)
assert.ok(anchorChangeStart >= 0 && anchorChangeEnd > anchorChangeStart)
assert.ok(panelStart >= 0 && panelEnd > panelStart)
assert.ok(panelBuilderStart >= 0 && panelBuilderEnd > panelBuilderStart)
assert.ok(copyMethodsStart >= 0 && copyMethodsEnd > copyMethodsStart)

const code = transformSync(
  `class BlockPanelHarness {
    ${source.slice(anchorChangeStart, anchorChangeEnd).trim()}
    ${source.slice(panelStart, panelEnd).trim()}
  }; module.exports = BlockPanelHarness;`,
  { loader: 'ts', format: 'cjs' }
).code
const copyMethodsCode = transformSync(
  `class CodeCopyHarness {
    ${source.slice(copyMethodsStart, copyMethodsEnd).trim()}
  }; module.exports = CodeCopyHarness;`,
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
    Space: { s1: 4, s2: 8 },
    WorkspaceEditGuard: {
      isUnsaved: () => false,
      mark: () => {},
      clear: () => {}
    },
    promptAction: { showToast: () => {} }
  })
  vm.runInContext(code, context)
  const app = new context.module.exports()
  Object.assign(app, {
    experienceMode: 'simple',
    topView: 'note',
    breakpoint: 'MD',
    activePane: 'left',
    currentVaultId: 'vault-a',
    leftOpenRequestId: 7,
    leftBlockPanelOpen: false,
    rightBlockPanelOpen: false,
    blockPanelPlacement: 'bottom-left',
    leftBlockAnchor: null,
    rightBlockAnchor: null,
    blockPanelSourceVaultId: '',
    blockPanelSourcePath: '',
    blockSourceEditing: false,
    blockSourceDraft: '',
    blockSourceBlockType: '',
    blockSourceFrom: 0,
    blockSourceTo: 0,
    blockSourceDocumentRevision: 0,
    blockSourceOpenRequestId: 0,
    leftBlockToolbarPaneArea: [0, 0, 400, 600],
    rightBlockToolbarPaneArea: [400, 0, 400, 600],
    setActivePane(pane) { this.activePane = pane },
    isPaneEditable() { return true },
    notePaneVisible() { return true },
    paneFilePath() { return 'note.md' },
    editorBridgeForPane() { return this.editorBridge },
    flushSimplePreviewChanges: async () => '',
    scheduleSave() {},
    scheduleRightSave() {},
    editorDirty: false,
    rightEditorDirty: false,
    updateBlockToolbarLayout() {},
    calculateAnchoredPopupLayout(_pane, _paneArea, _anchorArea, width) {
      return { placement: 'top-left', offsetX: -120, offsetY: -8, width, maxHeight: 240 }
    },
    previewBridgeForPane() { return this.previewBridge }
  })
  app.previewBridge = { focused: [], activated: [], focusBlock(from, to) {
    this.focused.push([from, to])
  }, activateLockedContent(from, to, inlineIndex) {
    this.activated.push([from, to, inlineIndex])
  } }
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => ''
  }
  return app
}

const linkAnchor = {
  type: 'paragraph', tapType: 'link', from: 12, to: 32,
  inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1,
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
    inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1,
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
  assert.deepEqual(app.previewBridge.activated, [[12, 32, -1]])
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

test('paragraph item rows open a precise item panel without losing the parent source range', () => {
  const item = { index: 1, type: 'link', from: 24, to: 42 }
  const paragraphAnchor = {
    type: 'paragraph', tapType: '', from: 10, to: 60, inlineItems: [item],
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const app = makeApp()
  app.openBlockPropertyPanel('left', paragraphAnchor)

  assert.equal(app.blockPanelTitle, '这一段')
  assert.equal(app.blockPanelInlineItemLabel(item), '链接 1')
  assert.equal(app.blockSourceActionLabel(), '以源码编辑这一段')
  assert.equal(app.blockSourceDescription(), '只显示这一段的 Markdown，保存后只替换这一段')

  app.openBlockInlineItem(item)
  assert.equal(app.blockPanelTitle, '链接')
  assert.equal(app.blockPanelAnchor.inlineIndex, 1)
  assert.deepEqual(app.blockPanelAnchor.inlineItems, [item])
  assert.equal(app.blockSourceActionLabel(), '以源码编辑这一项')
  assert.equal(app.blockSourceDescription(), '只显示这一项的 Markdown，保存后只替换这一项')
})

test('selection refresh preserves the chosen repeated inline target through action replay', () => {
  const items = [
    { index: 0, type: 'link', from: 16, to: 32 },
    { index: 1, type: 'link', from: 36, to: 54 }
  ]
  const paragraphAnchor = {
    type: 'paragraph', tapType: '', from: 10, to: 60, inlineItems: items,
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const app = makeApp()
  app.openBlockPropertyPanel('left', paragraphAnchor)
  app.openBlockInlineItem(items[1])
  app.onBlockAnchorChange('left', {
    ...paragraphAnchor,
    x: 170,
    y: 220
  })

  assert.equal(app.blockPanelAnchor.inlineIndex, 1)
  assert.equal(app.blockPanelAnchor.itemFrom, 36)
  assert.equal(app.blockPanelAnchor.itemTo, 54)
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.blockPanelPendingAction = true
  app.onBlockPropertyPanelDisappear()
  assert.deepEqual(app.previewBridge.activated, [[10, 60, 1]])
})

test('inline item source drawer reads only the selected exact source range', async () => {
  const source = '前文 [重复](https://first.test) 与 [重复](https://second.test) 后文'
  const firstFrom = source.indexOf('[重复]')
  const firstTo = source.indexOf(')', firstFrom) + 1
  const secondFrom = source.indexOf('[重复]', firstFrom + 1)
  const secondTo = source.indexOf(')', secondFrom) + 1
  const items = [
    { index: 0, type: 'link', from: firstFrom, to: firstTo },
    { index: 1, type: 'link', from: secondFrom, to: secondTo }
  ]
  const paragraphAnchor = {
    type: 'paragraph', tapType: '', from: 0, to: source.length, inlineItems: items,
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const app = makeApp()
  app.editorBridge.getContent = async () => source
  app.openBlockPropertyPanel('left', paragraphAnchor)
  app.openBlockInlineItem(items[1])
  await app.openBlockSourceDrawer()

  assert.equal(app.blockSourceFrom, secondFrom)
  assert.equal(app.blockSourceTo, secondTo)
  assert.equal(app.blockSourceDraft, '[重复](https://second.test)')
  assert.equal(app.blockSourceEditing, true)
})

test('async source opening is canceled if the selected inline item changes', async () => {
  const source = '前文 [一](https://a.test) 与 [二](https://b.test) 后文'
  const items = [
    { index: 0, type: 'link', from: source.indexOf('[一]'), to: source.indexOf(')', source.indexOf('[一]')) + 1 },
    { index: 1, type: 'link', from: source.indexOf('[二]'), to: source.indexOf(')', source.indexOf('[二]')) + 1 }
  ]
  const paragraphAnchor = {
    type: 'paragraph', tapType: '', from: 0, to: source.length, inlineItems: items,
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const app = makeApp()
  app.editorBridge.getContent = async () => source
  app.openBlockPropertyPanel('left', paragraphAnchor)
  app.openBlockInlineItem(items[0])
  app.flushSimplePreviewChanges = async () => {
    app.blockPanelAnchor = {
      ...app.blockPanelAnchor,
      inlineIndex: items[1].index,
      itemFrom: items[1].from,
      itemTo: items[1].to
    }
    return ''
  }
  await app.openBlockSourceDrawer()

  assert.equal(app.blockSourceEditing, false)
  assert.equal(app.blockSourceDraft, '')
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

test('language picker changes only the language range and retains updated panel state', async () => {
  const source = '```javascript\nconsole.log(1)\n```'
  const calls = []
  const app = makeApp()
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => source,
    replaceBlockSource: async (...args) => {
      calls.push(args)
      app.editorBridge.currentDocumentRevision++
      return true
    }
  }
  const codeAnchor = {
    type: 'code', tapType: '', from: 0, to: source.length,
    inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1,
    codeLanguage: 'javascript', codeLanguageFrom: 3, codeLanguageTo: 13,
    codeLanguageSelectable: true, codeLanguages: ['', 'javascript', 'python'], codeEditable: true,
    x: 160, y: 200, width: 180, height: 100
  }
  app.openBlockPropertyPanel('left', codeAnchor)

  await app.changeBlockCodeLanguage('python')

  assert.equal(calls.length, 1)
  assert.deepEqual(calls[0].slice(0, 4), [3, 13, 'javascript', 'python'])
  assert.equal(app.blockPanelAnchor.codeLanguage, 'python')
  assert.equal(app.blockPanelAnchor.codeLanguageTo, 9)
  assert.equal(app.blockPanelAnchor.to, source.length - 'javascript'.length + 'python'.length)
})

test('unknown code languages are not exposed as language edits', async () => {
  let reads = 0
  const app = makeApp()
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => { reads++; return '```custom\ncode\n```' },
    replaceBlockSource: async () => { throw new Error('must not write') }
  }
  const codeAnchor = {
    type: 'code', tapType: '', from: 0, to: 18,
    inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1,
    codeLanguage: 'custom', codeLanguageFrom: 3, codeLanguageTo: 9,
    codeLanguageSelectable: false, codeLanguages: ['', 'python'], codeEditable: true,
    x: 160, y: 200, width: 180, height: 100
  }
  app.openBlockPropertyPanel('left', codeAnchor)

  await app.changeBlockCodeLanguage('python')

  assert.equal(reads, 0)
  assert.equal(app.blockPanelAnchor.codeLanguage, 'custom')
})

test('code copy writes only the supplied text and the panel targets its selected pane range', async () => {
  const writes = []
  const notices = []
  let failWrite = false
  const context = vm.createContext({
    module: { exports: {} },
    pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain',
      getSystemPasteboard: () => ({
        setData: async (data) => {
          if (failWrite) throw new Error('pasteboard unavailable')
          writes.push(data)
        }
      }),
      createData: (mimeType, value) => ({ mimeType, value })
    },
    promptAction: { showToast: ({ message }) => notices.push(message) }
  })
  vm.runInContext(copyMethodsCode, context)
  const app = new context.module.exports()

  await app.copyCodeTextToPasteboard('const answer = 42')
  await app.copyCodeTextToPasteboard('')
  assert.equal(writes.length, 2)
  assert.equal(writes[0].mimeType, 'text/plain')
  assert.equal(writes[0].value, 'const answer = 42')
  assert.equal(writes[1].value, '')
  assert.deepEqual(notices.slice(0, 2), ['已复制代码', '已复制代码'])

  failWrite = true
  await app.copyCodeTextToPasteboard('private body')
  assert.equal(writes.length, 2)
  assert.equal(notices[2], '复制代码失败，请重试')

  const requests = []
  app.blockPanelPane = 'right'
  app.blockPanelAnchor = { type: 'code', from: 16, to: 48 }
  app.previewBridgeForPane = (pane) => ({
    copyCodeBlock: (from, to) => requests.push([pane, from, to])
  })
  app.copyCodeBlockFromPanel()
  assert.deepEqual(requests, [['right', 16, 48]])
})

test('code language badge opens the existing property panel and unknown values are retained', () => {
  const builder = source.slice(panelBuilderStart, panelBuilderEnd)

  assert.match(builder, /复制代码/)
  assert.match(builder, /copyCodeBlockFromPanel/)
  assert.match(builder, /this\.blockPanelAnchor\.codeLanguageSelectable/)
  assert.match(builder, /ForEach\(this\.blockPanelAnchor\.codeLanguages/)
  assert.match(builder, /保留：\$\{this\.blockPanelAnchor\.codeLanguage\}/)
  assert.match(mdpreviewSource, /attachCodeBlockLanguageButton/)
  assert.match(mdpreviewSource, /className = 'md-code-copy'/)
  assert.match(mdpreviewSource, /notifyCodeBlockCopyContent\(target\.textContent \?\? ''\)/)
  assert.match(mdpreviewSource, /arkts\.onLockedContentTap\(payload\)/)
  assert.match(previewSource, /copyCodeBlock\(from: number, to: number\)/)
  assert.match(previewSource, /onCopyCodeBlockContent/)
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
