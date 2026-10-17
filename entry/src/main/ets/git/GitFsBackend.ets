import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { FsOpMsg, FsReadResult, FsReaddirResult, FsStatResult, OkResult } from './GitBridgeModels'

/**
 * 桥接层的 fs 后端：把 JS 侧的相对路径操作落到应用沙箱的 vault 目录。
 *
 * 这里是「可发布为三方库」的关键抽象点：只要换一个 root，就能把 git 仓库
 * 落到任何目录，后端本身不关心业务。
 */
export class GitFsBackend {
  private root: string
  private base64: util.Base64Helper = new util.Base64Helper()
  private encoder: util.TextEncoder = new util.TextEncoder()
  private decoder: util.TextDecoder = new util.TextDecoder()

  constructor(root: string) {
    this.root = root
  }

  /** vault 根（供外部创建/检查） */
  getRoot(): string {
    return this.root
  }

  ensureRoot(): void {
    if (!fs.accessSync(this.root)) {
      fs.mkdirSync(this.root, true)
    }
  }

  /** 相对路径 -> 沙箱绝对路径，同时拦截越权路径 */
  private abs(rel: string): string {
    if (rel.length === 0) {
      return this.root
    }
    if (rel.startsWith('/') || rel.includes('..')) {
      throw new Error('EACCES: illegal path ' + rel)
    }
    return this.root + '/' + rel
  }

  private decodePath(pathB64: string): string {
    return this.decoder.decodeToString(this.base64.decodeSync(pathB64))
  }

  private decodeBytes(b64: string): Uint8Array {
    return this.base64.decodeSync(b64)
  }

  private encodeBytes(bytes: Uint8Array): string {
    return this.base64.encodeToStringSync(bytes)
  }

  /** 读文件 */
  read(rel: string): FsReadResult {
    const abs = this.abs(rel)
    const file = fs.openSync(abs, fs.OpenMode.READ_ONLY)
    try {
      const stat = fs.statSync(abs)
      const buf = new ArrayBuffer(stat.size)
      fs.readSync(file.fd, buf)
      return { dataB64: this.encodeBytes(new Uint8Array(buf)) }
    } finally {
      fs.closeSync(file)
    }
  }

  /**
   * 写文件。
   * .git 内部文件不做原子写（git 自身有完整性保障，且对象文件极多，原子写开销大）；
   * 工作区文件走 tmp + rename，避免写一半崩溃留下残文件。
   */
  write(rel: string, dataB64: string): OkResult {
    const abs = this.abs(rel)
    this.ensureParent(abs)
    const bytes = this.decodeBytes(dataB64)
    if (this.isGitInternal(rel)) {
      this.writeDirect(abs, bytes)
    } else {
      this.writeAtomic(abs, bytes)
    }
    return { ok: true }
  }

  private isGitInternal(rel: string): boolean {
    return rel === '.git' || rel.startsWith('.git/')
  }

  private writeDirect(abs: string, bytes: Uint8Array): void {
    const file = fs.openSync(abs, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    try {
      fs.writeSync(file.fd, bytes.buffer)
    } finally {
      fs.closeSync(file)
    }
  }

  private writeAtomic(abs: string, bytes: Uint8Array): void {
    const tmp = abs + '.tmp'
    this.writeDirect(tmp, bytes)
    if (fs.accessSync(abs)) {
      fs.unlinkSync(abs)
    }
    fs.renameSync(tmp, abs)
  }

  private ensureParent(abs: string): void {
    const idx = abs.lastIndexOf('/')
    if (idx > 0) {
      const parent = abs.substring(0, idx)
      if (!fs.accessSync(parent)) {
        fs.mkdirSync(parent, true)
      }
    }
  }

  mkdir(rel: string): OkResult {
    const abs = this.abs(rel)
    if (!fs.accessSync(abs)) {
      fs.mkdirSync(abs, true)
    }
    return { ok: true }
  }

  /** 幂等：isomorphic-git 结束时会 unlink 未必存在的 .git/shallow */
  unlink(rel: string): OkResult {
    const abs = this.abs(rel)
    if (fs.accessSync(abs)) {
      fs.unlinkSync(abs)
    }
    return { ok: true }
  }

  rmdir(rel: string): OkResult {
    const abs = this.abs(rel)
    if (fs.accessSync(abs)) {
      fs.rmdirSync(abs)
    }
    return { ok: true }
  }

  rename(rel: string, newRel: string): OkResult {
    const to = this.abs(newRel)
    this.ensureParent(to)
    fs.renameSync(this.abs(rel), to)
    return { ok: true }
  }

  readdir(rel: string): FsReaddirResult {
    const abs = this.abs(rel)
    if (!fs.accessSync(abs)) {
      return { entries: [] }
    }
    return { entries: fs.listFileSync(abs) }
  }

  stat(rel: string): FsStatResult {
    const abs = this.abs(rel)
    const stat = fs.statSync(abs)
    return {
      type: stat.isDirectory() ? 'dir' : 'file',
      size: stat.size
    }
  }

  /** 批量执行（clone 时的落盘主力，避免逐次跨桥） */
  batch(ops: FsOpMsg[]): OkResult {
    for (const op of ops) {
      const rel = this.decodePath(op.pathB64)
      switch (op.op) {
        case 'write':
          this.write(rel, op.dataB64 ?? '')
          break
        case 'mkdir':
          this.mkdir(rel)
          break
        case 'unlink':
          this.unlink(rel)
          break
        case 'rmdir':
          this.rmdir(rel)
          break
        case 'rename':
          this.rename(rel, this.decodePath(op.newPathB64 ?? ''))
          break
        default:
          throw new Error('ENOSYS: unsupported op ' + op.op)
      }
    }
    return { ok: true }
  }

  /** 列出 vault 下的 markdown 文件（相对路径），供 UI 展示 */
  listMarkdown(rel: string): string[] {
    const abs = this.abs(rel)
    const out: string[] = []
    if (!fs.accessSync(abs)) {
      return out
    }
    const entries = fs.listFileSync(abs)
    for (const name of entries) {
      if (name.startsWith('.') || name === 'node_modules') {
        continue
      }
      const childRel = rel.length === 0 ? name : rel + '/' + name
      const childAbs = this.abs(childRel)
      const stat = fs.statSync(childAbs)
      if (stat.isDirectory()) {
        const nested = this.listMarkdown(childRel)
        for (const n of nested) {
          out.push(n)
        }
      } else if (name.endsWith('.md')) {
        out.push(childRel)
      }
    }
    return out
  }
}
