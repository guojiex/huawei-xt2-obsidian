// 给 isomorphic-git 用的 fs 适配器。
// 所有真实 IO 都转发到 ArkTS（@ohos.file.fs），但在 JS 侧做一层写缓冲：
// clone 会产生成千上万次小文件写入，逐次跨桥会把耗时放大到不可接受。
// 策略：写先落 JS 内存队列，达到阈值或操作结束时批量提交，提交后清空缓存。

import { b64FromBytes, b64FromText, bytesFromB64, textFromB64 } from './codec'
import { createError, request } from './channel'

export interface FsOp {
  op: 'write' | 'mkdir' | 'unlink' | 'rmdir' | 'rename'
  pathB64: string
  dataB64?: string
  newPathB64?: string
}

export interface StatLike {
  type: 'file' | 'dir' | 'symlink'
  mode: number
  size: number
  ino: number
  mtimeMs: number
  ctimeMs: number
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
}

const MAX_PENDING_FILES = 128
const MAX_PENDING_BYTES = 4 * 1024 * 1024

function dirname(p: string): string {
  const i = p.lastIndexOf('/')
  return i <= 0 ? '' : p.substring(0, i)
}

function basename(p: string): string {
  const i = p.lastIndexOf('/')
  return i < 0 ? p : p.substring(i + 1)
}

export class BridgeFs {
  private gitDir: string
  /** 文件内容缓存（含未落盘的写入） */
  private mem = new Map<string, Uint8Array>()
  /** 已知类型缓存 */
  private types = new Map<string, 'file' | 'dir'>()
  /** 目录列表缓存 */
  private dirs = new Map<string, string[]>()

  /** 待提交操作队列（有序） */
  private queue: FsOp[] = []
  private writeIndex = new Map<string, FsOp>()
  private pendingBytes = 0
  lastReadError = ''

  constructor(gitDir: string) {
    this.gitDir = gitDir.replace(/\/+$/, '')
  }

  /** 把 isomorphic-git 的绝对路径映射为 vault 内相对路径 */
  private rel(p: string): string {
    let v = p.replace(/\\/g, '/')
    if (v.startsWith(this.gitDir)) {
      v = v.substring(this.gitDir.length)
    }
    while (v.startsWith('/')) {
      v = v.substring(1)
    }
    // isomorphic-git 偶尔会传相对路径 "."，归一化为根，避免原生 fs 拼出 "xxx/." 这种写法
    if (v === '.' || v === './') {
      v = ''
    }
    return v
  }

  // 注意：channel.onResult 已经把 payload 解过一次 base64，
  // 这里拿到的就是解析后的对象，不能再解第二次。
  private async call<T>(payload: Record<string, unknown>): Promise<T> {
    return await request<T>('fs', payload)
  }

  async readFile(filepath: string, opts?: any): Promise<any> {
    const rel = this.rel(filepath)
    let data = this.mem.get(rel)
    if (data === undefined) {
      try {
        const res = await this.call<{ dataB64: string }>({
          op: 'read',
          pathB64: b64FromText(rel),
        })
        data = bytesFromB64(res.dataB64)
        this.mem.set(rel, data)
      } catch (error) {
        this.lastReadError = `readFile ${rel}: ${(error as Error).message ?? String(error)}`
        throw error
      }
    }
    const enc = typeof opts === 'string' ? opts : opts?.encoding
    if (enc) {
      return new TextDecoder().decode(data)
    }
    return data
  }

  async writeFile(filepath: string, data: any, _opts?: any): Promise<void> {
    const rel = this.rel(filepath)
    const bytes: Uint8Array =
      typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data)
    this.mem.set(rel, bytes)
    this.types.set(rel, 'file')

    const existing = this.writeIndex.get(rel)
    if (existing) {
      const prevLen = existing.dataB64 ? existing.dataB64.length : 0
      existing.dataB64 = b64FromBytes(bytes)
      this.pendingBytes += existing.dataB64.length - prevLen
    } else {
      const op: FsOp = { op: 'write', pathB64: b64FromText(rel), dataB64: b64FromBytes(bytes) }
      this.queue.push(op)
      this.writeIndex.set(rel, op)
      this.pendingBytes += op.dataB64!.length
    }

    // 同步维护父目录列表，避免后续 readdir 漏掉未落盘的新文件
    const parent = dirname(rel)
    if (parent) {
      const list = this.dirs.get(parent)
      const name = basename(rel)
      if (list && !list.includes(name)) {
        list.push(name)
      }
    }

    if (this.queue.length >= MAX_PENDING_FILES || this.pendingBytes >= MAX_PENDING_BYTES) {
      await this.flush()
    }
  }

  async unlink(filepath: string): Promise<void> {
    const rel = this.rel(filepath)
    this.mem.delete(rel)
    this.types.delete(rel)
    this.queue.push({ op: 'unlink', pathB64: b64FromText(rel) })
    const parent = dirname(rel)
    const list = parent ? this.dirs.get(parent) : undefined
    if (list) {
      const idx = list.indexOf(basename(rel))
      if (idx >= 0) {
        list.splice(idx, 1)
      }
    }
  }

  async mkdir(filepath: string): Promise<void> {
    const rel = this.rel(filepath)
    if (!rel) {
      return
    }
    this.types.set(rel, 'dir')
    this.queue.push({ op: 'mkdir', pathB64: b64FromText(rel) })
  }

  async rmdir(filepath: string): Promise<void> {
    const rel = this.rel(filepath)
    this.types.delete(rel)
    this.dirs.delete(rel)
    this.queue.push({ op: 'rmdir', pathB64: b64FromText(rel) })
  }

  async rename(from: string, to: string): Promise<void> {
    const relFrom = this.rel(from)
    const relTo = this.rel(to)
    const data = this.mem.get(relFrom)
    this.mem.delete(relFrom)
    this.types.delete(relFrom)
    if (data) {
      this.mem.set(relTo, data)
      this.types.set(relTo, 'file')
    }
    this.queue.push({
      op: 'rename',
      pathB64: b64FromText(relFrom),
      newPathB64: b64FromText(relTo),
    })
  }

  async readdir(filepath: string): Promise<string[]> {
    const rel = this.rel(filepath)
    let remote: string[] = []
    try {
      const res = await this.call<{ entries: string[] }>({
        op: 'readdir',
        pathB64: b64FromText(rel),
      })
      remote = res.entries || []
    } catch (e) {
      if ((e as any)?.code === 'ENOENT') {
        remote = []
      } else {
        throw e
      }
    }
    // 合并尚未落盘的本地条目
    const merged = new Set<string>(remote)
    for (const op of this.queue) {
      const p = textFromB64(op.pathB64)
      if ((op.op === 'write' || op.op === 'mkdir') && dirname(p) === rel) {
        merged.add(basename(p))
      }
    }
    const list = Array.from(merged)
    this.dirs.set(rel, list)
    return list
  }

  async stat(filepath: string): Promise<StatLike> {
    return this.statInternal(filepath, false)
  }

  async lstat(filepath: string): Promise<StatLike> {
    return this.statInternal(filepath, true)
  }

  private async statInternal(filepath: string, _lstat: boolean): Promise<StatLike> {
    const rel = this.rel(filepath)
    const cached = this.mem.get(rel)
    if (cached !== undefined) {
      return makeStat('file', cached.length)
    }
    const known = this.types.get(rel)
    if (known) {
      return makeStat(known, known === 'file' ? (this.mem.get(rel)?.length ?? 0) : 0)
    }
    try {
      const res = await this.call<{ type: 'file' | 'dir' | 'symlink'; size: number }>({
        op: 'stat',
        pathB64: b64FromText(rel),
      })
      this.types.set(rel, res.type === 'dir' ? 'dir' : 'file')
      return makeStat(res.type, res.size)
    } catch (e) {
      if ((e as any)?.code === 'ENOENT') {
        throw createError('ENOENT', `no such file or directory: ${rel}`)
      }
      throw e
    }
  }

  async readlink(_filepath: string): Promise<string> {
    throw createError('ENOSYS', 'symlink is not supported on the bridge fs')
  }

  async symlink(_target: string, _filepath: string): Promise<void> {
    throw createError('ENOSYS', 'symlink is not supported on the bridge fs')
  }

  /** 把缓冲的写入一次性提交到 ArkTS，提交后释放内存缓存 */
  async flush(): Promise<void> {
    if (this.queue.length === 0) {
      this.clearCaches()
      return
    }
    const ops = this.queue
    this.queue = []
    this.writeIndex.clear()
    this.pendingBytes = 0
    await this.call<{ ok: boolean }>({ op: 'batch', ops })
    // 释放缓存，控制内存；后续读取会重新过桥
    this.clearCaches()
  }

  clearCaches(): void {
    this.mem.clear()
    this.types.clear()
    this.dirs.clear()
  }
}

function makeStat(type: 'file' | 'dir' | 'symlink', size: number): StatLike {
  return {
    type,
    mode: type === 'dir' ? 0o040755 : 0o100644,
    size,
    ino: 0,
    mtimeMs: Date.now(),
    ctimeMs: Date.now(),
    isFile: () => type === 'file',
    isDirectory: () => type === 'dir',
    isSymbolicLink: () => type === 'symlink',
  }
}
