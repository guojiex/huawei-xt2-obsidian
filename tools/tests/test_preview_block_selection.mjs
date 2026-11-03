import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const root = new URL('../../', import.meta.url)
const previewSource = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
const previewComponentSource = fs.readFileSync(
  new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8'
)
const indexSource = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', root), 'utf8')
const buildSource = fs.readFileSync(new URL('web/mdpreview/build.mjs', root), 'utf8')
const generatedPreview = fs.readFileSync(
  new URL('entry/src/main/resources/rawfile/mdpreview/index.html', root), 'utf8'
)

test('selection feedback outlines locked rendered children using v2 tokens', () => {
  assert.match(previewSource, /selectedLockedBlocks\(lockedBlocks, selection, sourceBlockForNode\)/)
  assert.match(previewSource, /block\.classList\.add\('simple-block-active'\)/)
  assert.match(buildSource, /#content \.preview-source-block\.simple-block-active > \*[\s\S]*?outline: var\(--stroke\) solid var\(--blue\)/)
  assert.ok(generatedPreview.includes(
    '#content .preview-source-block.simple-block-active > * {\n' +
    '    outline: var(--stroke) solid var(--blue); outline-offset: var(--stroke);'
  ))
})

test('preview WebView suppresses the system focus box around the whole note', () => {
  const webStart = previewComponentSource.indexOf("Web({ src: $rawfile('mdpreview/index.html'")
  const webEnd = previewComponentSource.indexOf('\n\n      if (!this.pageReady)', webStart)
  assert.ok(webStart >= 0 && webEnd > webStart)
  assert.match(previewComponentSource.slice(webStart, webEnd),
    /\.focusBox\(\{\s*strokeWidth: LengthMetrics\.vp\(0\)\s*\}\)/)
})

test('locked block taps route links and images without synthesizing a block selection', () => {
  const clickStart = previewSource.indexOf("contentElement.addEventListener('click', (event: MouseEvent): void => {")
  const clickEnd = previewSource.indexOf('\n\nasync function renderMermaidBlocks', clickStart)
  assert.ok(clickStart >= 0 && clickEnd > clickStart)
  const handler = previewSource.slice(clickStart, clickEnd)

  assert.doesNotMatch(handler, /setActiveLockedBlocks\(/)
  assert.match(handler, /event\.target\.closest\('input, button'\)\) return/)
  assert.match(handler, /anchor\.tapType = 'image'/)
  assert.match(handler, /anchor\.tapType = href\.indexOf\('#wikilink:'\) === 0 \? 'wikilink' : 'link'/)
  assert.match(handler, /event\.preventDefault\(\)/)
  assert.match(handler, /onLockedContentTap\(tapPayload\)/)
  assert.match(previewSource, /function activateLockedContent\(from: number, to: number\): void/)
  assert.match(previewSource, /replayingLockedTap = true/)
  assert.match(previewSource, /if \(!editable\) openImage\(img\)/)
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
