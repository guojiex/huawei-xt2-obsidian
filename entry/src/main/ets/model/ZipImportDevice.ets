/**
 * ZipImportDevice.ets —— v1.36「从 ZIP 导入知识库」系统适配层
 *
 * 依赖（api_notes Y 组，全部 ≤ API 24）：
 * - picker.DocumentViewPicker.select：fileSuffixFilters '描述|.zip' + maxSelectNumber 1（since 10）；
 * - fileIo.createRandomAccessFileSync + setFilePointer + read(buffer)：确定性随机读，
 *   绕开 fs.read ReadOptions.offset 的存疑语义（Y3）；
 * - zlib.createZipSync + Zip.inflateInit2(strm, -15) + Zip.inflate：raw inflate（since 12），
 *   ZStream 运行时字段语义带护栏，真机验收（Y4）；
 * - statfs.getFreeSizeSync：空间预检（since 10）；13900025 → no_space（Y2）；
 * - 沙箱内读写零权限（AGENTS.md 硬约束 13），暂存走 cacheDir（VaultPathResolver 拼路径）。
 */
import { common } from '@kit.AbilityKit';
import fileIo from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import statfs from '@ohos.file.statvfs';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  InflatePort, ZipImportError, ZipPickResult, ZipReaderPort, ZipWriterPort
} from './ZipImportService';

const NO_SPACE_ERROR_CODE: number = 13900025;

/** 系统 .zip 选择器；用户取消时 pick() 返回 null。 */
export class DeviceZipPicker {
  private context: common.UIAbilityContext;
  private filterDescription: string;

  constructor(context: common.UIAbilityContext, filterDescription: string = '笔记库备份') {
    this.context = context;
    this.filterDescription = filterDescription;
  }

  async pick(): Promise<ZipPickResult | null> {
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,
      fileSuffixFilters: [this.filterDescription + '|.zip']
    };
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
    const uris: Array<string> = await documentPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    return { uri: uris[0], fileName: zipFileNameFromUri(uris[0]) };
  }
}

/** URI 最后一段（解码后）作为文件名；用于预览显示与默认库名兜底。 */
export function zipFileNameFromUri(uri: string): string {
  let decoded: string = uri;
  try {
    decoded = decodeURIComponent(uri);
  } catch (error) {
    decoded = uri;
  }
  const slash: number = decoded.lastIndexOf('/');
  const name: string = slash >= 0 ? decoded.slice(slash + 1) : decoded;
  return name.length > 0 ? name : decoded;
}

/** 暂存文件随机读取器（api_notes Y3：setFilePointer + read 不带 options）。 */
export class StagingZipReader implements ZipReaderPort {
  private file: fileIo.RandomAccessFile;
  private totalSize: number;

  constructor(stagingFilePath: string) {
    this.totalSize = fileIo.statSync(stagingFilePath).size;
    this.file = fileIo.createRandomAccessFileSync(stagingFilePath, fileIo.OpenMode.READ_ONLY);
  }

  async size(): Promise<number> {
    return this.totalSize;
  }

  async readAt(offset: number, length: number): Promise<Uint8Array> {
    if (offset < 0 || length < 0 || offset + length > this.totalSize) {
      throw new ZipImportError('corrupt', 'ZIP 数据越界');
    }
    this.file.setFilePointer(offset);
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    const read: number = await this.file.read(buffer);
    if (read !== length) {
      throw new ZipImportError('corrupt', 'ZIP 数据不完整');
    }
    return new Uint8Array(buffer);
  }

  close(): void {
    this.file.close();
  }
}

/** 临时库目录写入器：段级路径校验（纵深防御）+ 逐级建父目录。 */
export class TempVaultZipWriter implements ZipWriterPort {
  private rootDir: string;

  constructor(rootDir: string) {
    this.rootDir = rootDir;
  }

  async writeFile(relativePath: string, data: Uint8Array): Promise<void> {
    const target: string = TempVaultZipWriter.resolveUnderRoot(this.rootDir, relativePath);
    try {
      const parentSlash: number = target.lastIndexOf('/');
      if (parentSlash > this.rootDir.length) {
        const parentDir: string = target.slice(0, parentSlash);
        if (!fileIo.accessSync(parentDir)) {
          fileIo.mkdirSync(parentDir, true);
        }
      }
      const file: fileIo.File = fileIo.openSync(target,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, TempVaultZipWriter.exactBuffer(data));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      if (err.code === NO_SPACE_ERROR_CODE) {
        throw new ZipImportError('no_space', '设备存储空间不足');
      }
      throw new ZipImportError('io', '写入导入文件失败');
    }
  }

  /**
   * v1.72 导入恢复 mtime（72.2）：解压写盘后按 ZIP central directory 的 DOS 时间
   * 回填文件修改时间（fileIo.utimes，api_notes Y5：API 11+，Epoch 毫秒，限沙箱路径——
   * tempDir 在 vaultsRoot 沙箱内）。尽力而为：失败仅 hilog 告警错误码（不记路径，
   * 隐私红线），不失败导入——内容正确性已由长度 + CRC32 校验保证。
   */
  setModifiedTime(relativePath: string, modifiedAtMs: number): void {
    try {
      fileIo.utimes(TempVaultZipWriter.resolveUnderRoot(this.rootDir, relativePath), modifiedAtMs);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.warn(0x0000, 'ZipImportDevice', '导入回填文件时间失败 %{public}d', err.code);
    }
  }

  /** 相对路径必须由安全段组成，落到 rootDir 之下（服务层已校验，此处纵深防御）。 */
  static resolveUnderRoot(rootDir: string, relativePath: string): string {
    if (relativePath.length === 0 || relativePath.startsWith('/')) {
      throw new ZipImportError('unsafe', 'ZIP 内包含不安全的条目名');
    }
    const segments: string[] = relativePath.split('/');
    const kept: string[] = [];
    for (let index: number = 0; index < segments.length; index++) {
      const segment: string = segments[index];
      if (segment.length === 0 || segment === '..' || segment === '.' || segment.indexOf('\\') >= 0) {
        throw new ZipImportError('unsafe', 'ZIP 内包含不安全的条目名');
      }
      kept.push(segment);
    }
    if (kept.length === 0) {
      throw new ZipImportError('unsafe', 'ZIP 内包含不安全的条目名');
    }
    return rootDir + '/' + kept.join('/');
  }

  /** Uint8Array → 独占完整 ArrayBuffer（子视图时拷贝）。 */
  static exactBuffer(data: Uint8Array): ArrayBuffer {
    if (data.byteOffset === 0 && data.byteLength === data.buffer.byteLength) {
      return data.buffer;
    }
    const copy: Uint8Array = new Uint8Array(data.byteLength);
    copy.set(data);
    return copy.buffer;
  }
}

/** raw inflate（windowBits -15）；护栏与真机验收要求见 api_notes Y4。 */
export class ZlibRawInflate implements InflatePort {
  private static readonly MAX_INFLATE_CALLS: number = 16;

  async inflateRaw(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array> {
    if (expectedSize === 0) {
      return new Uint8Array(0);
    }
    const output: ArrayBuffer = new ArrayBuffer(expectedSize);
    const strm: zlib.ZStream = {
      nextIn: TempVaultZipWriter.exactBuffer(compressed),
      availableIn: compressed.byteLength,
      nextOut: output,
      availableOut: expectedSize
    };
    const zip: zlib.Zip = zlib.createZipSync();
    let status: zlib.ReturnStatus = zlib.ReturnStatus.OK;
    try {
      const initStatus: zlib.ReturnStatus = await zip.inflateInit2(strm, -15);
      if (initStatus !== zlib.ReturnStatus.OK) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      status = await zip.inflate(strm, zlib.CompressFlushMode.NO_FLUSH);
      let calls: number = 1;
      while (status === zlib.ReturnStatus.OK && calls < ZlibRawInflate.MAX_INFLATE_CALLS) {
        status = await zip.inflate(strm, zlib.CompressFlushMode.NO_FLUSH);
        calls++;
      }
      if (status !== zlib.ReturnStatus.STREAM_END) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      // @ohos.zlib 不回写调用方传入的 ZStream（操作后须 getZStream() 重取状态，api_notes Y4），
      // 直接读传入对象的 availableOut 只会拿到初始值 expectedSize，导致所有非空 deflate 条目误判损坏。
      const current: zlib.ZStream = await zip.getZStream();
      const availableOut: number = current.availableOut ?? 0;
      if (expectedSize - availableOut !== expectedSize) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      return new Uint8Array(output);
    } catch (error) {
      if (error instanceof ZipImportError) {
        throw error;
      }
      const err: BusinessError = error as BusinessError;
      if (err.code === NO_SPACE_ERROR_CODE) {
        throw new ZipImportError('no_space', '设备存储空间不足');
      }
      throw new ZipImportError('corrupt', 'ZIP 数据损坏');
    } finally {
      try {
        await zip.inflateEnd(strm);
      } catch (cleanupError) {
        // 释放失败不影响结果判定；对象由 GC 兜底
      }
    }
  }
}

/** 把 Picker 临时授权的 ZIP 复制到沙箱暂存路径（新建唯一文件，不覆盖已有内容）。 */
export async function copyPickerZipToStaging(uri: string, stagingFilePath: string): Promise<void> {
  const source: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    await fileIo.copyFile(source.fd, stagingFilePath);
  } catch (error) {
    const err: BusinessError = error as BusinessError;
    if (err.code === NO_SPACE_ERROR_CODE) {
      throw new ZipImportError('no_space', '设备存储空间不足');
    }
    throw new ZipImportError('io', '读取所选 ZIP 失败');
  } finally {
    fileIo.closeSync(source);
  }
}

/** 空间预检：目录所在文件系统的剩余字节数（statfs.getFreeSizeSync，since 10）。 */
export function freeBytesUnder(directory: string): number {
  return statfs.getFreeSizeSync(directory);
}

/** 删除暂存文件；不存在或失败均静默（开弹窗时的目录级兜底清理兜住残留）。 */
export function removeStagingFile(stagingFilePath: string): void {
  try {
    if (fileIo.accessSync(stagingFilePath)) {
      fileIo.unlinkSync(stagingFilePath);
    }
  } catch (error) {
    // 暂存清理失败不阻塞导入流程
  }
}
