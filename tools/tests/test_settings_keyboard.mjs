import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url), 'utf8');
const methodStart = source.indexOf('  private onCategoryKey(category: string, event: KeyEvent): boolean {');
const methodEnd = source.indexOf('\n  private focusCategoryRow(', methodStart);
assert.ok(methodStart >= 0 && methodEnd > methodStart, 'could not find SettingsView.onCategoryKey');
const method = source.slice(methodStart, methodEnd).trim();
const code = transformSync(`class SettingsViewHarness {
  selectCategory(category) { this.selected.push(category); }
  focusCategoryRow(category) { this.focused.push(category); }
  ${method}
}; module.exports = SettingsViewHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

const KeyCode = {
  KEYCODE_DPAD_UP: 1,
  KEYCODE_DPAD_DOWN: 2,
  KEYCODE_MOVE_HOME: 3,
  KEYCODE_MOVE_END: 4,
  KEYCODE_ENTER: 5,
  KEYCODE_SPACE: 6,
  KEYCODE_DPAD_CENTER: 7
};
const KeyType = { Down: 1, Up: 2 };

function createHarness(singleScreenLayout, showCategoryList) {
  const context = vm.createContext({ module: { exports: {} }, KeyCode, KeyType });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    singleScreenLayout,
    showCategoryList,
    selected: [],
    focused: []
  });
  return app;
}

function key(keyCode, type = KeyType.Down) {
  return { keyCode, type };
}

test('wide settings navigation selects and focuses categories with wrapping and endpoints', () => {
  const app = createHarness(false, false);

  assert.equal(app.onCategoryKey('general', key(KeyCode.KEYCODE_DPAD_UP)), true);
  assert.equal(app.onCategoryKey('about', key(KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onCategoryKey('general', key(KeyCode.KEYCODE_MOVE_HOME)), true);
  assert.equal(app.onCategoryKey('general', key(KeyCode.KEYCODE_MOVE_END)), true);

  assert.deepEqual(app.selected, ['about', 'general', 'general', 'about']);
  assert.deepEqual(app.focused, app.selected);
});

test('single-screen category list moves focus before Enter selects the current row', () => {
  const app = createHarness(true, true);

  assert.equal(app.onCategoryKey('data', key(KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onCategoryKey('feedback', key(KeyCode.KEYCODE_MOVE_HOME)), true);
  assert.equal(app.onCategoryKey('general', key(KeyCode.KEYCODE_MOVE_END)), true);
  assert.equal(app.onCategoryKey('about', key(KeyCode.KEYCODE_ENTER)), true);

  assert.deepEqual(app.focused, ['feedback', 'general', 'about']);
  assert.deepEqual(app.selected, ['about']);
});

test('single-screen category details switch categories without requesting list focus', () => {
  const app = createHarness(true, false);

  assert.equal(app.onCategoryKey('data', key(KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onCategoryKey('feedback', key(KeyCode.KEYCODE_SPACE)), true);

  assert.deepEqual(app.selected, ['feedback', 'feedback']);
  assert.deepEqual(app.focused, []);
});

test('key-up and unrelated keys leave selection and focus unchanged', () => {
  const app = createHarness(false, false);

  assert.equal(app.onCategoryKey('general', key(KeyCode.KEYCODE_DPAD_DOWN, KeyType.Up)), false);
  assert.equal(app.onCategoryKey('general', key(999)), false);
  assert.deepEqual(app.selected, []);
  assert.deepEqual(app.focused, []);
});
