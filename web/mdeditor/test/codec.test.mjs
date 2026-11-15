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
  const text = '标题 😀\n第二行 é'
  assert.equal(codec.decodeBase64ToUtf8(codec.encodeUtf8ToBase64(text)), text)
})

// 2026-11-15 BOM 误报修复：解码必须无损保留开头 U+FEFF（ignoreBOM:true）。
// 回归背景：模拟器真实笔记带 UTF-8 BOM（Windows 工具产物），默认 TextDecoder
// 吞掉 BOM 后编辑器比基线少 1 字符且无脏标，误触发「内容不一致」恢复弹窗。
test('keeps a leading UTF-8 BOM when decoding (EF BB BF 23)', () => {
  assert.equal(codec.decodeBase64ToUtf8('77u/Iw=='), '\uFEFF#')
})

test('round-trips a BOM-prefixed note', () => {
  const text = '\uFEFF# 带签名的笔记\n正文'
  assert.equal(codec.decodeBase64ToUtf8(codec.encodeUtf8ToBase64(text)), text)
})
