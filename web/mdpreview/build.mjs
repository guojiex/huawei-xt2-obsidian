/**
 * mdpreview/build.mjs —— 把 src 打包成单个 IIFE 并内联进 index.html。
 * 与 web/mdeditor/build.mjs 同款链路：rawfile 相对路径引用在 Web 组件里不可靠，
 * 单文件内联避免加载不到 bundle.js。
 *
 * 改了 src/ 之后必须重跑，否则真机/模拟器跑旧产物（AGENTS.md §Web 打包约定）。
 * CSS token 与 docs/prototype/index.html 的 :root / [data-theme="dark"] 保持一致
 * （改值两边同步，v0.2 需求文档 §3.5）。
 */
import { build } from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../..')
const outDir = path.join(repoRoot, 'entry/src/main/resources/rawfile/mdpreview')
const tmpFile = path.join(here, '.bundle.tmp.js')
const katexDist = path.join(here, 'node_modules/katex/dist')

await build({
  entryPoints: [path.join(here, 'src/index.ts')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2019'],
  platform: 'browser',
  outfile: tmpFile,
  legalComments: 'none',
  define: {
    'process.env.NODE_ENV': '"production"',
    global: 'window'
  },
  logLevel: 'info'
})

const code = fs.readFileSync(tmpFile, 'utf8')
fs.unlinkSync(tmpFile)

// 内联脚本里出现 </script 会提前闭合标签
const safe = code.replace(/<\/script/gi, '<\\/script')
const katexCss = fs.readFileSync(path.join(katexDist, 'katex.min.css'), 'utf8')

const html = `<!doctype html>
<html data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>mdpreview</title>
<style>
  /* token 与 docs/prototype/index.html :root 同源（改值两边同步） */
  :root {
    --brand: #007DFF;
    --bg-card: #FFFFFF;
    --bg-secondary: #F1F3F5;
    --line: rgba(0, 0, 0, .08);
    --text-primary: rgba(0, 0, 0, .90);
    --text-secondary: rgba(0, 0, 0, .60);
    --text-tertiary: rgba(0, 0, 0, .40);
    --r-chip: 8px;
    --r-control: 12px;
    --sp-3: 12px;
    --sp-4: 16px;
    --h-touch: 48px;
    --preview-image-max-ratio: .6;
    --image-viewer-bg: rgba(0, 0, 0, .8);
  }
  [data-theme="dark"] {
    --brand: #4EA1FF;
    --bg-card: #1C1C1F;
    --bg-secondary: #1C1C1F;
    --line: rgba(255, 255, 255, .10);
    --text-primary: rgba(255, 255, 255, .92);
    --text-secondary: rgba(255, 255, 255, .60);
    --text-tertiary: rgba(255, 255, 255, .40);
  }
  html, body { margin: 0; padding: 0; height: 100%; background: var(--bg-card); }
  #content {
    height: 100%; overflow-y: auto; -webkit-overflow-scrolling: touch;
    box-sizing: border-box; padding: 20px 20px 48px;
    font-size: 16px; line-height: 1.65; color: var(--text-primary);
    font-family: system-ui, sans-serif;
    word-break: break-word;
  }
  #content h1 { font-size: 24px; margin: 0 0 16px; font-weight: 700; letter-spacing: .3px; line-height: 1.3; }
  #content h2 { font-size: 20px; margin: 24px 0 12px; font-weight: 700; line-height: 1.35; }
  #content h3 { font-size: 18px; margin: 20px 0 8px; font-weight: 600; }
  #content h4, #content h5, #content h6 { font-size: 16px; margin: 16px 0 8px; font-weight: 600; }
  #content p { margin: 0 0 12px; }
  #content ul, #content ol { margin: 0 0 12px; padding-left: 20px; }
  #content li { margin: 4px 0; }
  #content li::marker { color: var(--text-tertiary); }
  #content li:has(> input[type="checkbox"]) { list-style: none; margin-left: -20px; }
  #content blockquote {
    margin: 0 0 12px; padding: 12px 16px;
    border-left: 3px solid var(--brand); border-radius: var(--r-control);
    background: var(--bg-secondary); color: var(--text-secondary); font-size: 14px;
  }
  #content code {
    background: var(--bg-secondary); padding: 1px 6px; border-radius: var(--r-chip);
    font-size: 12px; font-family: ui-monospace, Menlo, Consolas, monospace;
  }
  #content pre {
    background: var(--bg-secondary); padding: 16px; border-radius: var(--r-control);
    overflow: auto; margin: 0 0 12px;
  }
  #content pre code { background: none; padding: 0; font-size: 12px; line-height: 1.7; }
  #content .katex-display { overflow-x: auto; overflow-y: hidden; padding: 2px 0; }
  #content .math-error, #content .mermaid-error {
    color: var(--text-secondary); border-left: 3px solid var(--brand);
    background: var(--bg-secondary); padding: 8px 12px; border-radius: var(--r-chip);
  }
  #content .mermaid-block { overflow-x: auto; margin: 0 0 12px; }
  #content .mermaid-source { display: none; }
  #content .mermaid-block svg { max-width: 100%; height: auto; }
  #content table {
    border-collapse: separate; border-spacing: 0; margin: 0 0 12px;
    font-size: 12px; border: 1px solid var(--line);
    border-radius: var(--r-control); overflow: hidden; width: 100%;
  }
  #content th, #content td {
    border-bottom: 1px solid var(--line); border-right: 1px solid var(--line);
    padding: 6px 12px; text-align: left;
  }
  #content th:last-child, #content td:last-child { border-right: none; }
  #content tbody tr:last-child td { border-bottom: none; }
  #content th { background: var(--bg-secondary); font-weight: 600; color: var(--text-primary); }
  #content hr { border: none; border-top: 1px solid var(--line); margin: 24px 0; }
  #content img { max-width: 100%; border-radius: var(--r-chip); }
  #content img.preview-local-image {
    display: block; max-height: var(--preview-image-max-height, none);
    width: auto; height: auto; object-fit: contain; cursor: zoom-in;
  }
  #content img.preview-local-image:focus-visible { outline: 2px solid var(--brand); outline-offset: 2px; }
  .image-viewer {
    position: fixed; inset: 0; z-index: 10; display: flex; flex-direction: column;
    gap: var(--sp-3); padding: var(--sp-4); box-sizing: border-box;
    background: var(--image-viewer-bg);
  }
  .image-viewer.hidden { display: none; }
  .image-viewer-toolbar { display: flex; justify-content: flex-end; flex: none; }
  #image-viewer-close {
    min-height: var(--h-touch); padding: 0 var(--sp-3); border: 1px solid var(--line);
    border-radius: var(--r-control); background: var(--bg-card); color: var(--text-primary);
    font: inherit;
  }
  .image-viewer-scroll { flex: 1; min-height: 0; overflow: auto; overscroll-behavior: contain; }
  #image-viewer-full { display: block; max-width: 100%; width: auto; height: auto; margin: 0 auto; }
  #content a { color: var(--brand); text-decoration: none; }
  #content input[type="checkbox"] { accent-color: var(--brand); width: 15px; height: 15px; vertical-align: -2px; margin-right: 6px; }
  #content .empty { color: var(--text-tertiary); font-size: 14px; text-align: center; margin-top: 40px; }
</style>
<style>
${katexCss}
</style>
</head>
<body>
<div id="content"></div>
<div id="image-viewer" class="image-viewer hidden" role="dialog" aria-modal="true" aria-label="完整图片">
  <div class="image-viewer-toolbar"><button id="image-viewer-close">关闭图片</button></div>
  <div id="image-viewer-scroll" class="image-viewer-scroll" tabindex="0" aria-label="完整图片，可滚动查看">
    <img id="image-viewer-full" alt="">
  </div>
</div>
<script>
${safe}
</script>
</body>
</html>
`

fs.mkdirSync(outDir, { recursive: true })
fs.cpSync(path.join(katexDist, 'fonts'), path.join(outDir, 'fonts'), { recursive: true })
const outFile = path.join(outDir, 'index.html')
fs.writeFileSync(outFile, html, 'utf8')
console.log(`written ${outFile} (${(Buffer.byteLength(html, 'utf8') / 1024).toFixed(0)} KB)`)
