import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/SettingsView.ets', import.meta.url), 'utf8');
const appConfig = JSON.parse(fs.readFileSync(new URL('../app_config.json', import.meta.url), 'utf8'));

function extractMethod(signature, nextSignature) {
  const start = source.indexOf(signature);
  const end = source.indexOf(nextSignature, start);
  assert.ok(start >= 0 && end > start, `could not find ${signature.trim()}`);
  return source.slice(start, end).trim();
}

const composeMethod = extractMethod(
  '  private composeFeedbackBody(): string {',
  '\n  private async openFeedbackEmail()'
);
const openEmailMethod = extractMethod(
  '  private async openFeedbackEmail(): Promise<void> {',
  '\n  private previewFeedback()'
);
const previewMethod = extractMethod(
  '  private previewFeedback(): void {',
  '\n  private onSelectedCategoryChanged()'
);
const code = transformSync(`class SettingsFeedbackHarness {
  ${composeMethod}
  ${openEmailMethod}
  ${previewMethod}
}; module.exports = SettingsFeedbackHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness({ steps = '', actual = '', expected = '', rejectStart = false } = {}) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    FEEDBACK_EMAIL: appConfig.feedbackEmail,
    getContext() {
      return {
        startAbility(want) {
          calls.push({ action: want.action, uri: want.uri });
          return rejectStart ? Promise.reject(new Error('controlled intent failure')) : Promise.resolve();
        }
      };
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    feedbackSteps: steps,
    feedbackActual: actual,
    feedbackExpected: expected,
    feedbackPreview: '',
    feedbackError: 'old error'
  });
  return { app, calls };
}

const fallbackDraft = '操作步骤：\n\n实际结果：\n\n期望结果：';
const expectedSubject = encodeURIComponent('曜石笔记 · 问题与建议');

test('feedback body joins labeled fields and omits blank fields', () => {
  const { app } = createHarness({
    steps: '  点击按钮  ',
    actual: '\n无变化\n',
    expected: '  '
  });

  assert.equal(app.composeFeedbackBody(), '操作步骤：\n点击按钮\n\n实际结果：\n无变化');
});

test('feedback preview uses trimmed fields and provides an empty-draft prompt', () => {
  const { app } = createHarness({ steps: '  点击按钮  ', actual: ' 无变化 ' });

  app.previewFeedback();
  assert.equal(app.feedbackPreview, '操作步骤：\n点击按钮\n\n实际结果：\n无变化');

  app.feedbackSteps = ' \n  ';
  app.feedbackActual = '';
  app.previewFeedback();
  assert.equal(app.feedbackPreview, '请先填写反馈内容');
});

test('mailto intent encodes the user draft as the email body', async () => {
  const draft = '操作步骤：\nA&B\n\n实际结果：\n标题=未更新？\n\n期望结果：\n显示草稿';
  const { app, calls } = createHarness({ steps: 'A&B', actual: '标题=未更新？', expected: '显示草稿' });

  await app.openFeedbackEmail();

  assert.deepEqual(calls, [{
    action: 'ohos.want.action.sendToData',
    uri: `mailto:${appConfig.feedbackEmail}?subject=${expectedSubject}&body=${encodeURIComponent(draft)}`
  }]);
  assert.equal(app.feedbackError, '');
});

test('mailto intent uses the documented template when the draft is empty', async () => {
  const { app, calls } = createHarness();

  await app.openFeedbackEmail();

  assert.deepEqual(calls, [{
    action: 'ohos.want.action.sendToData',
    uri: `mailto:${appConfig.feedbackEmail}?subject=${expectedSubject}&body=${encodeURIComponent(fallbackDraft)}`
  }]);
  assert.equal(app.feedbackError, '');
});

test('unhandled mail intent reports the existing manual-email fallback', async () => {
  const { app, calls } = createHarness({ steps: '反馈草稿', rejectStart: true });

  await app.openFeedbackEmail();

  assert.equal(calls.length, 1);
  assert.equal(app.feedbackError, '未能打开邮件应用，请使用上方反馈邮箱手动发送');
});
