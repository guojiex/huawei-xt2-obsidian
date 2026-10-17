// 把 src 打包成单个 IIFE，并内联进 index.html。
// 为什么要内联：rawfile 目录下的相对路径引用在 Web 组件里不一定可用，
// 单文件可以避免 bundle.js 加载不到的风险。

import { build } from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, '../..')
const outDir = path.join(repoRoot, 'entry/src/main/resources/rawfile/gitbridge')
const tmpFile = path.join(here, '.bundle.tmp.js')

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
    global: 'window',
  },
  logLevel: 'info',
})

const code = fs.readFileSync(tmpFile, 'utf8')
fs.unlinkSync(tmpFile)

// 内联脚本里出现 </script 会提前闭合标签
const safe = code.replace(/<\/script/gi, '<\\/script')

const html = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>gitbridge</title>
</head>
<body>
<script>
${safe}
</script>
</body>
</html>
`

fs.mkdirSync(outDir, { recursive: true })
const outFile = path.join(outDir, 'index.html')
fs.writeFileSync(outFile, html, 'utf8')
console.log(`written ${outFile} (${(Buffer.byteLength(html, 'utf8') / 1024).toFixed(0)} KB)`)
