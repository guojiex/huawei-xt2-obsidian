import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { buildSync, transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/model/SplitLayoutStore.ets', import.meta.url), 'utf8');
const layoutBundle = buildSync({
  entryPoints: [new URL('../entry/src/main/ets/model/PaneLayout.ets', import.meta.url).pathname],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  write: false,
  resolveExtensions: ['.ets', '.ts', '.js'],
  loader: { '.ets': 'ts' }
}).outputFiles[0].text;
const layoutModule = { exports: {} };
new Function('module', 'exports', layoutBundle)(layoutModule, layoutModule.exports);
const { DEFAULT_CONTENT_RATIO } = layoutModule.exports;
const classStart = source.indexOf('export class SplitLayoutStore {');
assert.ok(classStart >= 0, 'could not find SplitLayoutStore');
const classSource = source.slice(classStart).replace('export class SplitLayoutStore {', 'class SplitLayoutStore {');
const code = transformSync(`${classSource}\nmodule.exports = SplitLayoutStore;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createStore({ raw = '', initError = false } = {}) {
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
          return persisted.length > 0 ? persisted : fallback;
        },
        putSync(key, value) {
          calls.push(['put', key, value]);
          persisted = value;
        },
        flushSync() {
          calls.push(['flush']);
        },
        deleteSync(key) {
          calls.push(['delete', key]);
          persisted = '';
        }
      };
    }
  };
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    preferences,
    DEFAULT_CONTENT_RATIO,
    console: { warn() {} }
  }));
  const store = new module.exports({ filesDir: '/test/files' });
  return { store, calls, get persisted() { return persisted; } };
}

function normalizedState(store) {
  return JSON.parse(JSON.stringify(store.load()));
}

test('empty preferences load the navigation sentinel and default content ratio', () => {
  const fixture = createStore();

  assert.deepEqual(normalizedState(fixture.store), { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO });
  assert.equal(fixture.calls[0][0], 'open');
  assert.equal(fixture.calls[0][1].filesDir, '/test/files');
  assert.equal(fixture.calls[0][2].name, 'pane_layout');
});

test('valid persisted pane ratios include the configured navigation boundaries', () => {
  const lower = createStore({ raw: '{"navigationRatio":0.22,"contentRatio":0.25}' });
  const upper = createStore({ raw: '{"navigationRatio":0.46,"contentRatio":0.75}' });

  assert.deepEqual(normalizedState(lower.store), { navigationRatio: 0.22, contentRatio: 0.25 });
  assert.deepEqual(normalizedState(upper.store), { navigationRatio: 0.46, contentRatio: 0.75 });
});

test('out-of-range persisted ratios fall back independently', () => {
  const fixture = createStore({ raw: '{"navigationRatio":0.21,"contentRatio":1}' });

  assert.deepEqual(normalizedState(fixture.store), { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO });
});

test('malformed or incomplete snapshots return safe defaults', () => {
  const malformed = createStore({ raw: '{broken' });
  const incomplete = createStore({ raw: '{"navigationRatio":0.3}' });

  assert.deepEqual(normalizedState(malformed.store), { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO });
  assert.deepEqual(normalizedState(incomplete.store), {
    navigationRatio: 0.3,
    contentRatio: DEFAULT_CONTENT_RATIO
  });
});

test('preference initialization failure leaves layout defaults and makes save/reset safe no-ops', () => {
  const fixture = createStore({ initError: true });

  assert.deepEqual(normalizedState(fixture.store), { navigationRatio: -1, contentRatio: DEFAULT_CONTENT_RATIO });
  fixture.store.save({ navigationRatio: 0.3, contentRatio: 0.4 });
  fixture.store.reset();
  assert.equal(fixture.calls.length, 1);
});

test('save writes the existing shared_split JSON key and flushes it', () => {
  const fixture = createStore();
  const state = { navigationRatio: 0.31, contentRatio: 0.42 };

  fixture.store.save(state);

  assert.equal(fixture.persisted, JSON.stringify(state));
  assert.deepEqual(fixture.calls.slice(-2), [
    ['put', 'shared_split', JSON.stringify(state)],
    ['flush']
  ]);
});

test('reset deletes the existing shared_split key and flushes it', () => {
  const fixture = createStore({ raw: '{"navigationRatio":0.3,"contentRatio":0.4}' });

  fixture.store.reset();

  assert.equal(fixture.persisted, '');
  assert.deepEqual(fixture.calls.slice(-2), [['delete', 'shared_split'], ['flush']]);
});
