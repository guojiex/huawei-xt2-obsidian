import assert from 'node:assert/strict'
import { test } from 'node:test'
import fs from 'node:fs'
import vm from 'node:vm'
import { createRequire } from 'node:module'

const require = createRequire(new URL('../package.json', import.meta.url))
const { transformSync } = require('esbuild')
const source = fs.readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')

function extractBlock(startText) {
  const start = source.indexOf(startText)
  assert.ok(start >= 0, `could not find ${startText}`)
  const open = source.indexOf('{', start)
  let depth = 0
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++
    if (source[i] === '}') {
      depth--
      if (depth === 0) return source.slice(start, i + 1)
    }
  }
  assert.fail(`could not find end of ${startText}`)
}

const resetDocument = extractBlock('function resetPreviewDocument(): void {')
const cancelSourceFollow = extractBlock('function cancelSourceFollow(): void {')
const restoreMethod = extractBlock('  async restoreScrollTop(top: number): Promise<void> {')
  .replace(/^  async restoreScrollTop/, '  async restoreScrollTop')
const code = transformSync(`
  let workspaceScrollTimer;
  let workspaceScrollRestorePending = false;
  let workspaceScrollReportSuppressedUntil = 0;
  let workspaceScrollRestoreGeneration = 0;
  let sourceFollowAnchor = { line: 8 };
  let sourceFollowFrame = 1;
  let workspaceUserScrollIntent = true;
  let workspaceUserScrollIntentReported = true;
  let workspaceUserScrollIntentTimer = 7;
  let mermaidRender = Promise.resolve();
  const timers = [];
  const imageWaiters = [];
  const content = { scrollTop: 0, scrollHeight: 1200, clientHeight: 240 };
  const window = { clearTimeout() {}, cancelAnimationFrame() {}, setTimeout(callback) { timers.push(callback); } };
  const document = { getElementById() { return content; } };
  function closeImageViewer() {}
  async function waitForLocalImages() {
    return new Promise(resolve => imageWaiters.push(resolve));
  }
  function nextRenderedFrame() { return Promise.resolve(); }
  ${cancelSourceFollow}
  ${resetDocument}
  const api = { ${restoreMethod} };
  module.exports = { api, content, imageWaiters, resetPreviewDocument,
    getFollowState: () => ({ sourceFollowAnchor, sourceFollowFrame, workspaceUserScrollIntent,
      workspaceUserScrollIntentReported, workspaceUserScrollIntentTimer }) };
`, { loader: 'ts', format: 'cjs' }).code

function fixture() {
  const module = { exports: {} }
  vm.runInNewContext(code, vm.createContext({ module, exports: module.exports, Date, Number, Promise }))
  return module.exports
}

async function letImagesWaitStart() {
  await Promise.resolve()
  await Promise.resolve()
}

test('a pending restore cannot move the preview after a document reset and newer restore', async () => {
  const { api, content, imageWaiters, resetPreviewDocument, getFollowState } = fixture()
  const staleRestore = api.restoreScrollTop(720)
  await letImagesWaitStart()
  assert.equal(imageWaiters.length, 1)

  resetPreviewDocument()
  const followState = getFollowState()
  assert.equal(followState.sourceFollowAnchor, null)
  assert.equal(followState.sourceFollowFrame, 0)
  assert.equal(followState.workspaceUserScrollIntent, false)
  assert.equal(followState.workspaceUserScrollIntentReported, false)
  assert.equal(followState.workspaceUserScrollIntentTimer, undefined)
  const currentRestore = api.restoreScrollTop(180)
  await letImagesWaitStart()
  assert.equal(imageWaiters.length, 2)

  imageWaiters[1]()
  await currentRestore
  assert.equal(content.scrollTop, 180)

  imageWaiters[0]()
  await staleRestore
  assert.equal(content.scrollTop, 180)
})
