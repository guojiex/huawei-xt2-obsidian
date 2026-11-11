import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const dialogSource = readSourceFile(new URL('../../entry/src/main/ets/components/ShareNoteDialog.ets', import.meta.url));
const pathStart = indexSource.indexOf('  private sharePathForScope(');
const pathEnd = indexSource.indexOf('\n  build() {', pathStart);
assert.ok(pathStart >= 0 && pathEnd > pathStart, 'could not find sharePathForScope');

const harnessCode = transformSync(`
class ShareScopeHarness {
  ${indexSource.slice(pathStart, pathEnd)}
}
module.exports = ShareScopeHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createHarness() {
  const module = { exports: {} };
  vm.runInContext(harnessCode, vm.createContext({
    module,
    exports: module.exports,
    NoteShareService: {
      parentOf(path) {
        const slash = path.lastIndexOf('/');
        return slash < 0 ? '' : path.substring(0, slash);
      }
    }
  }));
  return new module.exports();
}

function extractDialogMethod(startMarker, endMarker) {
  const start = dialogSource.indexOf(startMarker);
  const end = dialogSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find ${startMarker}`);
  return dialogSource.slice(start, end);
}

const dialogMethods = transformSync(`
class ShareScopeDialogHarness {
  ${extractDialogMethod('  private selectScope(', '\n  private scopeFormatAreaHeight()')}
  ${extractDialogMethod('  private scopeFormatAreaHeight()', '\n  private onDialogKey(')}
}
module.exports = ShareScopeDialogHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createDialogHarness() {
  const module = { exports: {} };
  vm.runInContext(dialogMethods, vm.createContext({
    module,
    exports: module.exports,
    Motion: { navCurve: 'nav-curve' },
    Space: { s16: 64, s2: 8, s3: 12 }
  }));
  const dialog = new module.exports();
  dialog.scopeOptions = [
    { scope: 'note', available: true, options: [{}, {}, {}, {}] },
    { scope: 'folder', available: true, options: [{}] },
    { scope: 'vault', available: true, options: [{}, {}] }
  ];
  dialog.selectedScope = 'note';
  dialog.getUIContext = () => ({
    animateTo(options, callback) {
      dialog.animation = options;
      callback();
    }
  });
  return dialog;
}

test('share range resolves the active note, source folder, and current vault independently', () => {
  const app = createHarness();
  assert.equal(app.sharePathForScope('note', 'folder', '10_写作', '10_写作/草稿.md'),
    '10_写作/草稿.md');
  assert.equal(app.sharePathForScope('folder', 'folder', '10_写作', '其他/草稿.md'),
    '10_写作');
  assert.equal(app.sharePathForScope('folder', 'note', '草稿.md', '10_写作/草稿.md'),
    '10_写作');
  assert.equal(app.sharePathForScope('folder', 'vault', '', '草稿.md'), '');
  assert.equal(app.sharePathForScope('vault', 'folder', '10_写作', '草稿.md'), '');
});

test('range changes animate for 200ms and reserve the largest format area', () => {
  const dialog = createDialogHarness();

  dialog.selectScope('folder');

  assert.equal(dialog.selectedScope, 'folder');
  assert.equal(dialog.animation.duration, 200);
  assert.equal(dialog.animation.curve, 'nav-curve');
  assert.equal(dialog.scopeFormatAreaHeight(), 4 * (64 + 8 + 12) + 3 * 8);
  assert.match(dialogSource, /\.height\(this\.scopeFormatAreaHeight\(\)\)/);
  assert.match(dialogSource, /TransitionEffect\.opacity\(0\)\.combine\(TransitionEffect\.translate\(\{ y: Space\.s2 \}\)\)/);
  assert.match(dialogSource, /this\.selectScope\(this\.scopeOptions\[index\]\.scope\)/);
});

test('native share selector exposes three ranges, keyboard switching, and actionable format rows', () => {
  assert.match(indexSource, /label: '笔记'/);
  assert.match(indexSource, /label: '文件夹'/);
  assert.match(indexSource, /label: '知识库'/);
  assert.match(dialogSource, /KEYCODE_DPAD_LEFT/);
  assert.match(dialogSource, /KEYCODE_DPAD_RIGHT/);
  assert.match(dialogSource, /KEYCODE_ESCAPE/);
  assert.match(dialogSource, /Scroll\(\)/);
  assert.match(dialogSource, /this\.windowHeightVp - Space\.s8 \* 4/);
  assert.match(dialogSource, /this\.chooseFormat\(scope, option\)/);
  assert.match(dialogSource, /option\.icon/);
  assert.match(dialogSource, /minHeight: Space\.s16 \+ Space\.s2/);
  assert.match(dialogSource, /headerIcon: 'share'/);
  assert.match(dialogSource, /closeLabel: '关闭分享'/);
});

test('folder range is deduplicated against the vault range when the note sits at the vault root', () => {
  assert.match(indexSource, /folderScopeDistinct: boolean = folderPath\.length > 0/);
  assert.match(indexSource,
    /: folderScopeDistinct \? \[noteOption, folderOption, vaultOption\] : \[noteOption, vaultOption\]/);
  const app = createHarness();
  assert.equal(app.sharePathForScope('folder', 'note', '根笔记.md', '根笔记.md'), '');
  assert.equal(app.sharePathForScope('folder', 'note', '10_写作/草稿.md', '10_写作/草稿.md'), '10_写作');
});

// 2026-11-11 Z5 防回归：Color.Transparent = rgba(0,0,0,0)（透明黑，官方 FAQ
// faqs-arkui-1192 明载）。selectScope 的 animateTo 对 ARGB 四通道线性插值，
// bg_card（浅色 #FFFFFF）→ 透明黑的中途帧 ≈ rgba(128,128,128,.5) 半透明灰黑，
// 切范围时旧 tab「闪一下」。锁死：未选中底色必须是与 bg_card 同 RGB、只降 alpha
// 的主题资源 bg_card_transparent（纯 alpha 渐变，两主题都干净）。
test('scope tab background fades to themed transparent bg_card, never Color.Transparent', () => {
  const baseColors = readSourceFile(new URL(
    '../../entry/src/main/resources/base/element/color.json', import.meta.url));
  const darkColors = readSourceFile(new URL(
    '../../entry/src/main/resources/dark/element/color.json', import.meta.url));
  assert.match(baseColors, /\{ "name": "bg_card", "value": "#FFFFFF" \}/);
  assert.match(baseColors, /\{ "name": "bg_card_transparent", "value": "#00FFFFFF" \}/);
  assert.match(darkColors, /\{ "name": "bg_card", "value": "#1D232B" \}/);
  assert.match(darkColors, /\{ "name": "bg_card_transparent", "value": "#001D232B" \}/);
  assert.match(dialogSource, /bg_card_transparent/);
  // 只禁「使用形态」（注释里提及 Color.Transparent 不算）
  assert.doesNotMatch(dialogSource, /: Color\.Transparent\)/,
    'ShareNoteDialog must not animate bg_card toward transparent black (flash midframe)');
});
