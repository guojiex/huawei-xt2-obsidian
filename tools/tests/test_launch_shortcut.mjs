// v2.0 应用图标静态快捷方式：2.0.1 声明 / 2.0.2 双路径路由 / 2.0.3 dev 双包的源级断言
// + LaunchShortcutService 纯逻辑单测（esbuild + vm，同 test_share_ingest.mjs 惯例）。
import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import { readSourceFile } from './lib/source.mjs'

const root = new URL('../../', import.meta.url)
const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url))
const { transformSync } = require('esbuild')

// ---- 纯逻辑单测：LaunchShortcutService（无 SDK / UI 依赖，可直接跑） ----
const source = fs.readFileSync(new URL('entry/src/main/ets/model/LaunchShortcutService.ets', root), 'utf8')
const code = transformSync(`${source}\nmodule.exports = LaunchShortcutService;`, {
  loader: 'ts',
  format: 'cjs'
}).code
const context = vm.createContext({ module: { exports: {} } })
vm.runInContext(code, context)
const svc = context.module.exports

test('2.0.2 isKnownAction 只认 new_note / search 两个动作', () => {
  assert.ok(svc.isKnownAction('new_note'))
  assert.ok(svc.isKnownAction('search'))
  assert.ok(!svc.isKnownAction('sync'))
  assert.ok(!svc.isKnownAction(''))
  assert.ok(!svc.isKnownAction('new_note '))
})

test('2.0.2 actionFromParameters：合法动作透传，非字符串 / 未知 / 缺参数返回空串', () => {
  assert.equal(svc.actionFromParameters({ yaoshi_shortcut: 'new_note' }), 'new_note')
  assert.equal(svc.actionFromParameters({ yaoshi_shortcut: 'search' }), 'search')
  assert.equal(svc.actionFromParameters({}), '')
  assert.equal(svc.actionFromParameters({ yaoshi_shortcut: 'sync' }), '')
  assert.equal(svc.actionFromParameters({ yaoshi_shortcut: 1 }), '')
  assert.equal(svc.actionFromParameters(undefined), '')
})

test('2.0.2 buildPayload / isValidPayload 载荷结构与脏数据拒绝', () => {
  const payload = svc.buildPayload('search', 123)
  assert.equal(payload.action, 'search')
  assert.equal(payload.receivedAt, 123)
  assert.ok(svc.isValidPayload(payload))
  assert.ok(!svc.isValidPayload({}))
  assert.ok(!svc.isValidPayload({ action: 'sync', receivedAt: 1 }))
  assert.ok(!svc.isValidPayload({ action: 'search', receivedAt: 'x' }))
})

// ---- 源级断言 ----
// module.json5：去注释 + 去尾逗号后按 JSON 解析（文件里有 trailing comma，纯 JSON.parse 不认）。
const moduleJson = JSON.parse(readSourceFile(new URL('entry/src/main/module.json5', root))
  .replace(/\/\/[^\n]*/g, '')
  .replace(/,(\s*[}\]])/g, '$1'))

test('2.0.1 EntryAbility 挂 ohos.ability.shortcuts metadata → $profile:shortcuts_config（AO1 配置法）', () => {
  const ability = moduleJson.module.abilities.find((a) => a.name === 'EntryAbility')
  const meta = (ability.metadata || []).find((m) => m.name === 'ohos.ability.shortcuts')
  assert.ok(meta, '缺少 ohos.ability.shortcuts metadata')
  assert.equal(meta.resource, '$profile:shortcuts_config')
})

test('2.0.1 shortcuts_config：两条快捷方式，id / label / icon / wants 参数键齐备', () => {
  const config = JSON.parse(readSourceFile(new URL('entry/src/main/resources/base/profile/shortcuts_config.json', root)))
  const ids = config.shortcuts.map((s) => s.shortcutId).sort()
  assert.deepEqual(ids, ['new_note', 'search'])
  for (const sc of config.shortcuts) {
    assert.ok(sc.label.startsWith('$string:'), `label 必须走 string 资源：${sc.label}`)
    assert.ok(sc.icon.startsWith('$media:'), `icon 必须引用既有 media 资源：${sc.icon}`)
    assert.equal(sc.wants.length, 1)
    const want = sc.wants[0]
    assert.equal(want.bundleName, 'com.jxg.huaweiobsidian')
    assert.equal(want.moduleName, 'entry')
    assert.equal(want.abilityName, 'EntryAbility')
    assert.equal(want.parameters.yaoshi_shortcut, sc.shortcutId, 'wants 参数值必须等于 shortcutId')
  }
})

test('2.0.3 dev 双包：devres 覆盖版 shortcuts_config 指向 dev bundleName（AO2）', () => {
  const config = JSON.parse(readSourceFile(new URL('entry/src/devres/base/profile/shortcuts_config.json', root)))
  const ids = config.shortcuts.map((s) => s.shortcutId).sort()
  assert.deepEqual(ids, ['new_note', 'search'])
  for (const sc of config.shortcuts) {
    assert.equal(sc.wants[0].bundleName, 'com.jxg.huaweiobsidian.dev')
  }
})

test('2.0.1 label 字符串在 string.json 有定义', () => {
  const strings = JSON.parse(readSourceFile(new URL('entry/src/main/resources/base/element/string.json', root)))
  const names = new Set(strings.string.map((s) => s.name))
  assert.ok(names.has('shortcut_new_note'))
  assert.ok(names.has('shortcut_search'))
})

const entryAbility = readSourceFile(new URL('entry/src/main/ets/entryability/EntryAbility.ets', root))
const indexSource = readSourceFile(new URL('entry/src/main/ets/pages/Index.ets', root))

test('2.0.2 onCreate / onNewWant 双路径都接线 handleShortcutWant + AppStorage 转发', () => {
  assert.match(entryAbility, /onCreate\(want: Want[\s\S]*?this\.handleShortcutWant\(want\)/)
  assert.match(entryAbility, /onNewWant\(want: Want[\s\S]*?this\.handleShortcutWant\(want\)/)
  assert.match(entryAbility,
    /AppStorage\.setOrCreate\(LaunchShortcutService\.STORAGE_KEY, JSON\.stringify\(payload\)\)/)
})

test('2.0.2 Index 消费链：@StorageProp + @Watch + aboutToAppear 早到兜底 + 消费后清键', () => {
  assert.match(indexSource, /@StorageProp\('launchShortcut'\) @Watch\('onLaunchShortcutChanged'\)/)
  assert.match(indexSource,
    /const launchShortcutRaw: string = AppStorage\.get<string>\(LaunchShortcutService\.STORAGE_KEY\) \?\? ''/)
  assert.match(indexSource,
    /AppStorage\.setOrCreate\(LaunchShortcutService\.STORAGE_KEY, ''\)/)
})

test('2.0.2 动作分发：new_note → 新建对话框，search → 快切搜索；先回主视图；脏载荷静默忽略', () => {
  assert.match(indexSource, /action === LaunchShortcutService\.ACTION_NEW_NOTE[\s\S]*?this\.openCreateNoteDialog\(\)/)
  assert.match(indexSource, /action === LaunchShortcutService\.ACTION_SEARCH[\s\S]*?this\.openQuickSwitcher\(\)/)
  assert.match(indexSource, /payload === null \|\| !LaunchShortcutService\.isValidPayload\(payload\)/)
  assert.match(indexSource, /if \(this\.screenSaverOpen\) \{\s*\n\s*this\.closeScreenSaver\(\);/)
  assert.match(indexSource, /if \(this\.topView !== 'note'\) \{\s*\n\s*this\.topView = 'note';/)
})

test('2.0.4 零新增权限：requestPermissions 白名单不变', () => {
  const names = moduleJson.module.requestPermissions.map((p) => p.name).sort()
  assert.deepEqual(names, ['ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.INTERNET'])
})
