import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const serviceSource = fs.readFileSync(new URL('../entry/src/main/ets/model/NoteTextShareService.ets', import.meta.url), 'utf8');
const serviceCode = transformSync(serviceSource + '\nmodule.exports = NoteTextShareService;', {
  loader: 'ts',
  format: 'cjs'
}).code;
const arktsRuntime = {
  util: {
    TextEncoder: class {
      encodeInto(text) {
        const bytes = new TextEncoder().encode(text);
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      }
    }
  }
};
const arkDataRuntime = { uniformTypeDescriptor: { UniformDataType: { TEXT: 'text/plain' } } };
const serviceContext = vm.createContext({
  module: { exports: {} },
  require: (name) => name === '@kit.ArkTS' ? arktsRuntime :
    name === '@kit.ArkData' ? arkDataRuntime : require(name)
});
vm.runInContext(serviceCode, serviceContext);
const NoteTextShareService = serviceContext.module.exports;
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async shareTextContent(title: string, content: string): Promise<void> {');
const end = source.indexOf('\n  private waitForShareCaptureReady()', start);
assert.ok(start >= 0 && end > start, 'could not find Index.shareTextContent');
const method = source.slice(start, end).trim();
const code = transformSync(`class ShareHarness { ${method} }; module.exports = ShareHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(showFails = false) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    $r: (resource) => resource,
    NoteTextShareService,
    uniformTypeDescriptor: { UniformDataType: { TEXT: 'text/plain' } },
    VaultRegistry: { get: () => ({ abilityContext: () => 'ability-context' }) },
    systemShare: {
      SharedData: class {
        constructor(record) { this.record = record; calls.push(['data', record]); }
      },
      ShareController: class {
        constructor(data) { this.data = data; }
        async show(abilityContext, options) {
          calls.push(['show', this.data.record, abilityContext, options]);
          if (showFails) throw new Error('target rejected the text');
        }
      }
    }
  });
  vm.runInContext(code, context);
  const app = new context.module.exports();
  app.getUIContext = () => ({
    getPromptAction: () => ({
      showDialog: (options) => { calls.push(['error', options]); }
    })
  });
  return { app, calls };
}

test('native handoff sends an editable text record with Share Kit TEXT type and no file URI', async () => {
  const { app, calls } = createHarness();

  await app.shareTextContent('Note title', 'Note title\n\nEdited body');

  assert.equal(calls.length, 2);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[0])), [
    'data', { utd: 'text/plain', content: 'Note title\n\nEdited body', title: 'Note title', label: 'TEXT' }
  ]);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[1])), [
    'show', { utd: 'text/plain', content: 'Note title\n\nEdited body', title: 'Note title', label: 'TEXT' },
    'ability-context', {}
  ]);
});

test('Share Kit rejection is surfaced to the user without changing the source note', async () => {
  const { app, calls } = createHarness(true);

  await app.shareTextContent('Note title', 'Note title\n\nEdited body');

  assert.equal(calls[2][0], 'error');
  assert.equal(calls[2][1].title, '分享失败');
  assert.match(calls[2][1].message, /target rejected the text/);
  assert.equal(calls[2][1].buttons[0].text, '知道了');
});

test('oversize edited text is rejected before Share Kit handoff with a clear size reason', async () => {
  const { app, calls } = createHarness();

  await app.shareTextContent('Note title', 'x'.repeat(200 * 1024));

  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'error');
  assert.equal(calls[0][1].title, '分享失败');
  assert.match(calls[0][1].message, /200 KB/);
  assert.match(calls[0][1].message, /Markdown \/ ZIP/);
});
