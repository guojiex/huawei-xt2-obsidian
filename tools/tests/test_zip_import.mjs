import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

// ---------------------------------------------------------------------------
// v1.36 从 ZIP 导入：ZipImportService（行为，Node 真实 deflate 交叉验证）。
// 纯逻辑文件零 @kit 依赖，可整体 transform 后在 vm 中运行。
// ---------------------------------------------------------------------------

const serviceSource = readSourceFile(new URL('../../entry/src/main/ets/model/ZipImportService.ets', import.meta.url));
const serviceCode = transformSync(serviceSource, { loader: 'ts', format: 'cjs' }).code;
const serviceContext = vm.createContext({ module: { exports: {} } });
vm.runInContext(serviceCode, serviceContext);
const ZipImportService = serviceContext.module.exports.ZipImportService;
const ZipImportError = serviceContext.module.exports.ZipImportError;

assert.ok(typeof ZipImportService.parse === 'function', 'ZipImportService.parse 应可导出');
assert.ok(typeof ZipImportService.extract === 'function', 'ZipImportService.extract 应可导出');

// ---------------------------- 测试用 ZIP 构造器 ----------------------------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
})();

function crc32Of(buffer) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buffer.length; i++) {
    c = CRC_TABLE[(c ^ buffer[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}

function buildZip(entries, opts = {}) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.name, 'utf8');
    const data = Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data || '', 'utf8');
    const method = entry.method === undefined ? 8 : entry.method;
    const flags = (entry.flags || 0) | 0x800;
    const stored = method === 8 ? zlib.deflateRawSync(data) : data;
    const crc = entry.crc === undefined ? crc32Of(data) : entry.crc;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(stored.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    chunks.push(local, nameBuf, stored);
    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(flags, 8);
    centralHeader.writeUInt16LE(method, 10);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(stored.length, 20);
    centralHeader.writeUInt32LE(data.length, 24);
    centralHeader.writeUInt16LE(nameBuf.length, 28);
    centralHeader.writeUInt16LE(entry.extraLength || 0, 30);
    centralHeader.writeUInt16LE(entry.commentLength || 0, 32);
    centralHeader.writeUInt32LE(entry.extAttr || 0, 38);
    centralHeader.writeUInt32LE(entry.localOffset === undefined ? offset : entry.localOffset, 42);
    central.push(Buffer.concat([centralHeader, nameBuf]));
    offset += local.length + nameBuf.length + stored.length;
  }
  const centralBuf = Buffer.concat(central);
  const centralStart = offset;
  const eocd = Buffer.alloc(22);
  const count = opts.entryCount === undefined ? entries.length : opts.entryCount;
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(count, 8);
  eocd.writeUInt16LE(count, 10);
  eocd.writeUInt32LE(opts.cdSize === undefined ? centralBuf.length : opts.cdSize, 12);
  eocd.writeUInt32LE(opts.cdOffset === undefined ? centralStart : opts.cdOffset, 16);
  const comment = opts.comment ? Buffer.from(opts.comment, 'utf8') : Buffer.alloc(0);
  eocd.writeUInt16LE(comment.length, 20);
  return Buffer.concat([...chunks, centralBuf, eocd, comment]);
}

function createMockReader(buffer) {
  const bytes = new Uint8Array(buffer);
  return {
    size: async () => bytes.length,
    readAt: async (offset, length) => bytes.slice(offset, offset + length)
  };
}

function createMockWriter() {
  const files = new Map();
  const order = [];
  return {
    files,
    order,
    writeFile: async (relativePath, data) => {
      order.push(relativePath);
      files.set(relativePath, Buffer.from(data));
    }
  };
}

const nodeInflate = {
  inflateRaw: async (compressed) => new Uint8Array(zlib.inflateRawSync(Buffer.from(compressed)))
};

async function parseKind(zipBuffer, limits) {
  try {
    await ZipImportService.parse(createMockReader(zipBuffer), limits || ZipImportService.DEFAULT_LIMITS);
    return null;
  } catch (error) {
    return error.kind || `no-kind:${error.message}`;
  }
}

async function extractKind(zipBuffer, parsed, writer, hooks) {
  try {
    await ZipImportService.extract(createMockReader(zipBuffer), writer || createMockWriter(),
      nodeInflate, parsed, hooks || {});
    return null;
  } catch (error) {
    return error.kind || `no-kind:${error.message}`;
  }
}

const smallLimits = {
  maxEntries: 5000,
  maxTotalUncompressed: 512 * 1024 * 1024,
  maxSingleUncompressed: 64 * 1024 * 1024,
  maxNameBytes: 1024
};

// vm realm 与断言侧原型不同，JSON 往返归一后再比较。
const plain = (value) => JSON.parse(JSON.stringify(value));

// ------------------------------- parse 行为 -------------------------------

test('v1.36 parse 统计笔记/图片/跳过文件并给出唯一顶层文件夹', async () => {
  const zip = buildZip([
    { name: 'MyVault/' },
    { name: 'MyVault/note.md', data: '# 笔记' },
    { name: 'MyVault/sub/图片.png', data: Buffer.from([0x89, 0x50, 0x4E, 0x47]) },
    { name: 'MyVault/other.txt', data: 'misc' },
    { name: 'MyVault/.git/config', data: 'hidden' },
    { name: 'MyVault/.trash/deleted.md', data: 'hidden' },
    { name: 'outside.md' }
  ]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.noteCount, 2);
  assert.equal(parsed.imageCount, 1);
  assert.equal(parsed.skippedCount, 1); // other.txt；隐藏项与目录不计
  assert.equal(parsed.topFolder, ''); // 既有 MyVault/ 又有根级 outside.md
  assert.equal(parsed.totalUncompressed > 0, true);
  const names = parsed.entries.map((entry) => entry.name).sort();
  assert.deepEqual(plain(parsed.entries.map((entry) => entry.name).sort()),
    ['MyVault/note.md', 'MyVault/sub/图片.png', 'outside.md']);
});

test('v1.36 parse 顶层文件夹唯一且无根级文件时返回该文件夹名', async () => {
  const zip = buildZip([
    { name: '我的库/' },
    { name: '我的库/a.md', data: 'a' },
    { name: '我的库/deep/b/b.md', data: 'b' }
  ]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.topFolder, '我的库');
  assert.equal(parsed.noteCount, 2);
});

test('v1.36 parse 全根级文件时 topFolder 为空串', async () => {
  const zip = buildZip([{ name: 'a.md', data: 'a' }, { name: 'img/pic.jpg', data: 'x' }]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.topFolder, '');
});

test('v1.36 parse 两个不同顶层文件夹时 topFolder 为空串', async () => {
  const zip = buildZip([{ name: 'A/a.md', data: 'a' }, { name: 'B/b.md', data: 'b' }]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.topFolder, '');
});

test('v1.36 parse 跳过目录条目不要求其本地文件头有效', async () => {
  // 目录条目在 parse 阶段即被跳过（不读本地文件头），常规 ZIP 中目录条目带头也不受影响。
  const zip = buildZip([{ name: 'dir/' }, { name: 'dir/a.md', data: 'a' }]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.noteCount, 1);
  assert.equal(parsed.entries.length, 1);
});

test('v1.36 EOCD 注释存在时仍能定位（含伪签名）', async () => {
  const zip = buildZip(
    [{ name: 'a.md', data: 'a' }],
    { comment: '尾注 PK\u0005\u0006 嵌入注释中不应干扰' }
  );
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(parsed.noteCount, 1);
});

// ------------------------------- 安全校验 ---------------------------------

test('v1.36 36.5 拒绝 .. 越级、绝对路径、反斜杠、盘符、空段与 . 段', async () => {
  const bad = [
    { name: '../evil.md', data: 'x' },
    { name: 'a/../../evil.md', data: 'x' },
    { name: '/abs.md', data: 'x' },
    { name: 'a\\b.md', data: 'x' },
    { name: 'C:drive.md', data: 'x' },
    { name: 'a//b.md', data: 'x' },
    { name: 'a/./b.md', data: 'x' },
    { name: './a.md', data: 'x' }
  ];
  for (const entry of bad) {
    const zip = buildZip([entry]);
    assert.equal(await parseKind(zip), 'unsafe', `条目 ${entry.name} 应判 unsafe`);
  }
});

test('v1.36 36.5 拒绝控制字符与超长条目名', async () => {
  const control = buildZip([{ name: 'a\u0000b.md', data: 'x' }]);
  assert.equal(await parseKind(control), 'unsafe');
  const longLimits = Object.assign({}, smallLimits, { maxNameBytes: 10 });
  const long = buildZip([{ name: 'aaaaaaaaaaaa.md', data: 'x' }]);
  assert.equal(await parseKind(long, longLimits), 'over_limit');
});

test('v1.36 36.5 拒绝加密条目', async () => {
  const zip = buildZip([{ name: 'a.md', data: 'x', flags: 0x1 }]);
  assert.equal(await parseKind(zip), 'encrypted');
});

test('v1.36 36.5 拒绝不支持的压缩方法', async () => {
  const zip = buildZip([{ name: 'a.md', data: 'x', method: 12 }]);
  assert.equal(await parseKind(zip), 'corrupt');
});

test('v1.36 36.5 拒绝符号链接条目', async () => {
  const zip = buildZip([{ name: 'link.md', data: '/target', extAttr: (0xA1FF << 16) >>> 0 }]);
  assert.equal(await parseKind(zip), 'unsafe');
});

test('v1.36 36.5 拒绝 ZIP64 标记与多盘分卷', async () => {
  // 把中央目录首条目的 uncompressedSize 改成 0xFFFFFFFF（ZIP64 标记）
  const crafted = buildZip([{ name: 'a.md', data: 'x' }]);
  const cdStart = crafted.readUInt32LE(crafted.length - 6);
  crafted.writeUInt32LE(0xFFFFFFFF, cdStart + 24);
  assert.equal(await parseKind(crafted), 'over_limit');

  // 多盘分卷：diskStart !== 0 → corrupt
  const multiDisk = buildZip([{ name: 'a.md', data: 'x' }]);
  const cdStart2 = multiDisk.readUInt32LE(multiDisk.length - 6);
  multiDisk.writeUInt16LE(1, cdStart2 + 34);
  assert.equal(await parseKind(multiDisk), 'corrupt');
});

test('v1.36 36.5 条目数 / 单文件 / 总量上限', async () => {
  const two = buildZip([{ name: 'a.md', data: 'x' }, { name: 'b.md', data: 'y' }]);
  const entryLimit = Object.assign({}, smallLimits, { maxEntries: 1 });
  assert.equal(await parseKind(two, entryLimit), 'over_limit');

  const big = buildZip([{ name: 'a.md', data: 'x'.repeat(20) }]);
  const singleLimit = Object.assign({}, smallLimits, { maxSingleUncompressed: 10 });
  assert.equal(await parseKind(big, singleLimit), 'over_limit');

  const pair = buildZip([{ name: 'a.md', data: 'x'.repeat(10) }, { name: 'b.md', data: 'y'.repeat(10) }]);
  const totalLimit = Object.assign({}, smallLimits, { maxTotalUncompressed: 15 });
  assert.equal(await parseKind(pair, totalLimit), 'over_limit');
});

test('v1.36 不是笔记库 ZIP（无 Markdown）或空 ZIP 时拒绝', async () => {
  const onlyText = buildZip([{ name: 'a.txt', data: 'x' }]);
  assert.equal(await parseKind(onlyText), 'not_vault');
  const onlyImage = buildZip([{ name: 'a.png', data: 'x' }]);
  assert.equal(await parseKind(onlyImage), 'not_vault');
  const empty = buildZip([], { entryCount: 0 });
  assert.equal(await parseKind(empty), 'not_vault');
});

test('v1.36 非法 / 截断 ZIP 报 corrupt', async () => {
  assert.equal(await parseKind(Buffer.from('这不是一个zip文件，真的不是')), 'corrupt');
  assert.equal(await parseKind(Buffer.alloc(10)), 'corrupt');
  const zip = buildZip([{ name: 'a.md', data: 'x' }]);
  assert.equal(await parseKind(zip.subarray(0, zip.length - 8)), 'corrupt');
  const badCdOffset = buildZip([{ name: 'a.md', data: 'x' }], { cdOffset: 1 });
  assert.equal(await parseKind(badCdOffset), 'corrupt');
});

// ------------------------------- extract 行为 -----------------------------

test('v1.36 36.4 extract 只写笔记与图片并保持相对结构（含中文）', async () => {
  const noteText = '# 标题\n\n正文';
  const pngBytes = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]);
  const zip = buildZip([
    { name: 'MyVault/' },
    { name: 'MyVault/笔记.md', data: noteText },
    { name: 'MyVault/attachments/图 1.png', data: pngBytes, method: 0 },
    { name: 'MyVault/.skip.md', data: 'hidden' },
    { name: 'MyVault/other.txt', data: 'skip' }
  ]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  const writer = createMockWriter();
  const written = await ZipImportService.extract(createMockReader(zip), writer, nodeInflate, parsed, {});
  assert.equal(written, 2);
  assert.deepEqual(writer.order, ['MyVault/笔记.md', 'MyVault/attachments/图 1.png']);
  assert.equal(writer.files.get('MyVault/笔记.md').toString('utf8'), noteText);
  assert.deepEqual(writer.files.get('MyVault/attachments/图 1.png'), pngBytes);
});

test('v1.36 36.7 extract 每条目回报进度', async () => {
  const zip = buildZip([{ name: 'a.md', data: '1' }, { name: 'b.md', data: '2' }, { name: 'c.md', data: '3' }]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  const progress = [];
  await ZipImportService.extract(createMockReader(zip), createMockWriter(), nodeInflate, parsed, {
    onProgress: (done, total) => progress.push([done, total])
  });
  assert.deepEqual(progress, [[1, 3], [2, 3], [3, 3]]);
});

test('v1.36 36.5 extract 在条目间响应取消', async () => {
  const zip = buildZip([{ name: 'a.md', data: '1' }, { name: 'b.md', data: '2' }]);
  const parsed = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  const writer = createMockWriter();
  let checks = 0;
  const kind = await extractKind(zip, parsed, writer, {
    isCancelled: () => {
      checks++;
      return checks > 1;
    }
  });
  assert.equal(kind, 'cancelled');
  assert.equal(writer.order.length, 1); // 第一条已写入，第二条开始前取消
});

test('v1.36 36.7 extract 校验 CRC 与长度，损坏时报 corrupt', async () => {
  const badCrc = buildZip([{ name: 'a.md', data: 'x', crc: 0xDEADBEEF }]);
  const parsedCrc = await ZipImportService.parse(createMockReader(badCrc), ZipImportService.DEFAULT_LIMITS);
  assert.equal(await extractKind(badCrc, parsedCrc), 'corrupt');

  // 本地文件头签名错误 → corrupt
  const zip = buildZip([{ name: 'a.md', data: 'x' }]);
  zip.writeUInt32LE(0x11111111, 0);
  const parsedBad = await ZipImportService.parse(createMockReader(zip), ZipImportService.DEFAULT_LIMITS);
  assert.equal(await extractKind(zip, parsedBad), 'corrupt');
});

test('v1.36 crc32 与标准测试向量一致', () => {
  assert.equal(ZipImportService.crc32(new TextEncoder().encode('123456789')), 0xCBF43926);
  assert.equal(ZipImportService.crc32(new Uint8Array(0)), 0);
});

test('v1.36 36.2 分类覆盖 markdown 大小写与全部支持图片扩展名', () => {
  assert.equal(ZipImportService.classifyEntryName('a.md'), 'note');
  assert.equal(ZipImportService.classifyEntryName('a.MD'), 'note');
  assert.equal(ZipImportService.classifyEntryName('a.markdown'), 'note');
  assert.equal(ZipImportService.classifyEntryName('dir/b.PNG'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.JPG'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.jpeg'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.gif'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.webp'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.svg'), 'image');
  assert.equal(ZipImportService.classifyEntryName('b.txt'), 'skip');
  assert.equal(ZipImportService.classifyEntryName('b'), 'skip');
  assert.equal(ZipImportService.classifyEntryName('.md'), 'skip');
  assert.equal(ZipImportService.classifyEntryName('b.md/'), 'skip');
});

// ---------------------------------------------------------------------------
// v1.36 Index.ets 编排与 VaultRegistry 复用（源断言：36.1–36.7 接线不回归）。
// ---------------------------------------------------------------------------

const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const registrySource = readSourceFile(new URL('../../entry/src/main/ets/model/VaultRegistry.ets', import.meta.url));

test('v1.36 36.6 Index 清理暂存残留：启动清根、弹窗关闭清状态、临时目录后缀同源', () => {
  assert.match(indexSource, /const ZIP_IMPORTING_SUFFIX: string = '__importing';/);
  // aboutToAppear 尾部：启动即清 staging 根，残留不跨启动累积
  assert.match(indexSource, /this\.startExternalVaultPolling\(\);\r?\n\s*this\.cleanupZipImportStaging\(\);/);
  // 弹窗取消/关闭（clearImportDraft）同步清理 zip 解析与暂存
  assert.match(indexSource, /const clearImportDraft = \(\): void => \{\r?\n\s*GitImportDraftStore\.clear\(\);\r?\n\s*this\.pendingExternalDirectory = null;\r?\n\s*this\.cleanupZipImportState\(\);/);
  assert.match(indexSource, /onChooseZip: \(\): Promise<ZipChooseOutcome> => this\.chooseZipBackup\(\)/);
  assert.match(indexSource, /onImportZip: \(name: string, onProgress: \(done: number, total: number\) => void\): Promise<ZipImportOutcome> =>/);
  assert.match(indexSource, /private cleanupZipImportStaging\(\): void \{/);
  assert.match(indexSource, /private cleanupZipImportState\(\): void \{[\s\S]*?removeStagingFile\(this\.pendingZipStagingPath\)/);
  assert.match(indexSource, /private removePathTreeForImport\(/);
});

test('v1.36 36.1/36.2 chooseZipBackup：取消保原状态、暂存复制、解析预览与默认库名（源断言）', () => {
  // 选择器异常按取消处理（36.1：取消回到原状态，不弹失败）
  assert.match(indexSource, /catch \(_error\) \{\r?\n\s*\/\/ 选择器异常按取消处理（36\.1：取消回到原状态）\r?\n\s*picked = null;\r?\n\s*\}/);
  assert.match(indexSource, /status: 'cancelled', kind: 'corrupt', fileName: '', summary: '', defaultVaultName: ''/);
  // 每次选择先清旧暂存与旧解析结果
  assert.match(indexSource, /this\.cleanupZipImportState\(\);\r?\n\s*const fileName: string = picked\.fileName\.length > 0 \? picked\.fileName : '备份\.zip';/);
  // staging 文件名带时间戳，避免重名覆盖
  assert.match(indexSource, /resolveZipImportStaging\('import-' \+ Date\.now\(\)\.toString\(\) \+ '\.zip'\)/);
  assert.match(indexSource, /await copyPickerZipToStaging\(picked\.uri, stagingPath\)/);
  assert.match(indexSource, /parsed = await ZipImportService\.parse\(reader, ZipImportService\.DEFAULT_LIMITS\);/);
  assert.match(indexSource, /' 篇笔记 · ' \+ parsed\.imageCount\.toString\(\) \+/);
  assert.match(indexSource, /' 张图片 · 跳过 ' \+ parsed\.skippedCount\.toString\(\) \+ ' 个其他文件'/);
  assert.match(indexSource, /defaultVaultName: registry\.uniqueVaultId\(sanitizeVaultName\(baseName\), ''\)/);
  assert.match(indexSource, /this\.pendingZipParse = parsed;\r?\n\s*this\.pendingZipStagingPath = stagingPath;/);
  // 失败清理暂存半成品并回填 failed
  assert.match(indexSource, /removeStagingFile\(stagingPath\);\r?\n\s*this\.pendingZipParse = null;/);
});

test('v1.36 36.3–36.7 importZipBackup：空间预检、隔离解压、原子登记与失败清理（源断言）', () => {
  // 弹窗状态与暂存不一致（stale）按 io 失败，不落盘
  assert.match(indexSource, /const stale: ZipImportOutcome = \{ status: 'failed', kind: 'io', result: null \};/);
  assert.match(indexSource, /const tempId: string = registry\.uniqueVaultId\(finalId \+ ZIP_IMPORTING_SUFFIX, ''\);/);
  assert.match(indexSource, /registry\.beginGitImport\(finalId, tempId\);/);
  // 36.7 空间预检：解压总量超过剩余空间按 no_space 失败，不报告虚假成功
  assert.match(indexSource, /freeBytesUnder\(resolver\.vaultsRoot\(\)\) < parsed\.totalUncompressed/);
  assert.match(indexSource, /throw new ZipImportError\('no_space', '设备存储空间不足'\);/);
  assert.match(indexSource, /fileIo\.mkdirSync\(tempDir, true\);/);
  assert.match(indexSource, /new TempVaultZipWriter\(tempDir\), new ZlibRawInflate\(\), parsed,/);
  // extract 防御：写入条数与解析结果不一致按 corrupt
  assert.match(indexSource, /if \(written !== parsed\.entries\.length\) \{\r?\n\s*throw new ZipImportError\('corrupt', 'ZIP 数据损坏'\);/);
  // 36.3 只新建、不覆盖：目标目录已存在即拒绝
  assert.match(indexSource, /if \(fileIo\.accessSync\(finalDir\)\) \{\r?\n\s*throw new ZipImportError\('io', '目标库目录已存在，拒绝覆盖'\);/);
  assert.match(indexSource, /fileIo\.renameSync\(tempDir, finalDir\);/);
  assert.match(indexSource, /const entry: VaultEntry = registry\.registerImportedLocal\(finalId\);/);
  assert.match(indexSource, /registry\.finishGitImport\(finalId, tempId\);/);
  assert.match(indexSource, /'已导入 ' \+ parsed\.noteCount\.toString\(\) \+ ' 篇笔记'/);
  assert.match(indexSource, /void this\.switchVault\(entry\.id\);/);
  // 失败清理：删临时目录树 + 撤销导入标记（残留留给启动恢复）
  assert.match(indexSource, /this\.removePathTreeForImport\(tempDir\);/);
  assert.match(indexSource, /registry\.cleanupGitImport\(finalId, tempId\);/);
});

test('v1.36 36.6 Registry 提供本地导入登记并沿用 git 导入标记机制（源断言）', () => {
  assert.match(registrySource, /registerImportedLocal\(id: string\): VaultEntry \{/);
  assert.match(registrySource, /beginGitImport\(finalId: string, importingId: string\): void \{/);
  assert.match(registrySource, /finishGitImport\(finalId: string, importingId: string\): void \{/);
  assert.match(registrySource, /cleanupGitImport\(finalId: string, importingId: string\): void \{/);
  assert.match(registrySource, /this\.recoverGitImportResidues\(\);/);
});
