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
  username: string
}

interface CloneArgs {
  url: string
  branch: string
  token: string
  username: string
}

let fs: BridgeFs | null = null
let http: ReturnType<typeof createHttpClient> | null = null
let gitDir = '/vault'
let token = ''
let username = ''

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
    username = cfg.username || ''
    fs = new BridgeFs(gitDir)
    http = createHttpClient(token, username)
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
      // clone 可以带自己的凭据（页面上临时改的情况）
      const authToken = args.token || token
      const authUser = args.username || username
      http = createHttpClient(authToken, authUser)
      emitEvent('progress', { phase: 'preparing', loaded: 0, total: 0 })
      await git.clone({
        fs: fs as any,
        http: http as any,
        dir: gitDir,
        url: args.url,
        ref: args.branch || undefined,
        singleBranch: true,
        // GitHub 的 username 可任意填；Gitee 必须是真实用户名
        onAuth: () => ({ username: authUser || 'x-access-token', password: authToken }),
        onProgress: (p: any) => {
          emitEvent('progress', {
            phase: p?.phase ?? '',
            loaded: p?.loaded ?? 0,
            total: p?.total ?? 0,
          })
        },
      })
      await fs.flush()
      await this.verifyCloneOnDisk()
      emitEvent('cloneResult', { ok: true, message: 'clone 完成' })
    } catch (e) {
      const readError = fs?.lastReadError || ''
      const details = readError.length > 0 ? `\n${readError}` : ''
      emitEvent('cloneResult', { ok: false, message: fail(e) + details })
    }
  },

  /** 强制落盘（调试用） */
  async flush(): Promise<void> {
    if (fs) {
      await fs.flush()
    }
  },

  /** Clone 只有从磁盘重新读取后仍是干净仓库，才向 ArkTS 报成功并允许登记。 */
  async verifyCloneOnDisk(): Promise<void> {
    if (!fs) {
      throw new Error('EINIT: GitBridge 未初始化')
    }
    await git.resolveRef({ fs: fs as any, dir: gitDir, ref: 'HEAD' })
    const matrix = await git.statusMatrix({ fs: fs as any, dir: gitDir })
    let dirtyCount = 0
    for (const entry of matrix) {
      if (entry[1] !== 1 || entry[2] !== 1 || entry[3] !== 1) {
        dirtyCount++
      }
    }
    if (dirtyCount > 0) {
      throw new Error(`EVERIFY: clone checkout is not clean (${dirtyCount} path(s))`)
    }
  },
}

const w = window as any
w.GitBridge = GitBridge
w.__gitBridge = { onResult, onArktsMessage }
w.__gitBridgeReady = true
