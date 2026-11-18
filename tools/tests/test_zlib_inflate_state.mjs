import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const deviceSource = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ZipImportDevice.ets',
  import.meta.url
));

test('ZlibRawInflate re-fetches ZStream state via getZStream after STREAM_END (api_notes Y4)', () => {
  // 2026-11-17 恢复「备份文件损坏」根因：@ohos.zlib 流式操作不回写调用方传入的
  // ZStream，操作后读 strm.availableOut 恒为初始值 expectedSize，导致所有非空
  // deflate 条目被完整性检查误判为损坏。真实状态必须 await zip.getZStream() 重取。
  const inflateStart = deviceSource.indexOf('export class ZlibRawInflate');
  assert.ok(inflateStart >= 0, 'ZlibRawInflate class not found');
  const inflateBody = deviceSource.slice(inflateStart);
  assert.match(inflateBody, /zlib\.ReturnStatus\.STREAM_END/);
  assert.match(inflateBody, /await zip\.getZStream\(\)/);
  // availableOut 只能来自 getZStream 的返回值；禁止再读传入 strm 的陈旧字段。
  assert.doesNotMatch(inflateBody, /strm\.availableOut/);
});
