import fs from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../..')
const mdeditorNodeModules = path.join(repoRoot, 'web/mdeditor/node_modules')
const require = createRequire(path.join(repoRoot, 'web/mdeditor/package.json'))
const { build } = require('esbuild')
const outDir = path.join(repoRoot, 'entry/src/main/resources/rawfile/spike_editor')

const result = await build({
  entryPoints: [path.join(here, 'src/index.ts')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2019'],
  platform: 'browser',
  nodePaths: [mdeditorNodeModules],
  write: false,
  legalComments: 'none',
  define: { 'process.env.NODE_ENV': '"production"', global: 'window' },
  logLevel: 'info'
})

const code = result.outputFiles[0].text.replace(/<\/script/gi, '<\\/script')
const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>M0.5 输入法对照</title>
<style>
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; font-family: system-ui, sans-serif; color: #1f2329; background: #f5f6f8; }
  body { display: flex; flex-direction: column; padding: 8px; gap: 6px; }
  header { flex: 0 0 auto; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
  h1 { flex: 1 1 100%; margin: 0; font-size: 16px; }
  button { min-height: 36px; padding: 4px 10px; border: 1px solid #c8cbd0; border-radius: 8px; color: #202124; background: #fff; font-size: 13px; }
  button[aria-pressed="true"] { color: #fff; background: #007dff; border-color: #007dff; }
  #mode-status, #cursor, #viewport, #loaded-at { font-size: 11px; line-height: 1.4; }
  #status { flex: 0 0 auto; display: grid; grid-template-columns: 1fr; gap: 2px; padding: 5px 7px; border-radius: 6px; background: #fff; }
  #editors { flex: 1 1 auto; min-height: 80px; overflow: hidden; background: #fff; border: 1px solid #d9dce1; border-radius: 6px; }
  #cm-box, #textarea-box { width: 100%; height: 100%; overflow: auto; }
  #cm-box[hidden], #textarea-box[hidden] { display: none; }
  #cm-box .cm-editor { min-height: 100%; }
  #cm-box .cm-scroller { overflow: auto; -webkit-overflow-scrolling: touch; }
  #test-textarea { width: 100%; min-height: 100%; padding: 10px; resize: none; border: 0; outline: 0; font: 14px/1.55 ui-monospace, monospace; white-space: pre; overflow: auto; -webkit-overflow-scrolling: touch; }
  #log-panel { flex: 0 1 27%; min-height: 86px; display: flex; flex-direction: column; overflow: hidden; border: 1px solid #d9dce1; border-radius: 6px; background: #fff; }
  #log-head { display: flex; align-items: center; gap: 8px; padding: 4px 6px; border-bottom: 1px solid #e5e7eb; }
  #log-head strong { flex: 1; font-size: 12px; }
  #log-head button { min-height: 28px; padding: 2px 8px; font-size: 11px; }
  #event-list { flex: 1; overflow: auto; margin: 0; padding: 4px 6px 4px 28px; font: 10px/1.35 ui-monospace, monospace; overflow-wrap: anywhere; }
  #event-list li { padding: 1px 0; }
  #hint { flex: 0 0 auto; margin: 0; font-size: 10px; line-height: 1.3; color: #59616b; }
</style>
</head>
<body>
  <header>
    <h1>M0.5 输入法 A/B 对照</h1>
    <button id="mode-cm" aria-pressed="true">A · CodeMirror 6</button>
    <button id="mode-textarea" aria-pressed="false">B · TextArea</button>
    <button id="reset-sample">重置 500 行</button>
  </header>
  <section id="status">
    <div id="mode-status">当前：<span id="active-mode">CodeMirror 6 · contenteditable</span></div>
    <div id="cursor">光标位置</div>
    <div id="viewport">窗口尺寸</div>
    <div>页面载入时间：<span id="loaded-at"></span></div>
  </section>
  <main id="editors">
    <div id="cm-box"></div>
    <div id="textarea-box" hidden><textarea id="test-textarea" spellcheck="false" aria-label="M0.5 TextArea 对照编辑器"></textarea></div>
  </main>
  <section id="log-panel">
    <div id="log-head"><strong>输入事件 / 本次观察记录</strong><button id="clear-log">清空</button></div>
    <ol id="event-list"></ol>
  </section>
  <p id="hint">分别测试拼音、语音、手写、退格和长文滚动；观察 composition 事件、候选框位置、光标与折叠后的载入时间。</p>
<script>${code}</script>
</body>
</html>
`

fs.mkdirSync(outDir, { recursive: true })
const outFile = path.join(outDir, 'index.html')
fs.writeFileSync(outFile, html, 'utf8')
console.log(`written ${outFile} (${(Buffer.byteLength(html, 'utf8') / 1024).toFixed(0)} KB)`)
