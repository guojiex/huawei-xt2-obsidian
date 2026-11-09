/**
 * ZipImportService.ets —— v1.36「从 ZIP 导入知识库」纯逻辑核心
 *
 * 设计（需求文档 v1.36 §5 核实结论 1，api_notes Y1）：
 * - 本文件零 `@kit` 依赖：EOCD / Central Directory 解析、条目安全校验、分类、
 *   逐条目抽取编排全部通过注入端口（reader / writer / inflate）完成，
 *   Node 侧（tools/tests）可直接驱动；
 * - 解析顺序 = 安全顺序：解压前完成全部条目校验（36.5）——字节级名称检查
 *   （反斜杠 / 控制字符 / 绝对路径 / 盘符）、`..`/`.`/空段拒绝、加密位、
 *   非 0/8 压缩方法、symlink 模式位、ZIP64 标记、条目数与解压大小上限；
 * - 隐藏条目（任意路径段以 `.` 开头，含 `.git/`、`.trash/`）静默跳过不计数；
 *   非隐藏的未识别文件计入 skippedCount，完成后向用户报告（36.4）；
 * - 写入只经注入的 writer 端口落到未登记的临时库目录，登记与清理由
 *   VaultRegistry / 调用方负责（36.6）；本类不做任何登记操作；
 * - 错误统一为 ZipImportError（kind 分类），失败文案映射放 ImportVaultDialog；
 * - 失败信息携带底层错误进用户可见文案（46.9）；文件名、路径与笔记内容
 *   不进 hilog 日志或埋点（需求 §5 红线不变）。
 */

/** 解析结果中的单条目。kind：'note' | 'image' | 'skip'（skip 不参与写入）。 */
export interface ZipParsedEntry {
  name: string;
  kind: string;
  method: number;
  compressedSize: number;
  uncompressedSize: number;
  localHeaderOffset: number;
  crc32: number;
}

/** parse() 的返回：预览摘要 + 待写入条目（kind !== 'skip' 的部分）。 */
export interface ZipParsed {
  entries: ZipParsedEntry[];
  noteCount: number;
  imageCount: number;
  skippedCount: number;
  /** 待写条目共有的唯一顶层文件夹名（恰一个且无根级文件时），否则空串。 */
  topFolder: string;
  /** 待写条目的解压后总字节数（空间预检用）。 */
  totalUncompressed: number;
}

/** 安全上限（36.5：定值写入需求文档 §6）。 */
export interface ZipImportLimits {
  maxEntries: number;
  maxTotalUncompressed: number;
  maxSingleUncompressed: number;
  maxNameBytes: number;
}

/** 字节读取端口：设备侧用 RandomAccessFile 实现（api_notes Y3）。 */
export interface ZipReaderPort {
  size(): Promise<number>;
  readAt(offset: number, length: number): Promise<Uint8Array>;
}

/** 写入端口：设备侧落到临时库目录，负责逐级建父目录。 */
export interface ZipWriterPort {
  writeFile(relativePath: string, data: Uint8Array): Promise<void>;
}

/** raw deflate 解压端口：设备侧用 zlib Zip.inflateInit2(-15) 实现（api_notes Y4）。 */
export interface InflatePort {
  inflateRaw(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array>;
}

/** 抽取过程钩子：条目间检查取消（36.5 核实结论 3）与进度回报（36.7）。 */
export interface ZipExtractHooks {
  isCancelled?: () => boolean;
  onProgress?: (done: number, total: number) => void;
}

/** 系统选择器选中结果；用户取消由调用方返回 null 表达。 */
export interface ZipPickResult {
  uri: string;
  fileName: string;
}

/** 导入成功结果（Index 完成登记与切库后回填，用于弹窗关闭与完成提示）。 */
export interface ZipImportResult {
  vaultId: string;
  vaultName: string;
  noteCount: number;
  imageCount: number;
  skippedCount: number;
}

/**
 * 选择 ZIP 阶段的编排结果（Index 组装，弹窗消费）。
 * status：'cancelled'（用户关闭选择器）/ 'failed'（读取或解析失败，kind 定文案）/
 * 'selected'（解析成功，进入预览态）。
 */
export interface ZipChooseOutcome {
  status: string;
  kind: ZipImportErrorKind;
  /** 底层错误文本（46.9：随失败态展示给用户；成功 / 取消为空串）。 */
  detail: string;
  fileName: string;
  summary: string;
  defaultVaultName: string;
}

/**
 * 确认导入阶段的编排结果（Index 组装，弹窗消费）。
 * status：'ok'（登记切库完成）/ 'cancelled' / 'failed'。
 */
export interface ZipImportOutcome {
  status: string;
  kind: ZipImportErrorKind;
  /** 底层错误文本（46.9：随失败态展示给用户；成功 / 取消为空串）。 */
  detail: string;
  result: ZipImportResult | null;
}

/** 失败分类：文案映射见 ImportVaultDialog（36.7 四类 + 其余技术性失败）。 */
export type ZipImportErrorKind =
  'corrupt' | 'not_vault' | 'over_limit' | 'unsafe' | 'encrypted' | 'no_space' | 'io' | 'cancelled';

/** 带分类的导入错误；message 为可直接展示的底层错误文本。 */
export class ZipImportError extends Error {
  readonly kind: ZipImportErrorKind;

  constructor(kind: ZipImportErrorKind, message: string) {
    super(message);
    this.kind = kind;
  }
}

export class ZipImportService {
  /** 默认上限（512MB 总量 / 单文件 64MB / 5000 条目，v1.36 §6 定值）。 */
  static readonly DEFAULT_LIMITS: ZipImportLimits = {
    maxEntries: 5000,
    maxTotalUncompressed: 512 * 1024 * 1024,
    maxSingleUncompressed: 64 * 1024 * 1024,
    maxNameBytes: 1024
  };

  private static readonly EOCD_SIGNATURE: number = 0x06054b50;
  private static readonly CENTRAL_SIGNATURE: number = 0x02014b50;
  private static readonly LOCAL_SIGNATURE: number = 0x04034b50;
  private static readonly EOCD_MIN_SIZE: number = 22;
  /** EOCD 本体 22 字节 + 注释最长 65535 字节。 */
  private static readonly EOCD_SCAN_WINDOW: number = 22 + 65535;
  private static readonly CENTRAL_HEADER_SIZE: number = 46;
  private static readonly LOCAL_HEADER_SIZE: number = 30;

  private static crcTable: number[] | null = null;

  /**
   * 解析 ZIP 的 Central Directory 并完成解压前校验（36.5）。
   * 抛 ZipImportError：corrupt / not_vault / over_limit / unsafe / encrypted。
   */
  static async parse(reader: ZipReaderPort, limits: ZipImportLimits): Promise<ZipParsed> {
    const totalSize: number = await reader.size();
    const eocdOffset: number = await ZipImportService.locateEocd(reader, totalSize);
    const eocd: Uint8Array = await reader.readAt(eocdOffset, ZipImportService.EOCD_MIN_SIZE);
    const entryCount: number = ZipImportService.u16(eocd, 10);
    const centralSize: number = ZipImportService.u32(eocd, 12);
    const centralOffset: number = ZipImportService.u32(eocd, 16);
    // ZIP64 标记：条目数/偏移/大小任一为 0xFFFF(F) 即超出本版支持范围（36.5）。
    if (entryCount === 0xFFFF || centralSize === 0xFFFFFFFF || centralOffset === 0xFFFFFFFF) {
      throw new ZipImportError('over_limit', 'ZIP 使用了不支持的 ZIP64 格式');
    }
    if (entryCount === 0) {
      throw new ZipImportError('not_vault', 'ZIP 中没有任何文件');
    }
    if (entryCount > limits.maxEntries) {
      throw new ZipImportError('over_limit', 'ZIP 内条目数超出上限');
    }
    // Central Directory 必须完整落在 EOCD 之前。
    if (centralOffset > eocdOffset || centralOffset + centralSize > eocdOffset) {
      throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
    }
    const central: Uint8Array = await reader.readAt(centralOffset, centralSize);
    const entries: ZipParsedEntry[] = [];
    const topSegments: string[] = [];
    let noteCount: number = 0;
    let imageCount: number = 0;
    let skippedCount: number = 0;
    let totalUncompressed: number = 0;
    let cursor: number = 0;
    for (let index: number = 0; index < entryCount; index++) {
      if (cursor + ZipImportService.CENTRAL_HEADER_SIZE > central.length) {
        throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
      }
      if (ZipImportService.u32(central, cursor) !== ZipImportService.CENTRAL_SIGNATURE) {
        throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
      }
      const generalFlag: number = ZipImportService.u16(central, cursor + 8);
      const method: number = ZipImportService.u16(central, cursor + 10);
      const crc: number = ZipImportService.u32(central, cursor + 16);
      const compressedSize: number = ZipImportService.u32(central, cursor + 20);
      const uncompressedSize: number = ZipImportService.u32(central, cursor + 24);
      const nameLength: number = ZipImportService.u16(central, cursor + 28);
      const extraLength: number = ZipImportService.u16(central, cursor + 30);
      const commentLength: number = ZipImportService.u16(central, cursor + 32);
      const diskStart: number = ZipImportService.u16(central, cursor + 34);
      const externalAttributes: number = ZipImportService.u32(central, cursor + 38);
      const localHeaderOffset: number = ZipImportService.u32(central, cursor + 42);
      const recordEnd: number = cursor + ZipImportService.CENTRAL_HEADER_SIZE + nameLength + extraLength + commentLength;
      if (recordEnd > central.length) {
        throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
      }
      if (nameLength === 0) {
        throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
      }
      if (nameLength > limits.maxNameBytes) {
        throw new ZipImportError('over_limit', 'ZIP 内条目名超出长度上限');
      }
      if ((generalFlag & 0x1) !== 0) {
        throw new ZipImportError('encrypted', 'ZIP 使用了加密，暂不支持');
      }
      if (method !== 0 && method !== 8) {
        throw new ZipImportError('corrupt', 'ZIP 使用了不支持的压缩方法');
      }
      if (diskStart !== 0) {
        throw new ZipImportError('corrupt', 'ZIP 为多盘分卷，暂不支持');
      }
      if (((externalAttributes >>> 16) & 0xF000) === 0xA000) {
        throw new ZipImportError('unsafe', 'ZIP 内包含符号链接条目');
      }
      if (uncompressedSize === 0xFFFFFFFF || compressedSize === 0xFFFFFFFF ||
        localHeaderOffset === 0xFFFFFFFF) {
        throw new ZipImportError('over_limit', 'ZIP 使用了不支持的 ZIP64 格式');
      }
      if (uncompressedSize > limits.maxSingleUncompressed) {
        throw new ZipImportError('over_limit', 'ZIP 内单文件解压后超出大小上限');
      }
      if (localHeaderOffset + ZipImportService.LOCAL_HEADER_SIZE > centralOffset) {
        throw new ZipImportError('corrupt', 'ZIP 内条目定位失败');
      }
      const nameBytes: Uint8Array = central.subarray(
        cursor + ZipImportService.CENTRAL_HEADER_SIZE, cursor + ZipImportService.CENTRAL_HEADER_SIZE + nameLength);
      // 字节级安全检查先于解码：反斜杠 / 控制字符 / 绝对路径 / 盘符（36.5）。
      if (ZipImportService.hasUnsafeNameBytes(nameBytes)) {
        throw new ZipImportError('unsafe', 'ZIP 内包含不安全的条目名');
      }
      const isDirectory: boolean = nameBytes[nameBytes.length - 1] === 0x2F;
      const decoded: string = ZipImportService.decodeUtf8(
        isDirectory ? nameBytes.subarray(0, nameBytes.length - 1) : nameBytes);
      if (decoded.length === 0) {
        throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
      }
      const segments: string[] = decoded.split('/');
      let hidden: boolean = false;
      for (let segIndex: number = 0; segIndex < segments.length; segIndex++) {
        const segment: string = segments[segIndex];
        if (segment.length === 0 || segment === '..' || segment === '.') {
          throw new ZipImportError('unsafe', 'ZIP 内包含不安全的条目名');
        }
        if (segment.startsWith('.')) {
          hidden = true;
        }
      }
      // 隐藏项与目录条目静默跳过（36.4），不计入 skippedCount。
      if (hidden || isDirectory) {
        cursor = recordEnd;
        continue;
      }
      const kind: string = ZipImportService.classifyEntryName(decoded);
      if (kind === 'skip') {
        skippedCount++;
        cursor = recordEnd;
        continue;
      }
      if (kind === 'note') {
        noteCount++;
      } else {
        imageCount++;
      }
      totalUncompressed += uncompressedSize;
      if (totalUncompressed > limits.maxTotalUncompressed) {
        throw new ZipImportError('over_limit', 'ZIP 解压后总大小超出上限');
      }
      const topSegment: string = decoded.indexOf('/') >= 0 ? decoded.slice(0, decoded.indexOf('/')) : '';
      if (topSegments.indexOf(topSegment) < 0) {
        topSegments.push(topSegment);
      }
      const entry: ZipParsedEntry = {
        name: decoded,
        kind: kind,
        method: method,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
        crc32: crc
      };
      entries.push(entry);
      cursor = recordEnd;
    }
    if (cursor !== central.length) {
      throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
    }
    if (noteCount === 0) {
      throw new ZipImportError('not_vault', 'ZIP 中没有 Markdown 笔记');
    }
    const topFolder: string = topSegments.length === 1 && topSegments[0].length > 0 ? topSegments[0] : '';
    const parsed: ZipParsed = {
      entries: entries,
      noteCount: noteCount,
      imageCount: imageCount,
      skippedCount: skippedCount,
      topFolder: topFolder,
      totalUncompressed: totalUncompressed
    };
    return parsed;
  }

  /**
   * 逐条目抽取写入（36.4 / 36.6 / 36.7）：只写 note / image，保持相对结构；
   * 每条目先核对本地文件头与数据边界，解压后校验长度与 CRC32；
   * 条目间检查取消标志。返回成功写入的条目数。
   */
  static async extract(reader: ZipReaderPort, writer: ZipWriterPort, inflate: InflatePort,
    parsed: ZipParsed, hooks: ZipExtractHooks): Promise<number> {
    const targets: ZipParsedEntry[] = [];
    for (let index: number = 0; index < parsed.entries.length; index++) {
      if (parsed.entries[index].kind !== 'skip') {
        targets.push(parsed.entries[index]);
      }
    }
    const totalSize: number = await reader.size();
    let done: number = 0;
    for (let index: number = 0; index < targets.length; index++) {
      const entry: ZipParsedEntry = targets[index];
      if (hooks.isCancelled !== undefined && hooks.isCancelled()) {
        throw new ZipImportError('cancelled', '导入已取消');
      }
      const header: Uint8Array = await reader.readAt(entry.localHeaderOffset, ZipImportService.LOCAL_HEADER_SIZE);
      if (ZipImportService.u32(header, 0) !== ZipImportService.LOCAL_SIGNATURE) {
        throw new ZipImportError('corrupt', 'ZIP 内条目定位失败');
      }
      const localNameLength: number = ZipImportService.u16(header, 26);
      const localExtraLength: number = ZipImportService.u16(header, 28);
      const dataOffset: number = entry.localHeaderOffset +
        ZipImportService.LOCAL_HEADER_SIZE + localNameLength + localExtraLength;
      if (dataOffset + entry.compressedSize > totalSize) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      let compressed: Uint8Array = new Uint8Array(0);
      if (entry.compressedSize > 0) {
        compressed = await reader.readAt(dataOffset, entry.compressedSize);
      }
      let content: Uint8Array;
      if (entry.method === 8) {
        content = await inflate.inflateRaw(compressed, entry.uncompressedSize);
      } else {
        content = compressed;
      }
      if (content.length !== entry.uncompressedSize) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      if (ZipImportService.crc32(content) !== entry.crc32) {
        throw new ZipImportError('corrupt', 'ZIP 数据损坏');
      }
      await writer.writeFile(entry.name, content);
      done++;
      if (hooks.onProgress !== undefined) {
        hooks.onProgress(done, targets.length);
      }
    }
    return done;
  }

  /** 文件扩展名分类（36.4）：note / image / skip。 */
  static classifyEntryName(name: string): string {
    const slash: number = name.lastIndexOf('/');
    const base: string = slash >= 0 ? name.slice(slash + 1) : name;
    const dot: number = base.lastIndexOf('.');
    if (dot <= 0 || dot === base.length - 1) {
      return 'skip';
    }
    const ext: string = base.slice(dot + 1).toLowerCase();
    if (ext === 'md' || ext === 'markdown') {
      return 'note';
    }
    if (ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'gif' || ext === 'webp' || ext === 'svg') {
      return 'image';
    }
    return 'skip';
  }

  /**
   * 定位 End of Central Directory：从文件尾向前扫描 EOCD 签名，
   * 且注释长度必须与文件尾对齐（排除嵌套 ZIP 的伪签名）。
   */
  private static async locateEocd(reader: ZipReaderPort, totalSize: number): Promise<number> {
    if (totalSize < ZipImportService.EOCD_MIN_SIZE) {
      throw new ZipImportError('corrupt', '不是有效的 ZIP 文件');
    }
    const windowLength: number = Math.min(totalSize, ZipImportService.EOCD_SCAN_WINDOW);
    const window: Uint8Array = await reader.readAt(totalSize - windowLength, windowLength);
    for (let offset: number = window.length - ZipImportService.EOCD_MIN_SIZE; offset >= 0; offset--) {
      if (window[offset] === 0x50 && window[offset + 1] === 0x4B &&
        window[offset + 2] === 0x05 && window[offset + 3] === 0x06) {
        const commentLength: number = ZipImportService.u16(window, offset + 20);
        if (offset + ZipImportService.EOCD_MIN_SIZE + commentLength === window.length) {
          return totalSize - windowLength + offset;
        }
      }
    }
    throw new ZipImportError('corrupt', '不是有效的 ZIP 文件');
  }

  /** 字节级条目名检查：反斜杠、控制字符、前导 `/`、位置 1 的 `:`（盘符）。 */
  private static hasUnsafeNameBytes(nameBytes: Uint8Array): boolean {
    for (let index: number = 0; index < nameBytes.length; index++) {
      const byte: number = nameBytes[index];
      if (byte === 0x5C || byte < 0x20 || byte === 0x7F) {
        return true;
      }
      if (index === 0 && byte === 0x2F) {
        return true;
      }
      if (index === 1 && byte === 0x3A) {
        return true;
      }
    }
    return false;
  }

  /** 宽容式 UTF-8 解码（无效序列替换为 U+FFFD）；ZIP 条目名按 UTF-8 处理。 */
  private static decodeUtf8(bytes: Uint8Array): string {
    let out: string = '';
    let index: number = 0;
    while (index < bytes.length) {
      const b0: number = bytes[index];
      if (b0 < 0x80) {
        out += String.fromCharCode(b0);
        index++;
      } else if (b0 < 0xC0) {
        out += '\uFFFD';
        index++;
      } else if (b0 < 0xE0) {
        if (index + 1 < bytes.length && (bytes[index + 1] & 0xC0) === 0x80) {
          out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[index + 1] & 0x3F));
          index += 2;
        } else {
          out += '\uFFFD';
          index++;
        }
      } else if (b0 < 0xF0) {
        if (index + 2 < bytes.length && (bytes[index + 1] & 0xC0) === 0x80 && (bytes[index + 2] & 0xC0) === 0x80) {
          out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[index + 1] & 0x3F) << 6) | (bytes[index + 2] & 0x3F));
          index += 3;
        } else {
          out += '\uFFFD';
          index++;
        }
      } else {
        if (index + 3 < bytes.length && (bytes[index + 1] & 0xC0) === 0x80 &&
          (bytes[index + 2] & 0xC0) === 0x80 && (bytes[index + 3] & 0xC0) === 0x80) {
          const codePoint: number = ((b0 & 0x07) << 18) | ((bytes[index + 1] & 0x3F) << 12) |
            ((bytes[index + 2] & 0x3F) << 6) | (bytes[index + 3] & 0x3F);
          const offset: number = codePoint - 0x10000;
          out += String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF));
          index += 4;
        } else {
          out += '\uFFFD';
          index++;
        }
      }
    }
    return out;
  }

  /** CRC32（ZIP 标准），逐条目完整性校验（36.7 不报告虚假成功）。 */
  static crc32(data: Uint8Array): number {
    if (ZipImportService.crcTable === null) {
      const table: number[] = [];
      for (let n: number = 0; n < 256; n++) {
        let current: number = n;
        for (let bit: number = 0; bit < 8; bit++) {
          current = (current & 1) !== 0 ? (0xEDB88320 ^ (current >>> 1)) : (current >>> 1);
        }
        table.push(current >>> 0);
      }
      ZipImportService.crcTable = table;
    }
    const table: number[] = ZipImportService.crcTable as number[];
    let crc: number = 0xFFFFFFFF;
    for (let index: number = 0; index < data.length; index++) {
      crc = table[(crc ^ data[index]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  private static u16(bytes: Uint8Array, offset: number): number {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  private static u32(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
  }
}
