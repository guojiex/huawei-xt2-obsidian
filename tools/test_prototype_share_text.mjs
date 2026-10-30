import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const helperStart = html.indexOf('function plainShareText(title, markdown) {');
const helperEnd = html.indexOf('function previewShare(mode){', helperStart);
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find v2 plainShareText helper');
const context = vm.createContext({ module: { exports: {} } });
vm.runInContext(`${html.slice(helperStart, helperEnd)}\nmodule.exports = plainShareText;`, context);
const plainShareText = context.module.exports;

test('v2 note sharing offers text only for a note and presents an editable preview', () => {
  assert.match(html, /id="shareText"/);
  assert.match(html, /shareText'\)\.classList\.toggle\('hidden',s\.scope!=='note'\)/);
  assert.match(html, /\$\('shareText'\)\.onclick=\(\)=>previewShare\('text'\)/);
  assert.match(html, /id="shareTextDraft" aria-label="可编辑的分享文本"/);
  assert.match(html, /编辑仅作用于本次分享，不改写笔记/);
});

test('v2 text preview removes frontmatter and repeated title while keeping links, tasks, and image notices readable', () => {
  const result = plainShareText('fallback', [
    '---',
    'title: "Reading note"',
    'tags: [sample]',
    '---',
    '# Reading note',
    '',
    'A **bold** [link](https://example.test).',
    '- [x] done',
    '![cover](assets/cover.png)'
  ].join('\n'));

  assert.equal(result, [
    'Reading note',
    '',
    'A bold link (https://example.test).',
    '☑ done',
    '[图片：cover]'
  ].join('\n'));
});
