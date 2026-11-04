import assert from 'node:assert/strict'
import test from 'node:test'
import { serializeCalloutBody } from '../src/calloutEdit.mjs'

test('callout body edits preserve the header and quote each new paragraph line', () => {
  const source = '> [!note] Title\n> old body\n> next line\n'
  assert.equal(
    serializeCalloutBody(source, 'new body\n\nsecond paragraph'),
    '> [!note] Title\n> new body\n> \n> second paragraph\n'
  )
})

test('callout body edits preserve CRLF and nested quote markers', () => {
  const source = '> [!warning]- Title\r\n> > old body\r\n'
  assert.equal(
    serializeCalloutBody(source, '> nested body\n'),
    '> [!warning]- Title\r\n> > nested body\r\n'
  )
})

test('an empty callout body keeps the header and original trailing line ending', () => {
  assert.equal(serializeCalloutBody('> [!tip]\n> old\n', ''), '> [!tip]\n')
})

test('a new first body line uses the callout quote prefix and source line ending', () => {
  assert.equal(serializeCalloutBody('  > [!info]+', 'body'), '  > [!info]+\n  > body')
  assert.equal(serializeCalloutBody('\uFEFF> [!info]', 'body'), '\uFEFF> [!info]\n> body')
})
