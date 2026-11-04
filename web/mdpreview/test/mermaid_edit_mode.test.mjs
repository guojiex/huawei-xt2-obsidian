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
