/**
 * mdpreview/build.mjs —— 把 src 打包成单个 IIFE 并内联进 index.html。
 * 与 web/mdeditor/build.mjs 同款链路：rawfile 相对路径引用在 Web 组件里不可靠，
 * 单文件内联避免加载不到 bundle.js。
 *
 * 改了 src/ 之后必须重跑，否则真机/模拟器跑旧产物（AGENTS.md §Web 打包约定）。
 * CSS token 与 docs/prototype/v2/index.html 的 :root / [data-theme="dark"] 保持一致；改值时两边同步。
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
const prototypeHtml = fs.readFileSync(path.join(repoRoot, 'docs/prototype/v2/index.html'), 'utf8')
const sharedTokens = prototypeHtml.match(/:root\{[^\r\n]*\}\s*\[data-theme=dark\]\{[^\r\n]*\}/)?.[0]
if (!sharedTokens) {
  throw new Error('Unable to read shared v2 tokens from docs/prototype/v2/index.html')
}

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
// Keep generated rawfile clean when bundled Mermaid templates contain trailing spaces.
const safe = code.replace(/[ \t]+$/gm, '').replace(/<\/script/gi, '<\\/script')
const katexCss = fs.readFileSync(path.join(katexDist, 'katex.min.css'), 'utf8')

const html = `<!doctype html>
<html data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>mdpreview</title>
<style>
  /* v2 共享 token 从 prototype 源码注入；渲染器专属值留在此处。 */
  ${sharedTokens}
  :root {
    --preview-image-max-ratio: .6;
    --image-viewer-bg: rgba(0, 0, 0, .8);
    /* callout 渲染器专属色板（v1.4）：accent 尽量引用 v2 token；
       amber 组与各浅底为渲染器专属值，未入 v2 token，深色在下方覆盖。 */
    --callout-green-bg: rgba(53, 145, 109, .10);
    --callout-amber-accent: #a8680a;
    --callout-amber-bg: rgba(176, 116, 21, .12);
    --callout-red-bg: rgba(207, 64, 72, .10);
  }
  [data-theme="dark"] {
    --callout-green-bg: rgba(117, 199, 160, .12);
    --callout-amber-accent: #e2b25c;
    --callout-amber-bg: rgba(226, 178, 92, .14);
    --callout-red-bg: rgba(207, 64, 72, .18);
  }
  html, body { margin: 0; padding: 0; height: 100%; background: var(--paper); }
  #content {
    height: 100%; overflow-y: auto; -webkit-overflow-scrolling: touch;
    box-sizing: border-box; padding: var(--s6) var(--s10) var(--s16);
    font-size: var(--body); line-height: var(--leading); color: var(--ink);
    font-family: var(--font);
    word-break: break-word;
  }
  .preview-source-block { display: contents; }
  #content h1 { font-size: var(--heading); margin: var(--s3) 0 var(--s4); font-weight: 650; letter-spacing: -.035em; line-height: 1.35; }
  #content .note-tags { display: flex; align-items: center; flex-wrap: wrap; gap: var(--s2); margin-bottom: var(--s4); font-size: var(--caption); }
  #content .note-tag { display: inline-block; padding: 0 var(--s2); border-radius: var(--pill); background: var(--blue-soft); color: var(--blue); font-size: var(--small); overflow-wrap: anywhere; }
  #content h2 { font-size: var(--large); margin: var(--s8) 0 var(--s3); font-weight: 600; line-height: 1.35; }
  #content h3, #content h4, #content h5, #content h6 { font-size: var(--body); margin: var(--s5) 0 var(--s2); font-weight: 600; }
  #content p { margin: 0 0 var(--s5); }
  #content ul, #content ol { margin: 0 0 var(--s5); padding-left: var(--s6); }
  #content li { padding-left: var(--s1); margin-bottom: var(--s2); }
  #content li::marker { color: var(--muted); }
  #content li:has(> input[type="checkbox"]) { list-style: none; margin-left: calc(-1 * var(--s6)); }
  #content .callout {
    margin: var(--s6) 0; padding: var(--s3) var(--s4);
    border-left: 3px solid var(--callout-accent, var(--blue));
    border-radius: var(--small-r); background: var(--callout-bg, var(--blue-soft));
  }
  #content [data-callout-group="blue"] { --callout-accent: var(--blue); --callout-bg: var(--blue-soft); }
  #content [data-callout-group="green"] { --callout-accent: var(--green); --callout-bg: var(--callout-green-bg); }
  #content [data-callout-group="amber"] { --callout-accent: var(--callout-amber-accent); --callout-bg: var(--callout-amber-bg); }
  #content [data-callout-group="red"] { --callout-accent: var(--danger); --callout-bg: var(--callout-red-bg); }
  #content [data-callout-group="gray"] { --callout-accent: var(--muted); --callout-bg: var(--nav); }
  #content .callout-title {
    display: flex; align-items: center; gap: var(--s2);
    font-weight: 600; color: var(--callout-accent); font-size: var(--small);
  }
  #content .callout-title svg { width: var(--body); height: var(--body); flex: none; }
  #content details.callout > summary.callout-title { cursor: pointer; list-style: none; }
  #content details.callout > summary.callout-title::-webkit-details-marker { display: none; }
  #content details.callout > summary.callout-title::after {
    content: ''; margin-left: auto; width: 7px; height: 7px;
    border: solid currentColor; border-width: 0 1.7px 1.7px 0;
    transform: rotate(-45deg); transition: transform var(--ease, 180ms);
  }
  #content details.callout[open] > summary.callout-title::after { transform: rotate(45deg); }
  #content details.callout > summary.callout-title { margin-bottom: 0; }
  #content details.callout[open] > .callout-content { margin-top: var(--s2); }
  #content .callout-content > :last-child { margin-bottom: 0; }
  #content blockquote {
    margin: var(--s6) 0; padding: var(--s4) var(--s5);
    border-left: var(--focus) solid var(--blue); border-radius: 0 var(--small-r) var(--small-r) 0;
    background: var(--blue-soft); color: var(--ink); font-size: var(--small);
  }
  #content code {
    background: var(--nav); padding: var(--s1); border-radius: var(--s1);
    font-size: var(--small); font-family: var(--mono);
  }
  #content pre {
    background: var(--nav); padding: var(--s4); border-radius: var(--small-r);
    overflow: auto; margin: 0 0 var(--s5);
  }
  #content pre code { background: none; padding: 0; }
  #content .katex-display { overflow-x: auto; overflow-y: hidden; padding: var(--s1) 0; }
  #content .math-error, #content .mermaid-error {
    color: var(--muted); border-left: var(--focus) solid var(--blue);
    background: var(--blue-soft); padding: var(--s2) var(--s3); border-radius: var(--small-r);
  }
  #content .mermaid-block { overflow-x: auto; margin: 0 0 var(--s5); }
  #content .mermaid-source { display: none; }
  #content .mermaid-block svg { max-width: 100%; height: auto; }
  #content table {
    border-collapse: separate; border-spacing: 0; margin: 0 0 var(--s5);
    font-size: var(--caption); border: var(--stroke) solid var(--line);
    border-radius: var(--small-r); overflow: hidden; width: 100%;
  }
  #content th, #content td {
    border-bottom: var(--stroke) solid var(--line); border-right: var(--stroke) solid var(--line);
    padding: var(--s2) var(--s3); text-align: left;
  }
  #content th:last-child, #content td:last-child { border-right: none; }
  #content tbody tr:last-child td { border-bottom: none; }
  #content th { background: var(--nav); font-weight: 600; color: var(--ink); }
  #content hr { border: none; border-top: var(--stroke) solid var(--line); margin: var(--s8) 0; }
  #content img { max-width: 100%; border-radius: var(--small-r); }
  #content img.preview-local-image {
    display: block; max-height: var(--preview-image-max-height, none);
    width: auto; height: auto; object-fit: contain; cursor: zoom-in;
  }
  #content img.preview-local-image:focus-visible { outline: var(--focus) solid var(--blue); outline-offset: var(--s1); }
  .image-viewer {
    position: fixed; inset: 0; z-index: 10; display: flex; flex-direction: column;
    gap: var(--s3); padding: var(--s4); box-sizing: border-box;
    background: var(--image-viewer-bg);
  }
  .image-viewer.hidden { display: none; }
  .image-viewer-toolbar { display: flex; justify-content: flex-end; flex: none; }
  #image-viewer-close {
    min-height: var(--touch); padding: 0 var(--s3); border: var(--stroke) solid var(--line);
    border-radius: var(--small-r); background: var(--paper); color: var(--ink);
    font: inherit;
  }
  .image-viewer-scroll { flex: 1; min-height: 0; overflow: auto; overscroll-behavior: contain; }
  #image-viewer-full { display: block; max-width: 100%; width: auto; height: auto; margin: 0 auto; }
  #content a { color: var(--blue); text-decoration: none; }
  #content input[type="checkbox"] { accent-color: var(--blue); width: 15px; height: 15px; vertical-align: -2px; margin-right: var(--s1); }
  #content .empty { color: var(--muted); font-size: var(--small); text-align: center; margin-top: var(--s10); }
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
