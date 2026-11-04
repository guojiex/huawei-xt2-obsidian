import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8')
const helpersStart = html.indexOf('function cbImageAltParts(')
const helpersEnd = html.indexOf('\nfunction cbNotePath(', helpersStart)
const specStart = html.indexOf('function cbSpec(t){', helpersEnd)
const specEnd = html.indexOf('\n/* ---------- 面板形态', specStart)
const inlineStart = html.indexOf('function inline(')
const inlineEnd = html.indexOf('\nfunction rememberEditorPosition', inlineStart)
assert.ok(helpersStart >= 0 && helpersEnd > helpersStart)
assert.ok(specStart >= 0 && specEnd > specStart)
assert.ok(inlineStart >= 0 && inlineEnd > inlineStart)

function prototypeHarness() {
  const writes = []
  const notices = []
  const field = (label, control, hint) => `<field>${label}${control}${hint || ''}</field>`
  const context = vm.createContext({
    module: { exports: {} },
    CBH: {
      group: (content) => `<group>${content}</group>`,
      field,
      input: (name, value, placeholder, type = 'text') =>
        `<input data-cb="${name}" type="${type}" value="${value}" placeholder="${placeholder}">`,
      seg: (name) => `<seg data-cb-seg="${name}"></seg>`,
      act: (name, label) => `<button data-cb-act="${name}">${label}</button>`,
      info: (message) => `<info>${message}</info>`,
      source: () => '<source></source>'
    },
    CB_TYPE_NAME: {},
    note: () => ({}),
    isMarkdownEscaped: (source, index) => {
      let slashes = 0
      for (let i = index - 1; i >= 0 && source[i] === '\\'; i--) slashes++
      return slashes % 2 === 1
    },
    esc: (value) => String(value),
    cbWrite: (...args) => { writes.push(args); return true },
    toast: (message) => notices.push(message),
    closeBlockUi() {},
    openImageViewer() {},
    resolvePreviewImage: () => 'image.png',
    tagText: (value) => value,
    current: 'note-a',
    resolveWikiTarget() {},
    window: { open() {} },
    navigator: {}
  })
  const helperCode = html.slice(helpersStart, helpersEnd)
  const specCode = html.slice(specStart, specEnd)
  const inlineCode = html.slice(inlineStart, inlineEnd)
  vm.runInContext(
    `${helperCode}\n${specCode}\n${inlineCode}\nmodule.exports = { cbImageAltParts, cbImageParts, cbSpec, inline };`,
    context
  )
  return { ...context.module.exports, writes, notices }
}

test('20.3 prototype image panel edits remote addresses without offering local replacement', () => {
  const harness = prototypeHarness()
  const raw = '![风景|360](<https://example.test/old.png>)'
  const spec = harness.cbSpec({ id: 'note-a', kind: 'image', raw })

  assert.match(spec.html, /图片地址/)
  assert.match(spec.html, /data-cb="url"/)
  assert.doesNotMatch(spec.html, /data-cb-act="replace"/)
  spec.onField('url', ' ')
  assert.equal(harness.writes.length, 0)
  assert.equal(harness.notices.at(-1), '图片地址不能为空或包含空格')

  spec.onField('url', 'https://example.test/new.png')
  assert.equal(harness.writes[0][1], '![风景|360](<https://example.test/new.png>)')
})

test('20.3 prototype keeps literal pipes in alternative text and only replaces local image references', () => {
  const harness = prototypeHarness()
  const raw = '![旧图](attachments/image.png)'
  const spec = harness.cbSpec({ id: 'note-a', kind: 'image', raw })

  assert.doesNotMatch(spec.html, /data-cb="url"/)
  assert.match(spec.html, /data-cb-act="replace"/)
  spec.onField('alt', '版本|360')
  assert.equal(harness.writes[0][1], String.raw`![版本\|360](attachments/image.png)`)
})

test('20.3 prototype parser keeps an escaped pipe in alternative text separate from width', () => {
  const harness = prototypeHarness()
  const parts = harness.cbImageAltParts(String.raw`版本\|360|240`)

  assert.equal(parts.alt, '版本|360')
  assert.equal(parts.width, '240')
})

test('20.3 prototype preview renders escaped pipes as alt text and honors a separate width suffix', () => {
  const harness = prototypeHarness()
  const literalPipe = harness.inline(String.raw`![版本\|360](assets/image.png)`)
  assert.match(literalPipe, /alt="版本\|360"/)
  assert.doesNotMatch(literalPipe, /style="width:/)

  const literalPipeWithWidth = harness.inline(String.raw`![版本\|360|240](assets/image.png)`)
  assert.match(literalPipeWithWidth, /alt="版本\|360"/)
  assert.match(literalPipeWithWidth, /style="width:240px"/)
})

test('20.3 prototype image parsing and preview retain escaped closing brackets in alt text', () => {
  const harness = prototypeHarness()
  const raw = String.raw`![旧\]图|360](assets/image.png)`
  const parts = harness.cbImageParts(raw)

  assert.equal(parts.alt, '旧]图')
  assert.equal(parts.width, '360')
  assert.match(harness.inline(raw), /alt="旧\]图"/)
})
