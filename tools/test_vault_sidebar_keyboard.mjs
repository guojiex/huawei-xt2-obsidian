import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url), 'utf8');
const methodStart = source.indexOf('  private onChapterKey(chapter: ChapterEntry, event: KeyEvent): boolean {');
const methodEnd = source.indexOf('\n  /**', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find VaultSidebar.onChapterKey');
const onChapterKey = source.slice(methodStart, methodEnd).trim();
const code = transformSync(`
class VaultSidebarHarness {
  visibleChapterEntries() { return this.visible; }
  focusChapter(chapter) { this.focused.push(chapter.index); }
  hasChapterChildren(index) { return this.children.includes(index); }
  isChapterCollapsed(chapter) { return this.collapsed.includes(chapter.index); }
  toggleChapter(chapter) {
    if (this.isChapterCollapsed(chapter)) {
      this.collapsed = this.collapsed.filter((index) => index !== chapter.index);
    } else {
      this.collapsed.push(chapter.index);
    }
  }
  parentChapter(chapter) { return this.parents[chapter.index] || null; }
  onSelectChapter(index) { this.selected.push(index); }
  ${onChapterKey}
}
module.exports = VaultSidebarHarness;
`, { loader: 'ts', format: 'cjs' }).code;

const KeyCode = {
  KEYCODE_DPAD_UP: 1,
  KEYCODE_DPAD_DOWN: 2,
  KEYCODE_MOVE_HOME: 3,
  KEYCODE_MOVE_END: 4,
  KEYCODE_DPAD_LEFT: 5,
  KEYCODE_DPAD_RIGHT: 6,
  KEYCODE_ENTER: 7,
  KEYCODE_SPACE: 8,
  KEYCODE_DPAD_CENTER: 9
};
const KeyType = { Down: 1, Up: 2 };

function createHarness() {
  const context = vm.createContext({ module: { exports: {} }, KeyCode, KeyType });
  vm.runInContext(code, context);
  const chapters = [
    { index: 0, level: 1, title: 'Root', offset: 0 },
    { index: 1, level: 2, title: 'Child', offset: 10 },
    { index: 2, level: 1, title: 'Next', offset: 20 }
  ];
  const app = new context.module.exports();
  Object.assign(app, {
    visible: chapters,
    focused: [],
    selected: [],
    children: [],
    collapsed: [],
    parents: {}
  });
  return { app, chapters };
}

function key(keyCode, type = KeyType.Down) {
  return { keyCode, type };
}

test('chapter arrow keys move focus and Home/End target the visible endpoints', () => {
  const { app, chapters } = createHarness();

  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_DPAD_UP)), true);
  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_MOVE_HOME)), true);
  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_MOVE_END)), true);

  assert.deepEqual(app.focused, [0, 2, 0, 2]);
});

test('left/right keys collapse, expand, and move between a chapter and its child', () => {
  const { app, chapters } = createHarness();
  app.children = [0];
  app.parents[1] = chapters[0];
  app.collapsed = [0];

  assert.equal(app.onChapterKey(chapters[0], key(KeyCode.KEYCODE_DPAD_RIGHT)), true);
  assert.deepEqual(app.collapsed, []);
  assert.equal(app.onChapterKey(chapters[0], key(KeyCode.KEYCODE_DPAD_RIGHT)), true);
  assert.deepEqual(app.focused, [1]);
  assert.equal(app.onChapterKey(chapters[0], key(KeyCode.KEYCODE_DPAD_LEFT)), true);
  assert.deepEqual(app.collapsed, [0]);
  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_DPAD_LEFT)), true);
  assert.deepEqual(app.focused, [1, 0]);
});

test('Enter, Space, and center activate the focused chapter', () => {
  const { app, chapters } = createHarness();

  for (const code of [KeyCode.KEYCODE_ENTER, KeyCode.KEYCODE_SPACE, KeyCode.KEYCODE_DPAD_CENTER]) {
    assert.equal(app.onChapterKey(chapters[1], key(code)), true);
  }

  assert.deepEqual(app.selected, [1, 1, 1]);
});

test('key-up, unknown keys, and hidden chapters are not consumed', () => {
  const { app, chapters } = createHarness();
  app.visible = [chapters[0], chapters[2]];

  assert.equal(app.onChapterKey(chapters[0], key(KeyCode.KEYCODE_DPAD_DOWN, KeyType.Up)), false);
  assert.equal(app.onChapterKey(chapters[0], key(999)), false);
  assert.equal(app.onChapterKey(chapters[1], key(KeyCode.KEYCODE_ENTER)), false);
  assert.deepEqual(app.focused, []);
  assert.deepEqual(app.selected, []);
});
