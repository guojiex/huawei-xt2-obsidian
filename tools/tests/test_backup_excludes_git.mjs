import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

// ---------------------------------------------------------------------------
// v2.10「应用备份排除 .git 与恢复后重新关联远端」文本锚点回归。
// 备份方向 copyTree 无条件跳过 .git（目录或同名文件、任意层级），凭据清洗
// 三件套随 .git 整体排除而删除；恢复侧缺 .git 由 GitSyncDialog 的
// 「重新关联远端」（reattach）卡片承接。ApplicationBackupService /
// GitSyncDialog 含 @kit 导入，无法 esbuild 行为执行，走文本锚点
//（test_backup_overlimit_diagnostics.mjs 先例）；native reattach 语义由
// Git2Native.test.ets 设备用例覆盖。
// ---------------------------------------------------------------------------

const service = readSourceFile(new URL(
  '../../entry/src/main/ets/model/ApplicationBackupService.ets',
  import.meta.url
));
const backupDialog = readSourceFile(new URL(
  '../../entry/src/main/ets/components/ApplicationBackupDialog.ets',
  import.meta.url
));
const syncDialog = readSourceFile(new URL(
  '../../entry/src/main/ets/components/GitSyncDialog.ets',
  import.meta.url
));
const prototype = readSourceFile(new URL(
  '../../docs/prototype/v2/index.html',
  import.meta.url
));

test('备份方向 copyTree 无条件排除 .git（目录或同名文件、任意层级）', () => {
  const methodStart = service.indexOf('private static async copyTree');
  assert.ok(methodStart >= 0, 'copyTree method not found');
  const methodBody = service.slice(methodStart, methodStart + 1600);
  // 跳过必须发生在 lstat 之前：.git 目录与 .git 文件（worktree 形态）都不进备份。
  const skipPos = methodBody.indexOf("if (name === '.git')");
  assert.ok(skipPos >= 0, 'copyTree must skip .git by name');
  assert.ok(methodBody.indexOf('const stat: fileIo.Stat = fileIo.lstatSync(sourcePath)') > skipPos,
    '.git 跳过必须先于 lstat（目录与同名文件一并排除）');
  assert.ok(methodBody.indexOf('continue;') > skipPos, '跳过 .git 后必须 continue');
  // 无条件：不再有 scrubGitConfig 分支 / 凭据文件特判。
  assert.ok(!methodBody.includes('scrubGitConfig'), 'copyTree 不得再有 scrubGitConfig 分支');
  assert.ok(!methodBody.includes('isGitCredentialFile'), 'copyTree 不得再特判凭据文件');
});

test('凭据清洗三件套已随 .git 整体排除删除，调用点无残留实参', () => {
  assert.ok(!service.includes('isGitConfigFile'), 'isGitConfigFile 应已删除');
  assert.ok(!service.includes('isGitCredentialFile'), 'isGitCredentialFile 应已删除');
  assert.ok(!service.includes('sanitizeGitConfig'), 'sanitizeGitConfig 应已删除');
  assert.ok(!service.includes('scrubGitConfig'), 'scrubGitConfig 参数应已删除');
  assert.doesNotMatch(service, /copyTree\([^)]*,\s*true\)/, 'copyTree 调用点不得再传第三实参');
});

test('恢复兼容：恢复方向不得出现「恢复时删 .git」逻辑', () => {
  // 恢复流程（restoreBackup 及其辅助）只管落盘，不碰 .git 的存在性。
  const restoreStart = service.indexOf('async restoreBackup()');
  assert.ok(restoreStart >= 0, 'restoreBackup not found');
  assert.doesNotMatch(service, /删除[^。]*\.git|\.git[^。]*删除/,
    '不得引入恢复时删除 .git 的逻辑');
});

test('备份弹窗与原型文案同步「Git 历史不备份 + 重新关联」', () => {
  assert.ok(!backupDialog.includes('草稿与 Git 历史'), '内容项不得再宣称包含 Git 历史');
  assert.match(backupDialog, /Git 历史不备份（在同步页重新关联远端即可恢复）/,
    '范围说明必须声明 Git 历史不备份及恢复通道');
  assert.match(backupDialog, /Git 库恢复后请在同步页重新关联远端/,
    '恢复完成文案必须提示重新关联');
  assert.ok(!prototype.includes('草稿与 Git 历史'), '原型内容项不得再宣称包含 Git 历史');
  assert.match(prototype, /Git 历史不备份（在同步页重新关联远端即可恢复）/,
    '原型范围说明必须同步');
  assert.match(prototype, /Git 库恢复后请在同步页重新关联远端/,
    '原型恢复完成文案必须同步');
});

test('同步弹窗缺 .git 检测与 reattach 卡片', () => {
  // refreshLocalStatus 失败后用 fileIo.accessSync 复核 .git 缺失。
  const probePos = syncDialog.indexOf('private probeMissingGit()');
  assert.ok(probePos >= 0, 'probeMissingGit not found');
  assert.match(syncDialog.slice(probePos, probePos + 400),
    /fileIo\.accessSync\(VaultRegistry\.get\(\)\.vaultDirOf\(this\.vaultId\) \+ '\/\.git'\)/,
    '必须用 fileIo.accessSync 复核 vaultDir/.git');
  // 卡片态分流：缺 .git 渲染 ReattachCard，常规态维持 DialogContent。
  assert.match(syncDialog, /@Builder\s+private ContentBody\(\)/,
    'ContentBody 分流 builder 必须存在');
  const contentBody = syncDialog.slice(syncDialog.indexOf('@Builder'),
    syncDialog.indexOf('private DialogContent()'));
  assert.match(contentBody, /if \(this\.missingGit\)\s*\{\s*this\.ReattachCard\(\)/,
    '缺 .git 必须渲染重新关联卡片');
  // reattach 动作：targetBranch 取库注册 clone 分支（trackingBranch），远端地址可改。
  const runPos = syncDialog.indexOf('private async runReattach()');
  assert.ok(runPos >= 0, 'runReattach not found');
  const runBody = syncDialog.slice(runPos, runPos + 2400);
  assert.match(runBody, /operation: 'reattach'/, '必须调用 native reattach 操作');
  assert.match(runBody, /remoteUrl: remote/, '必须传入远端地址');
  assert.match(runBody,
    /targetBranch: this\.trackingBranch\.length > 0 \? this\.trackingBranch : this\.pushBranch/,
    'targetBranch 取库注册 clone 分支而非固定推送分支');
  // 地址校验拒绝内嵌凭据（与 native url_has_embedded_credentials 同口径）。
  const urlIssuePos = syncDialog.indexOf('private reattachUrlIssue()');
  assert.ok(urlIssuePos >= 0, 'reattachUrlIssue not found');
  const urlIssueBody = syncDialog.slice(urlIssuePos, urlIssuePos + 900);
  assert.match(urlIssueBody, /http:\/\/|https:\/\//, '地址必须限定 http(s)');
  assert.match(urlIssueBody, /authority\.includes\('@'\)/, '地址 authority 不得内嵌账号令牌');
  // 成功后回正常同步态（missingGit 复位 + 刷新 repositoryState）。
  assert.match(runBody, /this\.missingGit = false;[\s\S]*?await this\.refreshLocalStatus\(\)/,
    'reattach 成功后必须复位卡片态并刷新本地状态');
});
