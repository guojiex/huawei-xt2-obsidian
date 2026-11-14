// v1.56 接收系统分享：56.1 注册 / 56.2 双路径 / 56.4 落盘接线的源级断言
// + ShareIngestService 纯逻辑单测（esbuild + vm，同 test_markdown_inline_parser 惯例）。
import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import { readSourceFile } from './lib/source.mjs'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')

// ---- 纯逻辑单测：ShareIngestService（无 SDK / UI 依赖，可直接跑） ----
const source = fs.readFileSync(new URL('entry/src/main/ets/model/ShareIngestService.ets', root), 'utf8')
const code = transformSync(`${source}\nmodule.exports = ShareIngestService;`, {
  loader: 'ts',
  format: 'cjs'
}).code
const context = vm.createContext({ module: { exports: {} } })
vm.runInContext(code, context)
const svc = context.module.exports

test('56.3 标题默认链：record.title 非空直接用之', () => {
  const draft = svc.buildDraft(
    { utd: 'general.plain-text', title: '  官方标题  ', content: '正文', message: '', receivedAt: 1 }, 1)
  assert.equal(draft.title, '官方标题')
})

test('56.3 标题默认链：无标题的链接取 URL 截 80 字符', () => {
  const url = 'https://example.test/' + 'a'.repeat(100)
  const draft = svc.buildDraft(
    { utd: 'general.hyperlink', title: '', content: url, message: '', receivedAt: 1 }, 1)
  assert.equal(draft.title.length, 80)
  assert.equal(draft.title, url.substring(0, 80))
})

test('56.3 标题默认链：文本取首个非空行去空白截 30 字符', () => {
  const content = '\n\n   \n  ' + '一'.repeat(40) + '尾巴  \n第二行'
  const draft = svc.buildDraft(
    { utd: 'general.text', title: '', content: content, message: '', receivedAt: 1 }, 1)
  assert.equal(draft.title, '一'.repeat(30))
})

test('56.3 标题默认链：全兜底「分享剪藏 yyyy-MM-dd HH:mm」', () => {
  const now = new Date(2026, 10, 12, 9, 5).getTime()
  const draft = svc.buildDraft(
    { utd: 'general.plain-text', title: '', content: ' \n \t ', message: '', receivedAt: 1 }, now)
  assert.equal(draft.title, '分享剪藏 2026-11-12 09:05')
})

test('56.3 正文模板：链接 title 与 url 不同 → [title](url)', () => {
  const draft = svc.buildDraft(
    { utd: 'general.hyperlink', title: '华为官网', content: 'https://www.huawei.com', message: '', receivedAt: 1 }, 1)
  assert.equal(draft.content, '[华为官网](https://www.huawei.com)')
  assert.equal(draft.title, '华为官网')
})

test('56.3 正文模板：链接 title 与 url 相同 → 直接 url', () => {
  const draft = svc.buildDraft(
    { utd: 'general.hyperlink', title: ' https://a.test ', content: 'https://a.test', message: '', receivedAt: 1 }, 1)
  assert.equal(draft.content, 'https://a.test')
})

test('56.3 正文模板：文本记录 content 原文不动', () => {
  const content = '第一行\n\n第三行'
  const draft = svc.buildDraft(
    { utd: 'general.plain-text', title: 'T', content: content, message: '', receivedAt: 1 }, 1)
  assert.equal(draft.content, content)
})

test('56.2 isTextLikeUtd 只认三种文本类 UTD', () => {
  assert.ok(svc.isTextLikeUtd('general.text'))
  assert.ok(svc.isTextLikeUtd('general.plain-text'))
  assert.ok(svc.isTextLikeUtd('general.hyperlink'))
  assert.ok(!svc.isTextLikeUtd('general.html'))
  assert.ok(!svc.isTextLikeUtd('general.image'))
  assert.ok(!svc.isTextLikeUtd(''))
})

test('56.2 errorPayload 携带可读 message 且可通过 isValidPayload', () => {
  const payload = svc.errorPayload('无法读取分享内容', 123)
  assert.equal(payload.utd, 'error')
  assert.equal(payload.message, '无法读取分享内容')
  assert.equal(payload.receivedAt, 123)
  assert.ok(svc.isValidPayload(payload))
})

test('56.4 isValidPayload 拒绝缺字段 / 类型错误的脏载荷', () => {
  assert.ok(!svc.isValidPayload({}))
  assert.ok(!svc.isValidPayload({ utd: 'general.text', title: 'a', content: 'b', message: '' }))
  assert.ok(!svc.isValidPayload({ utd: '', title: 'a', content: 'b', message: '', receivedAt: 1 }))
  assert.ok(!svc.isValidPayload({ utd: 'general.text', title: 1, content: 'b', message: '', receivedAt: 1 }))
  assert.ok(!svc.isValidPayload({ utd: 'general.text', title: 'a', content: 'b', message: '', receivedAt: 'x' }))
})

// ---- 源级断言 ----
// module.json5：去注释 + 去尾逗号后按 JSON 解析（文件里有 trailing comma，纯 JSON.parse 不认）。
const moduleJson = JSON.parse(readSourceFile(new URL('entry/src/main/module.json5', root))
  .replace(/\/\/[^\n]*/g, '')
  .replace(/,(\s*[}\]])/g, '$1'))

test('56.1 EntryAbility.skills 注册 sendData + UTD 穷举，home skill 保留', () => {
  const ability = moduleJson.module.abilities.find((a) => a.name === 'EntryAbility')
  const skills = ability.skills
  assert.ok(skills.some((s) => (s.actions || []).includes('ohos.want.action.home')))
  const send = skills.find((s) => (s.actions || []).includes('ohos.want.action.sendData'))
  assert.ok(send, '缺少 sendData skill')
  // 官方指南：scheme 是预留字段（不生效）但构建 schema required——每个 uris 条目必须带。
  for (const uri of send.uris || []) {
    assert.equal(uri.scheme, 'file', `uris 条目缺 scheme: ${JSON.stringify(uri)}`)
  }
  const utds = (send.uris || []).map((u) => u.utd)
  assert.deepEqual(utds.sort(), ['general.hyperlink', 'general.plain-text', 'general.text'])
})

test('56.5 零新增权限：requestPermissions 白名单不变', () => {
  const names = moduleJson.module.requestPermissions.map((p) => p.name).sort()
  assert.deepEqual(names, ['ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.INTERNET'])
})

const entryAbility = readSourceFile(new URL('entry/src/main/ets/entryability/EntryAbility.ets', root))
const indexSource = readSourceFile(new URL('entry/src/main/ets/pages/Index.ets', root))
const shareFlowSource = readSourceFile(new URL('entry/src/main/ets/components/ShareFlowPanel.ets', root))
const dialogSource = readSourceFile(new URL('entry/src/main/ets/components/SaveShareDialog.ets', root))

test('56.2 onCreate / onNewWant 双路径都接线 handleSharedWant + getSharedData', () => {
  assert.match(entryAbility, /onCreate\(want: Want[\s\S]*?this\.handleSharedWant\(want\)/)
  assert.match(entryAbility, /onNewWant\(want: Want[\s\S]*?this\.handleSharedWant\(want\)/)
  assert.match(entryAbility, /systemShare\.getSharedData\(want\)/)
  assert.match(entryAbility, /want\.action !== ShareIngestService\.ACTION_SEND_DATA/)
})

test('56.2 解析失败 / 无有效记录 → 错误载荷「无法读取分享内容」，不崩溃', () => {
  assert.match(entryAbility, /errorPayload\('无法读取分享内容'/)
  const catches = entryAbility.match(/errorPayload\('无法读取分享内容'/g) || []
  assert.ok(catches.length >= 2, '无记录与抛错两条兜底都要有')
})

test('56.5 分享内容与标题不进 EntryAbility 日志', () => {
  // 日志只允许记录数与错误码，禁止把 title/content 写进 hilog。
  const hilogLines = entryAbility.split('\n').filter((l) => /hilog\.(info|warn|error|debug)/.test(l))
  assert.ok(hilogLines.length > 0)
  for (const line of hilogLines) {
    assert.ok(!/payload\.title|payload\.content|chosen\.title|chosen\.content/.test(line),
      `日志行泄漏内容：${line.trim()}`)
  }
})

test('56.4 Index 消费链：@StorageProp + @Watch + 消费后清键 + 落盘 + 打开', () => {
  assert.match(indexSource, /@StorageProp\('incomingShare'\) @Watch\('onIncomingShareChanged'\)/)
  assert.match(indexSource, /this\.shareFlowApi\?\.consumeIncomingShare\(\)/)
  assert.match(shareFlowSource, /private consumeIncomingShare\(\): void/)
  assert.match(shareFlowSource,
    /AppStorage\.setOrCreate\(ShareIngestService\.STORAGE_KEY, ''\)/)
  assert.match(shareFlowSource, /NoteService\.previewCreatePath\(registry, vaultId, rel\)/)
  assert.match(shareFlowSource, /NoteService\.createNoteWithContent\(registry, vaultId, target, content\)/)
  assert.match(indexSource, /this\.onSelectFile\(target, 'left', true\)/)
  assert.match(indexSource, /this\.revealPath = target/)
  assert.match(shareFlowSource, /已保存到 /)
})

test('56.4 库根约束：normalizeRelPath 后含 / 即拒绝（不建子目录）', () => {
  assert.match(shareFlowSource, /if \(rel\.indexOf\('\/'\) >= 0\) \{[\s\S]*?保存位置固定在库根/)
})

test('56.4 冷启动兜底：aboutToAppear 检查早到载荷', () => {
  assert.match(shareFlowSource,
    /const raw: string = AppStorage\.get<string>\(ShareIngestService\.STORAGE_KEY\) \?\? '';\s*\n\s*if \(raw\.length > 0\) \{\s*\n\s*setTimeout\(\(\): void => \{\s*\n\s*this\.consumeIncomingShare\(\);/)
})

test('56.3 确认层：标题为空 / 无库禁用保存，失败保留现场，成功才关闭', () => {
  assert.match(dialogSource, /this\.vaults\.length > 0 && this\.titleDraft\.trim\(\)\.length > 0/)
  assert.match(dialogSource, /catch \(error\) \{\s*\n\s*const err = error as Error;\s*\n\s*this\.errorMessage = err\.message;/)
  assert.match(dialogSource, /await this\.onConfirm\([\s\S]*?\);[\s\S]*?this\.controller\?\.close\(\);/)
})

test('56.5 确认层 token only：颜色 / 圆角全走 token 资源', () => {
  assert.ok(dialogSource.includes("$r('app.color."))
  assert.ok(dialogSource.includes('FontSize.'))
  assert.ok(dialogSource.includes('Space.'))
  assert.ok(!/"#[0-9a-fA-F]{3,8}"/.test(dialogSource), '禁止散写十六进制色值')
})
