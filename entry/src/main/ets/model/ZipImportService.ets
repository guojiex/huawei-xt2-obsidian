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
 * - v1.72 方案 B：库导入默认捕获 yaoshi-mtime.json 时间表候选（不进 entries、
 *   不计数）；extract 在 preserveMtime 开启时优先按表恢复 mtime，
 *   表缺失 / 损坏逐条回落 central directory 的 DOS 时间；
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
  /** ZIP DOS local-time timestamp converted to Epoch milliseconds. */
  modifiedAtMs: number;
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
  /** v1.72 方案 B：yaoshi-mtime.json 候选条目（readMtimeManifest 开启且命中；否则 null）。不进 entries、不计数。 */
  manifestCandidate?: ZipParsedEntry | null;
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
  /** Optional restore hook; only application backup imports opt into timestamp recovery. */
  setModifiedTime?(relativePath: string, modifiedAtMs: number): void;
}

/** raw deflate 解压端口：设备侧用 zlib Zip.inflateInit2(-15) 实现（api_notes Y4）。 */
export interface InflatePort {
  inflateRaw(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array>;
}

/** 抽取过程钩子：条目间检查取消（36.5 核实结论 3）与进度回报（36.7）。 */
export interface ZipExtractHooks {
  isCancelled?: () => boolean;
  onProgress?: (done: number, total: number) => void;
  preserveMtime?: boolean;
}

export interface ZipParseProfile {
  allowHiddenEntries: boolean;
  acceptAllFiles: boolean;
  requireMarkdown: boolean;
  /** v1.72 方案 B：捕获 yaoshi-mtime.json 时间表候选；库导入默认开，应用备份恢复不开。 */
  readMtimeManifest?: boolean;
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

/** yaoshi-mtime.json 宽松解析模型：JSON.parse 一次性转换后逐字段验证（v1.72 方案 B）。 */
interface MtimeManifestRaw {
  version: number;
  files: MtimeManifestFileRaw[];
}

interface MtimeManifestFileRaw {
  path: string;
  mtimeMs: number;
}

export class ZipImportService {
  /** 默认上限（1GB 总量 / 单文件 128MB / 10000 条目；v1.36 §6 初值，v2.8 全局提高）。 */
  static readonly DEFAULT_LIMITS: ZipImportLimits = {
    maxEntries: 10000,
    maxTotalUncompressed: 1024 * 1024 * 1024,
    maxSingleUncompressed: 128 * 1024 * 1024,
    maxNameBytes: 1024
  };

  /** v1.72 方案 B：随 ZIP 写入的 mtime 时间表文件（payload 根、普通文件名，确保 compressFile 收录）。 */
  static readonly MTIME_MANIFEST_NAME: string = 'yaoshi-mtime.json';
  /** 时间表格式版本；不匹配的整表忽略。 */
  static readonly MTIME_MANIFEST_VERSION: number = 1;
  /** 单表解压字节上限：超表忽略，回落 DOS 时间。 */
  private static readonly MTIME_MANIFEST_MAX_BYTES: number = 8 * 1024 * 1024;
  /** 单条 mtime 上限（2100-01-01，Epoch 毫秒），防御异常远未来值。 */
  private static readonly MTIME_MANIFEST_MAX_MS: number = 4102444800000;
  /** 单条路径字符上限，与 ZIP 条目名上限同量级。 */
  private static readonly MTIME_MANIFEST_MAX_PATH: number = 1024;

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
  static async parse(reader: ZipReaderPort, limits: ZipImportLimits,
    profile?: ZipParseProfile): Promise<ZipParsed> {
    const activeProfile: ZipParseProfile = profile ?? {
      allowHiddenEntries: false,
      acceptAllFiles: false,
      requireMarkdown: true,
      readMtimeManifest: true
    };
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
      throw new ZipImportError('over_limit',
        'ZIP 内共 ' + entryCount.toString() + ' 个条目，超出上限 ' + limits.maxEntries.toString());
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
    let manifestCandidate: ZipParsedEntry | null = null;
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
      const dosTime: number = ZipImportService.u16(central, cursor + 12);
      const dosDate: number = ZipImportService.u16(central, cursor + 14);
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
        throw new ZipImportError('over_limit',
          'ZIP 内有条目名长 ' + nameLength.toString() + ' 字节，超出上限 ' + limits.maxNameBytes.toString() + ' 字节');
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
        const sizeCulpritName: string = ZipImportService.decodeUtf8(central.subarray(
          cursor + ZipImportService.CENTRAL_HEADER_SIZE, cursor + ZipImportService.CENTRAL_HEADER_SIZE + nameLength));
        throw new ZipImportError('over_limit',
          '「' + sizeCulpritName + '」解压后约 ' + ZipImportService.formatBytes(uncompressedSize) +
          '，超过单文件上限 ' + ZipImportService.formatBytes(limits.maxSingleUncompressed));
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
      if ((!activeProfile.allowHiddenEntries && hidden) || isDirectory) {
        cursor = recordEnd;
        continue;
      }
      // v1.72 方案 B：时间表候选静默捕获——不进 entries、不计数、不参与 topFolder 统计。
      if (activeProfile.readMtimeManifest === true &&
        (decoded === ZipImportService.MTIME_MANIFEST_NAME ||
          decoded.endsWith('/' + ZipImportService.MTIME_MANIFEST_NAME))) {
        if (manifestCandidate === null) {
          const candidate: ZipParsedEntry = {
            name: decoded,
            kind: 'skip',
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localHeaderOffset,
            crc32: crc,
            modifiedAtMs: 0
          };
          manifestCandidate = candidate;
        }
        cursor = recordEnd;
        continue;
      }
      const kind: string = activeProfile.acceptAllFiles ? 'file' : ZipImportService.classifyEntryName(decoded);
      if (kind === 'skip') {
        skippedCount++;
        cursor = recordEnd;
        continue;
      }
      if (!activeProfile.acceptAllFiles && kind === 'note') {
        noteCount++;
      } else if (!activeProfile.acceptAllFiles && kind === 'image') {
        imageCount++;
      }
      totalUncompressed += uncompressedSize;
      if (totalUncompressed > limits.maxTotalUncompressed) {
        throw new ZipImportError('over_limit',
          'ZIP 解压后总大小约 ' + ZipImportService.formatBytes(totalUncompressed) +
          '，超出上限 ' + ZipImportService.formatBytes(limits.maxTotalUncompressed));
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
        crc32: crc,
        modifiedAtMs: ZipImportService.decodeDosTimestamp(dosDate, dosTime)
      };
      entries.push(entry);
      cursor = recordEnd;
    }
    if (cursor !== central.length) {
      throw new ZipImportError('corrupt', 'ZIP 目录结构损坏');
    }
    if (activeProfile.requireMarkdown && noteCount === 0) {
      throw new ZipImportError('not_vault', 'ZIP 中没有 Markdown 笔记');
    }
    const topFolder: string = topSegments.length === 1 && topSegments[0].length > 0 ? topSegments[0] : '';
    const parsed: ZipParsed = {
      entries: entries,
      noteCount: noteCount,
      imageCount: imageCount,
      skippedCount: skippedCount,
      topFolder: topFolder,
      totalUncompressed: totalUncompressed,
      manifestCandidate: manifestCandidate
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
    // v1.72 方案 B：先读 yaoshi-mtime.json 时间表（尽力而为）；命中条目用其 mtime，否则回落 DOS。
    const mtimeOverrides: Map<string, number> = hooks.preserveMtime === true
      ? await ZipImportService.readMtimeOverrides(reader, inflate, parsed)
      : new Map<string, number>();
    let done: number = 0;
    for (let index: number = 0; index < targets.length; index++) {
      const entry: ZipParsedEntry = targets[index];
      if (hooks.isCancelled !== undefined && hooks.isCancelled()) {
        throw new ZipImportError('cancelled', '导入已取消');
      }
      const header: Uint8Array = await reader.readAt(entry.localHeaderOffset, ZipImportService.LOCAL_HEADER_SIZE);
      if (ZipImportService.u32(header, 0) !== ZipImportService.LOCAL_SIGNATURE) {
        throw new ZipImportError('corrupt', 'ZIP 内条目定位失败(' + entry.name + ')');
      }
      const localNameLength: number = ZipImportService.u16(header, 26);
      const localExtraLength: number = ZipImportService.u16(header, 28);
      const dataOffset: number = entry.localHeaderOffset +
        ZipImportService.LOCAL_HEADER_SIZE + localNameLength + localExtraLength;
      if (dataOffset + entry.compressedSize > totalSize) {
        throw new ZipImportError('corrupt', 'ZIP 数据边界越界(' + entry.name + ')');
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
        throw new ZipImportError('corrupt', 'ZIP 条目长度不符(' + entry.name + ')');
      }
      if (ZipImportService.crc32(content) !== entry.crc32) {
        throw new ZipImportError('corrupt', 'ZIP 条目 CRC32 不符(' + entry.name + ')');
      }
      await writer.writeFile(entry.name, content);
      const restoredMtime: number = mtimeOverrides.get(entry.name) ?? entry.modifiedAtMs;
      if (hooks.preserveMtime === true && restoredMtime > 0 && writer.setModifiedTime !== undefined) {
        writer.setModifiedTime(entry.name, restoredMtime);
      }
      done++;
      if (hooks.onProgress !== undefined) {
        hooks.onProgress(done, targets.length);
      }
    }
    return done;
  }

  /**
   * v1.72 方案 B（72.2）：读取 yaoshi-mtime.json 时间表为「条目名 → Epoch 毫秒」映射。
   * 尽力而为：候选缺失 / 超大小 / 本地头不一致 / 长度 / CRC / 解析 / 校验任一失败
   * 都返回空表，逐条目回落 DOS 时间；失败不抛错、不影响导入内容。
   */
  private static async readMtimeOverrides(reader: ZipReaderPort, inflate: InflatePort,
    parsed: ZipParsed): Promise<Map<string, number>> {
    const overrides: Map<string, number> = new Map<string, number>();
    const candidate: ZipParsedEntry | null = parsed.manifestCandidate ?? null;
    if (candidate === null) {
      return overrides;
    }
    if (candidate.uncompressedSize === 0 ||
      candidate.uncompressedSize > ZipImportService.MTIME_MANIFEST_MAX_BYTES) {
      return overrides;
    }
    try {
      const totalSize: number = await reader.size();
      const header: Uint8Array = await reader.readAt(candidate.localHeaderOffset,
        ZipImportService.LOCAL_HEADER_SIZE);
      if (ZipImportService.u32(header, 0) !== ZipImportService.LOCAL_SIGNATURE) {
        return overrides;
      }
      const localNameLength: number = ZipImportService.u16(header, 26);
      const localExtraLength: number = ZipImportService.u16(header, 28);
      const dataOffset: number = candidate.localHeaderOffset +
        ZipImportService.LOCAL_HEADER_SIZE + localNameLength + localExtraLength;
      if (dataOffset + candidate.compressedSize > totalSize) {
        return overrides;
      }
      let compressed: Uint8Array = new Uint8Array(0);
      if (candidate.compressedSize > 0) {
        compressed = await reader.readAt(dataOffset, candidate.compressedSize);
      }
      let content: Uint8Array;
      if (candidate.method === 8) {
        content = await inflate.inflateRaw(compressed, candidate.uncompressedSize);
      } else {
        content = compressed;
      }
      if (content.length !== candidate.uncompressedSize) {
        return overrides;
      }
      if (ZipImportService.crc32(content) !== candidate.crc32) {
        return overrides;
      }
      ZipImportService.applyMtimeManifest(ZipImportService.decodeUtf8(content),
        parsed.topFolder, overrides);
    } catch (error) {
      // 时间表是尽力而为的元数据：任何失败回落 DOS 时间。
    }
    return overrides;
  }

  /** 解析并登记时间表；version 不符 / 结构非法整表忽略，单条非法仅跳过该条。 */
  private static applyMtimeManifest(manifestText: string, topFolder: string,
    overrides: Map<string, number>): void {
    const raw: MtimeManifestRaw = JSON.parse(manifestText) as MtimeManifestRaw;
    if (raw === null || typeof raw !== 'object' ||
      raw.version !== ZipImportService.MTIME_MANIFEST_VERSION || !Array.isArray(raw.files)) {
      return;
    }
    for (let index: number = 0; index < raw.files.length; index++) {
      const item: MtimeManifestFileRaw = raw.files[index];
      if (item === null) {
        continue;
      }
      const path: string = item.path;
      const mtimeMs: number = item.mtimeMs;
      if (typeof path !== 'string' || typeof mtimeMs !== 'number' ||
        !ZipImportService.isSafeManifestPath(path) ||
        !(mtimeMs > 0) || mtimeMs > ZipImportService.MTIME_MANIFEST_MAX_MS) {
        continue;
      }
      overrides.set(path, mtimeMs);
      if (topFolder.length > 0) {
        // 导入 ZIP 可能整体套一层顶层目录（topFolder）：补注册带前缀形态；
        // 反之 manifest 路径自带前缀时补注册剥离形态，双向兜底。
        overrides.set(topFolder + '/' + path, mtimeMs);
        if (path.startsWith(topFolder + '/')) {
          overrides.set(path.slice(topFolder.length + 1), mtimeMs);
        }
      }
    }
  }

  /** 时间表内路径的字符串级校验：与 ZIP 条目名同一安全基线（36.5）。 */
  private static isSafeManifestPath(path: string): boolean {
    if (path.length === 0 || path.length > ZipImportService.MTIME_MANIFEST_MAX_PATH) {
      return false;
    }
    if (path.startsWith('/') || path.indexOf('\\') >= 0 || path.indexOf(':') >= 0) {
      return false;
    }
    const segments: string[] = path.split('/');
    for (let index: number = 0; index < segments.length; index++) {
      const segment: string = segments[index];
      if (segment.length === 0 || segment === '.' || segment === '..') {
        return false;
      }
      for (let charIndex: number = 0; charIndex < segment.length; charIndex++) {
        const code: number = segment.charCodeAt(charIndex);
        if (code < 0x20 || code === 0x7F) {
          return false;
        }
      }
    }
    return true;
  }

  private static decodeDosTimestamp(dateBits: number, timeBits: number): number {
    const year: number = 1980 + ((dateBits >>> 9) & 0x7F);
    const month: number = (dateBits >>> 5) & 0x0F;
    const day: number = dateBits & 0x1F;
    const hour: number = (timeBits >>> 11) & 0x1F;
    const minute: number = (timeBits >>> 5) & 0x3F;
    const second: number = (timeBits & 0x1F) * 2;
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 58) {
      return 0;
    }
    const timestamp: Date = new Date(year, month - 1, day, hour, minute, second);
    if (timestamp.getFullYear() !== year || timestamp.getMonth() !== month - 1 || timestamp.getDate() !== day) {
      return 0;
    }
    return timestamp.getTime();
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

  /** 人类可读字节数（导入 / 备份错误提示共用；GB 两位小数、MB/KB 一位小数、不足 1KB 显示字节数，1024 进制）。 */
  static formatBytes(bytes: number): string {
    const gbUnit: number = 1024 * 1024 * 1024;
    const mbUnit: number = 1024 * 1024;
    if (bytes >= gbUnit) {
      return (bytes / gbUnit).toFixed(2) + ' GB';
    }
    if (bytes >= mbUnit) {
      return (bytes / mbUnit).toFixed(1) + ' MB';
    }
    if (bytes >= 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return bytes.toString() + ' 字节';
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
