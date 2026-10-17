// JS(WebView) <-> ArkTS 通信通道。
//   JS -> ArkTS： window.__arkts.postMessage(jsonString)   （javaScriptProxy 注入）
//   ArkTS -> JS： window.__gitBridge.onResult(id, ok, payloadB64)  （runJavaScript 调用）
// payload 一律是 JSON 文本再做一次 base64，从而不含引号/换行/特殊字符，避免脚本注入与转义问题。

import { jsonFromB64 } from './codec'

export interface Pending {
  resolve: (value: any) => void
  reject: (error: Error) => void
}

let seq = 0
const pending = new Map<number, Pending>()

const listeners: ((event: any) => void)[] = []

export function onArktsEvent(fn: (event: any) => void): void {
  listeners.push(fn)
}

function emit(event: any): void {
  for (const fn of listeners) {
    try {
      fn(event)
    } catch (e) {
      // 监听器异常不应影响主流程
      void e
    }
  }
}

/** 发送一个请求并等待 ArkTS 回包 */
export function request<T>(type: string, payload: Record<string, unknown>): Promise<T> {
  const id = ++seq
  return new Promise<T>((resolve, reject) => {
    pending.set(id, { resolve, reject })
    send({ id, type, ...payload })
  })
}

/** 单向事件（进度、日志、结果上报），不等待回包 */
export function emitEvent(name: string, payload: Record<string, unknown> = {}): void {
  send({ type: 'event', name, ...payload })
}

function send(msg: Record<string, unknown>): void {
  const w = window as any
  if (!w.__arkts || typeof w.__arkts.postMessage !== 'function') {
    const err = new Error('ArkTS bridge not ready')
    ;(err as any).code = 'EBRIDGE'
    throw err
  }
  w.__arkts.postMessage(JSON.stringify(msg))
}

/** ArkTS 回包入口：ArkTS 侧通过 runJavaScript 调用本函数 */
export function onResult(id: number, ok: boolean, payloadB64: string): void {
  const p = pending.get(id)
  if (!p) {
    return
  }
  pending.delete(id)
  if (!ok) {
    const err = new Error(payloadB64 ? jsonFromB64<string>(payloadB64) : 'unknown error') as any
    // ArkTS 侧会把 errno 放进 payload，形如 "ENOENT: ..."
    const text: string = String(err.message || '')
    const m = /^([A-Z]+):/.exec(text)
    err.code = m ? m[1] : 'EIO'
    p.reject(err)
    return
  }
  try {
    p.resolve(jsonFromB64(payloadB64))
  } catch (e) {
    p.reject(e as Error)
  }
}

/** ArkTS 侧主动下发事件（如初始化配置） */
export function onArktsMessage(event: any): void {
  emit(event)
}

export function createError(code: string, message: string): Error {
  const e = new Error(`${code}: ${message}`) as any
  e.code = code
  return e
}
