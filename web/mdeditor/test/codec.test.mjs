import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  entryPoints: [path.resolve(here, '../../shared/codec.ts')],
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const bundledCodec = result.outputFiles[0].text
const codec = await import(
  `data:text/javascript;base64,${Buffer.from(bundledCodec).toString('base64')}`
)

test('encodes and decodes an empty string', () => {
  assert.equal(codec.encodeUtf8ToBase64(''), '')
  assert.equal(codec.decodeBase64ToUtf8(''), '')
})

test('encodes and decodes ASCII text', () => {
  assert.equal(codec.encodeUtf8ToBase64('Hello, world!'), 'SGVsbG8sIHdvcmxkIQ==')
  assert.equal(codec.decodeBase64ToUtf8('SGVsbG8sIHdvcmxkIQ=='), 'Hello, world!')
})

test('encodes and decodes Chinese text', () => {
  assert.equal(codec.encodeUtf8ToBase64('你好，世界'), '5L2g5aW977yM5LiW55WM')
  assert.equal(codec.decodeBase64ToUtf8('5L2g5aW977yM5LiW55WM'), '你好，世界')
})

test('round-trips mixed Unicode and newlines', () => {
  const text = '标题 😀\n第二行 é'
  assert.equal(codec.decodeBase64ToUtf8(codec.encodeUtf8ToBase64(text)), text)
})
