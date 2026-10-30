import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const storeSource = fs.readFileSync(new URL('../entry/src/main/ets/model/EditorPreferenceStore.ets', import.meta.url), 'utf8');
const webSource = fs.readFileSync(new URL('../web/mdeditor/src/index.ts', import.meta.url), 'utf8');
const settingsSource = fs.readFileSync(new URL('../entry/src/main/ets/components/SettingsView.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const editorSource = fs.readFileSync(new URL('../entry/src/main/ets/components/EditorWebView.ets', import.meta.url), 'utf8');
const prototypeSource = fs.readFileSync(new URL('../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const editorBuildSource = fs.readFileSync(new URL('../web/mdeditor/build.mjs', import.meta.url), 'utf8');

const classStart = storeSource.indexOf('export class EditorPreferenceStore {');
assert.ok(classStart >= 0, 'could not find EditorPreferenceStore');
const classSource = storeSource.slice(classStart).replace('export class EditorPreferenceStore {', 'class EditorPreferenceStore {');
const storeCode = transformSync(`${classSource}\nmodule.exports = EditorPreferenceStore;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createStore({ raw = undefined, initError = false } = {}) {
  const calls = [];
  let persisted = raw;
  const preferences = {
    getPreferencesSync(context, options) {
      calls.push(['open', context, options]);
      if (initError) {
        throw new Error('preferences unavailable');
      }
      return {
        getSync(key, fallback) {
          calls.push(['get', key, fallback]);
          return persisted === undefined ? fallback : persisted;
        },
        putSync(key, value) {
          calls.push(['put', key, value]);
          persisted = value;
        },
        flushSync() {
          calls.push(['flush']);
        }
      };
    }
  };
  const module = { exports: {} };
  vm.runInContext(storeCode, vm.createContext({ module, exports: module.exports, preferences, console: { warn() {} } }));
  const store = new module.exports({ filesDir: '/test/files' });
  return { store, calls, get persisted() { return persisted; } };
}

function lineNumberHarness() {
  const helperStart = webSource.indexOf('function setLineNumberVisibility(show: boolean): void {');
  const helperEnd = webSource.indexOf('\n}', helperStart) + 2;
  assert.ok(helperStart >= 0 && helperEnd > helperStart, 'could not find line-number visibility function');
  const helper = webSource.slice(helperStart, helperEnd);
  const code = transformSync(`
    let lineNumbersVisible = false;
    let view = null;
    ${helper}
    module.exports = { setLineNumberVisibility, setView: (nextView) => { view = nextView; },
      getState: () => ({ lineNumbersVisible, view }) };
  `, { loader: 'ts', format: 'cjs' }).code;
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  return module.exports;
}

test('line numbers default off, persist across reloads, and are shared by all vaults', () => {
  const fixture = createStore();
  assert.equal(fixture.store.showLineNumbers(), false);
  assert.equal(fixture.calls[0][2].name, 'editor_preferences');
  assert.equal(fixture.store.saveShowLineNumbers(true), undefined);
  assert.equal(fixture.persisted, 'true');

  const reopened = createStore({ raw: fixture.persisted });
  assert.equal(reopened.store.showLineNumbers(), true);
  reopened.store.saveShowLineNumbers(false);
  assert.equal(reopened.persisted, 'false');
  assert.deepEqual(reopened.calls.slice(-2), [['put', 'show_line_numbers', 'false'], ['flush']]);
});

test('missing, malformed, or unavailable preferences safely keep line numbers off', () => {
  assert.equal(createStore().store.showLineNumbers(), false);
  assert.equal(createStore({ raw: 'yes' }).store.showLineNumbers(), false);
  const unavailable = createStore({ initError: true });
  assert.equal(unavailable.store.showLineNumbers(), false);
  unavailable.store.saveShowLineNumbers(true);
  assert.equal(unavailable.calls.length, 1);
});

test('CodeMirror line-number visibility changes only a CSS class and keeps the current editor state', () => {
  const harness = lineNumberHarness();
  const classes = new Set();
  const state = { doc: 'first\nsecond', selection: { anchor: 9 } };
  const view = {
    state,
    dom: {
      classList: {
        toggle(name, enabled) {
          if (enabled) classes.add(name);
          else classes.delete(name);
        }
      }
    }
  };
  harness.setView(view);
  harness.setLineNumberVisibility(true);
  assert.equal(classes.has('cm-show-line-numbers'), true);
  assert.equal(harness.getState().lineNumbersVisible, true);
  assert.equal(harness.getState().view, view);
  assert.equal(harness.getState().view.state, state);

  harness.setLineNumberVisibility(false);
  assert.equal(classes.has('cm-show-line-numbers'), false);
  assert.equal(harness.getState().view.state, state);
});

test('bundled CSS hides CodeMirror’s forced gutter and the theme change restores the selected visibility', () => {
  assert.match(editorBuildSource, /#editor \.cm-gutter\.cm-lineNumbers \{ display: none !important; \}/);
  assert.match(editorBuildSource, /#editor \.cm-editor\.cm-show-line-numbers \.cm-gutter\.cm-lineNumbers \{ display: flex !important; \}/);

  const themeStart = webSource.indexOf('  setTheme(theme: string): void {');
  const lineNumbersStart = webSource.indexOf('  setLineNumbers(show: boolean): void {', themeStart);
  const themeMethod = webSource.slice(themeStart, lineNumbersStart);
  const stateReset = themeMethod.indexOf('view.setState(');
  const visibilityRestore = themeMethod.indexOf('setLineNumberVisibility(lineNumbersVisible)');
  assert.ok(stateReset >= 0 && visibilityRestore > stateReset);
});

test('native setting is wired to both editors and exposes a named accessible switch', () => {
  assert.equal((indexSource.match(/showLineNumbers: this\.showLineNumbers/g) ?? []).length, 3);
  assert.match(indexSource, /saveShowLineNumbers\(show\)/);
  assert.match(editorSource, /@Prop @Watch\('onLineNumbersChanged'\) showLineNumbers: boolean = false/);
  assert.match(editorSource, /window\.__mdeditor\.setLineNumbers\(\$\{show\}\)/);
  assert.match(settingsSource, /Toggle\(\{ type: ToggleType\.Switch, isOn: this\.showLineNumbers \}\)[\s\S]*?\.accessibilityText\('显示行号'\)/);
  assert.match(settingsSource, /编辑 Markdown 时显示，预览不显示/);
});

test('v2 prototype has default-off, persistent line numbers synchronized with editing and layout', () => {
  assert.match(prototypeSource, /<input type="checkbox" role="switch" id="showLineNumbers"[^>]*>/);
  assert.match(prototypeSource, /localStorage\.getItem\(lineNumberKey\)==='true'/);
  assert.match(prototypeSource, /editor\.value\.split\('\\n'\)/);
  assert.match(prototypeSource, /for\(const \[editorId,scrollId\] of \[\['editor','writingScroll'\],\['rightEditor','rightScroll'\]\]\)/);
  assert.match(prototypeSource, /document\.addEventListener\('input',scheduleLineNumbers\)/);
  assert.match(prototypeSource, /ResizeObserver\(scheduleLineNumbers\)/);
  assert.match(prototypeSource, /localStorage\.removeItem\('xt2-line-numbers'\)/);
});
