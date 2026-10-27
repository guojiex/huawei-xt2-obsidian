import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { FsOpMsg, FsReadResult, FsReaddirResult, FsStatResult, OkResult } from './GitBridgeModels';

/**
 * 桥接层的 fs 后端：把 JS 侧的相对路径操作落到应用沙箱的 vault 目录。
 *
 * 这里是「可发布为三方库」的关键抽象点：只要换一个 root，就能把 git 仓库
 * 落到任何目录，后端本身不关心业务。
 */
export class GitFsBackend {
  private root: string;
  private allowImportBinaryWrites: boolean;
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder();

  constructor(root: string, allowImportBinaryWrites: boolean = false) {
    const rootName: string = root.substring(root.lastIndexOf('/') + 1);
    if (allowImportBinaryWrites && !rootName.endsWith('__importing')) {
      throw new Error('EACCES: binary import writes require an __importing root');
    }
    this.root = root;
    this.allowImportBinaryWrites = allowImportBinaryWrites;
  }

  /** vault 根（供外部创建/检查） */
  getRoot(): string {
    return this.root;
  }

  ensureRoot(): void {
    if (!fs.accessSync(this.root)) {
      fs.mkdirSync(this.root, true);
    }
  }

  /** 相对路径 -> 沙箱绝对路径，同时拦截越权路径 */
  private abs(rel: string): string {
    if (rel.length === 0) {
      return this.root;
    }
    if (rel.startsWith('/') || rel.includes('..')) {
      throw new Error('EACCES: illegal path ' + rel);
    }
    return this.root + '/' + rel;
  }

  private decodePath(pathB64: string): string {
    return this.decoder.decodeToString(this.base64.decodeSync(pathB64));
  }

  private decodeBytes(b64: string): Uint8Array {
    if (b64.length === 0) {
      return new Uint8Array(0);
    }
    return this.base64.decodeSync(b64);
  }

  private encodeBytes(bytes: Uint8Array): string {
    if (bytes.length === 0) {
      return '';
    }
    return this.base64.encodeToStringSync(bytes);
  }

  /** 读文件 */
  read(rel: string): FsReadResult {
    const abs = this.abs(rel);
    const file = fs.openSync(abs, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(abs);
      const buf = new ArrayBuffer(stat.size);
      let readTotal: number = 0;
      while (readTotal < stat.size) {
        const chunk: ArrayBuffer = new ArrayBuffer(stat.size - readTotal);
        const read: number = fs.readSync(file.fd, chunk);
        if (read <= 0 || read > chunk.byteLength) {
          throw new Error(`short read for ${rel}: ${readTotal}/${stat.size} bytes`);
        }
        new Uint8Array(buf).set(new Uint8Array(chunk, 0, read), readTotal);
        readTotal += read;
      }
      return { dataB64: this.encodeBytes(new Uint8Array(buf)) };
    } finally {
      fs.closeSync(file);
    }
  }

  /**
   * 新 clone 在未登记的导入目录内逐字节写入；其他 root 仅接受可无损 UTF-8 往返的文本，仍走 AtomicFile。
   */
  async write(rel: string, dataB64: string): Promise<OkResult> {
    const abs = this.abs(rel);
    const bytes = this.decodeBytes(dataB64);
    if (this.allowImportBinaryWrites) {
      this.ensureParent(abs);
      this.writeImportBytes(abs, rel, bytes);
    } else {
      const text: string | undefined = this.decodeExactUtf8(bytes);
      if (text === undefined) {
        throw new Error(`EUNSUPPORTED: refusing non-UTF-8 Git write outside an isolated import: ${rel}`);
      }
      this.ensureParent(abs);
      await this.writeAtomic(abs, rel, text);
    }
    return { ok: true };
  }

  /** 普通二进制写入只允许用于本次新 clone 的隔离目录；失败由 SyncPage 清理整个导入目录。 */
  private writeImportBytes(abs: string, rel: string, bytes: Uint8Array): void {
    const file: fs.File = fs.openSync(abs, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let failure: Error | Object | undefined = undefined;
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(bytes.length);
      new Uint8Array(buffer).set(bytes);
      let writtenTotal: number = 0;
      while (writtenTotal < bytes.length) {
        const remaining: ArrayBuffer = buffer.slice(writtenTotal);
        const written: number = fs.writeSync(file.fd, remaining);
        if (written !== Math.floor(written) || written <= 0 || written > remaining.byteLength) {
          throw new Error(`invalid writeSync byte count ${written} for ${remaining.byteLength} bytes`);
        }
        writtenTotal += written;
      }
    } catch (error) {
      failure = error as Error;
    }
    try {
      fs.closeSync(file);
    } catch (closeError) {
      if (failure === undefined) {
        failure = closeError as Error;
      }
    }
    if (failure !== undefined) {
      throw this.toWriteError('binary import write', rel, failure, 'GitFsBackend');
    }
  }

  /** 只允许无损 UTF-8 往返的内容走既有 AtomicFile 字符串写入路径。 */
  private decodeExactUtf8(bytes: Uint8Array): string | undefined {
    const text: string = this.decoder.decodeToString(bytes);
    const encoded: Uint8Array = this.encoder.encodeInto(text);
    if (encoded.length !== bytes.length) {
      return undefined;
    }
    for (let i: number = 0; i < bytes.length; i++) {
      if (encoded[i] !== bytes[i]) {
        return undefined;
      }
    }
    return text;
  }

  private writeAtomic(abs: string, rel: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile = new fs.AtomicFile(abs);
      let settled = false;
      let timerId = -1;
      const fail = (stage: string, error: Error | Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (cleanupError) {
          // Keep the original write error.
        }
        reject(this.toWriteError(stage, rel, error, 'AtomicFile'));
      };
      const commit = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
        } catch (error) {
          fail('finishWrite', error as Error);
          return;
        }
        settled = true;
        resolve();
      };

      let stream: fs.WriteStream;
      try {
        stream = atomicFile.startWrite();
      } catch (error) {
        fail('startWrite', error as Error);
        return;
      }
      timerId = setTimeout((): void => {
        fail('write', new Error('write callback timed out'));
      }, 3000);
      if (content.length === 0) {
        commit();
      } else {
        try {
          stream.write(content, 'utf-8', (error?: BusinessError): void => {
            if (error !== undefined && error !== null) {
              fail('write', error);
              return;
            }
            commit();
          });
        } catch (error) {
          fail('write', error as Error);
        }
      }
    });
  }

  private toWriteError(stage: string, rel: string, error: Error | Object, writer: string): Error {
    const businessError = error as BusinessError;
    const message = businessError.code !== undefined
      ? `${businessError.code}: ${businessError.message}`
      : error instanceof Error ? error.message : String(error);
    return new Error(`${writer} ${stage} failed for ${rel}: ${message}`);
  }

  private ensureParent(abs: string): void {
    const idx = abs.lastIndexOf('/');
    if (idx > 0) {
      const parent = abs.substring(0, idx);
      if (!fs.accessSync(parent)) {
        fs.mkdirSync(parent, true);
      }
    }
  }

  mkdir(rel: string): OkResult {
    const abs = this.abs(rel);
    if (!fs.accessSync(abs)) {
      fs.mkdirSync(abs, true);
    }
    return { ok: true };
  }

  /** 幂等：isomorphic-git 结束时会 unlink 未必存在的 .git/shallow */
  unlink(rel: string): OkResult {
    const abs = this.abs(rel);
    if (fs.accessSync(abs)) {
      fs.unlinkSync(abs);
    }
    return { ok: true };
  }

  rmdir(rel: string): OkResult {
    const abs = this.abs(rel);
    if (fs.accessSync(abs)) {
      fs.rmdirSync(abs);
    }
    return { ok: true };
  }

  rename(rel: string, newRel: string): OkResult {
    const to = this.abs(newRel);
    this.ensureParent(to);
    fs.renameSync(this.abs(rel), to);
    return { ok: true };
  }

  readdir(rel: string): FsReaddirResult {
    const abs = this.abs(rel);
    if (!fs.accessSync(abs)) {
      return { entries: [] };
    }
    return { entries: fs.listFileSync(abs) };
  }

  stat(rel: string): FsStatResult {
    const abs = this.abs(rel);
    const stat = fs.statSync(abs);
    return {
      type: stat.isDirectory() ? 'dir' : 'file',
      size: stat.size
    };
  }

  /** 批量执行（clone 时的落盘主力，避免逐次跨桥） */
  async batch(ops: FsOpMsg[]): Promise<OkResult> {
    for (let i: number = 0; i < ops.length; i++) {
      const op: FsOpMsg = ops[i];
      const rel = this.decodePath(op.pathB64);
      try {
        switch (op.op) {
          case 'write':
            await this.write(rel, op.dataB64 ?? '');
            break;
          case 'mkdir':
            this.mkdir(rel);
            break;
          case 'unlink':
            this.unlink(rel);
            break;
          case 'rmdir':
            this.rmdir(rel);
            break;
          case 'rename':
            this.rename(rel, this.decodePath(op.newPathB64 ?? ''));
            break;
          default:
            throw new Error('ENOSYS: unsupported op ' + op.op);
        }
      } catch (error) {
        const err = error as Error;
        throw new Error(`Git FS batch op ${i} ${op.op} ${rel}: ${err.message ?? String(error)}`);
      }
    }
    return { ok: true };
  }

  /** 列出 vault 下的 markdown 文件（相对路径），供 UI 展示 */
  listMarkdown(rel: string): string[] {
    const abs = this.abs(rel);
    const out: string[] = [];
    if (!fs.accessSync(abs)) {
      return out;
    }
    const entries = fs.listFileSync(abs);
    for (const name of entries) {
      if (name.startsWith('.') || name === 'node_modules') {
        continue;
      }
      const childRel = rel.length === 0 ? name : rel + '/' + name;
      const childAbs = this.abs(childRel);
      const stat = fs.statSync(childAbs);
      if (stat.isDirectory()) {
        const nested = this.listMarkdown(childRel);
        for (const n of nested) {
          out.push(n);
        }
      } else if (name.endsWith('.md')) {
        out.push(childRel);
      }
    }
    return out;
  }
}
