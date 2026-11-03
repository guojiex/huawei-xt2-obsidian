import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import vm from 'node:vm'
import { createRequire } from 'node:module'
import {
  PREVIEW_ZOOM_PRESETS,
  normalizePreviewZoomPercent
} from '../../web/mdpreview/src/previewZoom.mjs'

const repoRoot = new URL('../../', import.meta.url)
const previewSource = fs.readFileSync(new URL('web/mdpreview/src/index.ts', repoRoot), 'utf8')
const previewBridgeSource = fs.readFileSync(new URL('entry/src/main/ets/components/PreviewWebView.ets', repoRoot), 'utf8')
const indexSource = fs.readFileSync(new URL('entry/src/main/ets/pages/Index.ets', repoRoot), 'utf8')
const buildSource = fs.readFileSync(new URL('web/mdpreview/build.mjs', repoRoot), 'utf8')
const generatedPreview = fs.readFileSync(new URL('entry/src/main/resources/rawfile/mdpreview/index.html', repoRoot), 'utf8')

const require = createRequire(new URL('web/mdpreview/package.json', repoRoot))
const { transformSync } = require('esbuild')

test('zoom presets stay within the supported range and invalid values reset to 100%', () => {
  assert.deepEqual(PREVIEW_ZOOM_PRESETS, [50, 75, 100, 125, 150, 175, 200])
  assert.equal(normalizePreviewZoomPercent(49), 50)
  assert.equal(normalizePreviewZoomPercent(125.6), 126)
  assert.equal(normalizePreviewZoomPercent(250), 200)
  assert.equal(normalizePreviewZoomPercent(Number.NaN), 100)
})

test('preview zoom scales only the rendered body and keeps reset hidden at 100%', () => {
  assert.match(buildSource, /#content \.preview-body\s*\{\s*zoom: var\(--preview-scale, 1\);\s*\}/)
  assert.match(buildSource, /id="preview-zoom-controls"[^>]*hidden/)
  assert.match(buildSource, /id="preview-zoom-reset"[^>]*hidden/)
  assert.match(buildSource, /\.preview-zoom button\[hidden\]\s*\{\s*display: none;\s*\}/)
  assert.match(buildSource, /PREVIEW_ZOOM_PRESETS\.map/)
  for (const percent of PREVIEW_ZOOM_PRESETS) {
    assert.match(generatedPreview, new RegExp(`<option value="${percent}"`))
  }
  assert.match(previewSource, /previewZoomReset\.hidden = percent === 100/)
  assert.match(previewSource, /invalidateSourceGeometry\(\)/)
})

test('zoom controls fade during scrolling, remain visible while focused, and can be hidden in edit mode', () => {
  assert.match(buildSource, /\.preview-zoom\.is-scrolling\s*\{\s*opacity: 0; pointer-events: none;\s*\}/)
  assert.match(previewSource, /function schedulePreviewZoomFade\(\): void \{[\s\S]*?previewZoomControlFocused\(\)/)
  assert.match(previewSource, /previewZoomControls\.addEventListener\('focusin'/)
  assert.match(previewSource, /setPreviewZoomControlsVisible\(visible: boolean\): void/)
  assert.match(indexSource, /zoomControlsVisible: this\.experienceMode === 'simple' \|\| !this\.rightEditing/)
  assert.match(indexSource, /zoomControlsVisible: this\.experienceMode === 'simple' \|\| this\.smMode === 'preview'/)
})

test('left and right preview bridges retain independent zoom values across WebView rebinding', async () => {
  const start = previewBridgeSource.indexOf('class PreviewImpl {')
  const end = previewBridgeSource.indexOf('/**\n * 可见的预览 Web 组件', start)
  assert.ok(start >= 0 && end > start)
  const classes = previewBridgeSource.slice(start, end).replace(/^export /gm, '')
  const code = transformSync(`
    function normalizePreviewZoomPercent(percent) {
      if (!Number.isFinite(percent)) return 100;
      return Math.max(50, Math.min(200, Math.round(percent)));
    }
    ${classes}
    module.exports = { PreviewImpl, PreviewBridge };
  `, { loader: 'ts', format: 'cjs' }).code
  const module = { exports: {} }
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    BridgeCodec: { encode: (value) => value, decode: (value) => value },
    hilog: { warn() {} }
  }))
  const { PreviewImpl, PreviewBridge } = module.exports
  const makeImpl = (scripts) => new PreviewImpl({
    runJavaScript(script) {
      scripts.push(script)
      return Promise.resolve('')
    }
  })

  const left = new PreviewBridge()
  const right = new PreviewBridge()
  left.setPreviewZoomPercent(150)
  left.setPreviewZoomControlsVisible(true)
  right.setPreviewZoomPercent(75)

  const firstScripts = []
  const firstImpl = makeImpl(firstScripts)
  left.bind(firstImpl)
  await firstImpl.markReady()
  assert.ok(firstScripts.some((script) => script.includes('setPreviewZoomPercent(150)')))
  assert.ok(firstScripts.some((script) => script.includes('setPreviewZoomControlsVisible(true)')))

  const nextScripts = []
  const nextImpl = makeImpl(nextScripts)
  left.unbind(firstImpl)
  left.rememberPreviewZoomPercent(175)
  left.bind(nextImpl)
  await nextImpl.markReady()
  assert.ok(nextScripts.some((script) => script.includes('setPreviewZoomPercent(175)')))

  const rightScripts = []
  const rightImpl = makeImpl(rightScripts)
  right.bind(rightImpl)
  await rightImpl.markReady()
  assert.ok(rightScripts.some((script) => script.includes('setPreviewZoomPercent(75)')))
})

test('preview-follow geometry uses zoomed DOM bounds in scroll-container coordinates', () => {
  const start = previewSource.indexOf('function measureSourceBlocks(): void {')
  const end = previewSource.indexOf('\nfunction scheduleSourceFollow(): void {', start)
  assert.ok(start >= 0 && end > start)
  const measure = previewSource.slice(start, end)
  const code = transformSync(`
    let sourceBlockGeometry = [];
    let sourceGeometryDirty = true;
    const contentElement = {
      scrollTop: 100,
      getBoundingClientRect: () => ({ top: 8 }),
      querySelectorAll: () => [{
        dataset: { sourceStartLine: '2', sourceEndLine: '5' },
        children: [{
          getBoundingClientRect: () => ({ top: -52, bottom: 48, height: 100 })
        }]
      }]
    };
    ${measure}
    measureSourceBlocks();
    module.exports = { sourceBlockGeometry, sourceGeometryDirty };
  `, { loader: 'ts', format: 'cjs' }).code
  const module = { exports: {} }
  vm.runInContext(code, vm.createContext({ module, exports: module.exports, Number, Math }))
  assert.deepEqual(JSON.parse(JSON.stringify(module.exports.sourceBlockGeometry)), [{
    startLine: 2,
    endLine: 5,
    top: 40,
    height: 100
  }])
  assert.equal(module.exports.sourceGeometryDirty, false)
})
