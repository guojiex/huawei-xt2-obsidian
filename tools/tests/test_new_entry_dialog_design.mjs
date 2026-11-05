import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

const dialogSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/NoteDialogs.ets', import.meta.url));
const tokensSource = readSourceFile(
  new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const hintStart = dialogSource.indexOf('  private hintText(): string {');
const hintEnd = dialogSource.indexOf('\n  private confirm(): void {', hintStart);
const contentStart = dialogSource.indexOf('  DialogContent() {');
const contentEnd = dialogSource.indexOf('\n  @Builder\n  DialogFooter()', contentStart);
assert.ok(hintStart >= 0 && hintEnd > hintStart, 'could not find CreateNoteDialog.hintText');
assert.ok(contentStart >= 0 && contentEnd > contentStart, 'could not find CreateNoteDialog.DialogContent');
const hint = dialogSource.slice(hintStart, hintEnd);
const content = dialogSource.slice(contentStart, contentEnd);
const segmentStart = content.indexOf('// 切类型不清空已输名称');
const segmentEnd = content.indexOf('// 目录选择行', segmentStart);
assert.ok(segmentStart >= 0 && segmentEnd > segmentStart, 'could not find new-entry type segments');
const segments = content.slice(segmentStart, segmentEnd);

test('ordinary valid paths are not repeated below the selected folder', () => {
  assert.match(hint, /if \(actual !== rel\) \{[\s\S]*?同名已存在，自动加后缀/);
  assert.equal((hint.match(/return '';/g) || []).length, 2);
  assert.match(content, /if \(this\.hintText\(\)\.length > 0\) \{\s*Text\(this\.hintText\(\)\)/);
  assert.match(prototype, /#newEntryTarget:empty\{display:none\}/);
});

test('the creation type switch uses the v2 capsule segment tokens and labels', () => {
  assert.match(segments, /Row\(\{ space: Space\.s1 \}\)/);
  assert.match(segments, /\.padding\(Space\.s1\)/);
  assert.match(segments, /\.backgroundColor\(\$r\('app\.color\.bg_secondary'\)\)/);
  assert.match(segments, /\.borderRadius\(Radius\.full\)/);
  assert.match(segments, /Text\('笔记'\)[\s\S]*Text\('文件夹'\)/);
  assert.match(segments, /\.height\(Space\.s10\)/);
  assert.match(segments, /app\.color\.bg_card/);
  assert.match(segments, /app\.color\.brand/);
  assert.match(segments, /Shadow\.floatBlur/);
  assert.doesNotMatch(segments, /Icon\(/);
  assert.match(tokensSource, /static readonly floatBlur: number = 28/);
  assert.match(prototype, /\.new-entry-kind\{gap:var\(--s1\);padding:var\(--s1\);border-radius:var\(--pill\);background:var\(--nav\)\}/);
  assert.match(prototype, /\.new-entry-kind button\[aria-pressed=true\]\{border:0;background:var\(--paper\);color:var\(--blue\);box-shadow:var\(--float-shadow\)\}/);
});

test('the selected folder and create action remain intact', () => {
  assert.match(content, /this\.selectedDir\.length > 0 \? this\.selectedDir : '根目录'/);
  assert.match(dialogSource, /this\.onConfirm\(this\.composed\(\), this\.createType\)/);
});
