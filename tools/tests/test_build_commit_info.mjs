import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const repoRoot = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const generatorPath = join(repoRoot, 'tools/generators/build_commit_info.mjs');
const generatorSource = readFileSync(generatorPath, 'utf8');
const hvigorSource = readSourceFile(new URL('../../entry/hvigorfile.ts', import.meta.url));
const settingsSource = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const infoSource = readSourceFile(new URL('../../entry/src/main/ets/common/BuildCommitInfo.ets', import.meta.url));

/**
 * 隔离 git 仓库：生成器只吃 git 命令，测试自建仓库即可覆盖三种场景，
 * 不碰本项目工作区（不为测试改用户工作区）。
 */
function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'build-commit-'));
  const git = (args) => spawnSync('git', args, { cwd: dir, encoding: 'utf8', windowsHide: true });
  git(['init']);
  git(['config', 'user.email', 'build@example.com']);
  git(['config', 'user.name', 'build']);
  return { dir, git };
}

function readCommitInfo(cwd) {
  const result = spawnSync(process.execPath, [generatorPath], { cwd, encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0, `generator failed: ${result.stderr}`);
  return JSON.parse(result.stdout);
}

test('clean tree yields the short commit id only', () => {
  const { dir, git } = makeRepo();
  try {
    mkdirSync(join(dir, 'entry/src/main/ets'), { recursive: true });
    writeFileSync(join(dir, 'entry/src/main/ets/App.ets'), 'export const a = 1;\n');
    git(['add', '.']);
    git(['commit', '-m', 'init']);
    const info = readCommitInfo(dir);
    const head = git(['rev-parse', '--short=8', 'HEAD']).stdout.trim();
    assert.equal(info.state, 'clean');
    assert.equal(info.commitId, head);
    assert.equal(info.label, head);
    assert.match(info.label, /^[0-9a-f]{7,8}$/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('uncommitted build sources mark the build dirty', () => {
  const { dir, git } = makeRepo();
  try {
    mkdirSync(join(dir, 'entry/src/main/ets'), { recursive: true });
    writeFileSync(join(dir, 'entry/src/main/ets/App.ets'), 'export const a = 1;\n');
    git(['add', '.']);
    git(['commit', '-m', 'init']);
    const head = git(['rev-parse', '--short=8', 'HEAD']).stdout.trim();

    writeFileSync(join(dir, 'entry/src/main/ets/App.ets'), 'export const a = 2;\n');
    let info = readCommitInfo(dir);
    assert.equal(info.state, 'dirty');
    assert.equal(info.label, `${head}-dirty`);

    // 未跟踪的新增源码同样参与构建，必须算脏。
    git(['checkout', '--', 'entry/src/main/ets/App.ets']);
    writeFileSync(join(dir, 'entry/src/main/ets/New.ets'), 'export const b = 2;\n');
    info = readCommitInfo(dir);
    assert.equal(info.state, 'dirty');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('generated rawfile output is not reported as a user change', () => {
  const { dir, git } = makeRepo();
  try {
    mkdirSync(join(dir, 'entry/src/main/resources/rawfile/mdpreview'), { recursive: true });
    writeFileSync(join(dir, 'entry/src/main/resources/rawfile/mdpreview/index.html'), '<p>v1</p>\n');
    git(['add', '.']);
    git(['commit', '-m', 'init']);
    // 构建会重写 rawfile；它不在 dirty 判定范围内，否则每次构建都自称 dirty。
    writeFileSync(join(dir, 'entry/src/main/resources/rawfile/mdpreview/index.html'), '<p>v2</p>\n');
    const info = readCommitInfo(dir);
    assert.equal(info.state, 'clean');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a tree without git reports unknown and never reuses a stale id', () => {
  const dir = mkdtempSync(join(tmpdir(), 'build-commit-nogit-'));
  try {
    // 临时目录的上级（/tmp）不是 git 仓库；若环境里 /tmp 恰在仓库内，这条用例会失败——
    // 用临时目录自身作为无 .git 场景，且断言 label 不是上一次的值。
    const info = readCommitInfo(dir);
    assert.equal(info.state, 'unknown');
    assert.equal(info.commitId, '');
    assert.equal(info.label, '未知');
    assert.doesNotMatch(info.label, /[0-9a-f]{7}/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('hvigor injects the build commit into BuildProfile and never into the work tree', () => {
  assert.match(hvigorSource, /build_commit_info\.mjs/);
  assert.match(hvigorSource, /buildProfileFields/);
  assert.match(hvigorSource, /buildCommitId: buildCommit\.commitId/);
  assert.match(hvigorSource, /buildCommitState: buildCommit\.state/);
  assert.match(hvigorSource, /buildCommitLabel: buildCommit\.label/);
  // 取不到就退化为未知，不沿用上一次构建的值，也不写源文件或中断构建。
  assert.match(hvigorSource, /state: 'unknown', label: '未知'/);
  assert.doesNotMatch(hvigorSource, /writeFileSync/);
  // 生成器维护的判定范围必须排除生成产物 rawfile。
  assert.match(generatorSource, /entry\/src\/main\/ets/);
  assert.doesNotMatch(generatorSource, /entry\/src\/main\/resources\/rawfile'/);
});

test('settings shows the build commit with a copy action that carries only the label', () => {
  assert.match(settingsSource, /import BuildProfile from 'BuildProfile'/);
  assert.match(settingsSource, /Text\('构建提交'\)/);
  assert.match(settingsSource, /buildCommitLabel\(this\.buildCommitState\(\), this\.buildCommitLabelText\(\)\)/);
  assert.match(settingsSource, /accessibilityText\('复制构建提交号'\)/);
  assert.match(settingsSource, /\.enabled\(isBuildCommitKnown\(this\.buildCommitState\(\)\)\)/);
  assert.match(settingsSource, /promptAction\.showToast\(\{ message: '已复制构建提交号' \}\)/);
  assert.match(settingsSource, /promptAction\.showToast\(\{ message: '构建提交未知，不复制' \}\)/);
  // 复制只带标识本身，不带库目录、笔记或令牌。
  const copyBody = settingsSource.slice(
    settingsSource.indexOf('private async copyBuildCommit()'),
    settingsSource.indexOf('  @Builder\n  AgentTab()')
  );
  assert.doesNotMatch(copyBody, /vaultDir|currentVaultId|token|note/);
  assert.match(copyBody, /pasteboard\.createData\(pasteboard\.MIMETYPE_TEXT_PLAIN, payload\)/);
});

/** 纯逻辑：把 BuildCommitInfo.ets 的函数体搬到 Node 里跑，避免 BuildProfile 依赖。 */
const harnessCode = transformSync(`
${infoSource
  .replace(/^export type[^\n]*\n/m, '')
  .replace(/^export /gm, '')
  .replace(/: string/g, '')
  .replace(/: boolean/g, '')
  .replace(/\(state\)/g, '(state)')
  .replace(/\(state, label\)/g, '(state, label)')}
module.exports = { isBuildCommitKnown, buildCommitCopyPayload, buildCommitLabel, BUILD_COMMIT_UNKNOWN_LABEL };
`, { loader: 'ts', format: 'cjs' }).code;

const mod = { exports: {} };
new Function('module', 'exports', harnessCode)(mod, mod.exports);
const { isBuildCommitKnown, buildCommitCopyPayload, buildCommitLabel } = mod.exports;

test('unknown state is never presented or copied as a real commit id', () => {
  assert.equal(isBuildCommitKnown('clean'), true);
  assert.equal(isBuildCommitKnown('dirty'), true);
  assert.equal(isBuildCommitKnown('unknown'), false);

  assert.equal(buildCommitLabel('clean', 'a1b2c3d4'), 'a1b2c3d4');
  assert.equal(buildCommitLabel('dirty', 'a1b2c3d4'), 'a1b2c3d4');
  assert.equal(buildCommitLabel('unknown', 'a1b2c3d4'), '未知');
  assert.equal(buildCommitLabel('clean', ''), '未知', 'missing label must fall back to unknown');

  assert.equal(buildCommitCopyPayload('clean', 'a1b2c3d4'), 'a1b2c3d4');
  assert.equal(buildCommitCopyPayload('dirty', 'a1b2c3d4-dirty'), 'a1b2c3d4-dirty');
  assert.equal(buildCommitCopyPayload('unknown', 'a1b2c3d4'), '');
  assert.equal(buildCommitCopyPayload('clean', ''), '');
});

test('generator self-check passes on this repo', () => {
  const result = spawnSync(process.execPath, [generatorPath, '--check'], {
    cwd: repoRoot, encoding: 'utf8', windowsHide: true
  });
  assert.equal(result.status, 0, `self-check failed: ${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /自检通过/);
  assert.equal(existsSync(join(repoRoot, 'entry/src/main/ets/common/BuildCommitInfo.ets')), true);
});
