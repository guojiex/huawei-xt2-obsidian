import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const indexSource = await readFile(new URL('../src/index.ts', import.meta.url), 'utf8')
const buildSource = await readFile(new URL('../build.mjs', import.meta.url), 'utf8')

test('Mermaid preview preserves its source and code-block toolbar', () => {
  const start = indexSource.indexOf('async function renderMermaidBlocks(')
  const end = indexSource.indexOf('\n}\n\nmarked.setOptions', start)
  assert.ok(start >= 0 && end > start)
  const renderer = indexSource.slice(start, end)

  assert.match(renderer, /rendered\.className = 'mermaid-rendered'/)
  assert.match(renderer, /block\.appendChild\(rendered\)/)
  assert.match(renderer, /block\.appendChild\(fallback\)/)
  assert.doesNotMatch(renderer, /block\.innerHTML\s*=|block\.replaceChildren/)
})

test('editable Mermaid blocks show source and hide the read-only render result', () => {
  assert.match(buildSource, /#content \.mermaid-block\.md-code \.mermaid-source \{ display: block; \}/)
  assert.match(buildSource,
    /#content \.mermaid-block\.md-code \.mermaid-rendered,\s*#content \.mermaid-block\.md-code \.mermaid-error \{ display: none; \}/)
})

test('uneditable code blocks remain read-only and keep the source-edit entry', async () => {
  const previewSource = await readFile(new URL('../src/index.ts', import.meta.url), 'utf8')
  const start = previewSource.indexOf('function configureEditableBlocks(')
  const end = previewSource.indexOf('\nfunction ', start + 1)
  assert.ok(start >= 0 && end > start)
  const configure = previewSource.slice(start, end)

  assert.match(configure, /const model = target \? inspectCodeFence\(raw, target\.textContent \?\? ''\) : null/)
  assert.match(configure, /if \(target && model\?\.editable\)[\s\S]*?setAttribute\('contenteditable', 'plaintext-only'\)/)
  assert.match(configure, /model\?\.editable\s*\?\s*'可编辑代码块'\s*:\s*'此代码块请以源码编辑'/)
  assert.match(previewSource, /closed \? \(language \|\| '纯文本'\) : '源码'/)
})
