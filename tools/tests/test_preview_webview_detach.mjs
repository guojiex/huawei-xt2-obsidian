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
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const panelSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/BlockPropertyPanel.ets', import.meta.url));
const implStart = source.indexOf('class PreviewImpl {');
const componentStart = source.indexOf('/**\n * 可见的预览 Web 组件', implStart);
assert.ok(implStart >= 0 && componentStart > implStart, 'could not find PreviewImpl and PreviewBridge');
const formulaStart = source.indexOf('  private onFormulaChanged(): void {');
const formulaEnd = source.indexOf('\n  build() {', formulaStart);
assert.ok(formulaStart >= 0 && formulaEnd > formulaStart, 'could not find FormulaPreviewWeb methods');

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
const formulaCode = transformSync(`
class FormulaPreviewHarness {
  ${source.slice(formulaStart, formulaEnd).trim()}
}
module.exports = FormulaPreviewHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const formulaModule = { exports: {} };
vm.runInContext(formulaCode, vm.createContext({
  module: formulaModule,
  exports: formulaModule.exports,
  BridgeCodec: { encode: () => 'encoded' }
}));

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

test('post-ready script failures are reported once without exposing exception text, then reset after success', async () => {
  const secret = '/private/vault/note.md token=private-token';
  const failures = [];
  let failuresEnabled = true;
  const impl = new PreviewImpl({
    runJavaScript() {
      if (failuresEnabled) {
        return Promise.reject(new Error(secret));
      }
      return Promise.resolve('');
    }
  }, () => failures.push('preview bridge failure'));

  await impl.markReady();
  impl.setTheme('dark');
  impl.setTheme('light');
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(failures, ['preview bridge failure']);

  failuresEnabled = false;
  impl.setTheme('dark');
  await new Promise(resolve => setTimeout(resolve, 0));
  failuresEnabled = true;
  impl.setTheme('light');
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(failures, ['preview bridge failure', 'preview bridge failure']);
  assert.ok(!failures.join('\n').includes(secret));
});

test('formula preview bridge failures are reported once and recover after a successful update', async () => {
  const failures = [];
  let rejectScripts = true;
  const preview = new formulaModule.exports();
  Object.assign(preview, {
    pageReady: true,
    expression: 'private formula source',
    appTheme: 'light',
    onError() { failures.push('formula preview failure'); },
    controller: {
      runJavaScript() {
        return rejectScripts
          ? Promise.reject(new Error('/private/vault/note.md token=private-token'))
          : Promise.resolve('');
      }
    }
  });

  preview.onFormulaChanged();
  preview.onFormulaChanged();
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(failures, ['formula preview failure']);

  rejectScripts = false;
  preview.onFormulaChanged();
  await new Promise(resolve => setTimeout(resolve, 0));
  rejectScripts = true;
  preview.onFormulaChanged();
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(failures, ['formula preview failure', 'formula preview failure']);
  assert.match(panelSource, /FormulaPreviewWeb\(\{[\s\S]*?recordBackgroundFailure\('editor_preview', 'bridge', 'unknown', 'status_unknown', 'retry'\)/);
});
