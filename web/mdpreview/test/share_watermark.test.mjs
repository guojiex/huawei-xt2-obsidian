import assert from 'node:assert/strict'
import test from 'node:test'
import { appendShareWatermark } from '../src/shareWatermark.mjs'

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
      return { tagName, className: '', textContent: '' }
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

test('rejects a capture document without a rendered note body', () => {
  assert.throws(
    () => appendShareWatermark({ querySelector: () => null }, { createElement() {} }),
    /分享预览内容不可用/
  )
})
