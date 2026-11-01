import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const editorSource = readSourceFile(new URL('../../entry/src/main/ets/components/EditorWebView.ets', import.meta.url));

function sourceMethod(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find method ${startMarker}`);
  return source.slice(start, end).trim();
}

const surfaceWaitMethod = sourceMethod(indexSource,
  '  private async waitForInitialWorkspaceSurfaces(): Promise<void> {',
  '\n  private handleInitialWorkspaceSurfaceError');
const surfaceWaitCode = transformSync(`
class StartupSurfaceHarness {
  ${surfaceWaitMethod}
  notePaneVisible(pane) { return this.visiblePanes.indexOf(pane) >= 0; }
}
module.exports = StartupSurfaceHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const surfaceWaitModule = { exports: {} };
vm.runInContext(surfaceWaitCode, vm.createContext({ module: surfaceWaitModule, exports: surfaceWaitModule.exports }));
const StartupSurfaceHarness = surfaceWaitModule.exports;
const surfaceErrorMethod = sourceMethod(indexSource,
  '  private handleInitialWorkspaceSurfaceError(pane: string, surface: string): void {',
  '\n  private restoreWorkspaceScrollPositions');
const surfaceErrorCode = transformSync(`
class StartupSurfaceErrorHarness {
  ${surfaceErrorMethod}
  notePaneVisible(pane) { return this.visiblePanes.indexOf(pane) >= 0; }
  initializeWorkspaceSession() { this.restoreCalls += 1; }
}
module.exports = StartupSurfaceErrorHarness;
`, { loader: 'ts', format: 'cjs' }).code;
const surfaceErrorModule = { exports: {} };
vm.runInContext(surfaceErrorCode, vm.createContext({
  module: surfaceErrorModule,
  exports: surfaceErrorModule.exports
}));
const StartupSurfaceErrorHarness = surfaceErrorModule.exports;

const editorImplStart = editorSource.indexOf('class EditorImpl {');
const editorImplEnd = editorSource.indexOf('\n/** 父组件持有的句柄', editorImplStart);
const editorBridgeStart = editorSource.indexOf('export class EditorBridge {');
const editorBridgeEnd = editorSource.indexOf('\n/**\n * 可见的编辑器 Web 组件', editorBridgeStart);
assert.ok(editorImplStart >= 0 && editorImplEnd > editorImplStart, 'could not find EditorImpl');
assert.ok(editorBridgeStart >= 0 && editorBridgeEnd > editorBridgeStart, 'could not find EditorBridge');
const editorBridgeCode = transformSync(`
${editorSource.slice(editorImplStart, editorImplEnd)}
${editorSource.slice(editorBridgeStart, editorBridgeEnd).replace(/^export /gm, '')}
module.exports = { EditorImpl, EditorBridge };
`, { loader: 'ts', format: 'cjs' }).code;
const editorBridgeModule = { exports: {} };
vm.runInContext(editorBridgeCode, vm.createContext({
  module: editorBridgeModule,
  exports: editorBridgeModule.exports,
  BridgeCodec: { encode: (text) => Buffer.from(text, 'utf8').toString('base64') }
}));
const { EditorImpl, EditorBridge } = editorBridgeModule.exports;

test('cold-start waits only for visible pane Web surfaces', async () => {
  const calls = [];
  const app = new StartupSurfaceHarness();
  Object.assign(app, {
    visiblePanes: ['left', 'right'],
    smMode: 'edit',
    rightEditing: false,
    editorBridge: { waitUntilReady: async () => calls.push('left-editor') },
    previewBridge: { waitUntilReady: async () => calls.push('left-preview') },
    rightEditorBridge: { waitUntilReady: async () => calls.push('right-editor') },
    rightPreviewBridge: { waitUntilReady: async () => calls.push('right-preview') }
  });

  await app.waitForInitialWorkspaceSurfaces();
  assert.deepEqual(calls, ['left-editor', 'right-preview']);

  calls.length = 0;
  app.visiblePanes = ['right'];
  app.rightEditing = true;
  await app.waitForInitialWorkspaceSurfaces();
  assert.deepEqual(calls, ['right-editor']);
});

test('a hidden Web error cannot reveal the startup cover or bypass visible-pane restoration', () => {
  const app = new StartupSurfaceErrorHarness();
  Object.assign(app, {
    visiblePanes: ['left'],
    workspaceInitialRenderReady: false,
    workspaceSessionRestoreStarted: false,
    smMode: 'edit',
    rightEditing: false,
    restoreCalls: 0
  });

  app.handleInitialWorkspaceSurfaceError('right', 'preview');
  assert.equal(app.restoreCalls, 0);
  assert.equal(app.workspaceInitialRenderReady, false);

  app.handleInitialWorkspaceSurfaceError('left', 'edit');
  assert.equal(app.restoreCalls, 1);
  assert.equal(app.workspaceInitialRenderReady, false);
});

test('the workspace is covered until restoration completes, without a second loading view', () => {
  const buildStart = indexSource.indexOf('  build() {');
  const buildEnd = indexSource.indexOf('\n  /**', buildStart);
  assert.ok(buildStart >= 0 && buildEnd > buildStart, 'could not find Index.build');
  const buildSource = indexSource.slice(buildStart, buildEnd);
  assert.match(buildSource, /if \(!this\.workspaceInitialRenderReady\)\s*\{\s*Column\(\)\s*\{\}\s*[\s\S]*?backgroundColor\(\$r\('app\.color\.bg_page'\)\)/);
  assert.doesNotMatch(buildSource, /正在恢复工作区|正在加载笔记/);
});

test('session and note restoration starts before Web page-ready callbacks', () => {
  const appearStart = indexSource.indexOf('  aboutToAppear(): void {');
  const appearEnd = indexSource.indexOf('\n  private async loadAgentKitSlot', appearStart);
  assert.ok(appearStart >= 0 && appearEnd > appearStart, 'could not find Index.aboutToAppear');
  const appearSource = indexSource.slice(appearStart, appearEnd);
  const sessionLoadIndex = appearSource.indexOf('this.pendingWorkspaceSession =');
  const restoreStartIndex = appearSource.indexOf('void this.initializeWorkspaceSession();');
  const externalPollingIndex = appearSource.indexOf('this.startExternalVaultPolling();');
  assert.ok(sessionLoadIndex >= 0 && restoreStartIndex > sessionLoadIndex);
  assert.ok(externalPollingIndex > restoreStartIndex);
  assert.match(indexSource, /private async initializeWorkspaceSession\(\): Promise<void>/);
});

test('EditorBridge retains the startup note in memory until the first Web page is ready', async () => {
  const scripts = [];
  let releaseScript;
  let holdNextContent = false;
  const controller = {
    runJavaScript(script) {
      scripts.push(script);
      if (holdNextContent && script.includes('bmV4dA==')) {
        return new Promise((resolve) => { releaseScript = resolve; });
      }
      return Promise.resolve('');
    }
  };
  const bridge = new EditorBridge();
  await bridge.setContent('last session text');
  assert.equal(scripts.length, 0);
  assert.equal(await bridge.getContent(), 'last session text');

  const implementation = new EditorImpl(controller);
  bridge.bind(implementation);
  let becameReady = false;
  const readyWait = bridge.waitUntilReady().then(() => { becameReady = true; });
  await implementation.markReady();
  bridge.notifyReady();
  await readyWait;
  assert.equal(becameReady, true);
  assert.ok(scripts.some((script) => script.includes("setContent('bGFzdCBzZXNzaW9uIHRleHQ=',1,'','')")));

  holdNextContent = true;
  let contentApplied = false;
  const nextContent = bridge.setContent('next').then(() => { contentApplied = true; });
  await Promise.resolve();
  assert.equal(contentApplied, false);
  releaseScript();
  await nextContent;
  assert.equal(contentApplied, true);
});

test('document transitions reject stale edits and restore the last loaded revision on rollback', async () => {
  const scripts = [];
  const controller = { runJavaScript: (script) => { scripts.push(script); return Promise.resolve(''); } };
  const bridge = new EditorBridge();
  const implementation = new EditorImpl(controller);
  bridge.bind(implementation);
  await implementation.markReady();
  await bridge.setContent('previous');

  assert.equal(implementation.isCurrentDocumentRevision(1), true);
  const transitionRevision = bridge.beginDocumentTransition();
  assert.equal(implementation.isCurrentDocumentRevision(1), false);
  assert.equal(implementation.isCurrentDocumentRevision(transitionRevision), true);

  bridge.restoreDocumentTransition(transitionRevision);
  assert.equal(implementation.isCurrentDocumentRevision(1), true);

  const secondTransition = bridge.beginDocumentTransition();
  await bridge.setContent('next');
  bridge.restoreDocumentTransition(secondTransition);
  assert.equal(implementation.isCurrentDocumentRevision(1), false);
  assert.equal(implementation.isCurrentDocumentRevision(3), true);
  assert.ok(scripts.some((script) => script.includes("setContent('bmV4dA==',3,'','')")));
});

test('native change messages are accepted only for the current editor document revision', () => {
  const changeBranchStart = editorSource.indexOf("} else if (name === 'change') {");
  const changeBranchEnd = editorSource.indexOf("} else if (name === 'composition') {", changeBranchStart);
  assert.ok(changeBranchStart >= 0 && changeBranchEnd > changeBranchStart);
  const branch = editorSource.slice(changeBranchStart, changeBranchEnd);
  assert.match(branch, /isCurrentDocumentRevision\(msg\['revision'\] as number\)/);
  assert.match(branch, /this\.onChange\(\(msg\['len'\] as number\) \?\? 0\)/);
});
