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
const pathEnd = indexSource.indexOf('\n  private openShareDialog(', pathStart);
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
});
