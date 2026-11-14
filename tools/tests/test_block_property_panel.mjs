import assert from 'node:assert/strict'
import test from 'node:test'
import { createRequire } from 'node:module'
import { readSourceFile } from './lib/source.mjs'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const vm = require('node:vm')
const source = readSourceFile(new URL('entry/src/main/ets/pages/Index.ets', root))
const panelSource = readSourceFile(new URL('entry/src/main/ets/components/BlockPropertyPanel.ets', root))
const previewSource = readSourceFile(new URL('entry/src/main/ets/components/PreviewWebView.ets', root))
const mdpreviewSource = readSourceFile(new URL('web/mdpreview/src/index.ts', root))
const anchorChangeStart = source.indexOf('  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {')
const anchorChangeEnd = source.indexOf('\n  private recordBlockToolbarPaneArea(', anchorChangeStart)
const panelStart = source.indexOf('  private hasBlockPropertyPanelForPane(')
const panelEnd = source.indexOf('\n  private calculateAnchoredPopupLayout(', panelStart)
// 2026-11-14 拆分：面板 builder 与逻辑方法迁移到 components/BlockPropertyPanel.ets，
// 以下切片改读子组件文件；子组件里调用父回调的同名委托与 @Builder 不进 harness 类。
const blockIdBuilderStart = panelSource.indexOf('  BlockPanelBlockIdAction() {')
const blockIdBuilderEnd = panelSource.indexOf('\n  build() {', blockIdBuilderStart)
const panelBuilderStart = panelSource.indexOf('  build() {')
const panelBuilderEnd = panelSource.indexOf('\n  }\n\n}', panelBuilderStart)
const linkFieldBuilderStart = panelSource.indexOf('  BlockPanelLinkField(')
const linkFieldBuilderEnd = panelSource.indexOf('\n  }\n\n}', linkFieldBuilderStart)
const linkMethodsStart = panelSource.indexOf('  private async loadBlockPanelLink()')
const linkMethodsEnd = panelSource.indexOf('\n  private async convertInlineCodeToPlainText()', linkMethodsStart)
const frontmatterMethodsStart = panelSource.indexOf('  private async loadBlockPanelFrontmatter()')
const frontmatterMethodsEnd = panelSource.indexOf('\n  private blockPanelCalloutTypeOptions()', frontmatterMethodsStart)
const movedMethodsStart = panelSource.indexOf('  private blockPanelTitleFor(anchor: PreviewBlockAnchor): string {')
const movedMethodsEnd = panelSource.indexOf('\n  @Builder', movedMethodsStart)
const imagePickerStart = source.indexOf('  private async pickImageForCurrentNote(')
const imagePickerEnd = source.indexOf('\n  /** 状态栏右侧读数', imagePickerStart)
const copyMethodsStart = panelSource.indexOf('  private async copyTextToPasteboard(')
const copyMethodsEnd = panelSource.indexOf('\n  private async changeBlockCodeLanguage(', copyMethodsStart)
const copyCodeMethodStart = source.indexOf('  private async copyCodeTextToPasteboard(')
const copyCodeMethodEnd = source.indexOf('\n  private isCurrentBlockSourceTarget(', copyCodeMethodStart)
assert.ok(anchorChangeStart >= 0 && anchorChangeEnd > anchorChangeStart)
assert.ok(panelStart >= 0 && panelEnd > panelStart)
assert.ok(blockIdBuilderStart >= 0 && blockIdBuilderEnd > blockIdBuilderStart)
assert.ok(panelBuilderStart >= 0 && panelBuilderEnd > panelBuilderStart)
assert.ok(linkFieldBuilderStart >= 0 && linkFieldBuilderEnd > linkFieldBuilderStart)
assert.ok(linkMethodsStart >= 0 && linkMethodsEnd > linkMethodsStart)
assert.ok(frontmatterMethodsStart >= 0 && frontmatterMethodsEnd > frontmatterMethodsStart)
assert.ok(movedMethodsStart >= 0 && movedMethodsEnd > movedMethodsStart)
assert.ok(imagePickerStart >= 0 && imagePickerEnd > imagePickerStart)
assert.ok(copyMethodsStart >= 0 && copyMethodsEnd > copyMethodsStart)
assert.ok(copyCodeMethodStart >= 0 && copyCodeMethodEnd > copyCodeMethodStart)

const inlineParserSource = readSourceFile(
  new URL('entry/src/main/ets/model/MarkdownInlineParser.ets', root)
)
// 2026-11-13 起 .md/.markdown 显示名收敛到 common/NoteDisplayName.ets，Index 的
// blockPanelWikiDisplayText 改调它，harness 注入同一实现。
const noteDisplayNameModule = { exports: {} }
vm.runInNewContext(
  transformSync(
    readSourceFile(new URL('entry/src/main/ets/common/NoteDisplayName.ets', root)) +
    '\nmodule.exports = { noteDisplayName, noteDisplayNameOfPath };',
    { loader: 'ts', format: 'cjs' }
  ).code,
  { module: noteDisplayNameModule }
)
const inlineParserModule = { exports: {} }
vm.runInNewContext(
  transformSync(`${inlineParserSource}\nmodule.exports = MarkdownInlineParser;`, {
    loader: 'ts',
    format: 'cjs'
  }).code,
  { module: inlineParserModule }
)
const complexEditSource = readSourceFile(
  new URL('entry/src/main/ets/model/MarkdownComplexBlockEdit.ets', root)
)
const complexEditModule = { exports: {} }
vm.runInNewContext(
  transformSync(`${complexEditSource}\nmodule.exports = MarkdownComplexBlockEdit;`, {
    loader: 'ts',
    format: 'cjs'
  }).code,
  { module: complexEditModule }
)
const wikiParserSource = readSourceFile(
  new URL('entry/src/main/ets/model/WikiLinkParser.ets', root)
)
const wikiParserModule = { exports: {} }
vm.runInNewContext(
  transformSync(`${wikiParserSource}\nmodule.exports = WikiLinkParser;`, {
    loader: 'ts',
    format: 'cjs'
  }).code,
  {
    module: wikiParserModule,
    require: () => ({ BridgeCodec: { encode: (value) => value } })
  }
)
const blockPanelTitleForStart = panelSource.indexOf('export function blockPanelTitleFor(anchor: PreviewBlockAnchor): string {')
const blockPanelTitleForEnd = panelSource.indexOf('\n}', blockPanelTitleForStart) + 2
const blockPanelTitleForModule = { exports: {} }
vm.runInNewContext(
  transformSync(
    panelSource.slice(blockPanelTitleForStart, blockPanelTitleForEnd).replace('export function', 'function') +
    '\nmodule.exports = { blockPanelTitleFor };',
    { loader: 'ts', format: 'cjs' }
  ).code,
  { module: blockPanelTitleForModule }
)
const isSameBlockPanelTargetStart = previewSource.indexOf('export function isSameBlockPanelTarget(')
const isSameBlockPanelTargetEnd = previewSource.indexOf('\n}', isSameBlockPanelTargetStart) + 2
const isSameBlockPanelTargetModule = { exports: {} }
vm.runInNewContext(
  transformSync(
    previewSource.slice(isSameBlockPanelTargetStart, isSameBlockPanelTargetEnd).replace('export function', 'function') +
    '\nmodule.exports = { isSameBlockPanelTarget };',
    { loader: 'ts', format: 'cjs' }
  ).code,
  { module: isSameBlockPanelTargetModule }
)
const code = transformSync(
  `class BlockPanelHarness {
    ${source.slice(anchorChangeStart, anchorChangeEnd).trim()}
    ${source.slice(panelStart, panelEnd).trim()}
    ${panelSource.slice(linkMethodsStart, linkMethodsEnd).trim()}
    ${panelSource.slice(frontmatterMethodsStart, frontmatterMethodsEnd).trim()}
    ${panelSource.slice(movedMethodsStart, movedMethodsEnd).trim()}
    ${source.slice(imagePickerStart, imagePickerEnd).trim()}
  }; module.exports = BlockPanelHarness;`,
  { loader: 'ts', format: 'cjs' }
).code
const copyMethodsCode = transformSync(
  `class CodeCopyHarness {
    ${panelSource.slice(copyMethodsStart, copyMethodsEnd).trim()}
    ${source.slice(copyCodeMethodStart, copyCodeMethodEnd).trim()}
  }; module.exports = CodeCopyHarness;`,
  { loader: 'ts', format: 'cjs' }
).code

function makeApp() {
  const notices = []
  const removedImageAssets = []
  let importPickedImage = async () => ({
    markdownReference: '![new](attachments/new.png)',
    assetPath: 'attachments/new.png'
  })
  let wikiFiles = ['target.md', 'folder/next.md']
  const context = vm.createContext({
    module: { exports: {} },
    noteDisplayName: noteDisplayNameModule.exports.noteDisplayName,
    noteDisplayNameOfPath: noteDisplayNameModule.exports.noteDisplayNameOfPath,
    MarkdownInlineParser: inlineParserModule.exports,
    MarkdownComplexBlockEdit: complexEditModule.exports,
    WikiLinkParser: wikiParserModule.exports,
    blockPanelTitleFor: blockPanelTitleForModule.exports.blockPanelTitleFor,
    isSameBlockPanelTarget: isSameBlockPanelTargetModule.exports.isSameBlockPanelTarget,
    WikiLinkService: {
      files: () => wikiFiles,
      resolve: (target, sourcePath, files) =>
        wikiParserModule.exports.resolve(target, sourcePath, files)
    },
    NoteShareService: {
      isRemoteImage: (source) => source.startsWith('//') || /^(https?:|data:|blob:)/i.test(source)
    },
    NoteImageService: {
      selectedUri: (uris) => uris.length > 0 ? uris[0] : '',
      importPickedImage: (...args) => importPickedImage(...args),
      removeImportedImage: (...args) => removedImageAssets.push(args)
    },
    photoAccessHelper: {
      PhotoSelectOptions: class {},
      PhotoViewPicker: class {
        async select() {
          return { photoUris: ['picker-uri'] }
        }
      },
      PhotoViewMIMETypes: { IMAGE_TYPE: 'image' }
    },
    VaultRegistry: { get: () => ({ abilityContext: () => ({}) }) },
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
    promptAction: { showToast: ({ message }) => notices.push(message) }
  })
  vm.runInContext(code, context)
  const app = new context.module.exports()
  Object.assign(app, {
    notices,
    removedImageAssets,
    setImageImport(handler) { importPickedImage = handler },
    setWikiFiles(files) { wikiFiles = files },
    experienceMode: 'simple',
    topView: 'note',
    breakpoint: 'MD',
    activePane: 'left',
    currentVaultId: 'vault-a',
    rightOpenRequestId: 7,
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
    previewBridgeForPane() { return this.previewBridge },
    onTitleChange(title) { this.blockPanelTitle = title },
    onSourceEditingChange(editing) { this.blockSourceEditing = editing },
    onDirtyChange(pane, dirty) {
      if (pane === 'right') {
        this.rightEditorDirty = dirty
      } else {
        this.editorDirty = dirty
      }
    },
    isDirty(pane) { return pane === 'right' ? this.rightEditorDirty : this.editorDirty }
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

function prepareCalloutPanel(source, prefix = '', suffix = '') {
  const app = makeApp()
  const fullSource = prefix + source + suffix
  const from = prefix.length
  const to = from + source.length
  const anchor = {
    type: 'callout', tapType: '', from, to, inlineItems: [],
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const writes = []
  const history = []
  let content = fullSource
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = anchor
  app.blockPanelInlineItems = []
  app.leftBlockPanelOpen = true
  app.rightBlockPanelOpen = false
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.blockPanelCalloutReady = false
  app.blockPanelCalloutSaveTail = Promise.resolve()
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => content,
    replaceBlockSource: async (...args) => {
      writes.push(args)
      if (app.editorBridge.currentDocumentRevision !== args[4] ||
        content.slice(args[0], args[1]) !== args[2]) {
        return false
      }
      history.push(content)
      content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
      app.editorBridge.currentDocumentRevision++
      return true
    },
    undo: () => {
      if (history.length > 0) {
        content = history.pop()
        app.editorBridge.currentDocumentRevision++
      }
    },
    content: () => content,
    writes,
    history
  }
  return { app, anchor, writes, history, content: () => content }
}

function prepareFrontmatterPanel(raw, suffix = '') {
  const app = makeApp()
  const anchor = {
    type: 'frontmatter', tapType: '', from: 0, to: raw.length, inlineItems: [],
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const writes = []
  const history = []
  let content = raw + suffix
  Object.assign(app, {
    blockPanelPane: 'left',
    blockPanelAnchor: anchor,
    blockPanelInlineItems: [],
    leftBlockPanelOpen: true,
    rightBlockPanelOpen: false,
    blockPanelSourceVaultId: 'vault-a',
    blockPanelSourcePath: 'note.md',
    blockPanelFrontmatterReady: false,
    blockPanelFrontmatterSaveTail: Promise.resolve(),
    blockPanelFrontmatterSaving: false,
    updateBlockPropertyPanelLayout() {}
  })
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => content,
    replaceBlockSource: async (...args) => {
      writes.push(args)
      if (app.editorBridge.currentDocumentRevision !== args[4] ||
        content.slice(args[0], args[1]) !== args[2]) {
        return false
      }
      history.push(content)
      content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
      app.editorBridge.currentDocumentRevision++
      return true
    },
    undo: () => {
      if (history.length > 0) {
        content = history.pop()
        app.editorBridge.currentDocumentRevision++
      }
    },
    content: () => content,
    writes,
    history
  }
  return { app, anchor, writes, history, content: () => content }
}

function prepareWikiPanel(source, files = ['target.md', 'folder/next.md']) {
  const app = makeApp()
  app.setWikiFiles(files)
  const item = { index: 0, type: 'wikilink', from: 0, to: source.length }
  const anchor = {
    type: 'paragraph', tapType: 'wikilink', from: 0, to: source.length,
    inlineItems: [item], inlineIndex: 0, itemFrom: 0, itemTo: source.length,
    x: 160, y: 200, width: 100, height: 40
  }
  let content = source
  const history = []
  const writes = []
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = anchor
  app.blockPanelInlineItems = [item]
  app.leftBlockPanelOpen = true
  app.rightBlockPanelOpen = false
  app.activePane = 'left'
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => content,
    replaceBlockSource: async (...args) => {
      writes.push(args)
      if (app.editorBridge.currentDocumentRevision !== args[4] ||
        content.slice(args[0], args[1]) !== args[2]) {
        return false
      }
      history.push(content)
      content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
      app.editorBridge.currentDocumentRevision++
      return true
    },
    undo: () => {
      if (history.length > 0) {
        content = history.pop()
        app.editorBridge.currentDocumentRevision++
      }
    }
  }
  return {
    app,
    history,
    writes,
    content: () => content,
    setContent: (nextContent) => { content = nextContent }
  }
}

function prepareImagePanel(source, imageFrom, imageTo) {
  const app = makeApp()
  const item = { index: 0, type: 'image', from: imageFrom, to: imageTo }
  const anchor = {
    type: 'paragraph', tapType: 'image', from: 0, to: source.length,
    inlineItems: [item], inlineIndex: 0, itemFrom: imageFrom, itemTo: imageTo,
    x: 160, y: 200, width: 100, height: 40
  }
  let content = source
  const writes = []
  const history = []
  app.blockPanelPane = 'left'
  app.blockPanelAnchor = anchor
  app.blockPanelInlineItems = [item]
  app.leftBlockPanelOpen = true
  app.rightBlockPanelOpen = false
  app.activePane = 'left'
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  app.editorBridge = {
    currentDocumentRevision: 11,
    getContent: async () => content,
    replaceBlockSource: async (...args) => {
      writes.push(args)
      if (app.editorBridge.currentDocumentRevision !== args[4] ||
        content.slice(args[0], args[1]) !== args[2]) {
        return false
      }
      history.push(content)
      content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
      app.editorBridge.currentDocumentRevision++
      return true
    },
    undo: () => {
      if (history.length > 0) {
        content = history.pop()
        app.editorBridge.currentDocumentRevision++
      }
    }
  }
  app.closeBlockPropertyPanel = () => {
    app.leftBlockPanelOpen = false
    app.rightBlockPanelOpen = false
  }
  return { app, writes, history, content: () => content }
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

test('opening a paragraph inline link starts loading the selected link', () => {
  const item = { index: 1, type: 'link', from: 24, to: 50 }
  const paragraphAnchor = {
    type: 'paragraph', tapType: '', from: 10, to: 60, inlineItems: [item],
    inlineIndex: -1, itemFrom: -1, itemTo: -1,
    x: 160, y: 200, width: 100, height: 40
  }
  const app = makeApp()
  let loads = 0
  app.loadBlockPanelLink = async () => { loads++ }
  app.openBlockPropertyPanel('left', paragraphAnchor)
  app.openBlockInlineItem(item)

  assert.equal(loads, 1)
  assert.equal(app.blockPanelLinkReady, false)
  assert.equal(app.blockPanelLinkMessage, '正在读取链接…')
})

test('21.2 loads and edits only a callout range, preserving outside source and undo', async () => {
  const raw = '> [!note] Old title\r\n> body\r\n'
  const prefix = '前文\n\n'
  const suffix = '\n\n后文'
  const { app, writes, history, content } = prepareCalloutPanel(raw, prefix, suffix)
  await app.loadBlockPanelCallout()

  assert.equal(app.blockPanelCalloutTitle, 'Old title')
  assert.equal(app.blockPanelCalloutFold, '')
  await app.saveBlockPanelCalloutField('title', 'New title')
  await app.saveBlockPanelCalloutType(7)
  await app.saveBlockPanelCalloutFold(2)

  assert.equal(content(), `${prefix}> [!warning]- New title\r\n> body\r\n${suffix}`)
  assert.equal(writes.length, 3)
  assert.equal(writes[0][0], prefix.length)
  assert.equal(writes[0][2], raw)
  assert.equal(writes[0][3], '> [!note] New title\r\n> body\r\n')
  assert.deepEqual(Array.from(history), [
    `${prefix}${raw}${suffix}`,
    `${prefix}> [!note] New title\r\n> body\r\n${suffix}`,
    `${prefix}> [!warning] New title\r\n> body\r\n${suffix}`
  ])
  app.editorBridge.undo()
  app.editorBridge.undo()
  app.editorBridge.undo()
  assert.equal(content(), `${prefix}${raw}${suffix}`)
})

test('21.2 unknown callout types keep their type and expose no type or fold controls', async () => {
  const raw = '> [!vendor_kind]- Old title\n> body\n'
  const { app, writes, content } = prepareCalloutPanel(raw)
  await app.loadBlockPanelCallout()

  assert.equal(app.blockPanelCalloutModel.knownType, false)
  assert.equal(app.blockPanelCalloutModel.type, 'vendor_kind')
  await app.saveBlockPanelCalloutField('title', 'New title')

  assert.equal(content(), '> [!vendor_kind]- New title\n> body\n')
  assert.equal(writes.length, 1)
  assert.match(panelSource.slice(panelBuilderStart, panelBuilderEnd),
    /blockPanelCalloutModel\.knownType[\s\S]*?Select\(this\.blockPanelCalloutTypeOptions\(\)\)[\s\S]*?if \(this\.blockPanelCalloutModel\.knownType\)/)
  assert.match(panelSource.slice(panelBuilderStart, panelBuilderEnd), /类型 · 保留：\$\{this\.blockPanelCalloutModel\.type\}/)
})

test('21.3 loads and edits only frontmatter, preserving outside source and undo', async () => {
  const raw = '---\r\ntitle: Original\r\ntags:\r\n  - old\r\nnested:\r\n  path: keep\r\n---\r\n'
  const suffix = '\r\n# Body\r\n'
  const { app, writes, history, content } = prepareFrontmatterPanel(raw, suffix)
  await app.loadBlockPanelFrontmatter()

  assert.equal(app.blockPanelFrontmatterModel.properties.length, 3)
  assert.equal(app.blockPanelFrontmatterMessage, '')
  await app.saveBlockPanelFrontmatterProperty('set', 'title', 'Updated')
  await app.saveBlockPanelFrontmatterProperty('set', 'tags', 'new, work')
  await app.saveBlockPanelFrontmatterProperty('add', 'published', 'true')
  await app.saveBlockPanelFrontmatterProperty('remove', 'nested', '')

  assert.equal(content(), '---\r\ntitle: Updated\r\ntags:\r\n  - new\r\n  - work\r\npublished: true\r\n---\r\n' + suffix)
  assert.equal(writes.length, 4)
  assert.equal(writes[0][0], 0)
  assert.equal(writes[0][1], raw.length)
  assert.equal(writes[0][2], raw)
  assert.equal(history.length, 4)
  const undoCount = history.length
  for (let index = 0; index < undoCount; index++) app.editorBridge.undo()
  assert.equal(content(), raw + suffix)
})

test('21.3 malformed YAML loads read-only without replacing source', async () => {
  const raw = '---\ntitle value\n---\n'
  const { app, writes, content } = prepareFrontmatterPanel(raw)
  await app.loadBlockPanelFrontmatter()
  assert.equal(app.blockPanelFrontmatterModel, null)
  assert.match(app.blockPanelFrontmatterMessage, /只读|安全编辑/)
  assert.equal(await app.saveBlockPanelFrontmatterProperty('set', 'title', 'unsafe'), false)
  assert.equal(writes.length, 0)
  assert.equal(content(), raw)
})

function prepareLinkEditor(app, content) {
  const history = []
  const calls = []
  const editor = {
    currentDocumentRevision: 11,
    getContent: async () => content,
    replaceBlockSource: async (...args) => {
      calls.push(args)
      if (editor.currentDocumentRevision !== args[4] ||
        content.slice(args[0], args[1]) !== args[2]) {
        return false
      }
      history.push(content)
      content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
      editor.currentDocumentRevision++
      return true
    },
    undo: () => {
      if (history.length === 0) return
      content = history.pop()
      editor.currentDocumentRevision++
    },
    content: () => content,
    history,
    calls
  }
  app.editorBridge = editor
  app.blockPanelPane = 'left'
  app.leftBlockPanelOpen = true
  app.rightBlockPanelOpen = false
  app.blockPanelSourceVaultId = 'vault-a'
  app.blockPanelSourcePath = 'note.md'
  return editor
}

function makeSelectedLinkAnchor(content, linkFrom, linkTo, inlineIndex = 1) {
  const item = { index: inlineIndex, type: 'link', from: linkFrom, to: linkTo }
  return {
    type: 'paragraph', tapType: 'link', from: 0, to: content.length,
    inlineItems: [item], inlineIndex, itemFrom: linkFrom, itemTo: linkTo,
    x: 160, y: 200, width: 100, height: 40
  }
}

test('20.1 loads and edits only the selected link range, preserving other inline items', async () => {
  const content = '前文 [一](https://first.test) 与 [二](https://second.test) 后文'
  const linkFrom = content.indexOf('[二]')
  const linkTo = content.indexOf(')', linkFrom) + 1
  const app = makeApp()
  const scheduled = []
  app.scheduleSave = () => scheduled.push('left')
  app.scheduleRightSave = () => scheduled.push('right')
  const editor = prepareLinkEditor(app, content)
  app.blockPanelAnchor = makeSelectedLinkAnchor(content, linkFrom, linkTo)

  await app.loadBlockPanelLink()
  assert.equal(app.blockPanelLinkLabel, '二')
  assert.equal(app.blockPanelLinkDestination, 'https://second.test')

  app.blockPanelLinkLabel = '改名'
  await app.saveBlockPanelLinkField('label')
  app.blockPanelLinkDestination = 'https://updated.test/path'
  await app.saveBlockPanelLinkField('destination')

  assert.equal(
    editor.content(),
    '前文 [一](https://first.test) 与 [改名](https://updated.test/path) 后文'
  )
  assert.equal(editor.calls.length, 2)
  assert.equal(editor.calls[0][2], '[二](https://second.test)')
  assert.equal(editor.calls[0][3], '[改名](https://second.test)')
  assert.equal(editor.calls[1][2], '[改名](https://second.test)')
  assert.equal(editor.calls[1][3], '[改名](https://updated.test/path)')
  assert.deepEqual(scheduled, ['left', 'left'])
  assert.equal(app.editorDirty, true)
  assert.equal(app.blockPanelAnchor.itemTo - app.blockPanelAnchor.itemFrom,
    '[改名](https://updated.test/path)'.length)
})

test('20.1 rejects an empty destination without writing the note', async () => {
  const content = '前 [链接](https://example.test) 后'
  const linkFrom = content.indexOf('[链接]')
  const linkTo = content.indexOf(')', linkFrom) + 1
  const app = makeApp()
  const editor = prepareLinkEditor(app, content)
  app.blockPanelAnchor = makeSelectedLinkAnchor(content, linkFrom, linkTo)
  await app.loadBlockPanelLink()
  app.blockPanelLinkDestination = '   '

  await app.saveBlockPanelLinkField('destination')

  assert.equal(editor.content(), content)
  assert.equal(editor.calls.length, 0)
  assert.deepEqual(app.notices, ['地址不能为空或包含空格，未修改链接'])
})

test('20.1 unlink preserves the label and one undo restores exact Markdown', async () => {
  const content = '前文 [显示 \\[文字\\]](https://example.test/a\\(b\\)) 后文'
  const linkFrom = content.indexOf('[')
  const linkTo = content.lastIndexOf(')') + 1
  const app = makeApp()
  const editor = prepareLinkEditor(app, content)
  app.blockPanelAnchor = makeSelectedLinkAnchor(content, linkFrom, linkTo)
  app.closeBlockPropertyPanel = () => {}
  await app.loadBlockPanelLink()

  await app.unlinkBlockPanelLink()

  assert.equal(editor.content(), '前文 显示 [文字] 后文')
  assert.equal(editor.history.length, 1)
  editor.undo()
  assert.equal(editor.content(), content)
})

test('20.1 unsupported link forms remain read-only and preserve a source-edit route', async () => {
  const content = '前 [链接](https://example.test "说明") 后'
  const linkFrom = content.indexOf('[链接]')
  const linkTo = content.indexOf(')', linkFrom) + 1
  const app = makeApp()
  const editor = prepareLinkEditor(app, content)
  app.blockPanelAnchor = makeSelectedLinkAnchor(content, linkFrom, linkTo)

  await app.loadBlockPanelLink()

  assert.equal(app.blockPanelLinkParts, null)
  assert.equal(app.blockPanelLinkMessage, '此链接写法暂不支持结构化编辑')
  assert.equal(editor.content(), content)
})

test('20.1 reports a failed write once and leaves the source unchanged', async () => {
  const content = '前 [链接](https://example.test) 后'
  const linkFrom = content.indexOf('[链接]')
  const linkTo = content.indexOf(')', linkFrom) + 1
  const app = makeApp()
  const editor = prepareLinkEditor(app, content)
  app.blockPanelAnchor = makeSelectedLinkAnchor(content, linkFrom, linkTo)
  await app.loadBlockPanelLink()
  editor.replaceBlockSource = async () => { throw new Error('write failed') }
  app.blockPanelLinkLabel = '新标题'

  await app.saveBlockPanelLinkField('label')

  assert.equal(editor.content(), content)
  assert.deepEqual(app.notices, ['修改链接失败，请重试'])
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

test('plain-text action unwraps only the selected inline code in either pane', async () => {
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)
  assert.match(builder, /\.onClick\(\(\): void => \{ void this\.performBlockPanelAction\(\); \}\)/)

  for (const pane of ['left', 'right']) {
    const sourceText = pane === 'left'
      ? 'left: before ``a`b`` after'
      : 'right: before `value` after'
    const itemFrom = sourceText.indexOf('`')
    const itemTo = sourceText.indexOf(' after')
    const item = { index: 0, type: 'inlinecode', from: itemFrom, to: itemTo }
    const paragraphAnchor = {
      type: 'paragraph', tapType: '', from: 0, to: sourceText.length,
      inlineItems: [item], inlineIndex: -1, itemFrom: -1, itemTo: -1,
      x: 160, y: 200, width: 100, height: 40
    }
    const calls = []
    let content = sourceText
    const editor = {
      currentDocumentRevision: 11,
      getContent: async () => content,
      replaceBlockSource: async (...args) => {
        calls.push(args)
        if (content.slice(args[0], args[1]) !== args[2]) return false
        content = content.slice(0, args[0]) + args[3] + content.slice(args[1])
        editor.currentDocumentRevision++
        return true
      }
    }
    const app = makeApp()
    app.editorBridgeForPane = (targetPane) => {
      assert.equal(targetPane, pane)
      return editor
    }
    app.openBlockPropertyPanel(pane, paragraphAnchor)
    app.openBlockInlineItem(item)
    app.onBlockAnchorChange(pane, { ...paragraphAnchor, x: 170, y: 220 })

    assert.equal(app.blockPanelPane, pane)
    assert.equal(app.blockPanelAnchor.tapType, 'inlinecode')
    assert.equal(app.blockPanelAnchor.inlineIndex, item.index)
    assert.equal(app.blockPanelAnchor.itemFrom, item.from)
    assert.equal(app.blockPanelAnchor.itemTo, item.to)
    assert.equal(app.blockPanelActionLabel(), '转为纯文本')

    await app.performBlockPanelAction()

    assert.equal(content, pane === 'left' ? 'left: before a`b after' : 'right: before value after')
    assert.equal(calls.length, 1)
    assert.deepEqual(calls[0].slice(0, 4), [
      item.from,
      item.to,
      sourceText.slice(item.from, item.to),
      pane === 'left' ? 'a`b' : 'value'
    ])
    assert.equal(app.leftBlockPanelOpen || app.rightBlockPanelOpen, false)
    assert.deepEqual(app.previewBridge.activated, [])
  }
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

test('20.1 link panel shows the open action, address, editable fields and unlink action', () => {
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)
  assert.match(builder, /tapType === 'link'/)
  assert.match(builder, /this\.blockPanelLinkParts\.destination/)
  assert.match(builder, /BlockPanelLinkField\('显示文字', 'label'/)
  assert.match(builder, /BlockPanelLinkField\('地址', 'destination'/)
  assert.match(builder, /this\.unlinkBlockPanelLink\(\)/)
  assert.match(panelSource.slice(linkFieldBuilderStart, linkFieldBuilderEnd),
    /BlockPanelLinkField\(label: string, field: string, value: string, placeholder: string\)[\s\S]*不自动补全协议/)
})

test('20.2 tapping a wiki link opens its panel and starts loading it', () => {
  const app = makeApp()
  const anchor = {
    ...linkAnchor,
    tapType: 'wikilink',
    inlineIndex: 0,
    itemFrom: 12,
    itemTo: 32
  }
  let loads = 0
  app.loadBlockPanelWikiLink = async () => { loads++ }

  app.openBlockPropertyPanel('left', anchor)

  assert.equal(app.blockPanelTitle, '双链')
  assert.equal(app.blockPanelWikiReady, false)
  assert.equal(app.blockPanelWikiMessage, '正在读取双链…')
  assert.equal(loads, 1)
})

test('20.2 opens the wiki-link panel and loads the current-vault target and alias', async () => {
  const { app } = prepareWikiPanel('[[target.md|Visible title]]')

  await app.loadBlockPanelWikiLink()

  assert.equal(app.blockPanelWikiReady, true)
  assert.equal(app.blockPanelWikiTarget, 'target.md')
  assert.equal(app.blockPanelWikiAlias, 'Visible title')
  assert.equal(app.blockPanelWikiResolutionStatus, 'resolved')
  assert.equal(app.blockPanelWikiResolutionPath, 'target.md')
  assert.equal(app.blockPanelWikiMessage, '')
  assert.equal(app.blockPanelActionLabel(), '打开目标笔记')
  assert.deepEqual(
    Array.from(app.blockPanelWikiSelectOptions(), (option) => option.value),
    ['./target.md', 'folder/next.md']
  )
})

test('20.2 property panel binds target selection, alias editing, and unlinking', () => {
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)
  assert.match(builder, /tapType === 'wikilink'/)
  assert.match(builder, /Select\(this\.blockPanelWikiSelectOptions\(\)\)/)
  assert.match(builder, /saveBlockPanelWikiField\('target', value\)/)
  assert.match(builder, /this\.BlockPanelWikiAliasField\(\)/)
  assert.match(builder, /this\.unlinkBlockPanelWiki\(\)/)
  assert.match(panelSource, /标题锚点暂不支持跳转/)
})

test('20.2 missing targets remain editable and changing the alias preserves the target', async () => {
  const { app, content } = prepareWikiPanel('[[missing.md|Old label]]', ['target.md'])
  await app.loadBlockPanelWikiLink()

  assert.equal(app.blockPanelWikiResolutionStatus, 'missing')
  assert.match(app.blockPanelWikiMessage, /目标笔记还没有创建/)
  assert.equal(app.blockPanelActionLabel(), '')
  await app.saveBlockPanelWikiField('alias', 'New label')

  assert.equal(content(), '[[missing.md|New label]]')
  assert.equal(app.blockPanelWikiTarget, 'missing.md')
  assert.equal(app.blockPanelWikiAlias, 'New label')
  assert.match(app.blockPanelWikiMessage, /目标笔记还没有创建/)
  await app.saveBlockPanelWikiField('target', './target.md')
  assert.equal(content(), '[[./target.md|New label]]')
  assert.equal(app.blockPanelWikiResolutionStatus, 'resolved')
})

test('20.2 title anchors explain that jumping is unsupported but allow target replacement', async () => {
  const original = '[[target.md#Intro|Jump]]'
  const { app, content } = prepareWikiPanel(original)
  await app.loadBlockPanelWikiLink()

  assert.match(app.blockPanelWikiMessage, /标题锚点暂不支持跳转/)
  assert.equal(app.blockPanelActionLabel(), '')
  await app.saveBlockPanelWikiField('target', './target.md')

  assert.equal(content(), '[[./target.md|Jump]]')
  assert.equal(app.blockPanelWikiResolutionStatus, 'resolved')
  assert.equal(app.blockPanelActionLabel(), '打开目标笔记')
  app.editorBridge.undo()
  assert.equal(content(), original)
})

test('20.2 clearing the alias removes its separator and unlinking retains visible text', async () => {
  const clearAlias = prepareWikiPanel('[[folder/next.md|Visible]]')
  await clearAlias.app.loadBlockPanelWikiLink()
  await clearAlias.app.saveBlockPanelWikiField('alias', '')
  assert.equal(clearAlias.content(), '[[folder/next.md]]')

  const removeAlias = prepareWikiPanel('[[folder/next.md|Visible]]')
  await removeAlias.app.loadBlockPanelWikiLink()
  removeAlias.app.closeBlockPropertyPanel = () => {}
  await removeAlias.app.unlinkBlockPanelWiki()
  assert.equal(removeAlias.content(), 'Visible')

  const removeDefaultLabel = prepareWikiPanel('[[folder/next.md]]')
  await removeDefaultLabel.app.loadBlockPanelWikiLink()
  removeDefaultLabel.app.closeBlockPropertyPanel = () => {}
  await removeDefaultLabel.app.unlinkBlockPanelWiki()
  assert.equal(removeDefaultLabel.content(), 'next')
})

test('20.2 opens resolved targets in the other pane without invoking missing-note creation', async () => {
  const resolved = prepareWikiPanel('[[folder/next.md]]')
  await resolved.app.loadBlockPanelWikiLink()
  const opened = []
  const closed = []
  resolved.app.closeBlockPropertyPanel = (restoreFocus) => closed.push(restoreFocus)
  resolved.app.openFileInOtherPane = (path) => opened.push(path)
  resolved.app.handleWikiLinkClick = () => assert.fail('must not use the preview click path')

  await resolved.app.performBlockPanelAction()

  assert.deepEqual(opened, ['folder/next.md'])
  assert.deepEqual(closed, [false])

  const missing = prepareWikiPanel('[[missing.md]]')
  await missing.app.loadBlockPanelWikiLink()
  missing.app.closeBlockPropertyPanel = () => assert.fail('missing targets must not close and open')
  missing.app.openFileInOtherPane = () => assert.fail('missing targets must not open')
  await missing.app.performBlockPanelAction()
})

test('20.2 stale source ranges reject wiki-link edits without writing', async () => {
  const { app, content, writes, setContent } = prepareWikiPanel('[[target.md|Old]]')
  await app.loadBlockPanelWikiLink()
  setContent('the source changed')
  app.editorBridge.currentDocumentRevision++

  await app.saveBlockPanelWikiField('alias', 'New')

  assert.equal(content(), 'the source changed')
  assert.equal(writes.length, 0)
})

test('20.3 image width and deletion touch only the selected image range and undo as one edit', async () => {
  const original = '前文 ![本地图片|360](attachments/old.png) 后文'
  const imageFrom = original.indexOf('![')
  const imageTo = original.indexOf(')', imageFrom) + 1
  const { app, writes, history, content } = prepareImagePanel(original, imageFrom, imageTo)

  await app.loadBlockPanelImage()
  assert.equal(app.blockPanelImageReady, true)
  assert.equal(app.blockPanelImageAlt, '本地图片')
  assert.equal(app.blockPanelImageWidth, '360')
  assert.equal(app.blockPanelImageRemote(), false)

  await app.saveBlockPanelImageField('width', '480')
  assert.equal(content(), '前文 ![本地图片|480](attachments/old.png) 后文')
  assert.deepEqual(writes[0].slice(0, 4), [
    imageFrom,
    imageTo,
    '![本地图片|360](attachments/old.png)',
    '![本地图片|480](attachments/old.png)'
  ])
  assert.equal(history.length, 1)
  app.editorBridge.undo()
  assert.equal(content(), original)

  await app.loadBlockPanelImage()
  await app.deleteBlockPanelImage()
  assert.equal(content(), '前文  后文')
  assert.equal(history.length, 1)
  assert.doesNotMatch(panelSource.slice(panelSource.indexOf('private async deleteBlockPanelImage()'),
    panelSource.indexOf('\n  private openBlockPanelWikiTarget()', panelSource.indexOf('private async deleteBlockPanelImage()'))),
  /NoteImageService/)
})

test('20.3 external image addresses are editable while local image paths are not', async () => {
  const original = '前文 ![远端图|240](<https://example.test/old.png>) 后文'
  const imageFrom = original.indexOf('![')
  const imageTo = original.indexOf(')', imageFrom) + 1
  const { app, writes, content } = prepareImagePanel(original, imageFrom, imageTo)
  await app.loadBlockPanelImage()

  assert.equal(app.blockPanelImageRemote(), true)
  await app.saveBlockPanelImageField('destination', '  ')
  assert.equal(writes.length, 0)
  assert.equal(app.notices.at(-1), '图片地址不能为空或包含空格，未修改')

  await app.saveBlockPanelImageField('destination', 'https://example.test/new.png')
  assert.equal(content(), '前文 ![远端图|240](<https://example.test/new.png>) 后文')
  assert.equal(writes.length, 1)

  const local = prepareImagePanel(
    '![本地](attachments/image.png)', 0, '![本地](attachments/image.png)'.length
  )
  await local.app.loadBlockPanelImage()
  await local.app.saveBlockPanelImageField('destination', 'https://example.test/new.png')
  assert.equal(local.writes.length, 0)
})

test('20.3 replacing a local image preserves its alt text and width in one source replacement', async () => {
  const original = '前文 ![本地图片|360](attachments/old.png) 后文'
  const imageFrom = original.indexOf('![')
  const imageTo = original.indexOf(')', imageFrom) + 1
  const { app } = prepareImagePanel(original, imageFrom, imageTo)
  const writes = []
  app.currentFilePath = 'note.md'
  app.previewBridge.ready = true
  app.replaceBlockPanelInlineSource = async (...args) => {
    writes.push(args)
    return true
  }
  await app.loadBlockPanelImage()

  await app.pickImageForCurrentNote('left', true, app.imageReplaceContext())

  assert.deepEqual(writes[0].slice(0, 2), [
    '![本地图片|360](attachments/old.png)',
    '![本地图片|360](attachments/new.png)'
  ])
  assert.deepEqual(app.removedImageAssets, [])
})

test('20.3 removes only the new attachment when the selected image changes during import', async () => {
  const original = '前文 ![本地图片](attachments/old.png) 后文'
  const imageFrom = original.indexOf('![')
  const imageTo = original.indexOf(')', imageFrom) + 1
  const { app, content } = prepareImagePanel(original, imageFrom, imageTo)
  const writes = []
  app.currentFilePath = 'note.md'
  app.previewBridge.ready = true
  app.replaceBlockPanelInlineSource = async (...args) => {
    writes.push(args)
    return true
  }
  app.setImageImport(async () => {
    app.editorBridge.currentDocumentRevision++
    return { markdownReference: '![new](attachments/new.png)', assetPath: 'attachments/new.png' }
  })
  await app.loadBlockPanelImage()

  await app.pickImageForCurrentNote('left', true, app.imageReplaceContext())

  assert.equal(content(), original)
  assert.equal(writes.length, 0)
  assert.equal(app.removedImageAssets.length, 1)
  assert.equal(app.removedImageAssets[0][1], 'vault-a')
  assert.equal(app.removedImageAssets[0][2], 'attachments/new.png')
  assert.equal(app.notices.at(-1), '图片已变化，未替换')
})

test('20.3 image panel only offers address editing for external images', () => {
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)
  assert.match(builder, /tapType === 'image'/)
  assert.match(builder, /blockPanelImageRemote\(\)/)
  assert.match(builder, /BlockPanelImageField\(\s*'destination', '图片地址'/)
  assert.match(builder, /if \(!this\.blockPanelImageRemote\(\)\) \{[\s\S]*pickImageForCurrentNote\(this\.blockPanelPane, true\)/)
  assert.match(builder, /this\.deleteBlockPanelImage\(\)/)
  assert.match(source, /private async pickImageForCurrentNote\([\s\S]*NoteImageService\.importPickedImage/)
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
    MarkdownComplexBlockEdit: complexEditModule.exports,
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

test('21.5 paragraph block link copies the current ID and never creates a missing one', async () => {
  const writes = []
  const notices = []
  let source = 'Paragraph text ^note-1'
  const context = vm.createContext({
    module: { exports: {} },
    MarkdownComplexBlockEdit: complexEditModule.exports,
    pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain',
      getSystemPasteboard: () => ({
        setData: async (data) => writes.push(data)
      }),
      createData: (mimeType, value) => ({ mimeType, value })
    },
    promptAction: { showToast: ({ message }) => notices.push(message) }
  })
  vm.runInContext(copyMethodsCode, context)
  const app = new context.module.exports()
  const anchor = {
    type: 'paragraph', tapType: '', from: 0, to: source.length,
    inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1
  }
  Object.assign(app, {
    blockPanelPane: 'left',
    blockPanelAnchor: anchor,
    blockPanelSourceVaultId: 'vault-a',
    blockPanelSourcePath: 'note.md',
    leftOpenRequestId: 7,
    flushSimplePreviewChanges: async () => '',
    editorBridgeForPane: () => ({
      currentDocumentRevision: 11,
      getContent: async () => source
    }),
    isCurrentBlockSourceTarget: () => true,
    isSameBlockPanelTarget: (current, expected) => current === expected
  })

  await app.loadBlockPanelBlockId()
  assert.equal(app.blockPanelBlockId, 'note-1')
  assert.equal(app.blockPanelBlockIdReady, true)
  await app.copyBlockLink()
  assert.equal(writes.length, 1)
  assert.equal(writes[0].mimeType, 'text/plain')
  assert.equal(writes[0].value, '[[#^note-1]]')
  assert.deepEqual(notices, ['已复制块链接'])

  source = 'Paragraph without ID'
  anchor.to = source.length
  await app.loadBlockPanelBlockId()
  assert.equal(app.blockPanelBlockId, '')
  assert.equal(app.blockPanelBlockIdReady, true)
  await app.copyBlockLink()
  assert.equal(writes.length, 1)
  assert.deepEqual(notices.slice(-1), ['本段尚无块 ID，请先生成 ID'])
})

test('21.5 paragraph block link refuses a stale source range', async () => {
  const writes = []
  const notices = []
  const context = vm.createContext({
    module: { exports: {} },
    MarkdownComplexBlockEdit: complexEditModule.exports,
    pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain',
      getSystemPasteboard: () => ({
        setData: async (data) => writes.push(data)
      }),
      createData: (mimeType, value) => ({ mimeType, value })
    },
    promptAction: { showToast: ({ message }) => notices.push(message) }
  })
  vm.runInContext(copyMethodsCode, context)
  const app = new context.module.exports()
  const anchor = {
    type: 'paragraph', tapType: '', from: 0, to: 14,
    inlineItems: [], inlineIndex: -1, itemFrom: -1, itemTo: -1
  }
  Object.assign(app, {
    blockPanelPane: 'left',
    blockPanelAnchor: anchor,
    blockPanelSourceVaultId: 'vault-a',
    blockPanelSourcePath: 'note.md',
    leftOpenRequestId: 7,
    flushSimplePreviewChanges: async () => '',
    editorBridgeForPane: () => ({
      currentDocumentRevision: 11,
      getContent: async () => 'short'
    }),
    isCurrentBlockSourceTarget: () => true,
    isSameBlockPanelTarget: (current, expected) => current === expected
  })

  await app.copyBlockLink()
  assert.equal(writes.length, 0)
  assert.deepEqual(notices, ['无法读取本段，请重新打开面板'])
})

test('code language badge opens the existing property panel and unknown values are retained', () => {
  const blockIdBuilder = panelSource.slice(blockIdBuilderStart, blockIdBuilderEnd)
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)

  assert.match(blockIdBuilder, /复制块链接/)
  assert.match(blockIdBuilder, /复制指向本段的链接/)
  assert.match(blockIdBuilder, /本操作不会自动生成/)
  assert.match(panelSource, /loadBlockPanelBlockId\(\)/)
  assert.match(panelSource, /MarkdownComplexBlockEdit\.parseBlockId\(raw\)/)
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
  const builder = panelSource.slice(panelBuilderStart, panelBuilderEnd)
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
