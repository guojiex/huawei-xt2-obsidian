import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  stdin: {
    contents: "export { preservedScrollTop } from '../src/scrollAnchor.ts'",
    resolveDir: here,
    sourcefile: 'scroll_anchor_test_entry.ts',
    loader: 'ts'
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const scrollAnchor = await import(
  `data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`
)

test('keeps the same source anchor at the same viewport offset after reflow', () => {
  const savedViewportY = 150 - 100
  const currentScrollTop = 300
  const nextDocumentTop = 750
  const currentScreenTop = 100 + nextDocumentTop - currentScrollTop
  const nextScrollTop = scrollAnchor.preservedScrollTop(
    currentScrollTop,
    currentScreenTop,
    100,
    savedViewportY,
    2000,
    800
  )
  assert.equal(nextScrollTop, 700)
  assert.equal(100 + nextDocumentTop - nextScrollTop - 100, savedViewportY)
})

test('clamps at a shorter viewport range without changing the saved anchor', () => {
  const anchor = { offset: 180, viewportY: 36 }
  const wideScrollTop = scrollAnchor.preservedScrollTop(800, 1200, 0, anchor.viewportY, 1000, 800)
  assert.equal(wideScrollTop, 200)
  assert.deepEqual(anchor, { offset: 180, viewportY: 36 })
})

test('restores the original source position after an intermediate layout clamps scrolling', () => {
  const savedViewportY = 150 - 100
  const clampedScrollTop = scrollAnchor.preservedScrollTop(
    300,
    100 + 750 - 300,
    100,
    savedViewportY,
    1250,
    800
  )
  assert.equal(clampedScrollTop, 450)

  const returnedScrollTop = scrollAnchor.preservedScrollTop(
    clampedScrollTop,
    100 + 350 - clampedScrollTop,
    100,
    savedViewportY,
    2000,
    800
  )
  assert.equal(returnedScrollTop, 300)
})

test('returns zero when content fits and never returns a negative offset', () => {
  assert.equal(scrollAnchor.preservedScrollTop(0, 0, 0, 24, 300, 500), 0)
  assert.equal(scrollAnchor.preservedScrollTop(5, 0, 100, 24, 1000, 500), 0)
})
