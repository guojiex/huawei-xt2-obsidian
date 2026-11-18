import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

const repoRoot = new URL('../../', import.meta.url);
const previewSource = readSourceFile(new URL('web/mdpreview/src/index.ts', repoRoot));
const indexSource = readSourceFile(new URL('entry/src/main/ets/pages/Index.ets', repoRoot));
const generatedPreview = readSourceFile(
  new URL('entry/src/main/resources/rawfile/mdpreview/index.html', repoRoot)
);

test('v1.83: simple-mode empty placeholders are unified to 空笔记 in source', () => {
  // 可编辑空态（simpleGenerated 分支与 setContent 复用分支）统一占位文案。
  assert.match(
    previewSource,
    /empty\.dataset\.placeholder = '空笔记'\s*\n\s*empty\.dataset\.simpleGenerated = 'true'/
  );
  assert.match(
    previewSource,
    /if \(empty && editable\) \{[\s\S]*?empty\.dataset\.placeholder = '空笔记'[\s\S]*?empty\.setAttribute\('contenteditable', 'true'\)/
  );
  // 只读空态占位保持不变。
  assert.match(
    previewSource,
    /'<div class="preview-body"><div class="empty" data-placeholder="空笔记"><\/div><\/div>'/
  );
  // 旧文案不再出现：两栏同笔记不再显示成不一样。
  assert.ok(!previewSource.includes('在此输入正文'));
});

test('v1.83: rebuilt rawfile bundle carries the unified placeholder', () => {
  assert.ok(!generatedPreview.includes('在此输入正文'));
  assert.ok(!generatedPreview.includes('\\u5728\\u6B64\\u8F93\\u5165'));
  const unified = (generatedPreview.match(/\\u7A7A\\u7B14\\u8BB0/g) ?? []).length;
  assert.ok(unified >= 4, `expected >= 4 unified placeholder escapes, got ${unified}`);
  // 可编辑空态节点仍带 contenteditable 与源区间属性（2026-11-09 光标居中修复不回退）。
  assert.match(
    generatedPreview,
    /dataset\.placeholder="\\u7A7A\\u7B14\\u8BB0",h\.setAttribute\("contenteditable","true"\)/
  );
});

test('v1.83: same-note single-caret rule is unchanged (83.2)', () => {
  assert.match(
    indexSource,
    /private simplePreviewEditable\(pane: string\): boolean \{\s*if \(this\.experienceMode !== 'simple' \|\| this\.vaultSwitchInProgress\) \{\s*return false;\s*\}\s*const sameNote: boolean = this\.currentFilePath\.length > 0 &&\s*this\.currentFilePath === this\.rightFilePath;\s*return !sameNote \|\| this\.activePane === pane;\s*\}/
  );
  assert.match(indexSource, /private async refreshSharedEditability\(\): Promise<void> \{/);
});
