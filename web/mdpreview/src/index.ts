/**
 * mdpreview/src/index.ts —— M3：Web 组件内的 Markdown 预览渲染器（marked）。
 *
 * 打包：esbuild → 单文件 IIFE → 内联进 index.html → rawfile/mdpreview/index.html
 *      （与 web/mdeditor 同款链路，AGENTS.md §Web 打包约定：改了 src 必须重跑 build）
 *
 * 桥接协议（对称于 mdeditor，方向相反为主）：
 *   ArkTS → Web：window.__mdpreview.setContent(b64) / setNoteDir(b64) / setTheme(t)
 *   Web → ArkTS：window.__arkts.readAsset(b64 relPath) → data URI（同步返回，本地图片用）
 *
 * 本地图片渲染（3.1 的「图片」项）：vault 沙箱里的相对图片引用无法被 WebView 直接加载
 * （resource://rawfile 页面拿不到沙箱文件，api_notes B4：ArkWeb 禁 file/resource 跨域），
 * 所以渲染后对每个 <img> 走一遍 JS→ArkTS 同步桥：readAsset(库内相对路径) → data URI。
 * 网络图片（http/https/data 开头）不走过桥，直接交给 WebView 自己加载。
 */

import { marked } from 'marked'

declare global {
  interface Window {
    __mdpreview: MdPreviewApi
    __arkts?: { readAsset?: (relB64: string) => string }
  }
}

/** 给 ArkTS 侧看的 API 面（setContent/setNoteDir 走 base64，避免引号/换行转义地狱） */
interface MdPreviewApi {
  setContent(b64: string): void
  setNoteDir(b64: string): void
  setTheme(theme: string): void
}

// ---------- base64（浏览器侧，处理 UTF-8，与 mdeditor 同款） ----------
function b64encode(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let bin = ''
  for (let i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i])
  }
  return btoa(bin)
}

function b64decode(b64: string): string {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) {
    bytes[i] = bin.charCodeAt(i)
  }
  return new TextDecoder().decode(bytes)
}

/** 库内相对路径拼接：'docs' + 'img/a.png' → 'docs/img/a.png'；允许 src 自带 'a/../b' 归一 */
function joinVaultPath(dir: string, src: string): string {
  const base = dir.length > 0 ? dir + '/' + src : src
  const segs: string[] = []
  for (const seg of base.split('/')) {
    if (seg === '' || seg === '.') {
      continue
    }
    if (seg === '..') {
      segs.pop()
      continue
    }
    segs.push(seg)
  }
  return segs.join('/')
}

/** 当前笔记所在目录（库内相对，'' = 根目录）—— 相对图片引用的解析基准 */
let noteDir = ''

/**
 * 渲染后处理 <img>：本地相对引用 → __arkts.readAsset 换成 data URI。
 * ⚠️ 必须挂在对象上直接调用（mdeditor L-4 踩坑：detach 调用会被桥接接收者校验拒绝），
 * 所以这里写 `window.__arkts.readAsset(...)` 而不是先取出来再调。
 */
function localizeImages(root: HTMLElement): void {
  const imgs = root.querySelectorAll('img')
  for (let i = 0; i < imgs.length; i++) {
    const img = imgs[i] as HTMLImageElement
    const src = img.getAttribute('src') ?? ''
    if (src.length === 0 || /^(https?:|data:|blob:)/i.test(src)) {
      continue
    }
    const rel = joinVaultPath(noteDir, src)
    try {
      const arkts = window.__arkts
      if (arkts && typeof arkts.readAsset === 'function') {
        const dataUri = arkts.readAsset(b64encode(rel))
        if (dataUri.length > 0) {
          img.src = dataUri
        } else {
          img.alt = src + '（图片不存在）'
        }
      }
    } catch (error) {
      console.log('[mdpreview] readAsset threw: ' + String(error))
    }
  }
}

marked.setOptions({ gfm: true, breaks: false })

const api: MdPreviewApi = {
  setContent(b64: string): void {
    const text = b64decode(b64)
    const el = document.getElementById('content') as HTMLElement
    if (text.trim().length === 0) {
      el.innerHTML = '<div class="empty">空笔记</div>'
      console.log('[mdpreview] setContent: empty')
      return
    }
    el.innerHTML = marked.parse(text) as string
    localizeImages(el)
    console.log('[mdpreview] setContent len=' + text.length)
  },

  setNoteDir(b64: string): void {
    noteDir = b64decode(b64)
  },

  setTheme(theme: string): void {
    document.documentElement.setAttribute('data-theme', theme === 'dark' ? 'dark' : 'light')
  }
}

window.__mdpreview = api
console.log('[mdpreview] script loaded')
