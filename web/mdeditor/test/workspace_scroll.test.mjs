import assert from 'node:assert/strict'
import { test } from 'node:test'
import { build } from 'esbuild'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  stdin: {
    contents: "export { clampWorkspaceScrollTop, editorWorkspaceScrollContainer } from '../src/workspaceScroll.ts'",
    resolveDir: here,
    sourcefile: 'workspace_scroll_test_entry.ts',
    loader: 'ts'
  },
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false
})
const workspaceScroll = await import(
  `data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString('base64')}`
)

test('uses the document root when CodeMirror has no internal scroll range', () => {
  const editor = { scrollTop: 0, scrollHeight: 1111, clientHeight: 1111 }
  const document = { scrollTop: 348, scrollHeight: 1111, clientHeight: 540 }
  assert.equal(workspaceScroll.editorWorkspaceScrollContainer(editor, document), document)
})

test('uses the CodeMirror scroller when it owns the scroll range', () => {
  const editor = { scrollTop: 70, scrollHeight: 1300, clientHeight: 500 }
  const document = { scrollTop: 0, scrollHeight: 500, clientHeight: 500 }
  assert.equal(workspaceScroll.editorWorkspaceScrollContainer(editor, document), editor)
})

test('clamps restored positions and treats invalid offsets as zero', () => {
  const container = { scrollTop: 0, scrollHeight: 1200, clientHeight: 300 }
  assert.equal(workspaceScroll.clampWorkspaceScrollTop(container, 720), 720)
  assert.equal(workspaceScroll.clampWorkspaceScrollTop(container, 2000), 900)
  assert.equal(workspaceScroll.clampWorkspaceScrollTop(container, Number.NaN), 0)
  assert.equal(workspaceScroll.clampWorkspaceScrollTop(container, -10), 0)
})
