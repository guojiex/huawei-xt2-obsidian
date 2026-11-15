import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const serviceSource = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteTextShareService.ets', import.meta.url), 'utf8');
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
// 2026-11-15 冷启动优化：systemShare 从 ShareFlowPanel 拆到 model/SystemShareDevice，
// 面板改为动态 import —— 此处加载真实设备模块（独立 VM），harness 的 require 把
// '../model/SystemShareDevice' 映射过去，共用同一个 @kit.ShareKit mock 与 calls。
const deviceSource = fs.readFileSync(new URL('../../entry/src/main/ets/model/SystemShareDevice.ets', import.meta.url), 'utf8');
const deviceCode = transformSync(deviceSource, {
  loader: 'ts',
  format: 'cjs'
}).code;
const source = fs.readFileSync(new URL('../../entry/src/main/ets/components/ShareFlowPanel.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private async shareTextContent(title: string, content: string): Promise<void> {');
const end = source.indexOf('\n  private waitForShareCaptureReady()', start);
assert.ok(start >= 0 && end > start, 'could not find ShareFlowPanel.shareTextContent');
const method = source.slice(start, end).trim();
// esbuild transform 模式不会把 import() 降级成 require（VM 里也没有动态 import
// 回调），此处手动模拟打包产物形态：await import('…') → require('…')，语义等价。
const harnessMethod = method.replace("await import('../model/SystemShareDevice')",
  "require('../model/SystemShareDevice')");
assert.notEqual(harnessMethod, method, 'expected ShareFlowPanel.shareTextContent to dynamic-import SystemShareDevice');
const code = transformSync(`class ShareHarness { ${harnessMethod} }; module.exports = ShareHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;

function createHarness(showFails = false) {
  const calls = [];
  const shareKitRuntime = {
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
  };
  const deviceModule = { exports: {} };
  const deviceContext = vm.createContext({
    module: deviceModule,
    exports: deviceModule.exports,
    require: (name) => name === '@kit.ShareKit' ? shareKitRuntime :
      name === '@kit.ArkData' ? arkDataRuntime : {}
  });
  vm.runInContext(deviceCode, deviceContext);
  const context = vm.createContext({
    module: { exports: {} },
    NoteTextShareService,
    VaultRegistry: { get: () => ({ abilityContext: () => 'ability-context' }) },
    require: (name) => {
      assert.equal(name, '../model/SystemShareDevice');
      return deviceModule.exports;
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

test('Share Kit rejection propagates to the text detail without changing the source note', async () => {
  const { app, calls } = createHarness(true);

  await assert.rejects(app.shareTextContent('Note title', 'Note title\n\nEdited body'),
    /target rejected the text/);

  assert.equal(calls.length, 2);
  assert.equal(calls[1][0], 'show');
});

test('oversize edited text propagates a clear size reason before Share Kit handoff', async () => {
  const { app, calls } = createHarness();

  await assert.rejects(app.shareTextContent('Note title', 'x'.repeat(200 * 1024)),
    /200 KB.*Markdown \/ ZIP/);

  assert.equal(calls.length, 0);
});
