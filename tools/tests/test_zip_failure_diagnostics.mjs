import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

// ---------------------------------------------------------------------------
// 2026-11-18 真机「备份文件损坏或格式不完整」定位需求（用户要求页面透出底层错误）：
// ① 行为级：extract 的损坏错误信息必须携带条目名（真机上可直接看出失败在哪一条）。
// ② 源级：设备层 inflate 失败携带 status/calls/code；备份恢复文案透传底层 message。
// ---------------------------------------------------------------------------

const serviceSource = readSourceFile(new URL('../../entry/src/main/ets/model/ZipImportService.ets', import.meta.url));
const serviceCode = transformSync(serviceSource, { loader: 'ts', format: 'cjs' }).code;
const serviceContext = vm.createContext({ module: { exports: {} } });
vm.runInContext(serviceCode, serviceContext);
const ZipImportService = serviceContext.module.exports.ZipImportService;
const ZipImportError = serviceContext.module.exports.ZipImportError;

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

function buildZip(entries) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.name, 'utf8');
    const data = Buffer.from(entry.data, 'utf8');
    const stored = zlib.deflateRawSync(data);
    const crc = entry.crc === undefined ? crc32Of(data) : entry.crc;
    const declaredSize = entry.uncompressedSize === undefined ? data.length : entry.uncompressedSize;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(stored.length, 18);
    local.writeUInt32LE(declaredSize, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    chunks.push(local, nameBuf, stored);
    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(0x800, 8);
    centralHeader.writeUInt16LE(8, 10);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(stored.length, 20);
    centralHeader.writeUInt32LE(declaredSize, 24);
    centralHeader.writeUInt16LE(nameBuf.length, 28);
    centralHeader.writeUInt32LE(offset, 42);
    central.push(Buffer.concat([centralHeader, nameBuf]));
    offset += local.length + nameBuf.length + stored.length;
  }
  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, centralBuf, eocd]);
}

function createMockReader(buffer) {
  const view = new Uint8Array(buffer);
  return {
    size: async () => view.byteLength,
    readAt: async (offset, length) => view.subarray(offset, offset + length),
    close: () => {}
  };
}

const nodeInflate = {
  inflateRaw: async (compressed, expectedSize) => new Uint8Array(zlib.inflateRawSync(Buffer.from(compressed)))
};

async function extractZip(buffer) {
  const reader = createMockReader(buffer);
  const parsed = await ZipImportService.parse(reader, ZipImportService.DEFAULT_LIMITS, {
    allowHiddenEntries: true,
    acceptAllFiles: true,
    requireMarkdown: false
  });
  const written = [];
  const writer = {
    writeFile: async (name, content) => { written.push(name); },
    setModifiedTime: async () => {}
  };
  await ZipImportService.extract(reader, writer, nodeInflate, parsed, { preserveMtime: false });
  return written;
}

test('extract 长度不符的错误信息携带条目名', async () => {
  const zip = buildZip([{ name: 'notes/a.md', data: '# hello', uncompressedSize: 99 }]);
  await assert.rejects(
    () => extractZip(zip),
    (error) => error instanceof ZipImportError && error.kind === 'corrupt' &&
      error.message.includes('长度不符') && error.message.includes('notes/a.md')
  );
});

test('extract CRC 不符的错误信息携带条目名', async () => {
  const zip = buildZip([{ name: 'notes/b.md', data: '# world', crc: 0xDEADBEEF }]);
  await assert.rejects(
    () => extractZip(zip),
    (error) => error instanceof ZipImportError && error.kind === 'corrupt' &&
      error.message.includes('CRC32 不符') && error.message.includes('notes/b.md')
  );
});

test('ZlibRawInflate 失败信息携带 status/calls/code（真机诊断透出）', () => {
  const deviceSource = readSourceFile(new URL(
    '../../entry/src/main/ets/model/ZipImportDevice.ets',
    import.meta.url
  ));
  const inflateStart = deviceSource.indexOf('export class ZlibRawInflate');
  assert.ok(inflateStart >= 0, 'ZlibRawInflate class not found');
  const inflateBody = deviceSource.slice(inflateStart).replace(/\/\/[^\n]*/g, '');
  assert.match(inflateBody, /'ZIP 解压初始化失败\(status=' \+ initStatus\.toString\(\) \+ '\)'/);
  assert.match(inflateBody, /'ZIP 解压未正常结束\(status=' \+ status\.toString\(\) \+ ',calls=' \+ calls\.toString\(\) \+ '\)'/);
  assert.match(inflateBody, /'ZIP 解压异常\(code=' \+ code\.toString\(\) \+ '\)'/);
});

test('备份恢复失败文案透传底层错误 message（chooseBackup）', () => {
  const backupSource = readSourceFile(new URL(
    '../../entry/src/main/ets/model/ApplicationBackupService.ets',
    import.meta.url
  ));
  const corruptStart = backupSource.indexOf("error.kind === 'corrupt'");
  assert.ok(corruptStart >= 0, 'chooseBackup corrupt mapping not found');
  const mappingBody = backupSource.slice(corruptStart, corruptStart + 600).replace(/\/\/[^\n]*/g, '');
  assert.match(mappingBody, /'备份文件损坏或格式不完整（' \+ error\.message \+ '）。请选择其他文件后重试。'/);
  assert.match(mappingBody, /'无法读取该应用备份（' \+ reason \+ '）。请选择有效的曜石笔记备份文件后重试。'/);
});
