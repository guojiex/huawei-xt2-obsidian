import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const prototype = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

test('v2 settings prototype includes recent error details and copy action', () => {
  assert.ok(prototype.includes('id="recentErrorTemplate"'));
  assert.ok(prototype.includes('<dt>最近错误</dt>'));
  assert.ok(prototype.includes('操作：设置 / 复制构建提交号 · 分类：剪贴板失败'));
  assert.ok(prototype.includes('结果：未完成 · 下一步：稍后重试'));
  assert.ok(prototype.includes('id="copyRecentErrors" class="hs-back" aria-label="复制最近错误记录">复制最近错误</button>'));
  assert.ok(prototype.includes('recentErrorBuildRow.after(recentErrorTemplate.content.cloneNode(true))'));
});

test('recent error prototype styling uses v2 design tokens and copies only the sample payload', () => {
  assert.ok(/\.diagnostic-error-lines\{[^}]*var\(--s1\)[^}]*var\(--caption\)[^}]*var\(--leading\)/.test(prototype));
  assert.ok(prototype.includes('navigator.clipboard.writeText(payload)'));
  assert.ok(prototype.includes("toast('已复制最近错误记录')"));
  assert.ok(/toast\('复制失败，请稍后重试',\s*false\)/.test(prototype));
  assert.ok(!/copyRecentErrors[\s\S]{0,700}(?:note\.text|remoteUrl|accessToken|token)/.test(prototype));
});
