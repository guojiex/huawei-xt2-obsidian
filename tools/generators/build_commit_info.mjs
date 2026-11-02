/**
 * build_commit_info.mjs —— v1.15 构建提交号诊断的构建期数据来源。
 *
 * 用法：
 *   node tools/generators/build_commit_info.mjs           # 输出 JSON：{ commitId, state, label }
 *   node tools/generators/build_commit_info.mjs --check   # 自检接线与产出（供提交前核对）
 *
 * 结论只用于识别构建，不参与包版本、不上报、不写进任何日志之外的位置。
 * 三种结果：
 *   clean   → 短 ID（8 位）
 *   dirty   → 短 ID + '-dirty'（参与构建的源码有未提交更改）
 *   unknown → '未知'（无 .git / 取不到 commit / 取不到变更状态），不使用上一次构建的残留值
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * 参与构建的源码范围。dirty 判定只看这些路径：
 *   - 覆盖：App 源码、模块配置、Web（mdpreview / mdeditor 等）与 Native 源码、hvigor 构建脚本；
 *   - 排除：`entry/src/main/resources/rawfile`（由 web/ 构建生成，会被本次构建重写，不算用户改动）、
 *     `.local/` 等本机文件（已 gitignore，本就不进 status）、构建输出目录。
 *   规则与范围在本文件集中维护，避免散落到构建脚本里各判一次。
 */
export const BUILD_SOURCE_PATHS = [
  'AppScope',
  'build-profile.json5',
  'hvigor',
  'hvigorfile.ts',
  'native',
  'oh-package.json5',
  'web',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/cpp',
  'entry/src/main/ets',
  'entry/src/main/module.json5',
  'entry/src/main/resources/base',
  'entry/src/main/resources/dark',
  'tools/abi.ps1',
  'tools/build.ps1',
  'tools/generators',
  'tools/signing.ps1'
];

const SHORT_ID_LENGTH = 8;
export const UNKNOWN_LABEL = '未知';

function git(args, cwd) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8', windowsHide: true });
  if (result.error !== undefined || result.status !== 0) {
    return null;
  }
  return result.stdout ?? '';
}

/** 取构建源码快照的 commit 短 ID；取不到返回 null（无 .git 或 HEAD 不可用）。 */
export function readShortCommitId(cwd) {
  const output = git(['rev-parse', '--short=' + SHORT_ID_LENGTH.toString(), 'HEAD'], cwd);
  if (output === null) {
    return null;
  }
  const id = output.trim();
  return id.length > 0 ? id : null;
}

/**
 * 参与构建的源码是否有未提交更改（含未跟踪的新增源码）。
 * 变更状态取不到时返回 null —— 不能据此冒充干净构建，调用方须按未知处理。
 */
export function readDirtyState(cwd) {
  const output = git(['status', '--porcelain', '--untracked-files=all', '--', ...BUILD_SOURCE_PATHS], cwd);
  if (output === null) {
    return null;
  }
  return output.trim().length > 0;
}

/** 汇总成界面与注入使用的三元组。 */
export function readBuildCommit(cwd = process.cwd()) {
  const commitId = readShortCommitId(cwd);
  if (commitId === null) {
    return { commitId: '', state: 'unknown', label: UNKNOWN_LABEL };
  }
  const dirty = readDirtyState(cwd);
  if (dirty === null) {
    // 短 ID 可信但变更状态未知：保留 ID，明确标记状态未知，不冒充干净构建。
    return { commitId: commitId, state: 'unknown', label: commitId + '（状态未知）' };
  }
  return {
    commitId: commitId,
    state: dirty ? 'dirty' : 'clean',
    label: dirty ? commitId + '-dirty' : commitId
  };
}

/** 自检：hvigor 注入与设置页接线是否还在，且本仓库能算出合法结果。 */
function check(repoRoot) {
  const hvigorFile = resolve(repoRoot, 'entry/hvigorfile.ts');
  if (!existsSync(hvigorFile)) {
    console.error('[build-commit] 缺少 entry/hvigorfile.ts');
    return false;
  }
  const hvigorSource = readFileSync(hvigorFile, 'utf8');
  if (!hvigorSource.includes('buildProfileFields') || !hvigorSource.includes('build_commit_info.mjs')) {
    console.error('[build-commit] entry/hvigorfile.ts 未注入 buildProfileFields —— 设置页会取不到构建提交');
    return false;
  }
  const settingsFile = resolve(repoRoot, 'entry/src/main/ets/components/SettingsView.ets');
  if (!existsSync(settingsFile)) {
    console.error('[build-commit] 缺少 SettingsView.ets');
    return false;
  }
  const settingsSource = readFileSync(settingsFile, 'utf8');
  if (!settingsSource.includes("BuildProfile") || !settingsSource.includes("'构建提交'")) {
    console.error('[build-commit] SettingsView.ets 未显示构建提交');
    return false;
  }
  const info = readBuildCommit(repoRoot);
  if (info.label.length === 0) {
    console.error('[build-commit] 当前仓库算不出构建标识');
    return false;
  }
  console.log(`[build-commit] 自检通过：${info.label}（${info.state}）`);
  return true;
}

function main() {
  const args = process.argv.slice(2);
  const repoRoot = resolve(process.cwd());
  if (args.includes('--check')) {
    process.exit(check(repoRoot) ? 0 : 1);
  }
  console.log(JSON.stringify(readBuildCommit(repoRoot)));
}

main();
