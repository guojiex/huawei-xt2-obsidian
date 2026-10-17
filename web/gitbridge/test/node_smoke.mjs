// 用 node 伪造一个「ArkTS 后端」，把打包好的 gitbridge 真跑一遍 clone。
// 目的：在没有真机的情况下验证 fsBridge 的写缓冲/缓存逻辑、httpBridge 的请求形状、
// 以及 isomorphic-git 的调用参数是否正确。这是本机能做到的最强验证。
//
// 运行：npm run smoke

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../../..')
const htmlPath = path.join(
  repoRoot,
  'entry/src/main/resources/rawfile/gitbridge/index.html'
)

const REPO = process.env.SMOKE_REPO || 'https://github.com/octocat/Hello-World'
const BRANCH = process.env.SMOKE_BRANCH || 'master'
const TOKEN = process.env.SMOKE_TOKEN || ''

// ---------- 伪造的「ArkTS 后端」 ----------
const sandboxRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'gitbridge-smoke-'))
const vaultDir = path.join(sandboxRoot, 'vault')
// 注意别用 mkdtempSync 建 vault：它会追加随机后缀并返回新路径
fs.mkdirSync(vaultDir, { recursive: true })

let lastEvent = null
const events = []

function b64FromBytes(bytes) {
  return Buffer.from(bytes).toString('base64')
}
function bytesFromB64(s) {
  return new Uint8Array(Buffer.from(s, 'base64'))
}
function b64FromJson(v) {
  return Buffer.from(JSON.stringify(v), 'utf8').toString('base64')
}

function resolveSafe(rel) {
  if (!rel) return vaultDir
  const abs = path.resolve(vaultDir, rel)
  if (!abs.startsWith(vaultDir)) {
    throw new Error('EACCES: path escapes vault root')
  }
  return abs
}

function ensureParent(abs) {
  fs.mkdirSync(path.dirname(abs), { recursive: true })
}

function fsCall(msg) {
  const rel = msg.pathB64 ? Buffer.from(msg.pathB64, 'base64').toString('utf8') : ''
  if (process.env.SMOKE_TRACE) {
    process.stdout.write(`  FS ${msg.op} "${rel}"\n`)
  }
  switch (msg.op) {
    case 'read': {
      const buf = fs.readFileSync(resolveSafe(rel))
      return { dataB64: b64FromBytes(buf) }
    }
    case 'write': {
      const abs = resolveSafe(rel)
      ensureParent(abs)
      fs.writeFileSync(abs, bytesFromB64(msg.dataB64))
      return { ok: true }
    }
    case 'mkdir': {
      fs.mkdirSync(resolveSafe(rel), { recursive: true })
      return { ok: true }
    }
    case 'unlink': {
      // 幂等：isomorphic-git 结束时会 unlink 未必存在的 .git/shallow
      const abs = resolveSafe(rel)
      if (fs.existsSync(abs)) {
        fs.unlinkSync(abs)
      }
      return { ok: true }
    }
    case 'rmdir': {
      fs.rmSync(resolveSafe(rel), { recursive: true, force: true })
      return { ok: true }
    }
    case 'rename': {
      const to = Buffer.from(msg.newPathB64, 'base64').toString('utf8')
      fs.renameSync(resolveSafe(rel), resolveSafe(to))
      return { ok: true }
    }
    case 'readdir': {
      return { entries: fs.readdirSync(resolveSafe(rel)) }
    }
    case 'stat': {
      const st = fs.statSync(resolveSafe(rel))
      return { type: st.isDirectory() ? 'dir' : 'file', size: st.size }
    }
    case 'batch': {
      for (const op of msg.ops || []) {
        fsCall(op)
      }
      return { ok: true }
    }
    default:
      throw new Error(`ENOSYS: unsupported fs op ${msg.op}`)
  }
}

async function httpCall(msg) {
  const res = await fetch(msg.url, {
    method: msg.method || 'GET',
    headers: msg.headers || {},
    body: msg.bodyB64 ? Buffer.from(msg.bodyB64, 'base64') : undefined,
  })
  const buf = new Uint8Array(await res.arrayBuffer())
  console.log(
    `  HTTP ${msg.method || 'GET'} ${msg.url} -> ${res.status} ${buf.length}B`
  )
  return {
    url: res.url,
    method: msg.method || 'GET',
    headers: Object.fromEntries(res.headers.entries()),
    bodyB64: b64FromBytes(buf),
    status: res.status,
    statusMessage: res.statusText,
  }
}

async function handleFromArkts(json) {
  const msg = JSON.parse(json)
  if (msg.type === 'event') {
    events.push(msg)
    lastEvent = msg
    if (msg.name === 'progress') {
      process.stdout.write(
        `  progress ${msg.phase} ${msg.loaded}/${msg.total}\n`
      )
    }
    return
  }
  try {
    const payload =
      msg.type === 'fs' ? fsCall(msg) : msg.type === 'http' ? await httpCall(msg) : {}
    window.__gitBridge.onResult(msg.id, true, b64FromJson(payload))
  } catch (e) {
    const code = e.code ? `${e.code}: ` : ''
    window.__gitBridge.onResult(msg.id, false, b64FromJson(`${code}${e.message}`))
  }
}

globalThis.window = {
  __arkts: {
    postMessage(json) {
      // 同步入口，内部允许异步完成
      void handleFromArkts(json)
    },
  },
  addEventListener() {},
}

// ---------- 加载打包产物 ----------
const html = fs.readFileSync(htmlPath, 'utf8')
const m = /<script>([\s\S]*?)<\/script>/.exec(html)
if (!m) {
  console.error('未能在 index.html 中找到内联脚本')
  process.exit(1)
}
new Function(m[1])()

// ---------- 执行 clone ----------
const bridge = globalThis.window.GitBridge
if (!bridge) {
  console.error('GitBridge 未挂载')
  process.exit(1)
}

console.log(`repo    : ${REPO}`)
console.log(`branch  : ${BRANCH}`)
console.log(`vault   : ${vaultDir}`)

await bridge.init(b64FromJson({ gitDir: '/vault', token: TOKEN }))
await bridge.clone(b64FromJson({ url: REPO, branch: BRANCH, token: TOKEN }))

// 等待 cloneResult 事件
const deadline = Date.now() + 120000
while (Date.now() < deadline) {
  if (events.some((e) => e.name === 'cloneResult')) break
  await new Promise((r) => setTimeout(r, 200))
}

const result = events.find((e) => e.name === 'cloneResult')
if (!result) {
  console.error('超时：未收到 cloneResult 事件')
  process.exit(1)
}

if (!result.ok) {
  console.error(`clone 失败：${result.message}`)
  process.exit(1)
}

const files = fs.readdirSync(vaultDir)
console.log(`\nclone 成功，vault 顶层：${files.join(', ')}`)
const gitDirExists = fs.existsSync(path.join(vaultDir, '.git'))
console.log(`.git 目录：${gitDirExists ? '存在' : '缺失'}`)
if (!gitDirExists) {
  process.exit(1)
}
console.log('smoke 通过')
