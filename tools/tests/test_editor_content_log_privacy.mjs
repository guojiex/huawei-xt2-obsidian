import assert from 'node:assert/strict'
import fs from 'node:fs'
import { test } from 'node:test'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const editor = read('../../web/mdeditor/src/index.ts')
const preview = read('../../web/mdpreview/src/index.ts')
const previewRawfile = read('../../entry/src/main/resources/rawfile/mdpreview/index.html')
const editorBridge = read('../../entry/src/main/ets/components/EditorWebView.ets')
const previewBridge = read('../../entry/src/main/ets/components/PreviewWebView.ets')
const trashView = read('../../entry/src/main/ets/components/TrashView.ets')
const noteService = read('../../entry/src/main/ets/model/NoteService.ets')
const noteDraftService = read('../../entry/src/main/ets/model/NoteDraftService.ets')
const vaultRegistry = read('../../entry/src/main/ets/model/VaultRegistry.ets')
const fileTree = read('../../entry/src/main/ets/components/FileTreeView.ets')
const trashService = read('../../entry/src/main/ets/model/TrashService.ets')
const workspace = read('../../entry/src/main/ets/pages/Index.ets')

test('editor diagnostics never report note content length or a content-bearing bridge payload', () => {
  assert.doesNotMatch(editor, /(?:setContent|requestContent)[^\n]*(?:text|doc)\.length/)
  assert.doesNotMatch(editorBridge, /hilog\.(?:info|warn|error)\([^\n]*(?:json|content|text|path)/i)
  assert.doesNotMatch(editorBridge, /onConsole\([^)]*\)[\s\S]{0,180}getMessage\(/)
  assert.doesNotMatch(previewBridge, /onConsole\([^)]*\)[\s\S]{0,180}getMessage\(/)
})

test('preview diagnostics omit note length and raw resource errors in source and rawfile', () => {
  for (const [name, source] of [['preview source', preview], ['preview rawfile', previewRawfile]]) {
    assert.doesNotMatch(source, /setContent len=/, `${name} must not log note length`)
    assert.doesNotMatch(source, /readAsset threw:/, `${name} must not log raw read errors`)
  }
  assert.match(preview, /console\.warn\('\[mdpreview\] readAsset failed'\)/)
  assert.match(previewRawfile, /readAsset failed/)
})

test('note, file-tree, trash, draft and vault diagnostics omit note names and paths', () => {
  const sensitiveArgument = /hilog\.(?:info|warn|error)\([^\n]*(?:relPath|trashRel|n\.relPath|FileTree\.describe)/
  for (const source of [noteService, fileTree, trashService, workspace, trashView, noteDraftService, vaultRegistry]) {
    assert.doesNotMatch(source, sensitiveArgument)
  }
  assert.doesNotMatch(noteService, /hilog\.(?:info|warn|error)\([^\n]*text\.length/)
  const loggedCalls = [trashView, noteDraftService, vaultRegistry]
    .flatMap((source) => [...source.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)].map(([call]) => call))
  for (const call of loggedCalls) {
    assert.doesNotMatch(call, /err\.message|JSON\.stringify\(err\)|dirs\[i\]/)
  }
})
