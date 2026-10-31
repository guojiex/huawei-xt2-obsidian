import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';
const source = readSourceFile(new URL('../entry/src/main/ets/model/RecentOpenStore.ets', import.meta.url));
const code = transformSync(source.replace(/^import .*;\n/gm, ''), { loader: 'ts', format: 'cjs' }).code;

function createStore(initial = {}) {
  const values = new Map(Object.entries(initial));
  const preferences = {
    getPreferencesSync(_context, options) {
      assert.equal(options.name, 'recent_open_state');
      return {
        getSync(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
        putSync(key, value) { values.set(key, value); },
        flush() {}
      };
    }
  };
  const context = vm.createContext({
    module: { exports: {} },
    preferences,
    hilog: { error() {} }
  });
  vm.runInContext(code, context);
  const Store = context.module.exports.RecentOpenStore;
  return { store: new Store({}), values };
}

test('keeps recent paths isolated by vault and moves a reopened note to the front', () => {
  const { store, values } = createStore();
  store.record('a', 'folder/first.md');
  store.record('a', 'second.md');
  store.record('a', 'folder/first.md');
  store.record('b', 'other-vault.md');

  assert.deepEqual(Array.from(store.load('a', ['folder/first.md', 'second.md'])), ['folder/first.md', 'second.md']);
  assert.deepEqual(Array.from(store.load('b', ['other-vault.md'])), ['other-vault.md']);
  assert.equal(values.get('recent_a'), '["folder/first.md","second.md"]');
  assert.equal(values.get('recent_b'), '["other-vault.md"]');
});

test('caps recent history at the supported limit', () => {
  const { store } = createStore();
  for (let i = 0; i < 12; i++) {
    store.record('a', 'note-' + i.toString() + '.md');
  }

  const recent = store.load('a', Array.from({ length: 12 }, (_value, index) => 'note-' + index.toString() + '.md'));
  assert.equal(recent.length, 10);
  assert.equal(recent[0], 'note-11.md');
  assert.equal(recent[9], 'note-2.md');
});

test('prunes deleted paths and duplicates when loading current-vault history', () => {
  const { store, values } = createStore({
    recent_a: '["deleted.md","kept.md","kept.md","also-kept.md"]'
  });

  assert.deepEqual(Array.from(store.load('a', ['kept.md', 'also-kept.md'])), ['kept.md', 'also-kept.md']);
  assert.equal(values.get('recent_a'), '["kept.md","also-kept.md"]');
});

test('retargets one file without changing similarly prefixed paths', () => {
  const { store, values } = createStore({
    recent_a: '["folder/note.md","folder/note.mdx","other.md"]'
  });

  store.retarget('a', 'folder/note.md', 'archive/note.md', false);
  assert.equal(values.get('recent_a'), '["archive/note.md","folder/note.mdx","other.md"]');
});

test('retargets a moved directory subtree while leaving sibling directories alone', () => {
  const { store, values } = createStore({
    recent_a: '["folder/a.md","folder/sub/b.md","folderish/c.md"]'
  });

  store.retarget('a', 'folder', 'archive/folder', true);
  assert.equal(values.get('recent_a'), '["archive/folder/a.md","archive/folder/sub/b.md","folderish/c.md"]');
});
