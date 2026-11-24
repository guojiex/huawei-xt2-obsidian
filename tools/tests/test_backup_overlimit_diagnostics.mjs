import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

// ---------------------------------------------------------------------------
// 2026-11-24 真机「导出应用备份报“有单个文件超过备份安全上限”，用户不知道
// 是哪个文件、多大」根因回归：导出侧 over_limit 文案必须点名超限文件
// （相对 payload 根路径）与实际大小，并给出上限值与处理指引；总量超限
// 同样给出实际条目数 / 总字节数与上限。导入侧（ZipImportService.parse）
// 的同类文案由 test_zip_import.mjs 行为测试覆盖。
// ---------------------------------------------------------------------------

const source = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ApplicationBackupService.ets',
  import.meta.url
));

test('导出超限定位：findOversizedFile 返回文件相对路径与字节数', () => {
  assert.ok(source.indexOf('hasOversizedFile') < 0, 'hasOversizedFile 应已被 findOversizedFile 取代');
  const methodStart = source.indexOf('private static findOversizedFile');
  assert.ok(methodStart >= 0, 'findOversizedFile method not found');
  const methodBody = source.slice(methodStart, methodStart + 900);
  assert.match(methodBody, /relativePath: childRelative, bytes: stat\.size/,
    '超限文件必须同时携带相对路径与大小');
  assert.match(methodBody, /return null/, '无超限文件时返回 null');
});

test('导出单文件超限文案点名文件、大小、上限与处理指引', () => {
  const checkStart = source.indexOf("findOversizedFile(payloadDir, '', APP_BACKUP_LIMITS.maxSingleUncompressed)");
  assert.ok(checkStart >= 0, 'export flow must locate the oversized file');
  const flowBody = source.slice(checkStart, checkStart + 700).replace(/\/\/[^\n]*/g, '');
  assert.match(flowBody, /oversized\.relativePath/, '文案必须包含超限文件路径');
  assert.match(flowBody, /ZipImportService\.formatBytes\(oversized\.bytes\)/, '文案必须包含实际大小');
  assert.match(flowBody, /ZipImportService\.formatBytes\(APP_BACKUP_LIMITS\.maxSingleUncompressed\)/,
    '文案必须包含单文件上限值');
  assert.match(flowBody, /移出或删除该文件后重试/, '文案必须给出处理指引');
});

test('导出总量超限文案点名条目数、总大小与上限', () => {
  const checkStart = source.indexOf('treeSize.entries > APP_BACKUP_LIMITS.maxEntries');
  assert.ok(checkStart >= 0, 'export total-limit check not found');
  const flowBody = source.slice(checkStart, checkStart + 700).replace(/\/\/[^\n]*/g, '');
  assert.match(flowBody, /treeSize\.entries\.toString\(\)/, '文案必须包含实际条目数');
  assert.match(flowBody, /ZipImportService\.formatBytes\(treeSize\.bytes\)/, '文案必须包含实际总大小');
  assert.match(flowBody, /ZipImportService\.formatBytes\(APP_BACKUP_LIMITS\.maxTotalUncompressed\)/,
    '文案必须包含总量上限值');
  assert.match(flowBody, /请移出部分文件后重试/, '文案必须给出处理指引');
});
