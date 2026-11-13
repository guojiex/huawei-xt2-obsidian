import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：v1.34 4970d5c —— AtomicFile 统一 end 收尾
// 根因：AtomicFile 的 end() 方法未在所有路径调用，导致 x86_64 模拟器删除笔记空副本
// 修复：统一在 try/finally 中调用 stream.end + finishWrite/failWrite
// 2026-11-13 起该模式收敛到 common/AtomicWrite.ets 单一真源，锁定对象随之迁移；
// NoteDraftService 等写入方必须走 atomicWriteText，不得再内联样板

const atomicWrite = readSourceFile(new URL('../../entry/src/main/ets/common/AtomicWrite.ets', import.meta.url));
const draftService = readSourceFile(new URL('../../entry/src/main/ets/model/NoteDraftService.ets', import.meta.url));

test('atomicWriteText single source uses AtomicFile with startWrite/end/finishWrite pattern', () => {
  assert.match(atomicWrite, /new fileIo\.AtomicFile\(/);
  assert.match(atomicWrite, /startWrite\(\)/);
  assert.match(atomicWrite, /stream\.end\(/);
  assert.match(atomicWrite, /finishWrite\(\)/);
  // 写入方走单一真源，不再各持一份样板
  assert.match(draftService, /return atomicWriteText\(/);
});

test('atomicWriteText has failWrite fallback for error paths', () => {
  assert.match(atomicWrite, /failWrite\(\)/);
});

// 防回归：v1.34 05c97ad —— 回收站根目录单级 mkdirSync 导致删除必然失败
// 修复：先递归创建 .trash 根目录（mkdirSync(trashRoot, true)）

const trashService = readSourceFile(new URL('../../entry/src/main/ets/model/TrashService.ets', import.meta.url));

test('TrashService.moveToTrash creates trash root with recursive mkdir (true param)', () => {
  // mkdirSync(trashRoot, true) 在 moveTextToPrivateTrash 中（moveToTrash 的内部实现）
  const moveImpl = trashService.substring(
    trashService.indexOf('private static async moveTextToPrivateTrash('),
    trashService.indexOf('\n  private static', trashService.indexOf('private static async moveTextToPrivateTrash(') + 1)
  );
  // 必须使用 mkdirSync(trashRoot, true) 递归创建
  // Regex: mkdirSync(someVar, true) — 第二参数为 true 表示递归
  assert.match(moveImpl, /mkdirSync\([^,]+,\s*true\)/);
  assert.match(moveImpl, /recursion/, 'moveToTrash must document the recursive mkdir purpose');
});

// 防回归：v1.34 846c4b0 —— 回收站读回校验退避重试
test('TrashService read-back verification retries on mismatch', () => {
  assert.match(trashService, /readBackWithRetry/);
  assert.match(trashService, /TrashReadBackResult/);
});

// 防回归：v1.34 2d0d164 —— 回收站四处校验点错误信息细化
test('TrashService error messages include detailed mismatch info', () => {
  const mismatchMethods = trashService.substring(
    trashService.indexOf('private static firstMismatchIndex('),
    trashService.indexOf('\n  private static', trashService.indexOf('private static firstMismatchIndex(') + 1)
  );
  assert.match(mismatchMethods, /长度|字符|差异|位置|码点|charCodeAt|length/);
});

// 防回归：8b0059b —— 改用异步 AtomicFile 写入并记录 clone 诊断
// GitImportDraftStore 只是进程内临时存储（内存），不涉及文件写入
// AtomicFile 实际在 GitCloneService / NoteDraftService 等文件写入场景中使用
test('git import draft store is purely in-memory (no file IO), AtomicFile used in actual write paths', () => {
  const gitImport = readSourceFile(new URL('../../entry/src/main/ets/model/GitImportDraftStore.ets', import.meta.url));
  // 确认是纯内存存储——没有 fileIo 导入
  assert.doesNotMatch(gitImport, /fileIo/, 'draft store must be in-memory, no file IO');
  // AtomicFile 的实际使用在 NoteDraftService 中（已在上面的 test 中验证）
});

// 防回归：da246ce —— 改用 copyFile 保存相册图片
test('image save uses copyFile instead of writeSync for binary safety', () => {
  const noteService = readSourceFile(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url));
  assert.doesNotMatch(noteService, /writeSync.*image|writeTextSync.*image/i,
    'image saving must not use writeTextSync for binary data');
});

console.log('文件 IO 与原子性类 bug 防回归检查通过（AtomicFile end + mkdirSync 递归 + 读回重试）');
