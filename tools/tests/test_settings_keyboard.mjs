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

const experienceMethodStart = source.indexOf('  private onExperienceModeKey(mode: EditorExperienceMode, event: KeyEvent): boolean {');
const experienceMethodEnd = source.indexOf('\n  private onExperienceModeHeadingKey', experienceMethodStart);
assert.ok(experienceMethodStart >= 0 && experienceMethodEnd > experienceMethodStart,
  'could not find SettingsView.onExperienceModeKey');
const experienceMethod = source.slice(experienceMethodStart, experienceMethodEnd).trim();
const experienceHeadingStart = source.indexOf('  private onExperienceModeHeadingKey(event: KeyEvent): boolean {');
const experienceHeadingEnd = source.indexOf('\n  @Builder', experienceHeadingStart);
assert.ok(experienceHeadingStart >= 0 && experienceHeadingEnd > experienceHeadingStart,
  'could not find SettingsView.onExperienceModeHeadingKey');
const experienceHeadingMethod = source.slice(experienceHeadingStart, experienceHeadingEnd).trim();
const experienceCode = transformSync(`class ExperienceModeHarness {
  focusExperienceMode(mode) { this.focused.push(mode); }
  onExperienceModeChange(mode) { this.selected.push(mode); }
  ${experienceMethod}
  ${experienceHeadingMethod}
}; module.exports = ExperienceModeHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

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

test('editor mode rows can receive touch and sequential Tab focus', () => {
  const simpleRow = source.slice(source.indexOf('ExperienceModeRow(mode:'), source.indexOf('private composeFeedbackBody'));
  assert.match(simpleRow, /Button\(\{ type: ButtonType\.Normal, stateEffect: false \}\)/);
  assert.match(simpleRow, /\.tabStop\(true\)/);
  assert.match(source, /Text\('编辑模式'\)[\s\S]*?\.tabStop\(true\)[\s\S]*?onExperienceModeHeadingKey\(event\)/);
});

test('editor mode arrow keys move focus and activation keys select the focused mode', () => {
  const context = vm.createContext({
    module: { exports: {} },
    KeyCode: {
      KEYCODE_DPAD_UP: 10,
      KEYCODE_DPAD_DOWN: 11,
      KEYCODE_ENTER: 12,
      KEYCODE_SPACE: 13,
      KEYCODE_DPAD_CENTER: 14
    },
    KeyType
  });
  vm.runInContext(experienceCode, context);
  const app = new context.module.exports();
  Object.assign(app, { focused: [], selected: [], experienceMode: 'simple' });

  assert.equal(app.onExperienceModeKey('simple', key(context.KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onExperienceModeKey('professional', key(context.KeyCode.KEYCODE_DPAD_UP)), true);
  assert.deepEqual(app.focused, ['professional', 'simple']);

  for (const keyCode of [context.KeyCode.KEYCODE_ENTER, context.KeyCode.KEYCODE_SPACE,
    context.KeyCode.KEYCODE_DPAD_CENTER]) {
    assert.equal(app.onExperienceModeKey('professional', key(keyCode)), true);
  }
  assert.deepEqual(app.selected, ['professional', 'professional', 'professional']);
  assert.equal(app.onExperienceModeKey('simple', key(context.KeyCode.KEYCODE_DPAD_DOWN, KeyType.Up)), false);
  assert.equal(app.onExperienceModeHeadingKey(key(context.KeyCode.KEYCODE_DPAD_DOWN)), true);
  assert.equal(app.onExperienceModeHeadingKey(key(context.KeyCode.KEYCODE_ENTER)), true);
  assert.deepEqual(app.focused, ['professional', 'simple', 'simple', 'simple']);
  assert.equal(app.onExperienceModeHeadingKey(key(context.KeyCode.KEYCODE_SPACE, KeyType.Up)), false);
});
