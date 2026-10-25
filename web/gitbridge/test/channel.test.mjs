import assert from 'node:assert/strict'
import test from 'node:test'
import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'

const source = fileURLToPath(new URL('../src/channel.ts', import.meta.url))
const { outputFiles } = await build({
  entryPoints: [source],
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'browser',
})

const requests = []
let messageListener = () => {}
globalThis.window = {
  __arkts: {
    postMessage(raw) {
      requests.push(JSON.parse(raw))
    },
  },
  addEventListener(name, listener) {
    if (name === 'message') messageListener = listener
  },
}
globalThis.document = {}

const channelUrl = `data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`
const channel = await import(channelUrl)

test('browser rejects non-empty binary requests until WebMessagePort is ready', async () => {
  const before = requests.length
  await assert.rejects(
    channel.request('fs', { dataBytes: new Uint8Array([1]) }),
    /WebMessagePort is not ready/
  )
  assert.equal(requests.length, before)
})

test('browser binary requests use ArrayBuffer chunks capped at 4 MB', async () => {
  const portMessages = []
  const port = {
    onmessage: null,
    started: false,
    postMessage(message) {
      portMessages.push(message)
    },
    start() {
      this.started = true
    },
  }
  messageListener({ ports: [port] })
  assert.equal(port.started, true)
  assert.equal(requests.some((request) => request.type === 'portReady'), true)

  const bytes = new Uint8Array(4 * 1024 * 1024 + 17)
  const response = channel.request('http', { bodyBytes: bytes })
  const request = requests.at(-1)
  assert.equal(request.transfer, 'upload')
  assert.equal(request.transferField, 'bodyBytes')
  assert.equal(request.byteLength, bytes.byteLength)

  port.onmessage({ data: JSON.stringify({ kind: 'uploadReady', id: request.id }) })
  assert.equal(portMessages[0], JSON.stringify({
    kind: 'uploadStart', id: request.id, byteLength: bytes.byteLength,
  }))
  assert.deepEqual(portMessages.slice(1, 3).map((chunk) => chunk.byteLength), [4 * 1024 * 1024, 17])
  assert.equal(portMessages[3], JSON.stringify({ kind: 'uploadEnd', id: request.id }))

  channel.onResult(request.id, true, btoa('{"ok":true}'))
  assert.deepEqual(await response, { ok: true })
})

test('small browser binary requests use the MessagePort transfer path', async () => {
  const portMessages = []
  const port = {
    onmessage: null,
    postMessage(message) {
      portMessages.push(message)
    },
    start() {},
  }
  messageListener({ ports: [port] })

  const bytes = new Uint8Array([0, 1, 127, 255])
  const response = channel.request('http', { bodyBytes: bytes })
  const request = requests.at(-1)
  assert.equal(request.transfer, 'upload')
  assert.equal(request.bodyB64, undefined)
  assert.equal(request.bodyBytes, undefined)

  port.onmessage({ data: JSON.stringify({ kind: 'uploadReady', id: request.id }) })
  assert.equal(portMessages[0], JSON.stringify({
    kind: 'uploadStart', id: request.id, byteLength: bytes.byteLength,
  }))
  assert.deepEqual(Array.from(new Uint8Array(portMessages[1])), Array.from(bytes))
  assert.equal(portMessages[2], JSON.stringify({ kind: 'uploadEnd', id: request.id }))
  channel.onResult(request.id, true, btoa('{"ok":true}'))
  assert.deepEqual(await response, { ok: true })
})

test('small native binary responses reassemble over MessagePort', async () => {
  const portMessages = []
  const port = {
    onmessage: null,
    postMessage(message) {
      portMessages.push(message)
    },
    start() {},
  }
  messageListener({ ports: [port] })

  const response = channel.request('http', { url: 'https://example.invalid/data' })
  const request = requests.at(-1)
  const bytes = new Uint8Array([0, 1, 127, 255])
  const metadata = { status: 200, headers: { 'content-type': 'application/octet-stream' } }
  const metadataB64 = Buffer.from(JSON.stringify(metadata)).toString('base64')

  channel.onTransferResult(request.id, true, metadataB64, 'bodyBytes', bytes.length)
  assert.deepEqual(JSON.parse(portMessages.at(-1)), { kind: 'downloadReady', id: request.id })
  port.onmessage({
    data: JSON.stringify({ kind: 'downloadStart', id: request.id, byteLength: bytes.length }),
  })
  port.onmessage({ data: bytes.buffer })
  port.onmessage({ data: JSON.stringify({ kind: 'downloadEnd', id: request.id }) })
  assert.deepEqual(await response, { ...metadata, bodyBytes: bytes })
})

test('large native binary responses reassemble 4 MB ArrayBuffer chunks', async () => {
  const portMessages = []
  const port = {
    onmessage: null,
    postMessage(message) {
      portMessages.push(message)
    },
    start() {},
  }
  messageListener({ ports: [port] })

  const response = channel.request('http', { url: 'https://example.invalid/data' })
  const request = requests.at(-1)
  const bytes = new Uint8Array(4 * 1024 * 1024 + 17)
  for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251
  const metadata = { status: 200, headers: { 'content-type': 'application/octet-stream' } }
  const metadataB64 = Buffer.from(JSON.stringify(metadata)).toString('base64')

  channel.onTransferResult(request.id, true, metadataB64, 'bodyBytes', bytes.length)
  assert.deepEqual(JSON.parse(portMessages.at(-1)), { kind: 'downloadReady', id: request.id })
  port.onmessage({
    data: JSON.stringify({ kind: 'downloadStart', id: request.id, byteLength: bytes.length }),
  })
  const chunks = [bytes.slice(0, 4 * 1024 * 1024), bytes.slice(4 * 1024 * 1024)]
  assert.deepEqual(chunks.map((chunk) => chunk.byteLength), [4 * 1024 * 1024, 17])
  for (const chunk of chunks) port.onmessage({ data: chunk.buffer })
  port.onmessage({ data: JSON.stringify({ kind: 'downloadEnd', id: request.id }) })

  assert.deepEqual(await response, { ...metadata, bodyBytes: bytes })
})
