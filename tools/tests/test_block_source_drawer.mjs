import assert from 'node:assert/strict'
import { test } from 'node:test'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const indexSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8')
const editorSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/EditorWebView.ets'), 'utf8')
const tokenSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/common/Tokens.ets'), 'utf8')
const panelStart = indexSource.indexOf('  @Builder\n  BlockPropertyPanel() {')
const panelEnd = indexSource.indexOf('\n  @Builder\n  PreviewBlockPanel(', panelStart)
const panel = indexSource.slice(panelStart, panelEnd)

test('18.7 从块属性面板打开仅含目标源码的编辑器，并提供取消与保存', () => {
  assert.match(panel, /this\.openBlockSourceDrawer\(\)/)
  assert.match(panel, /TextArea\(\{ text: this\.blockSourceDraft \}\)/)
  assert.match(panel, /Button\('取消'\)/)
  assert.match(panel, /Button\('保存'\)/)
  assert.doesNotMatch(panel, /getContent\(/)
})

test('18.7 打开前同步预览，并绑定库、笔记、请求代次、目标区间和文档修订号', () => {
  const start = indexSource.indexOf('  private async openBlockSourceDrawer(): Promise<void> {')
  const end = indexSource.indexOf('\n  private cancelBlockSourceDrawer()', start)
  const open = indexSource.slice(start, end)
  assert.match(open, /flushSimplePreviewChanges\(\)/)
  assert.match(open, /bridge\.getContent\(\)/)
  assert.match(open, /anchor\.inlineIndex >= 0 \? anchor\.itemFrom : anchor\.from/)
  assert.match(open, /anchor\.inlineIndex >= 0 \? anchor\.itemTo : anchor\.to/)
  assert.match(open, /source\.slice\(sourceFrom, sourceTo\)/)
  assert.match(open, /sourceFrom < anchor\.from \|\| sourceTo > anchor\.to/)
  assert.match(open, /blockSourceDocumentRevision = documentRevision/)
  assert.match(indexSource, /currentVaultId === vaultId/)
  assert.match(indexSource, /currentDocumentRevision === documentRevision/)
})

test('18.7 回写复用编辑器事务，脏状态在异步回写前设置，冲突明确提示重开', () => {
  const start = indexSource.indexOf('  private async saveBlockSourceDrawer(): Promise<void> {')
  const end = indexSource.indexOf('\n  private blockPanelActionLabel()', start)
  const save = indexSource.slice(start, end)
  assert.ok(save.indexOf('this.editorDirty = true') < save.indexOf('await bridge.replaceBlockSource'))
  assert.match(save, /this\.rightEditorDirty = true/)
  assert.match(save, /scheduleRightSave\(\)/)
  assert.match(save, /scheduleSave\(\)/)
  assert.match(save, /块内容已变化；本次修改未应用。请重新打开块源码后再编辑/)
  assert.match(editorSource, /async replaceBlockSource\(/)
  assert.match(editorSource, /handleBlockSourceEditResult/)
})

test('18.7 Ctrl/Cmd+Enter 保存源码，Escape 取消源码编辑', () => {
  const start = indexSource.indexOf('  private onBlockSourceEditorKey(event: KeyEvent): boolean {')
  const end = indexSource.indexOf('\n  private async saveBlockSourceDrawer()', start)
  const keyHandler = indexSource.slice(start, end)
  assert.match(keyHandler, /KEYCODE_ENTER/)
  assert.match(keyHandler, /getModifierKeyState\(\['Ctrl'\]\)/)
  assert.match(keyHandler, /event\.metaKey === 1/)
  assert.match(keyHandler, /KEYCODE_ESCAPE/)
})

test('18.7 宽屏源码抽屉使用 480vp token 并仍受栏内布局约束', () => {
  assert.match(tokenSource, /blockSourceW: number = 480/)
  assert.match(indexSource, /this\.blockSourceEditing \? Size\.blockSourceW : Size\.blockPanelW/)
  assert.match(indexSource, /this\.updateBlockPropertyPanelLayout\(pane\)/)
})
