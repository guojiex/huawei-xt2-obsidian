import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')
const vm = require('node:vm')
const previewSource = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
const previewComponentSource = fs.readFileSync(
  new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8'
)
const indexSource = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
const buildSource = fs.readFileSync(new URL('web/mdpreview/build.mjs', root), 'utf8')
const generatedPreview = fs.readFileSync(
  new URL('entry/src/main/resources/rawfile/mdpreview/index.html', root), 'utf8'
)

function loadFunction(source, startMarker, endMarker, name, isExported = false) {
  const start = source.indexOf(startMarker)
  const end = source.indexOf(endMarker, start)
  assert.ok(start >= 0 && end > start)
  const body = source.slice(start, end).replace(isExported ? 'export function' : 'function', 'function')
  const context = vm.createContext({ module: { exports: {} } })
  const code = transformSync(`${body}\nmodule.exports = ${name};`, {
    loader: 'ts',
    format: 'cjs'
  }).code
  vm.runInContext(code, context)
  return { fn: context.module.exports, context }
}

test('selection feedback outlines locked rendered children using v2 tokens', () => {
  assert.match(previewSource, /selectedLockedBlocks\(lockedBlocks, selection, sourceBlockForNode\)/)
  assert.match(previewSource, /block\.classList\.add\('simple-block-active'\)/)
  assert.match(buildSource, /#content \.preview-source-block\.simple-block-active > \*[\s\S]*?outline: var\(--stroke\) solid var\(--blue\)/)
  assert.ok(generatedPreview.includes(
    '#content .preview-source-block.simple-block-active > * {\n' +
    '    outline: var(--stroke) solid var(--blue); outline-offset: var(--stroke);'
  ))
})

test('focused preview scroll area suppresses its default outline, not block outlines', () => {
  assert.match(buildSource, /#content:focus\s*\{\s*outline:\s*none;\s*\}/)
  assert.ok(generatedPreview.includes('#content:focus { outline: none; }'))
  assert.doesNotMatch(previewComponentSource, /\.focusBox\(/)
})

test('locked block taps route links and images without synthesizing a block selection', () => {
  const clickStart = previewSource.indexOf("contentElement.addEventListener('click', (event: MouseEvent): void => {")
  const clickEnd = previewSource.indexOf('\n\nasync function renderMermaidBlocks', clickStart)
  assert.ok(clickStart >= 0 && clickEnd > clickStart)
  const handler = previewSource.slice(clickStart, clickEnd)

  assert.doesNotMatch(handler, /setActiveLockedBlocks\(/)
  assert.match(handler, /event\.target\.closest\('input, button'\)\) return/)
  assert.match(handler, /if \(lockedBlock && payload\.length > 0 && inlineTarget\)/)
  assert.doesNotMatch(handler, /anchor\.tapType = href\.indexOf/)
  assert.doesNotMatch(handler, /anchor\.tapType = 'image'/)
  assert.match(handler, /anchor\.inlineIndex = Number\(inlineTarget\.dataset\.previewInlineIndex\)/)
  assert.match(handler, /event\.preventDefault\(\)/)
  assert.match(handler, /onLockedContentTap\(tapPayload\)/)
  assert.match(previewSource, /function activateLockedContent\(from: number, to: number, inlineIndex: number = -1\): void/)
  assert.match(previewSource, /if \(Number\(item\.dataset\.previewInlineIndex\) === inlineIndex\)/)
  assert.match(previewSource, /replayingLockedTap = true/)
  assert.match(previewSource, /if \(!editable\) openImage\(img\)/)
})

test('preview anchor bridge accepts exact inline identities and rejects invalid ranges', () => {
  const { fn: mapAnchor } = loadFunction(
    previewComponentSource,
    'export function mapPreviewBlockAnchor',
    '\ninterface CaptureWaiter',
    'mapPreviewBlockAnchor',
    true
  )
  const payload = {
    type: 'paragraph',
    from: 10,
    to: 80,
    inlineItems: [{ index: 0, type: 'link', from: 18, to: 35 }],
    inlineIndex: 0,
    tapType: 'link',
    itemFrom: 18,
    itemTo: 35,
    left: 20,
    top: 30,
    width: 100,
    height: 40,
    viewportWidth: 400,
    viewportHeight: 600
  }
  const anchor = mapAnchor(JSON.stringify(payload), [5, 7, 800, 1200])

  assert.deepEqual(JSON.parse(JSON.stringify(anchor.inlineItems)), [
    { index: 0, type: 'link', from: 18, to: 35 }
  ])
  assert.equal(anchor.inlineIndex, 0)
  assert.equal(anchor.itemFrom, 18)
  assert.equal(anchor.itemTo, 35)
  assert.equal(anchor.x, 45)

  const invalid = mapAnchor(JSON.stringify({
    ...payload,
    inlineItems: [{ index: 0, type: 'link', from: 9, to: 35 }]
  }), [5, 7, 800, 1200])
  assert.deepEqual(JSON.parse(JSON.stringify(invalid.inlineItems)), [])
  assert.equal(invalid.inlineIndex, -1)
  assert.equal(invalid.tapType, '')
})

test('rendered inline nodes receive metadata only after every item maps', () => {
  const { fn: annotate } = loadFunction(
    previewSource,
    'function annotateInlineItems',
    '\nfunction setActiveLockedBlocks',
    'annotateInlineItems'
  )
  const makeNode = (href = '') => ({
    dataset: {},
    closest: () => null,
    getAttribute: (name) => name === 'href' ? href : null
  })
  const link = makeNode('https://example.test')
  const wikiLink = makeNode('#wikilink:opaque')
  const code = makeNode()
  const math = makeNode()
  const block = {
    dataset: {},
    querySelectorAll(selector) {
      if (selector === 'a') return [link, wikiLink]
      if (selector === 'img') return []
      if (selector === 'code') return [code]
      if (selector === '.katex') return [math]
      return []
    }
  }
  const items = [
    { index: 0, type: 'link', from: 2, to: 12 },
    { index: 1, type: 'link', from: 20, to: 35 },
    { index: 2, type: 'inlinecode', from: 40, to: 47 },
    { index: 3, type: 'mathInline', from: 50, to: 53 }
  ]

  annotate(block, { inlineSafe: true, inlineItems: items })
  assert.equal(block.dataset.inlineItemsReady, 'true')
  assert.equal(link.dataset.previewInlineIndex, '0')
  assert.equal(wikiLink.dataset.previewInlineType, 'wikilink')
  assert.equal(code.dataset.previewInlineFrom, '40')
  assert.equal(math.dataset.previewInlineTo, '53')

  const mismatchedBlock = {
    dataset: {},
    querySelectorAll(selector) {
      if (selector === 'a') return [makeNode()]
      return []
    }
  }
  annotate(mismatchedBlock, { inlineSafe: true, inlineItems: items.slice(0, 2) })
  assert.equal(mismatchedBlock.dataset.inlineItemsReady, 'false')
  assert.equal(mismatchedBlock.querySelectorAll('a')[0].dataset.previewInlineIndex, undefined)
})

test('protected paragraphs show prototype-aligned hints for supported and unsupported syntax', () => {
  const { fn: configure, context } = loadFunction(
    previewSource,
    'function configureEditableBlocks(root: HTMLElement, bodyOffset: number): void {',
    '\nfunction replaceSourceBlock',
    'configureEditableBlocks'
  )
  context.editable = true
  context.setActiveLockedBlocks = () => {}
  context.publishLockedBlockAnchor = () => {}
  context.containsLockedSyntax = () => true
  context.editableElementFor = (block) => block.paragraph
  context.sourceText = ''

  const makeRoot = (inlineItemsReady) => {
    const paragraph = { tagName: 'P', dataset: {}, setAttribute() {}, removeAttribute() {} }
    const block = {
      dataset: { sourceType: 'paragraph', inlineItemsReady },
      paragraph,
      setAttribute() {},
      removeAttribute() {}
    }
    return {
      paragraph,
      root: {
        querySelectorAll(selector) {
          return selector === '.preview-source-block' ? [block] : []
        },
        querySelector(selector) {
          return selector === '.preview-source-block' ? block : null
        }
      }
    }
  }

  const supported = makeRoot('true')
  configure(supported.root, 0)
  assert.equal(supported.paragraph.dataset.simpleModeHint, 'inline-items')

  const unsupported = makeRoot('false')
  configure(unsupported.root, 0)
  assert.equal(unsupported.paragraph.dataset.simpleModeHint, 'unsupported')
})

test('generated preview uses the same protected-paragraph copy and v2 visual tokens', () => {
  assert.match(buildSource, /data-simple-mode-hint="inline-items"[\s\S]*?content: '含链接、代码或公式 · 点按逐项编辑'/)
  assert.match(buildSource, /data-simple-mode-hint="unsupported"[\s\S]*?content: '此内容请在专业模式编辑'/)
  assert.match(buildSource, /margin-top: var\(--s1\); color: var\(--muted\)/)
  assert.ok(generatedPreview.includes('含链接、代码或公式 · 点按逐项编辑'))
  assert.ok(generatedPreview.includes('此内容请在专业模式编辑'))
  assert.ok(generatedPreview.includes('font-size: var(--caption); line-height: var(--leading);'))
})

test('replaying a paragraph action activates only the selected repeated inline item', () => {
  const first = { dataset: { previewInlineIndex: '0' }, tagName: 'A', clicks: 0, click() { this.clicks++ } }
  const second = { dataset: { previewInlineIndex: '1' }, tagName: 'A', clicks: 0, click() { this.clicks++ } }
  const block = {
    dataset: { sourceFrom: '10', sourceTo: '80' },
    querySelectorAll: () => [first, second]
  }
  const contentElement = { querySelectorAll: () => [block] }
  const { fn: activate, context } = loadFunction(
    previewSource,
    'function activateLockedContent',
    '\nfunction configureEditableBlocks',
    'activateLockedContent'
  )
  context.contentElement = contentElement
  context.lastLockedTapTarget = null
  context.replayingLockedTap = false
  context.openImage = () => {}

  activate(10, 80, 1)
  assert.equal(first.clicks, 0)
  assert.equal(second.clicks, 1)
  assert.equal(context.replayingLockedTap, false)
})

test('changing preview content or leaving simple mode clears stale block outlines', () => {
  const configureStart = previewSource.indexOf('function configureEditableBlocks(root: HTMLElement, bodyOffset: number): void {')
  const configureEnd = previewSource.indexOf('\nfunction replaceSourceBlock', configureStart)
  assert.ok(configureStart >= 0 && configureEnd > configureStart)
  assert.match(previewSource.slice(configureStart, configureEnd), /setActiveLockedBlocks\(root, \[\]\)/)
})

test('clearing the browser selection removes stale block outlines', () => {
  const handlerStart = previewSource.indexOf("document.addEventListener('selectionchange', (): void => {")
  const handlerEnd = previewSource.indexOf("\n\ncontentElement.addEventListener('click'", handlerStart)
  assert.ok(handlerStart >= 0 && handlerEnd > handlerStart)
  const handler = previewSource.slice(handlerStart, handlerEnd)

  assert.match(handler, /if \(!selection \|\| selection\.rangeCount === 0\) \{\s*setActiveLockedBlocks\(contentElement, \[\]\)\s*publishLockedBlockAnchor\(null\)\s*return\s*\}/)
  assert.match(generatedPreview, /if\(!\w+\|\|\w+\.rangeCount===0\)\{\w+\(\w+,\[\]\)[;,]\w+\(null\);return\}/)
})

test('block anchor geometry is published through the parent preview bridge', () => {
  assert.match(previewComponentSource, /onBlockAnchorChange: \(anchor: PreviewBlockAnchor \| null\)/)
  assert.match(previewComponentSource, /this\.bridge\.onBlockAnchorChange\(mapPreviewBlockAnchor\(/)
  assert.doesNotMatch(previewComponentSource, /this\.onBlockAnchorChange\(/)
})

test('generated preview rawfile contains the tap action API', () => {
  assert.match(generatedPreview, /isLockedTapActivation/)
  assert.match(generatedPreview, /activateLockedContent/)
})

test('workspace keeps left and right preview block anchors independent', () => {
  const handlerStart = indexSource.indexOf('  private onBlockAnchorChange(pane: string, anchor: PreviewBlockAnchor | null): void {')
  const handlerEnd = indexSource.indexOf('\n  private recordBlockToolbarPaneArea(', handlerStart)
  assert.ok(handlerStart >= 0 && handlerEnd > handlerStart)
  assert.match(indexSource, /@State leftBlockAnchor: PreviewBlockAnchor \| null = null/)
  assert.match(indexSource, /@State rightBlockAnchor: PreviewBlockAnchor \| null = null/)
  assert.match(indexSource,
    /this\.previewBridge\.onBlockAnchorChange = \(anchor: PreviewBlockAnchor \| null\): void => \{\s*this\.onBlockAnchorChange\('left', anchor\);/)
  assert.match(indexSource,
    /this\.rightPreviewBridge\.onBlockAnchorChange = \(anchor: PreviewBlockAnchor \| null\): void => \{\s*this\.onBlockAnchorChange\('right', anchor\);/)
  assert.match(indexSource.slice(handlerStart, handlerEnd),
    /private onBlockAnchorChange\(pane: string, anchor: PreviewBlockAnchor \| null\): void \{[\s\S]*?if \(pane === 'right'\) \{\s*this\.rightBlockAnchor = anchor;\s*\} else \{\s*this\.leftBlockAnchor = anchor;/)
  assert.doesNotMatch(indexSource, /shareCaptureBridge\.onBlockAnchorChange/)
})
