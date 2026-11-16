import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL(
  '../../entry/src/main/ets/components/GitSyncDialog.ets', import.meta.url));

function method(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find GitSyncDialog method ${startMarker}`);
  return source.slice(start, end).trim();
}

const methodCode = transformSync(`
class GitSyncDialogHarness {
  ${method('  private trackingTargetLabel(): string {', '\n  private remoteStepIndex()')}
  ${method('  private remoteStepIndex(): number {', '\n  private progressStepLabels()')}
  ${method('  private progressStepLabels(): string[] {', '\n  private shouldCommitChanges()')}
  ${method('  private shouldCommitChanges(): boolean {', '\n  private waitingStatusText()')}
  ${method('  private primaryActionEnabled(): boolean {', '\n  private primaryActionLabel()')}
  ${method('  private primaryActionLabel(): string {', '\n  private saveBranch()')}
  ${method('  private canPush(): boolean {', '\n  private startBusy(')}
  ${method('  private startBusy(', '\n  private finishBusy()')}
  ${method('  private finishBusy(): void {', '\n  private setStep(')}
  ${method('  private setStep(', '\n  private showOperationFailure(')}
  ${method('  private makePullOptions(', '\n  private canPull()')}
  ${method('  private canPull(): boolean {', '\n  private async runPullAction()')}
  ${method('  private async runPullAction(): Promise<void> {', '\n  private showPullFailure(error')}
  ${method('  private showPullFailure(error: Error | Object): void {', '\n  private async runPrimaryAction()')}
  ${method('  private async runPrimaryAction(): Promise<void> {', '\n  private canPush()')}
  ${method('  private retryActionLabel(): string {', '\n  private retryActionEnabled()')}
  ${method('  private retryFailedOperation(): void {', '\n  private dismissResult()')}
  ${method('  private dismissResult(): void {', '\n  @Builder')}
}
module.exports = GitSyncDialogHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness(state = {}, action = async () => 'pushed') {
  const calls = [];
  const actionOptions = [];
  const registry = {
    currentId: () => 'repo',
    vaultDirOf: () => '/vaults/repo',
    recordGitSync: () => {}
  };
  const module = { exports: {} };
  vm.runInNewContext(methodCode, {
    module,
    exports: module.exports,
    applyRemoteAuth: () => {},
    VaultRegistry: { get: () => registry },
    GitNativeService: {
      action: async (options) => {
        calls.push(options.operation);
        actionOptions.push(options);
        return action(options);
      }
    }
  });
  const dialog = new module.exports();
  Object.assign(dialog, {
    vaultId: 'repo',
    statusReady: true,
    statusEntryCount: 0,
    trackingKnown: false,
    aheadCount: 0,
    remoteBranchMissing: false,
    localCommitPending: false,
    syncIncludesCommit: false,
    pushBranch: 'phone/notes',
    trackingBranch: '',
    remoteLabel: '',
    authUsername: '',
    result: 'none',
    onBusyChange: () => {},
    onPulled: () => {},
    findVaultEntry: () => ({ id: 'repo', type: 'git' }),
    effectiveToken: () => '',
    isGitHubRemote: () => true,
    makeActionOptions: (operation) => ({ operation }),
    defaultCommitMessage: () => '更新 1 个文件（曜石笔记）',
    saveCredentialsAfterRemoteSuccess: () => {},
    refreshLocalStatus: () => {},
    showOperationFailure: () => {},
    ...state
  });
  return { dialog, calls, actionOptions };
}

test('first push is available only after the remote branch is confirmed missing', () => {
  assert.equal(createHarness().dialog.canPush(), false);
  assert.equal(createHarness({ remoteBranchMissing: true }).dialog.canPush(), true);
  assert.equal(createHarness({
    trackingKnown: true,
    aheadCount: 2
  }).dialog.canPush(), true);
  assert.equal(createHarness({
    trackingKnown: true,
    aheadCount: 0
  }).dialog.canPush(), false);
});

test('local changes remain pushable before remote status is known', () => {
  assert.equal(createHarness({ statusEntryCount: 1 }).dialog.canPush(), true);
  assert.equal(createHarness({ statusReady: false, statusEntryCount: 1 }).dialog.canPush(), false);
  assert.equal(createHarness({ localCommitPending: true }).dialog.canPush(), true);
});

test('progress steps match whether the sync needs a local commit', () => {
  const clean = createHarness();
  assert.equal(clean.dialog.remoteStepIndex(), 0);
  assert.deepEqual(Array.from(clean.dialog.progressStepLabels()), [
    '检查远端 phone/notes',
    '推送 phone/notes'
  ]);

  const changed = createHarness({ statusEntryCount: 2 });
  changed.dialog.syncIncludesCommit = true;
  assert.equal(changed.dialog.remoteStepIndex(), 2);
  assert.deepEqual(Array.from(changed.dialog.progressStepLabels()), [
    '暂存改动',
    '创建提交',
    '检查远端 phone/notes',
    '推送 phone/notes'
  ]);
});

test('missing clone metadata is shown as unknown instead of assuming main', () => {
  assert.equal(createHarness().dialog.trackingTargetLabel(), '跟踪分支未知');
  assert.equal(createHarness({ trackingBranch: 'master' }).dialog.trackingTargetLabel(), 'master');
});

test('retry after fetch succeeds and push fails stays push-only with newer worktree changes', async () => {
  const phases = [];
  let pushCount = 0;
  const { dialog, calls } = createHarness({
    statusEntryCount: 1,
    localCommitPending: true,
    commitMessage: '',
    authorName: '',
    authorEmail: '',
    showOperationFailure: () => { dialog.result = 'network'; }
  }, async (options) => {
    assert.equal(options.operation, 'push');
    pushCount++;
    if (pushCount === 1) {
      phases.push('fetch succeeded', 'push rejected');
      throw new Error('remote rejected update');
    }
    return 'pushed';
  });

  await dialog.runPrimaryAction();
  assert.deepEqual(calls, ['push']);
  assert.equal(dialog.localCommitPending, true);
  assert.equal(dialog.statusEntryCount, 1);
  assert.deepEqual(phases, ['fetch succeeded', 'push rejected']);
  assert.equal(dialog.syncIncludesCommit, false);
  assert.deepEqual(Array.from(dialog.progressStepLabels()), [
    '检查远端 phone/notes',
    '推送 phone/notes'
  ]);
  assert.equal(dialog.primaryActionLabel(), '推送');
  assert.equal(dialog.primaryActionEnabled(), true);

  dialog.dismissResult();
  await dialog.runPrimaryAction();
  assert.deepEqual(calls, ['push', 'push']);
  assert.equal(dialog.localCommitPending, false);
  assert.equal(dialog.statusEntryCount, 1);
});

test('blank commit messages use the generated default', async () => {
  const { dialog, calls, actionOptions } = createHarness({
    statusEntryCount: 1,
    commitMessage: '   ',
    authorName: 'Device',
    authorEmail: 'device@example.invalid'
  });

  assert.equal(dialog.primaryActionEnabled(), true);
  await dialog.runPrimaryAction();

  assert.deepEqual(calls, ['stage', 'commit', 'push']);
  const commit = actionOptions.find((options) => options.operation === 'commit');
  assert.equal(commit.message, '更新 1 个文件（曜石笔记）');
});

test('pull requires a tracking branch, ready status and a clean worktree', () => {
  assert.equal(createHarness().dialog.canPull(), false);
  assert.equal(createHarness({ trackingBranch: 'main' }).dialog.canPull(), true);
  assert.equal(createHarness({
    trackingBranch: 'main',
    statusEntryCount: 1
  }).dialog.canPull(), false);
  assert.equal(createHarness({
    trackingBranch: 'main',
    statusReady: false
  }).dialog.canPull(), false);
});

test('fast-forward pull fetches the tracking branch and refreshes the workspace', async () => {
  const pulledEvents = [];
  const { dialog, calls, actionOptions } = createHarness({
    trackingBranch: 'main',
    onPulled: () => { pulledEvents.push('pulled'); }
  }, async (options) => {
    assert.equal(options.operation, 'pull');
    return 'fast-forwarded';
  });

  await dialog.runPullAction();
  assert.deepEqual(calls, ['pull']);
  assert.deepEqual(pulledEvents, ['pulled']);
  const pullOptions = actionOptions.find((options) => options.operation === 'pull');
  assert.equal(pullOptions.targetBranch, 'main');
  assert.equal(dialog.result, 'success');
  assert.equal(dialog.resultTitle, '已拉取远端更新');
  assert.equal(dialog.pulling, false);
  assert.equal(dialog.busy, false);
});

test('up-to-date pull keeps the dialog open without the pulled refresh', async () => {
  const pulledEvents = [];
  const { dialog, calls } = createHarness({
    trackingBranch: 'main',
    onPulled: () => { pulledEvents.push('pulled'); }
  }, async () => 'up-to-date');

  await dialog.runPullAction();
  assert.deepEqual(calls, ['pull']);
  assert.deepEqual(pulledEvents, []);
  assert.equal(dialog.result, 'none');
  assert.equal(dialog.statusMessage.includes('已是最新'), true);
});

test('pull with local changes never starts the native operation', async () => {
  const { dialog, calls } = createHarness({
    trackingBranch: 'main',
    statusEntryCount: 2
  });

  await dialog.runPullAction();
  assert.deepEqual(calls, []);
});

test('pull failures are classified by the native error keywords', () => {
  const local = createHarness({ trackingBranch: 'main' }).dialog;
  local.showPullFailure(new Error('libgit2 pull failed (code -1): 工作区还有未提交更改，请先暂存并提交'));
  assert.equal(local.result, 'local');
  assert.equal(local.retryAction, 'pull');
  assert.equal(local.resultTitle, '本地有未提交更改');

  const stale = createHarness({ trackingBranch: 'main' }).dialog;
  stale.showPullFailure(new Error('libgit2 pull failed (code -1): 本地有未推送提交，拒绝合并；请先推送到远端或交由 PC 处理'));
  assert.equal(stale.result, 'stale');
  assert.equal(stale.retryAction, 'pull');
  assert.equal(stale.resultTitle, '本地有未推送提交');

  const auth = createHarness({ trackingBranch: 'main' }).dialog;
  auth.showPullFailure(new Error('libgit2 pull failed (code -1): request failed with status code: 401'));
  assert.equal(auth.result, 'auth');
  assert.equal(auth.requiresNewToken, true);
  assert.equal(auth.credentialEditorOpen, true);
  assert.equal(auth.retryActionLabel(), '验证并重试拉取');

  const network = createHarness({ trackingBranch: 'main' }).dialog;
  network.showPullFailure(new Error('libgit2 pull failed (code -1): failed to connect to host'));
  assert.equal(network.result, 'network');
  assert.equal(network.retryActionLabel(), '重试拉取');
});

test('retrying a failed pull goes back to the pull flow', async () => {
  const { dialog, calls } = createHarness({
    trackingBranch: 'main',
    result: 'network',
    retryAction: 'pull'
  }, async () => 'fast-forwarded');

  dialog.retryFailedOperation();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, ['pull']);
  assert.equal(dialog.result, 'success');
});
