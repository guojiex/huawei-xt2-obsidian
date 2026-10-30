import { spawnSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const port = Number.parseInt(process.env.GIT2_FIXTURE_PORT ?? '19439', 10)
const username = 'fixture-user'
const password = 'fixture-password'
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'git2-napi-fixture-'))
const work = path.join(root, 'work')
const repositories = path.join(root, 'repositories')
const bare = path.join(repositories, 'fixture.git')
const image = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x80, 0x01, 0x42, 0x00, 0x7f, 0xfe])
const gitBinary = Buffer.from([0x00, 0xff, 0x7f, 0xc3, 0x28, 0x80])
let server

function runGit(args) {
  const result = spawnSync('git', args, { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`git fixture setup failed (${args[0]} ${args[1] ?? ''})`)
  }
}

function parseResponse(raw) {
  let boundary = raw.indexOf(Buffer.from('\r\n\r\n'))
  let separatorLength = 4
  if (boundary < 0) {
    boundary = raw.indexOf(Buffer.from('\n\n'))
    separatorLength = 2
  }
  if (boundary < 0) throw new Error('Git CGI response has no header boundary')
  const headers = {}
  let statusCode = 200
  for (const line of raw.subarray(0, boundary).toString('latin1').split(/\r?\n/)) {
    const colon = line.indexOf(':')
    if (colon < 0) continue
    const key = line.slice(0, colon).trim()
    const value = line.slice(colon + 1).trim()
    if (key.toLowerCase() === 'status') statusCode = Number.parseInt(value, 10) || 200
    else headers[key] = value
  }
  return { statusCode, headers, body: raw.subarray(boundary + separatorLength) }
}

function handleGitRequest(request, response) {
  const url = new URL(request.url, 'http://127.0.0.1')
  const expected = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`
  if (request.method === 'GET' && url.pathname === '/__fixture/pack-sha256') {
    const packName = fs.readdirSync(path.join(bare, 'objects', 'pack'))
      .find((name) => name.endsWith('.pack'))
    if (!packName) {
      response.writeHead(500).end()
      return
    }
    const pack = fs.readFileSync(path.join(bare, 'objects', 'pack', packName))
    response.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
    response.end(createHash('sha256').update(pack).digest('hex'))
    return
  }

  if (request.headers.authorization !== expected) {
    response.writeHead(401, { 'WWW-Authenticate': 'Basic realm="git2-fixture"' })
    response.end()
    return
  }

  const chunks = []
  request.on('data', (chunk) => chunks.push(chunk))
  request.on('end', () => {
    const body = Buffer.concat(chunks)
    setTimeout(() => {
      const env = {
        ...process.env,
        GATEWAY_INTERFACE: 'CGI/1.1',
        GIT_PROJECT_ROOT: repositories,
        GIT_HTTP_EXPORT_ALL: '1',
        PATH_INFO: url.pathname,
        QUERY_STRING: url.searchParams.toString(),
        REQUEST_METHOD: request.method,
        CONTENT_TYPE: request.headers['content-type'] ?? '',
        CONTENT_LENGTH: String(body.byteLength),
        REMOTE_ADDR: '127.0.0.1',
        SERVER_PROTOCOL: 'HTTP/1.1',
        SERVER_NAME: '127.0.0.1',
        SERVER_PORT: String(port),
        HTTP_HOST: request.headers.host ?? '127.0.0.1',
      }
      const child = spawn('git', ['http-backend'], { env })
      const stdout = []
      child.stdout.on('data', (chunk) => stdout.push(chunk))
      child.on('error', () => {
        if (!response.headersSent) response.writeHead(500).end()
      })
      child.on('close', (code) => {
        if (response.headersSent) return
        try {
          const raw = Buffer.concat(stdout)
          if (code !== 0 && raw.length === 0) throw new Error('git http-backend failed')
          const parsed = parseResponse(raw)
          response.writeHead(parsed.statusCode, parsed.headers)
          response.end(parsed.body)
        } catch {
          response.writeHead(502).end()
        }
      })
      child.stdin.end(body)
    }, 75)
  })
}

function shutdown() {
  if (server) server.close()
  fs.rmSync(root, { recursive: true, force: true })
}

try {
  fs.mkdirSync(path.dirname(work), { recursive: true })
  fs.mkdirSync(path.join(work, '笔记'), { recursive: true })
  fs.mkdirSync(path.join(work, '50_Assets'), { recursive: true })
  fs.writeFileSync(path.join(work, '笔记', '中文.md'), '# Native clone 验证\n这是 xt2 分支。\n', 'utf8')
  fs.writeFileSync(path.join(work, '空文件.bin'), Buffer.alloc(0))
  fs.writeFileSync(path.join(work, '50_Assets', '小图.png'), image)
  fs.writeFileSync(path.join(work, 'git-object.bin'), gitBinary)
  runGit(['init', '--initial-branch=main', work])
  runGit(['-C', work, 'config', 'user.name', 'Native Fixture'])
  runGit(['-C', work, 'config', 'user.email', 'native-fixture@example.invalid'])
  runGit(['-C', work, 'add', '.'])
  runGit(['-C', work, 'commit', '-m', 'fixture main'])
  runGit(['-C', work, 'switch', '-c', 'xt2'])
  fs.writeFileSync(path.join(work, 'branch.txt'), 'xt2 selected\n', 'utf8')
  runGit(['-C', work, 'add', 'branch.txt'])
  runGit(['-C', work, 'commit', '-m', 'fixture xt2'])
  fs.mkdirSync(repositories, { recursive: true })
  runGit(['init', '--bare', '--initial-branch=main', bare])
  runGit(['-C', work, 'push', bare, 'main', 'xt2'])
  runGit(['--git-dir', bare, 'gc', '--aggressive', '--prune=now'])

  server = createServer(handleGitRequest)
  server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`Native libgit2 fixture ready on 127.0.0.1:${port}\n`)
  })
  server.on('error', (error) => {
    process.stderr.write(`Native libgit2 fixture could not start: ${error.code ?? 'unknown'}\n`)
    shutdown()
    process.exitCode = 1
  })
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
} catch {
  shutdown()
  process.stderr.write('Native libgit2 fixture setup failed\n')
  process.exitCode = 1
}
