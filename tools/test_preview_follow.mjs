import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const policySource = fs.readFileSync(new URL('../entry/src/main/ets/model/PreviewFollowPolicy.ets', import.meta.url), 'utf8');
const preferenceSource = fs.readFileSync(new URL('../entry/src/main/ets/model/EditorPreferenceStore.ets', import.meta.url), 'utf8');
const editorWebSource = fs.readFileSync(new URL('../web/mdeditor/src/index.ts', import.meta.url), 'utf8');
const editorBridgeSource = fs.readFileSync(new URL('../entry/src/main/ets/components/EditorWebView.ets', import.meta.url), 'utf8');
const previewBridgeSource = fs.readFileSync(new URL('../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

function extractFunction(source, signature, nextSignature) {
  const start = source.indexOf(signature);
  const end = source.indexOf(nextSignature, start);
  assert.ok(start >= 0 && end > start, `could not find ${signature}`);
  return source.slice(start, end).trim();
}

const policyCode = transformSync(`${policySource}\nmodule.exports = { resolvePreviewFollowPair };`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const policyModule = { exports: {} };
vm.runInNewContext(policyCode, vm.createContext({ module: policyModule, exports: policyModule.exports }));
const { resolvePreviewFollowPair } = policyModule.exports;

const classStart = preferenceSource.indexOf('export class EditorPreferenceStore {');
assert.ok(classStart >= 0, 'could not find EditorPreferenceStore');
const classSource = preferenceSource.slice(classStart).replace('export class EditorPreferenceStore {', 'class EditorPreferenceStore {');
const preferenceCode = transformSync(`${classSource}\nmodule.exports = EditorPreferenceStore;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createPreferenceStore(raw = undefined) {
  let persisted = raw;
  const calls = [];
  const preferences = {
    getPreferencesSync() {
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
  vm.runInContext(preferenceCode, vm.createContext({ module, exports: module.exports, preferences, console }));
  return { store: new module.exports({}), calls, get persisted() { return persisted; } };
}

function editorScrollAnchorHarness(userIntent = true, suppressed = false) {
  const readAnchor = extractFunction(editorWebSource,
    'function readVisibleSourceAnchor(editor: EditorView):',
    'function scheduleSourceScrollReport(force: boolean = false):');
  const scheduleReport = extractFunction(editorWebSource,
    'function scheduleSourceScrollReport(force: boolean = false): void {',
    'function handleEditorScroll(event: Event): void {');
  const code = transformSync(`
    let sourceScrollReportFrame = 0;
    let sourceScrollReportForced = false;
    let userScrollIntent = ${userIntent};
    let workspaceScrollReportSuppressedUntil = ${suppressed ? 'Date.now() + 10000' : '0'};
    let view = null;
    const frames = [];
    const events = [];
    const documentScroller = { scrollTop: 0, scrollHeight: 0, clientHeight: 50 };
    const document = { scrollingElement: documentScroller, documentElement: documentScroller };
    const window = { requestAnimationFrame(callback) { frames.push(callback); return frames.length; } };
    function editorWorkspaceScrollContainer(editor, root) {
      return editor.scrollHeight > editor.clientHeight ? editor : root;
    }
    function postToArkts(message) { events.push(message); }
    ${readAnchor}
    ${scheduleReport}
    module.exports = { frames, events, documentScroller, setView(value) { view = value; }, scheduleSourceScrollReport };
  `, { loader: 'ts', format: 'cjs' }).code;
  const module = { exports: {} };
  vm.runInNewContext(code, vm.createContext({ module, exports: module.exports, Date, Math, Number }));
  return module.exports;
}

function makeEditor(top = 49, scrollHeight = 100, clientHeight = 50) {
  const heightRequests = [];
  return {
    heightRequests,
    scrollDOM: {
      getBoundingClientRect: () => ({ top: 10 }),
      scrollHeight,
      clientHeight,
      scrollTop: top
    },
    documentTop: -39,
    lineBlockAtHeight(height) {
      heightRequests.push(height);
      return { from: 10, top: 40, bottom: 60 };
    },
    state: { doc: { lineAt: () => ({ number: 3, from: 10, to: 20 }) } }
  };
}

test('follow pairing requires a visible same-note editor/preview pair and chooses the opposite pane', () => {
  const context = {
    topView: 'note', vaultId: 'vault', leftPath: 'folder/note.md', rightPath: 'folder/note.md',
    leftEditing: true, rightEditing: false, bothPanesVisible: true
  };
  const pair = resolvePreviewFollowPair(context);
  assert.equal(pair.sourcePane, 'left');
  assert.equal(pair.previewPane, 'right');
  assert.equal(resolvePreviewFollowPair({ ...context, leftEditing: false, rightEditing: true }).sourcePane, 'right');
  assert.equal(resolvePreviewFollowPair({ ...context, rightPath: 'other.md' }), null);
  assert.equal(resolvePreviewFollowPair({ ...context, bothPanesVisible: false }), null);
  assert.equal(resolvePreviewFollowPair({ ...context, topView: 'settings' }), null);
});

test('application preview-follow preference defaults on and persists across store instances', () => {
  const first = createPreferenceStore();
  assert.equal(first.store.followPreview(), true);
  first.store.saveFollowPreview(false);
  assert.equal(first.persisted, 'false');

  const reopened = createPreferenceStore(first.persisted);
  assert.equal(reopened.store.followPreview(), false);
  reopened.store.saveFollowPreview(true);
  assert.equal(reopened.persisted, 'true');
  assert.deepEqual(reopened.calls.slice(-2), [['put', 'follow_preview', 'true'], ['flush']]);
});

test('editor source-scroll reports are frame-coalesced and contain only numeric position data', () => {
  const harness = editorScrollAnchorHarness();
  const editor = makeEditor();
  harness.setView(editor);
  harness.scheduleSourceScrollReport();
  harness.scheduleSourceScrollReport();
  assert.equal(harness.frames.length, 1);
  harness.frames[0]();
  assert.equal(harness.events.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(harness.events[0])), {
    type: 'event', name: 'sourceScroll', line: 3, lineProgress: 0.5, viewportRatio: 0,
    atStart: false, atEnd: true
  });
  assert.deepEqual(editor.heightRequests, [50]);
  assert.equal('text' in harness.events[0], false);
});

test('requesting the current editor anchor works without a user scroll or stale-restore suppression', () => {
  const harness = editorScrollAnchorHarness(false, true);
  const editor = makeEditor();
  harness.setView(editor);
  harness.scheduleSourceScrollReport(true);
  assert.equal(harness.frames.length, 1);
  harness.frames[0]();
  assert.equal(harness.events.length, 1);
  assert.equal(harness.events[0].name, 'sourceScroll');
  assert.equal(harness.events[0].line, 3);
  assert.deepEqual(editor.heightRequests, [50]);
  assert.equal('text' in harness.events[0], false);
});

test('source boundary flags use the document scroller when CodeMirror has no scroll range', () => {
  const harness = editorScrollAnchorHarness();
  harness.documentScroller.scrollTop = 400;
  harness.documentScroller.scrollHeight = 500;
  harness.documentScroller.clientHeight = 100;
  harness.setView(makeEditor(0, 50, 50));
  harness.scheduleSourceScrollReport();
  harness.frames[0]();
  assert.equal(harness.events.length, 1);
  assert.equal(harness.events[0].atStart, false);
  assert.equal(harness.events[0].atEnd, true);
});

test('visible source anchor uses the page viewport when the workspace document scrolls', () => {
  const harness = editorScrollAnchorHarness();
  harness.documentScroller.scrollTop = 500;
  harness.documentScroller.scrollHeight = 1500;
  harness.documentScroller.clientHeight = 1000;
  const editor = makeEditor(0, 50, 50);
  editor.documentTop = -500;
  editor.scrollDOM.getBoundingClientRect = () => ({ top: -510 });
  editor.lineBlockAtHeight = (height) => {
    editor.heightRequests.push(height);
    return { from: 410, top: 490, bottom: 510 };
  };
  editor.state.doc.lineAt = () => ({ number: 42, from: 410, to: 420 });
  harness.setView(editor);
  harness.scheduleSourceScrollReport();
  harness.frames[0]();
  assert.deepEqual(editor.heightRequests, [501]);
  assert.deepEqual(JSON.parse(JSON.stringify(harness.events[0])), {
    type: 'event', name: 'sourceScroll', line: 42, lineProgress: 0.55, viewportRatio: 0,
    atStart: false, atEnd: true
  });
});

test('native bridges and workspace connect source anchors, manual pause, and persistent preference', () => {
  assert.match(editorBridgeSource, /name === 'sourceScroll'/);
  assert.match(editorBridgeSource, /reportVisibleSourceAnchor\(\)/);
  assert.match(fs.readFileSync(new URL('../web/mdpreview/src/index.ts', import.meta.url), 'utf8'),
    /sourceFollowAnchor = null[\s\S]*window\.cancelAnimationFrame\(sourceFollowFrame\)/);
  assert.match(previewBridgeSource, /scrollToSourceLine\(anchor: PreviewFollowAnchor\)/);
  assert.match(indexSource, /bothPanesVisible: !this\.isSingleScreenLayout\(\) && this\.isReferenceShown\(\)/);
  assert.match(indexSource, /onSourceScrollChange: \(anchor: PreviewFollowAnchor\)/);
  assert.match(indexSource, /saveFollowPreview\(enabled\)/);
  assert.match(indexSource, /editorBridgeForPane\(pair\.sourcePane\)\.reportVisibleSourceAnchor\(\)/);
  assert.match(indexSource, /跟随编辑：' \+ \(this\.followPreviewEnabled/);
});
