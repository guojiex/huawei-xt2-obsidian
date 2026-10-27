// 通过本机 Git Smart HTTP fixture 验证中文、空文件、图片及 packfile clone。
// 同时注入一次指定文件写入失败，检查隔离导入目录的失败清理路径。

import { spawn, spawnSync } from 'node:child_process'
import { createServer } from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../../..')
const smokePath = path.join(here, 'node_smoke.mjs')
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gitbridge-fixture-'))
const workDir = path.join(root, 'work')
const repositoriesDir = path.join(root, 'repositories')
const bareRepo = path.join(repositoriesDir, 'fixture.git')
let server

function runGit(args) {
  const result = spawnSync('git', args, { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${result.stderr}`)
  }
  return result.stdout.trim()
}

function runSmoke(env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [smokePath], {
      cwd: repoRoot,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'inherit', 'inherit'],
    })
    child.once('error', reject)
    child.once('close', (code) => {
      if (code === 0) resolve()
      else reject(new Error(`node_smoke exited ${code}`))
    })
  })
}

function parseCgiResponse(raw) {
  let split = raw.indexOf(Buffer.from('\r\n\r\n'))
  let separatorLength = 4
  if (split < 0) {
    split = raw.indexOf(Buffer.from('\n\n'))
    separatorLength = 2
  }
  if (split < 0) throw new Error('git http-backend omitted CGI headers')
  const lines = raw.subarray(0, split).toString('latin1').split(/\r?\n/)
  let statusCode = 200
  const headers = {}
  for (const line of lines) {
    const colon = line.indexOf(':')
    if (colon < 0) continue
    const name = line.substring(0, colon).trim()
    const value = line.substring(colon + 1).trim()
    if (name.toLowerCase() === 'status') {
      statusCode = Number.parseInt(value, 10) || 200
    } else {
      headers[name] = value
    }
  }
  return { statusCode, headers, body: raw.subarray(split + separatorLength) }
}

function createSmartHttpServer() {
  return createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1')
    console.log(`[fixture] ${request.method} ${url.pathname}${url.search}`)
    const bodyChunks = []
    request.on('data', (chunk) => bodyChunks.push(chunk))
    request.on('end', () => {
      const body = Buffer.concat(bodyChunks)
      const env = {
        ...process.env,
        GATEWAY_INTERFACE: 'CGI/1.1',
        GIT_PROJECT_ROOT: repositoriesDir,
        GIT_HTTP_EXPORT_ALL: '1',
        PATH_INFO: url.pathname,
        QUERY_STRING: url.searchParams.toString(),
        REQUEST_METHOD: request.method,
        CONTENT_TYPE: request.headers['content-type'] || '',
        CONTENT_LENGTH: String(body.byteLength),
        REMOTE_ADDR: '127.0.0.1',
        SERVER_PROTOCOL: 'HTTP/1.1',
        SERVER_NAME: '127.0.0.1',
        SERVER_PORT: String(server.address().port),
        HTTP_HOST: request.headers.host || '127.0.0.1',
      }
      const child = spawn('git', ['http-backend'], { env })
      const stdout = []
      const stderr = []
      child.stdout.on('data', (chunk) => stdout.push(chunk))
      child.stderr.on('data', (chunk) => stderr.push(chunk))
      child.on('error', (error) => {
        if (!response.headersSent) {
          response.writeHead(500)
          response.end(String(error))
        }
      })
      child.on('close', (code) => {
        if (response.headersSent) return
        try {
          const raw = Buffer.concat(stdout)
          if (code !== 0 && raw.length === 0) {
            throw new Error(Buffer.concat(stderr).toString('utf8') || `git http-backend exited ${code}`)
          }
          const parsed = parseCgiResponse(raw)
          console.log(`[fixture] CGI ${parsed.statusCode} ${parsed.body.byteLength} bytes`)
          response.writeHead(parsed.statusCode, parsed.headers)
          response.end(parsed.body)
        } catch (error) {
          response.writeHead(502)
          response.end(String(error))
        }
      })
      child.stdin.end(body)
    })
  })
}

try {
  fs.mkdirSync(repositoriesDir, { recursive: true })
  runGit(['init', '--initial-branch=main', workDir])
  runGit(['-C', workDir, 'config', 'user.name', 'Clone Fixture'])
  runGit(['-C', workDir, 'config', 'user.email', 'fixture@example.invalid'])
  fs.mkdirSync(path.join(workDir, '笔记'), { recursive: true })
  fs.mkdirSync(path.join(workDir, '50_Assets'), { recursive: true })
  fs.writeFileSync(path.join(workDir, '笔记', '中文.md'), '# 原始字节验证\n包含中文与换行。\n', 'utf8')
  fs.writeFileSync(path.join(workDir, '空文件.bin'), Buffer.alloc(0))
  fs.writeFileSync(path.join(workDir, '50_Assets', '像素.png'), Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0xff, 0x80, 0x01, 0x42, 0x00, 0x7f, 0xfe,
  ]))
  fs.writeFileSync(path.join(workDir, 'git-object.bin'), Buffer.from([0x00, 0xff, 0x7f, 0xc3, 0x28, 0x80]))
  runGit(['-C', workDir, 'add', '.'])
  runGit(['-C', workDir, 'commit', '-m', 'fixture'])
  runGit(['init', '--bare', '--initial-branch=main', bareRepo])
  runGit(['-C', workDir, 'push', bareRepo, 'main'])
  runGit(['--git-dir', bareRepo, 'gc', '--aggressive', '--prune=now'])

  server = createSmartHttpServer()
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })
  const port = server.address().port
  const repoUrl = `http://127.0.0.1:${port}/fixture.git`

  console.log('fixture files: 中文文本、空文件、PNG 字节、Git 对象（bare repo 已 gc 为 pack）')
  console.log('\n成功路径：')
  await runSmoke({
    SMOKE_REPO: repoUrl,
    SMOKE_BRANCH: 'main',
    SMOKE_EXPECT_DIR: workDir,
  })

  console.log('\n写入失败路径：')
  await runSmoke({
    SMOKE_REPO: repoUrl,
    SMOKE_BRANCH: 'main',
    SMOKE_EXPECT_FAILURE: '1',
    SMOKE_FAIL_WRITE_PATH: '50_Assets/像素.png',
  })

  await new Promise((resolve) => server.close(resolve))
  console.log('\n本机隔离 clone fixture 通过')
} finally {
  fs.rmSync(root, { recursive: true, force: true })
}
