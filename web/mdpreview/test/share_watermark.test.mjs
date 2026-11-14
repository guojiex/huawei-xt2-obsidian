import assert from 'node:assert/strict'
import test from 'node:test'
import {
  appendShareWatermark,
  prepareShareWatermarkForPdfCapture,
  setShareWatermarkVisibleAtScroll
} from '../src/shareWatermark.mjs'

function createElement() {
  return {
    tagName: 'footer',
    className: '',
    textContent: '',
    style: {},
    removeAttribute() {
      this.style = {}
    }
  }
}

function captureDocument() {
  const children = []
  const body = {
    querySelector(selector) {
      return selector === '.share-watermark'
        ? children.find((child) => child.className === 'share-watermark') ?? null
        : null
    },
    appendChild(child) {
      children.push(child)
    }
  }
  const content = {
    querySelector(selector) {
      return selector === '.preview-body' ? body : null
    }
  }
  const documentRef = {
    createElement(tagName) {
      const element = createElement()
      element.tagName = tagName
      return element
    }
  }
  return { body, content, children, documentRef }
}

test('appends one branded footer after the rendered note body', () => {
  const capture = captureDocument()

  assert.equal(appendShareWatermark(capture.content, capture.documentRef), true)
  assert.equal(capture.children.length, 1)
  assert.equal(capture.children[0].tagName, 'footer')
  assert.equal(capture.children[0].className, 'share-watermark')
  assert.equal(capture.children[0].textContent, '曜石笔记')
})

test('does not duplicate the watermark when capture preparation is repeated', () => {
  const capture = captureDocument()

  appendShareWatermark(capture.content, capture.documentRef)
  assert.equal(appendShareWatermark(capture.content, capture.documentRef), false)
  assert.equal(capture.children.length, 1)
})

test('reused watermark drops pdf badge inline styles back to in-flow (53.13)', () => {
  const capture = captureDocument()

  appendShareWatermark(capture.content, capture.documentRef)
  const badge = prepareShareWatermarkForPdfCapture(capture.body)
  assert.equal(badge.style.position, 'fixed')
  assert.equal(appendShareWatermark(capture.content, capture.documentRef), false)
  assert.deepEqual(capture.children[0].style, {})
})

test('rejects a capture document without a rendered note body', () => {
  assert.throws(
    () => appendShareWatermark({ querySelector: () => null }, { createElement() {} }),
    /分享预览内容不可用/
  )
})

test('prepareShareWatermarkForPdfCapture converts the footer to a hidden fixed badge (53.13)', () => {
  const capture = captureDocument()
  appendShareWatermark(capture.content, capture.documentRef)

  const badge = prepareShareWatermarkForPdfCapture(capture.body)
  assert.equal(badge, capture.children[0])
  assert.equal(badge.style.position, 'fixed')
  assert.equal(badge.style.right, '0')
  assert.equal(badge.style.bottom, '0')
  assert.equal(badge.style.display, 'none')
  assert.equal(badge.style.borderTop, 'none')
  assert.equal(badge.style.padding, 'var(--s2)')
})

test('prepareShareWatermarkForPdfCapture returns null without a watermark', () => {
  const capture = captureDocument()
  assert.equal(prepareShareWatermarkForPdfCapture(capture.body), null)
})

test('setShareWatermarkVisibleAtScroll shows the badge only on the last page (53.13)', () => {
  const capture = captureDocument()
  appendShareWatermark(capture.content, capture.documentRef)
  const badge = prepareShareWatermarkForPdfCapture(capture.body)

  setShareWatermarkVisibleAtScroll(badge, 0, 587)
  assert.equal(badge.style.display, 'none')
  setShareWatermarkVisibleAtScroll(badge, 587, 587)
  assert.equal(badge.style.display, '')
  setShareWatermarkVisibleAtScroll(badge, 585, 587)
  assert.equal(badge.style.display, 'none')
})

test('setShareWatermarkVisibleAtScroll tolerates a missing badge', () => {
  assert.doesNotThrow(() => setShareWatermarkVisibleAtScroll(null, 0, 100))
})
