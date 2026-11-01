import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { test } from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const policySource = fs.readFileSync(new URL('../../entry/src/main/ets/model/EditorExperiencePolicy.ets', import.meta.url), 'utf8');
const storeSource = fs.readFileSync(new URL('../../entry/src/main/ets/model/EditorExperienceStore.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const settingsSource = fs.readFileSync(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url), 'utf8');
const editorSource = fs.readFileSync(new URL('../../entry/src/main/ets/components/EditorWebView.ets', import.meta.url), 'utf8');
const storeStart = storeSource.indexOf('export class EditorExperienceStore {');
assert.ok(storeStart >= 0, 'could not find EditorExperienceStore');
const classSource = storeSource.slice(storeStart).replace('export class EditorExperienceStore {', 'class EditorExperienceStore {');
const policy = policySource.replace(/^export /gm, '');
const code = transformSync(`${policy}\nconst EXPERIENCE_DOMAIN = 0;\nconst EXPERIENCE_TAG = 'test';\n${classSource}\nmodule.exports = EditorExperienceStore;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createStore({ raw = undefined, initError = false, readError = false, writeError = false, flushError = false } = {}) {
  const calls = [];
  let persisted = raw;
  const preferences = {
    getPreferencesSync(context, options) {
      calls.push(['open', context, options]);
      if (initError) throw new Error('preferences unavailable');
      return {
        getSync(key, fallback) {
          calls.push(['get', key, fallback]);
          if (readError) throw new Error('read failed');
          return persisted === undefined ? fallback : persisted;
        },
        putSync(key, value) {
          calls.push(['put', key, value]);
          if (writeError) throw new Error('write failed');
          persisted = value;
        },
        flushSync() {
          calls.push(['flush']);
          if (flushError) throw new Error('flush failed');
        }
      };
    }
  };
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({
    module,
    exports: module.exports,
    preferences,
    hilog: { error() {} },
    JSON
  }));
  const store = new module.exports({ filesDir: '/test/files' });
  return { store, calls, get persisted() { return persisted; } };
}

test('mode defaults to simple without writing a preference and is shared across vaults', () => {
  const fixture = createStore();
  assert.equal(fixture.store.load(), 'simple');
  assert.equal(JSON.stringify(fixture.calls), JSON.stringify([
    ['open', { filesDir: '/test/files' }, { name: 'editor_preferences' }],
    ['get', 'experience_mode', 'simple']
  ]));
  assert.equal(fixture.persisted, undefined);
});

test('only an explicit supported mode is stored and survives store recreation', () => {
  const fixture = createStore();
  assert.equal(fixture.store.save('professional'), true);
  assert.equal(fixture.persisted, 'professional');
  assert.equal(JSON.stringify(fixture.calls.slice(-2)), JSON.stringify([
    ['put', 'experience_mode', 'professional'],
    ['flush']
  ]));
  assert.equal(createStore({ raw: fixture.persisted }).store.load(), 'professional');
  assert.equal(fixture.store.save('simple'), true);
  assert.equal(fixture.persisted, 'simple');
});

test('missing, invalid, or unreadable values safely fall back to simple', () => {
  assert.equal(createStore().store.load(), 'simple');
  assert.equal(createStore({ raw: 'pro' }).store.load(), 'simple');
  assert.equal(createStore({ readError: true }).store.load(), 'simple');
  const unavailable = createStore({ initError: true });
  assert.equal(unavailable.store.load(), 'simple');
  assert.equal(unavailable.store.save('professional'), false);
});

test('a preference write or flush failure is reported without claiming persistence', () => {
  const fixture = createStore({ writeError: true });
  assert.equal(fixture.store.save('professional'), false);
  assert.equal(fixture.persisted, undefined);
  const flushFailure = createStore({ flushError: true });
  assert.equal(flushFailure.store.save('professional'), false);
});

test('the workspace loads mode independently of restored editor and preview flags', () => {
  const modeLoad = indexSource.indexOf('this.experienceMode = (this.editorExperienceStore as EditorExperienceStore).load()');
  const sessionLoad = indexSource.indexOf('this.pendingWorkspaceSession = (this.workspaceSessionStore as WorkspaceSessionStore).load()');
  assert.ok(modeLoad >= 0 && sessionLoad > modeLoad);
  const selectionStart = indexSource.indexOf('private async selectEditorExperience(');
  const selectionEnd = indexSource.indexOf('\n  }', selectionStart);
  const selection = indexSource.slice(selectionStart, selectionEnd);
  assert.ok(selection.indexOf('await this.flushWorkspaceSaves()') < selection.indexOf('save(mode)'));
  assert.match(selection, /this\.experienceMode = mode;/);
  assert.match(indexSource, /偏好保存失败；重启后无法保证保留本次选择/);
  assert.match(indexSource, /this\.ExperienceMenuItem\('simple', '简单模式'/);
  assert.match(indexSource, /this\.ExperienceMenuItem\('professional', '专业模式'/);
  assert.match(indexSource, /onExperienceModeChange: \(mode: EditorExperienceMode\): void => \{ void this\.selectEditorExperience\(mode\); \}/);
  assert.match(settingsSource, /ExperienceModeRow\('simple', '简单模式'/);
  assert.match(settingsSource, /ExperienceModeRow\('professional', '专业模式'/);
  assert.match(settingsSource, /onExperienceModeKey\(mode: EditorExperienceMode/);
  assert.match(indexSource, /@State focusMoreMenuOnAppear: boolean = false/);
  assert.match(indexSource, /\.id\('workspace-more-button'\)/);
  assert.match(indexSource, /getFocusController\(\)\.requestFocus\('workspace-more-button'\)/);
  assert.match(editorSource, /@Prop @Watch\('onExperienceChanged'\) experienceMode: string = 'simple'/);
  assert.match(editorSource, /window\.__mdeditor\.setExperience\('\$\{safeMode\}'\)/);
  assert.match(indexSource, /if \(this\.experienceMode === 'simple'\) \{[\s\S]*this\.LeftWorkspacePane\(false\)/);
});
