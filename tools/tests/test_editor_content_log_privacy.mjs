import assert from 'node:assert/strict'
import fs from 'node:fs'
import { test } from 'node:test'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const editor = read('../../web/mdeditor/src/index.ts')
const editorBridge = read('../../entry/src/main/ets/components/EditorWebView.ets')
const previewBridge = read('../../entry/src/main/ets/components/PreviewWebView.ets')
const noteService = read('../../entry/src/main/ets/model/NoteService.ets')
const fileTree = read('../../entry/src/main/ets/components/FileTreeView.ets')
const trashService = read('../../entry/src/main/ets/model/TrashService.ets')
const workspace = read('../../entry/src/main/ets/pages/Index.ets')

test('editor diagnostics never report note content length or a content-bearing bridge payload', () => {
  assert.doesNotMatch(editor, /(?:setContent|requestContent)[^\n]*(?:text|doc)\.length/)
  assert.doesNotMatch(editorBridge, /hilog\.(?:info|warn|error)\([^\n]*(?:json|content|text|path)/i)
  assert.doesNotMatch(editorBridge, /onConsole\([^)]*\)[\s\S]{0,180}getMessage\(/)
  assert.doesNotMatch(previewBridge, /onConsole\([^)]*\)[\s\S]{0,180}getMessage\(/)
})

test('note, file-tree and trash diagnostics omit note names and paths', () => {
  const sensitiveArgument = /hilog\.(?:info|warn|error)\([^\n]*(?:relPath|trashRel|n\.relPath|FileTree\.describe)/
  for (const source of [noteService, fileTree, trashService, workspace]) {
    assert.doesNotMatch(source, sensitiveArgument)
  }
  assert.doesNotMatch(noteService, /hilog\.(?:info|warn|error)\([^\n]*text\.length/)
})
