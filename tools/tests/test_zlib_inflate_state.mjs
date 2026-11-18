import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const deviceSource = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ZipImportDevice.ets',
  import.meta.url
));
const serviceSource = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ZipImportService.ets',
  import.meta.url
));

test('ZlibRawInflate does not gate on availableOut; STREAM_END is the only device-layer terminal check (api_notes Y4)', () => {
  // 2026-11-18 真机回归：getZStream 的 availableOut 语义随系统构建而异
  // （x86_64 模拟器通过、XT2 真机复验仍失败），依它判定会在部分设备上误杀正确解压。
  // 设备层只要求 ReturnStatus.STREAM_END；完整性由服务层长度 + CRC32 权威校验兜底。
  const inflateStart = deviceSource.indexOf('export class ZlibRawInflate');
  assert.ok(inflateStart >= 0, 'ZlibRawInflate class not found');
  // 只断言代码本身，剥离行注释，避免注释里的历史记录误伤断言。
  const inflateBody = deviceSource.slice(inflateStart).replace(/\/\/[^\n]*/g, '');
  assert.match(inflateBody, /zlib\.ReturnStatus\.STREAM_END/);
  // 禁止任何 availableOut（含 getZStream 返回值）参与损坏判定。
  assert.doesNotMatch(inflateBody, /availableOut\s*(?:\?\?|!==|===|-)/);
  assert.doesNotMatch(inflateBody, /getZStream/);
});

test('ZipImportService.extract still verifies inflated bytes by length and CRC32', () => {
  // 设备层放弃 availableOut 检查后，extract 的长度 + CRC32 是唯一权威完整性校验，必须保留。
  const extractStart = serviceSource.indexOf('static async extract(');
  assert.ok(extractStart >= 0, 'ZipImportService.extract not found');
  const extractBody = serviceSource.slice(extractStart);
  assert.match(extractBody, /content\.length !== entry\.uncompressedSize/);
  assert.match(extractBody, /ZipImportService\.crc32\(content\) !== entry\.crc32/);
});
