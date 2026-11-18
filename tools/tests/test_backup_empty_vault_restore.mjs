import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

// ---------------------------------------------------------------------------
// 2026-11-18 真机「应用备份缺少知识库目录」根因回归：
// 空知识库在备份 zip 里只有目录条目（vaults/<id>/，无任何文件），而
// ZipImportService.parse 按设计跳过目录条目（isDirectory 静默丢弃），
// 解压后空库目录缺失，validateRegistryAgainstManifest 报
// 「应用备份缺少知识库目录」。修复：chooseBackup 在恢复校验前按 manifest
// 补建沙箱库目录（ensureSandboxVaultDirs，已存在 no-op，外部库跳过）。
// ---------------------------------------------------------------------------

const backupSource = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ApplicationBackupService.ets',
  import.meta.url
));
const serviceSource = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ZipImportService.ets',
  import.meta.url
));

test('chooseBackup 在恢复校验前按 manifest 补建空库目录', () => {
  const callStart = backupSource.indexOf('readAndValidateManifest(newRoot)');
  assert.ok(callStart >= 0, 'chooseBackup manifest read not found');
  const flowBody = backupSource.slice(callStart, callStart + 700).replace(/\/\/[^\n]*/g, '');
  const ensureIdx = flowBody.indexOf('ensureSandboxVaultDirs(newRoot, manifest)');
  const validateIdx = flowBody.indexOf('validateRegistryAgainstManifest(storeSnapshots, manifest, newRoot)');
  assert.ok(ensureIdx > 0, 'ensureSandboxVaultDirs call missing in chooseBackup flow');
  assert.ok(validateIdx > ensureIdx, 'ensureSandboxVaultDirs must run before registry validation');
});

test('ensureSandboxVaultDirs 只补建缺失的沙箱库目录，外部库跳过', () => {
  const methodStart = backupSource.indexOf('private static ensureSandboxVaultDirs');
  assert.ok(methodStart >= 0, 'ensureSandboxVaultDirs method not found');
  const methodBody = backupSource.slice(methodStart, methodStart + 800).replace(/\/\/[^\n]*/g, '');
  assert.match(methodBody, /vault\.rootKind !== 'sandbox'/, 'non-sandbox vaults must be skipped');
  assert.match(methodBody, /rootDir \+ '\/vaults\/' \+ vault\.id/, 'dir path must follow manifest vault id');
  assert.match(methodBody, /fileIo\.accessSync\(dir\)/, 'existing dirs must be probed first');
  assert.match(methodBody, /fileIo\.mkdirSync\(dir, true\)/, 'missing dirs must be created recursively');
});

test('根因锚点：ZipImportService.parse 仍按设计跳过目录条目（空库目录必须由恢复侧补齐）', () => {
  const parseStart = serviceSource.indexOf('static async parse(');
  assert.ok(parseStart >= 0, 'ZipImportService.parse not found');
  const parseBody = serviceSource.slice(parseStart, parseStart + 9000).replace(/\/\/[^\n]*/g, '');
  assert.match(parseBody, /isDirectory\)/, 'directory entries are still skipped by parse');
});
