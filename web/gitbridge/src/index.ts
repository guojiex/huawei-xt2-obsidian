// GitBridge —— 挂在 window 上供 ArkTS 调用的 git 能力入口。
// 运行位置：Web 组件（rawfile/gitbridge/index.html），只做计算，不依赖 DOM。

// isomorphic-git 的 StreamReader 强依赖 Buffer（见其源码注释 #1855），
// Web 组件里没有这个全局，必须注入 polyfill，否则一解析报文就抛
// "Missing Buffer dependency"。
import { Buffer } from 'buffer'

if (typeof (globalThis as any).Buffer === 'undefined') {
  ;(globalThis as any).Buffer = Buffer
}

import git from 'isomorphic-git'
import { BridgeFs } from './fsBridge'
import { createHttpClient } from './httpBridge'
import { emitEvent, onArktsMessage, onResult } from './channel'
import { jsonFromB64 } from './codec'

interface InitConfig {
  gitDir: string
  token: string
}

interface CloneArgs {
  url: string
  branch: string
  token: string
}

let fs: BridgeFs | null = null
let http: ReturnType<typeof createHttpClient> | null = null
let gitDir = '/vault'
let token = ''

function fail(e: any): string {
  const code = e?.code ? `${e.code}: ` : ''
  const stack = e?.stack
    ? `\n${String(e.stack).split('\n').slice(0, 6).join('\n')}`
    : ''
  return `${code}${e?.message ?? String(e)}${stack}`
}

const GitBridge = {
  /** ArkTS 在页面加载完成后下发配置 */
  async init(configB64: string): Promise<boolean> {
    const cfg = jsonFromB64<InitConfig>(configB64)
    gitDir = cfg.gitDir || '/vault'
    token = cfg.token || ''
    fs = new BridgeFs(gitDir)
    http = createHttpClient(token)
    return true
  },

  /**
   * 克隆仓库到 vault。异步结果通过事件回传（runJavaScript 拿不到 Promise 结果）。
   * 全程不使用 shallow clone：后续要做 commit/push，shallow 仓库推不回去。
   */
  async clone(argsB64: string): Promise<void> {
    try {
      const args = jsonFromB64<CloneArgs>(argsB64)
      if (!fs || !http) {
        throw new Error('EINIT: GitBridge 未初始化')
      }
      emitEvent('progress', { phase: 'preparing', loaded: 0, total: 0 })
      await git.clone({
        fs: fs as any,
        http: http as any,
        dir: gitDir,
        url: args.url,
        ref: args.branch || undefined,
        singleBranch: true,
        onAuth: () => ({ username: 'x-access-token', password: args.token || token }),
        onProgress: (p: any) => {
          emitEvent('progress', {
            phase: p?.phase ?? '',
            loaded: p?.loaded ?? 0,
            total: p?.total ?? 0,
          })
        },
      })
      await fs.flush()
      emitEvent('cloneResult', { ok: true, message: 'clone 完成' })
    } catch (e) {
      emitEvent('cloneResult', { ok: false, message: fail(e) })
    }
  },

  /** 强制落盘（调试用） */
  async flush(): Promise<void> {
    if (fs) {
      await fs.flush()
    }
  },
}

const w = window as any
w.GitBridge = GitBridge
w.__gitBridge = { onResult, onArktsMessage }
w.__gitBridgeReady = true
