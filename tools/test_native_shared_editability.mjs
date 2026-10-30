import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const methodNames = [
  ['refreshSharedEditability', '  private async refreshSharedEditability(): Promise<void> {', '\n  private toggleActivePane()'],
  ['isPaneEditable', '  private isPaneEditable(pane: string): boolean {', '\n  private isImagePickerBusy(']
];
const methods = methodNames.map(([name, startMarker, endMarker]) => {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index.${name}`);
  return source.slice(start, end).trim();
});
const code = transformSync(`class IndexHarness {
  ${methods.join('\n\n  ')}
}; module.exports = IndexHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(overrides = {}) {
  const calls = [];
  const bridge = (name) => ({
    ready: true,
    editable: true,
    focused: true,
    async setEditable(editable) {
      calls.push(`${name}:${editable}`);
      this.editable = editable;
    },
    blur() {
      this.focused = false;
    }
  });
  const context = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  Object.assign(app, {
    currentFilePath: 'shared.md',
    rightFilePath: 'shared.md',
    activePane: 'left',
    smMode: 'edit',
    rightEditing: true,
    leftComposing: false,
    rightComposing: false,
    editorBridge: bridge('left'),
    rightEditorBridge: bridge('right'),
    ...overrides
  });
  return { app, calls };
}

test('same-note mode keeps only the active left pane editable', async () => {
  const { app, calls } = createHarness();

  await app.refreshSharedEditability();

  assert.equal(app.editorBridge.editable, true);
  assert.equal(app.rightEditorBridge.editable, false);
  assert.equal(app.rightEditorBridge.focused, false);
  assert.deepEqual(calls, ['right:false', 'left:true']);
  assert.equal(app.isPaneEditable('left'), true);
  assert.equal(app.isPaneEditable('right'), false);
});

test('same-note mode keeps only the active right pane editable', async () => {
  const { app, calls } = createHarness({ activePane: 'right' });

  await app.refreshSharedEditability();

  assert.equal(app.editorBridge.editable, false);
  assert.equal(app.editorBridge.focused, false);
  assert.equal(app.rightEditorBridge.editable, true);
  assert.deepEqual(calls, ['left:false', 'right:true']);
  assert.equal(app.isPaneEditable('left'), false);
  assert.equal(app.isPaneEditable('right'), true);
});

test('different notes remain independently editable', async () => {
  const { app, calls } = createHarness({ rightFilePath: 'other.md' });

  await app.refreshSharedEditability();

  assert.equal(app.editorBridge.editable, true);
  assert.equal(app.rightEditorBridge.editable, true);
  assert.equal(app.isPaneEditable('left'), true);
  assert.equal(app.isPaneEditable('right'), true);
  assert.deepEqual(calls, ['left:true', 'right:true']);
});

test('same-note preview pane is not made editable', async () => {
  const { app } = createHarness({ activePane: 'right', rightEditing: false });

  await app.refreshSharedEditability();

  assert.equal(app.editorBridge.editable, false);
  assert.equal(app.rightEditorBridge.editable, false);
  assert.equal(app.isPaneEditable('left'), false);
  assert.equal(app.isPaneEditable('right'), false);
});

test('an editor in composition remains the sole editable source until composition ends', async () => {
  const { app } = createHarness({ rightComposing: true });

  await app.refreshSharedEditability();

  assert.equal(app.editorBridge.editable, false);
  assert.equal(app.rightEditorBridge.editable, true);
  assert.equal(app.isPaneEditable('left'), false);
  assert.equal(app.isPaneEditable('right'), true);
});
