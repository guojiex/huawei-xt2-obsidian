import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

// 回归测试：跨笔记串写防护（任务清单 372B 内容写入 快速上手.md 的实锤事故）。
// 保存链必须同时满足：会话活动 isFor(vaultId, path) + snapshot.revision === session.revision。
// 任一不满足 → 拒绝落盘（撕裂只导致少保存，绝不存错文件）。

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function extract(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find source block ${startMarker}`);
  return source.slice(start, end).trim();
}

const methods = [
  extract('  private async persistEditorDraftSnapshot(', '\n  private async refreshBacklinks()'),
  extract('  private async flushRightSave(', '\n  private scheduleRightSave()'),
  extract('  private async flushSave(', '\n  /** Persist visible workspace content')
];
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
  sharedNoteEditor() { return this.rightEditorBridge; }
}; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function makeSession(vaultId, path, baseline, revision) {
  return {
    vaultId,
    path,
    baseline,
    revision,
    isFor(otherVaultId, otherPath) {
      return this.vaultId === otherVaultId && this.path === otherPath;
    }
  };
}

const TUTORIAL_BASELINE = '# 快速上手\n\n曜石笔记入门指南，包含基础操作表格与链接示例。';
const CHECKLIST_CONTENT = '- [ ] 整理三栏布局要点\n- [ ] 验证自动保存\n- [ ] 复查串写回归\n';

function createHarness(options = {}) {
  const calls = [];
  const writes = [];
  const leftEditor = {
    ready: true,
    async getContentSnapshot() {
      calls.push('left-read');
      return {
        text: options.leftText ?? CHECKLIST_CONTENT,
        revision: options.leftRevision ?? 6
      };
    }
  };
  const rightEditor = {
    ready: true,
    async getContentSnapshot() {
      calls.push('right-read');
      return {
        text: options.rightText ?? CHECKLIST_CONTENT,
        revision: options.rightRevision ?? 6
      };
    }
  };
  const context = vm.createContext({
    module: { exports: {} },
    clearTimeout() {},
    DOMAIN: 0,
    TAG: 'test',
    NoteService: { async saveNote(...args) { writes.push(args); } },
    NoteDraftService: {
      async persist(...args) { calls.push(['draft-persist', ...args.slice(1)]); return true; },
      async clearIfMatches(...args) { calls.push(['draft-clear', ...args.slice(1)]); }
    },
    VaultRegistry: { get: () => ({}) },
    WorkspaceEditGuard: { clear() {} },
    shouldShowSaveFeedback: () => false,
    promptAction: { showToast() {} },
    hilog: { warn() {}, error() {} }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    context,
    calls,
    writes,
    currentFilePath: '00_开始/快速上手.md',
    currentVaultId: 'local',
    rightFilePath: '10_写作/任务清单.md',
    editorBridge: leftEditor,
    rightEditorBridge: rightEditor,
    leftComposing: false,
    rightComposing: false,
    leftSession: makeSession('local', '00_开始/快速上手.md', TUTORIAL_BASELINE, 5),
    rightSession: makeSession('local', '10_写作/任务清单.md', CHECKLIST_CONTENT, 5),
    saveTimer: -1,
    rightSaveTimer: -1,
    saveFeedbackRevision: 0,
    editorDirty: true,
    rightEditorDirty: true,
    topView: 'note',
    clearStaleSaveNotice() {},
    showSaveFeedback() {},
    refreshBacklinks() {},
    handleEditorSaveError() { calls.push('save-error'); },
    showEditorMismatchRecovery(_vault, path) { calls.push('mismatch:' + path); }
  });
  return app;
}

test('cross-note content with a foreign revision can never reach saveNote (372B regression)', async () => {
  const app = createHarness();
  // 事故形态：左栏会话指向 快速上手.md(rev5)，编辑器回包却是 任务清单 内容且 revision=6。
  assert.equal(await app.flushSave(), false);
  assert.deepEqual(app.calls, ['left-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.leftSession.baseline, TUTORIAL_BASELINE);
});

test('cross-note content with a foreign revision is rejected in the right pane too', async () => {
  const app = createHarness();
  assert.equal(await app.flushRightSave(), false);
  assert.deepEqual(app.calls, ['right-read']);
  assert.deepEqual(app.writes, []);
  assert.equal(app.rightSession.baseline, CHECKLIST_CONTENT);
});

test('a matching revision saves the session note normally', async () => {
  const app = createHarness({
    leftText: TUTORIAL_BASELINE + '\n新增一段。',
    leftRevision: 5
  });

  assert.equal(await app.flushSave(), true);
  assert.equal(app.writes.length, 1);
  assert.equal(app.writes[0][1], 'local');
  assert.equal(app.writes[0][2], '00_开始/快速上手.md');
  assert.equal(app.writes[0][3], TUTORIAL_BASELINE + '\n新增一段。');
  assert.equal(app.writes[0][4], TUTORIAL_BASELINE);
  assert.equal(app.leftSession.baseline, TUTORIAL_BASELINE + '\n新增一段。');
});
