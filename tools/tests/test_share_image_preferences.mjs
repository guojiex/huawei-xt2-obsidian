import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(
  new URL('../../entry/src/main/ets/model/ShareImagePreferenceStore.ets', import.meta.url));
const classStart = source.indexOf('export class ShareImagePreferenceStore {');
assert.ok(classStart >= 0, 'could not find ShareImagePreferenceStore');
const classSource = source.slice(classStart).replace('export class ShareImagePreferenceStore {',
  'class ShareImagePreferenceStore {');
const code = transformSync(`${classSource}\nmodule.exports = ShareImagePreferenceStore;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createStore(options = {}) {
  const calls = [];
  const warnings = [];
  let persisted = options.persisted ?? '';
  const preferences = {
    getPreferencesSync(context, config) {
      calls.push(['open', config.name]);
      if (options.initError) {
        throw new Error('preferences unavailable');
      }
      return {
        getSync(key, fallback) {
          calls.push(['get', key, fallback]);
          if (options.readError) {
            throw new Error('read failed');
          }
          return persisted || fallback;
        },
        putSync(key, value) {
          calls.push(['put', key, value]);
          if (options.writeError) {
            throw new Error('write failed');
          }
          persisted = value;
        },
        flushSync() {
          calls.push(['flush']);
          if (options.flushError) {
            throw new Error('flush failed');
          }
        }
      };
    }
  };
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    preferences,
    console: { warn: (message) => warnings.push(message) }
  }));
  return {
    store: new module.exports({ filesDir: '/test/files' }),
    calls,
    warnings,
    get persisted() { return persisted; }
  };
}

test('appearance preference defaults to light and accepts only stored dark as dark', () => {
  assert.equal(createStore().store.loadTheme(), 'light');
  assert.equal(createStore({ persisted: 'dark' }).store.loadTheme(), 'dark');
  assert.equal(createStore({ persisted: 'other' }).store.loadTheme(), 'light');
});

test('initialization and read failures preserve the light default', () => {
  assert.equal(createStore({ initError: true }).store.loadTheme(), 'light');
  assert.equal(createStore({ readError: true }).store.loadTheme(), 'light');
});

test('saving the appearance flushes one app-wide key and survives a new store instance', () => {
  const fixture = createStore();
  assert.equal(fixture.store.saveTheme('dark'), true);
  assert.equal(fixture.persisted, 'dark');
  assert.deepEqual(fixture.calls.slice(-2), [['put', 'theme', 'dark'], ['flush']]);

  const reopened = createStore({ persisted: fixture.persisted });
  assert.equal(reopened.store.loadTheme(), 'dark');
});

test('invalid or failed saves do not claim persistence', () => {
  const fixture = createStore();
  assert.equal(fixture.store.saveTheme('system'), false);
  assert.equal(fixture.store.saveTheme('dark'), true);
  assert.equal(createStore({ initError: true }).store.saveTheme('dark'), false);
  assert.equal(createStore({ writeError: true }).store.saveTheme('dark'), false);
  assert.equal(createStore({ flushError: true }).store.saveTheme('dark'), false);
});

test('ShareFlowPanel restores the app-wide theme and passes it to the next settings dialog', () => {
  // 分享域拆至 ShareFlowPanel 后，主题偏好的恢复与落盘都在子组件内
  const indexSource = readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));
  const dialogSource = readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareImageSettingsDialog.ets', import.meta.url));
  assert.match(indexSource,
    /this\.shareCaptureTheme = \(this\.shareImagePreferenceStore as ShareImagePreferenceStore\)\.loadTheme\(\)/);
  assert.match(indexSource, /initialTheme: this\.shareCaptureTheme/);
  // v1.42 起主题/宽度在统一预览弹窗的 onGenerate 回调里更新并落盘
  assert.match(indexSource,
    /onGenerate: async \(widthId: string, theme: string\): Promise<ShareImagePreviewImage> => \{\s*this\.shareCaptureWidthId = widthId;\s*this\.shareCaptureTheme = theme;[\s\S]*?this\.ensureShareImagePreferenceStore\(\);\s*if \(!\(this\.shareImagePreferenceStore as ShareImagePreferenceStore\)\.saveTheme\(theme\)\)/);
  assert.match(dialogSource, /this\.theme = this\.initialTheme === 'dark' \? 'dark' : 'light'/);
});

test('width preference defaults to phone and accepts only valid ids', () => {
  assert.equal(createStore().store.loadWidth(), 'phone');
  assert.equal(createStore({ persisted: 'wide' }).store.loadWidth(), 'wide');
  assert.equal(createStore({ persisted: 'pane' }).store.loadWidth(), 'pane');
  assert.equal(createStore({ persisted: 'phone' }).store.loadWidth(), 'phone');
  assert.equal(createStore({ persisted: 'invalid' }).store.loadWidth(), 'phone');
});

test('saving the width flushes one app-wide key and survives a new store instance', () => {
  const fixture = createStore();
  assert.equal(fixture.store.saveWidth('wide'), true);
  assert.equal(fixture.persisted, 'wide');
  assert.deepEqual(fixture.calls.slice(-2), [['put', 'width', 'wide'], ['flush']]);

  const reopened = createStore({ persisted: fixture.persisted });
  assert.equal(reopened.store.loadWidth(), 'wide');
});

test('invalid or failed width saves do not claim persistence', () => {
  const fixture = createStore();
  assert.equal(fixture.store.saveWidth('unknown'), false);
  assert.equal(fixture.store.saveWidth('wide'), true);
  assert.equal(createStore({ initError: true }).store.saveWidth('wide'), false);
  assert.equal(createStore({ writeError: true }).store.saveWidth('wide'), false);
  assert.equal(createStore({ flushError: true }).store.saveWidth('wide'), false);
});

test('ShareFlowPanel restores the app-wide width preference and passes it to the settings dialog', () => {
  // 分享域拆至 ShareFlowPanel 后，宽度偏好的恢复与落盘都在子组件内
  const indexSource = readSourceFile(
    new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url));
  assert.match(indexSource,
    /this\.shareCaptureWidthId = \(this\.shareImagePreferenceStore as ShareImagePreferenceStore\)\.loadWidth\(\)/);
  assert.match(indexSource, /initialWidthId: this\.shareCaptureWidthId/);
  assert.match(indexSource,
    /this\.shareCaptureWidthId = widthId;\s*this\.shareCaptureTheme = theme/);
  assert.match(indexSource,
    /!\(this\.shareImagePreferenceStore as ShareImagePreferenceStore\)\.saveWidth\(widthId\)/);
});
