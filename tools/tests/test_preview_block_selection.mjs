import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const root = new URL('../../', import.meta.url)
const previewSource = fs.readFileSync(new URL('web/mdpreview/src/index.ts', root), 'utf8')
const previewComponentSource = fs.readFileSync(
  new URL('entry/src/main/ets/components/PreviewWebView.ets', root), 'utf8'
)
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

test('locked block clicks keep existing link, image, and checkbox behavior', () => {
  const clickStart = previewSource.indexOf("contentElement.addEventListener('click', (event: MouseEvent): void => {")
  const clickEnd = previewSource.indexOf('\n\nasync function renderMermaidBlocks', clickStart)
  assert.ok(clickStart >= 0 && clickEnd > clickStart)
  const handler = previewSource.slice(clickStart, clickEnd)

  assert.match(handler, /setActiveLockedBlocks\(contentElement, lockedBlock \? \[lockedBlock\] : \[\]\)/)
  assert.match(handler, /event\.target\.closest\('a, input, img, button'\)\) return/)
  assert.match(handler, /onLockedContentTap\(\)/)
  assert.doesNotMatch(handler, /preventDefault\(\)/)
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
