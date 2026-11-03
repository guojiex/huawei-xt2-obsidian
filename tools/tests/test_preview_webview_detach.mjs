import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = readSourceFile(new URL(
  '../../entry/src/main/ets/components/PreviewWebView.ets',
  import.meta.url
));
const implStart = source.indexOf('class PreviewImpl {');
const componentStart = source.indexOf('/**\n * 可见的预览 Web 组件', implStart);
assert.ok(implStart >= 0 && componentStart > implStart, 'could not find PreviewImpl and PreviewBridge');

const coreCode = transformSync(`
function normalizePreviewZoomPercent(percent) {
  if (!Number.isFinite(percent)) return 100;
  return Math.max(50, Math.min(200, Math.round(percent)));
}
${source.slice(implStart, componentStart).replace(/^export /gm, '')}
module.exports = { PreviewImpl, PreviewBridge };
`, { loader: 'ts', format: 'cjs' }).code;
const coreModule = { exports: {} };
vm.runInContext(coreCode, vm.createContext({
  module: coreModule,
  exports: coreModule.exports,
  BridgeCodec: { encode: (text) => text, decode: (text) => text },
  hilog: { warn() {} }
}));
const { PreviewImpl, PreviewBridge } = coreModule.exports;

test('detached preview bridge queues state until a newly attached WebView is ready', async () => {
  const firstScripts = [];
  const firstController = {
    runJavaScript(script) {
      firstScripts.push(script);
      return Promise.resolve('');
    }
  };
  const bridge = new PreviewBridge();
  const firstImpl = new PreviewImpl(firstController);
  bridge.bind(firstImpl);
  await firstImpl.markReady();
  assert.equal(bridge.ready, true);

  bridge.unbind(firstImpl);
  bridge.setEditable(true);
  assert.equal(bridge.ready, false);
  assert.equal(firstScripts.some((script) => script.includes('setEditable(true)')), false);

  const nextScripts = [];
  const nextImpl = new PreviewImpl({
    runJavaScript(script) {
      nextScripts.push(script);
      return Promise.resolve('');
    }
  });
  bridge.bind(nextImpl);
  await nextImpl.markReady();
  assert.equal(bridge.ready, true);
  assert.ok(nextScripts.some((script) => script.includes('setEditable(true)')));
});

test('PreviewWebView unbinds its controller before it can be reused after disappearance', () => {
  assert.match(source, /aboutToDisappear\(\): void \{[\s\S]*?this\.bridge\.unbind\(this\.boundImpl\)/);
  assert.match(source, /\.onPageEnd\(\(\) => \{\s*if \(!this\.componentActive\)/);
});
