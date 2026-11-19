// v1.89 无库只读打开单个 Markdown 文件：
// 89.1 系统 .md 打开方式注册 / 89.2 冷热启动 want 解析 / 89.3 临时授权 URI 读取 / 89.4 只读页。
// 纯逻辑单测（esbuild + vm，同 test_share_ingest 惯例）+ module.json5 / 源级断言。
import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import { readSourceFile } from './lib/source.mjs'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')

// ---- 纯逻辑单测：MarkdownOpenService（无 SDK / UI 依赖） ----
const serviceSource = readSourceFile(new URL('entry/src/main/ets/model/MarkdownOpenService.ets', root))
const code = transformSync(`${serviceSource}\nmodule.exports = MarkdownOpenService;`, {
  loader: 'ts',
  format: 'cjs'
}).code
const context = vm.createContext({ module: { exports: {} } })
vm.runInContext(code, context)
const svc = context.module.exports

test('89.2 只认 viewData action，其余 want 一律拒绝', () => {
  assert.equal(svc.isViewDataAction('ohos.want.action.viewData'), true)
  assert.equal(svc.isViewDataAction('ohos.want.action.sendData'), false)
  assert.equal(svc.isViewDataAction(undefined), false)
  assert.equal(svc.isViewDataAction(''), false)
})

test('89.2 文件名从 URI 末段解析并 URL decode', () => {
  assert.equal(svc.fileNameFromUri('file://com.ohos.userdocs/data/storage/el2/base/files/hello%20world.md'), 'hello world.md')
  assert.equal(svc.fileNameFromUri('content://media/external/file/阅读笔记.md?foo=1'), '阅读笔记.md')
  assert.equal(svc.fileNameFromUri('file:///a/b/#frag'), '未命名.md') // 末尾斜杠无文件名 -> 兜底
  assert.equal(svc.fileNameFromUri(''), '未命名.md')
  assert.equal(svc.fileNameFromUri('file:///a/b/%ZZ'), '%ZZ') // decode 失败兜底
})

test('89.3 大小上限判定：2MB 以内放行、超限截断', () => {
  assert.equal(svc.isOverLimit(svc.MAX_FILE_BYTES), false)
  assert.equal(svc.isOverLimit(svc.MAX_FILE_BYTES + 1), true)
  assert.equal(svc.isOverLimit(null), false) // 未知大小由设备层兜底
  assert.ok(svc.MAX_PREVIEW_BYTES < svc.MAX_FILE_BYTES)
})

test('89.3 UTF-8 截断不切断多字节字符', () => {
  const bytes = new TextEncoder().encode('甲'.repeat(100)) // 每字 3 字节
  const cut = svc.truncateUtf8Bytes(bytes, 10) // 10 不是 3 的倍数
  assert.equal(cut.byteLength % 3, 0)
  const text = new TextDecoder().decode(cut)
  assert.equal(text, '甲'.repeat(Math.floor(10 / 3)))
})

test('89.3 载荷序列化 / 反序列化 round-trip 与 error 兜底', () => {
  const payload = svc.contentPayload('a.md', '# 正文', false, 123)
  const parsed = svc.deserialize(svc.serialize(payload))
  assert.deepEqual(parsed, payload)
  assert.equal(svc.deserialize(''), null)
  assert.equal(svc.deserialize('not json'), null)
  assert.equal(svc.deserialize(JSON.stringify({ state: 'bogus', receivedAt: 1, fileName: 'x' })), null)
  const err = svc.errorPayload('a.md', '无法读取该文件内容', 456)
  assert.equal(svc.deserialize(svc.serialize(err)).state, svc.STATE_ERROR)
})

test('89.3 截断载荷 state=truncated 且带可读提示，文件名非空', () => {
  const payload = svc.contentPayload('big.md', 'x', true, 1)
  assert.equal(payload.state, svc.STATE_TRUNCATED)
  assert.match(payload.message, /仅预览前/)
  assert.equal(payload.fileName, 'big.md')
})

// ---- 源级断言 ----
const moduleJson = JSON.parse(readSourceFile(new URL('entry/src/main/module.json5', root))
  .replace(/\/\/[^\n]*/g, '')
  .replace(/,(\s*[}\]])/g, '$1'))

test('89.1 注册独立 MarkdownViewAbility + viewData/FileOpen/general.markdown，且不碰 EntryAbility 的 sendData', () => {
  const abilities = moduleJson.module.abilities
  const entry = abilities.find((a) => a.name === 'EntryAbility')
  const view = abilities.find((a) => a.name === 'MarkdownViewAbility')
  assert.ok(view, '缺少 MarkdownViewAbility')
  assert.equal(view.exported, true)
  const viewSkill = view.skills.find((s) => (s.actions || []).includes('ohos.want.action.viewData'))
  assert.ok(viewSkill, '缺少 viewData skill')
  assert.equal(viewSkill.uris[0].scheme, 'file')
  assert.equal(viewSkill.uris[0].type, 'general.markdown')
  assert.equal(viewSkill.uris[0].linkFeature, 'FileOpen')
  // EntryAbility 既有 sendData skill 保留不被改写
  assert.ok(entry.skills.some((s) => (s.actions || []).includes('ohos.want.action.sendData')))
  assert.ok(entry.skills.some((s) => (s.actions || []).includes('ohos.want.action.home')))
})

test('89.1/89.5 零新增权限：requestPermissions 白名单不变', () => {
  const names = moduleJson.module.requestPermissions.map((p) => p.name).sort()
  assert.deepEqual(names, ['ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.INTERNET'])
})

const viewAbility = readSourceFile(new URL('entry/src/main/ets/entryability/MarkdownViewAbility.ets', root))
const device = readSourceFile(new URL('entry/src/main/ets/model/MarkdownOpenDevice.ets', root))
const page = readSourceFile(new URL('entry/src/main/ets/pages/MarkdownFileOpenPage.ets', root))
const mainPages = JSON.parse(readSourceFile(new URL('entry/src/main/resources/base/profile/main_pages.json', root)))

test('89.2 冷 / 热启动两路径 + 载荷 nonce + 不初始化 VaultRegistry', () => {
  assert.match(viewAbility, /onCreate\(want: Want[\s\S]*?this\.openWant = want/)
  assert.match(viewAbility, /onNewWant\(want: Want[\s\S]*?this\.publishPayload\(want\)/)
  assert.match(viewAbility, /loadContent\('pages\/MarkdownFileOpenPage'/)
  assert.match(viewAbility, /isViewDataAction\(want\.action\)/)
  assert.match(viewAbility, /await import\('\.\.\/model\/MarkdownOpenDevice'\)/)
  // 独立性：本 ability 的实际代码不引用任何库服务（剥离行注释，注释里的说明文字不算）
  const viewCode = viewAbility.split('\n').filter((l) => !l.trim().startsWith('*') && !l.trim().startsWith('//')).join('\n')
  assert.ok(!/VaultRegistry|AgentRuntime|FullTextSearchService|NoteDraftService/.test(viewCode),
    'MarkdownViewAbility 不应初始化库 / Agent / 搜索服务')
})

test('89.3 设备层：openSync(READ_ONLY) + statSync 判上限 + readSync + 关 fd，零落盘', () => {
  assert.match(device, /fileIo\.openSync\(uri, fileIo\.OpenMode\.READ_ONLY\)/)
  assert.match(device, /fileIo\.statSync\(file\.fd\)/)
  assert.match(device, /fileIo\.readSync\(file\.fd, chunk\)/)
  assert.match(device, /fileIo\.closeSync\(file\)/)
  assert.match(device, /isOverLimit\(size\)/)
  assert.match(device, /truncateUtf8Bytes/)
  // 不写盘：无 copyFile / write / TRUNC
  assert.ok(!/copyFile|OpenMode\.WRITE|OpenMode\.TRUNC|writeSync/.test(device), '设备层不应写盘')
})

test('89.4 只读页：复用 TrashPreviewWeb，无编辑 / 保存 / 入库入口', () => {
  assert.match(page, /@StorageProp\('markdownFileOpen'\) @Watch\('onPayloadChanged'\)/)
  assert.match(page, /aboutToAppear\(\)[\s\S]*?consumePayload\(\)/)
  assert.match(page, /TrashPreviewWeb\(\{ markdown:/)
  // 只读语义：剥离注释后检查实际代码（注释里的「不 setEditable(true)」「无保存/入库」是说明文字）
  const pageCode = page.split('\n').filter((l) => !l.trim().startsWith('*') && !l.trim().startsWith('//')).join('\n')
  assert.ok(!/setEditable\(true\)/.test(pageCode))
  assert.ok(!/另存|保存到|入库|下载/.test(pageCode), '只读页不应出现写入口文案')
})

test('89.4 页面已注册进 main_pages', () => {
  assert.ok(mainPages.src.includes('pages/MarkdownFileOpenPage'))
})
