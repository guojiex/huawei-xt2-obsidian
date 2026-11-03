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
const entryAbility = read('../../entry/src/main/ets/entryability/EntryAbility.ets')
const externalDirProbe = read('../../entry/src/main/ets/pages/ExternalDirProbePage.ets')
const gitCredentialStore = read('../../entry/src/main/ets/git/GitCredentialStore.ets')
const recentOpenStore = read('../../entry/src/main/ets/model/RecentOpenStore.ets')
const expandStore = read('../../entry/src/main/ets/model/FileTree.ets')
const editorPreferenceStore = read('../../entry/src/main/ets/model/EditorPreferenceStore.ets')
const editorExperienceStore = read('../../entry/src/main/ets/model/EditorExperienceStore.ets')
const splitLayoutStore = read('../../entry/src/main/ets/model/SplitLayoutStore.ets')
const workspaceSessionStore = read('../../entry/src/main/ets/model/WorkspaceSessionStore.ets')
const agentOperationStorage = read('../../entry/src/main/ets/model/AgentOperationStorage.ets')
const agentStorageLogCalls = [...agentOperationStorage.matchAll(/hilog\.(?:info|warn|error)\([\s\S]*?;/g)]
  .map(([call]) => call)

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

test('workspace and preference diagnostics never log raw errors or library identifiers', () => {
  for (const source of [
    entryAbility,
    recentOpenStore,
    expandStore,
    editorPreferenceStore,
    editorExperienceStore,
    splitLayoutStore,
    workspaceSessionStore
  ]) {
    assert.doesNotMatch(source, /JSON\.stringify\((?:err|error)\)|err\.message/)
  }
  assert.doesNotMatch(gitCredentialStore, /hilog\.(?:info|warn|error)\([\s\S]{0,140}vaultId/)
})

test('bridge, directory-probe and file-tree diagnostics omit payloads, paths and counts', () => {
  assert.doesNotMatch(editorBridge, /hilog\.(?:info|warn|error)\([^\n]*(?:err\.message|JSON\.stringify\(err\))/)
  assert.doesNotMatch(previewBridge, /hilog\.(?:info|warn|error)\([^\n]*(?:err\.message|JSON\.stringify\(err\))/)
  assert.doesNotMatch(editor, /console\.log\([^\n]*String\(error\)/)
  assert.doesNotMatch(fileTree, /hilog\.info\([^\n]*this\.nodes\.length/)

  const logStep = externalDirProbe.match(/private logStep\(step: ProbeStep\): void \{([\s\S]*?)\n  \}/)?.[1] ?? ''
  assert.doesNotMatch(logStep, /detail|step\.detail/)
})

test('agent storage diagnostics do not expose raw state or serialized-content details', () => {
  for (const call of agentStorageLogCalls) {
    assert.doesNotMatch(call, /rawState\.|state\.|serializedChars|persistedChars|rawLength|firstCode|lastCode|charCodeAt/)
  }
  assert.match(agentOperationStorage, /hash \^= text\.charCodeAt\(i\)/)
})
