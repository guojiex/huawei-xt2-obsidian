// isomorphic-git 的自定义 http client。
//
// 为什么必须自定义：github.com 的 git 服务端点（info/refs、git-upload-pack）
// 不返回 CORS 头，WebView 内的 fetch 会被同源策略拦掉。
// 这里把请求转发给 ArkTS 的原生 @ohos.net.http，天然不受 CORS 限制。

import { b64FromBytes, b64FromJson, bytesFromB64 } from './codec'
import { request } from './channel'

export interface GitHttpRequest {
  url: string
  method?: string
  headers?: Record<string, string>
  body?: Uint8Array | AsyncIterable<Uint8Array> | undefined
}

interface RawResponse {
  url: string
  method: string
  headers: Record<string, string>
  bodyB64: string
  status: number
  statusMessage: string
}

async function collectBody(body: GitHttpRequest['body']): Promise<Uint8Array | undefined> {
  if (!body) {
    return undefined
  }
  if (body instanceof Uint8Array) {
    return body
  }
  // push 时 isomorphic-git 可能传异步迭代器
  const chunks: Uint8Array[] = []
  for await (const chunk of body as AsyncIterable<Uint8Array>) {
    chunks.push(chunk)
  }
  const total = chunks.reduce((n, c) => n + c.length, 0)
  const merged = new Uint8Array(total)
  let offset = 0
  for (const c of chunks) {
    merged.set(c, offset)
    offset += c.length
  }
  return merged
}

// isomorphic-git 用 StreamReader 消费响应体，它会优先走 Symbol.asyncIterator。
// 直接给 Uint8Array 会被当成「逐字节迭代」（Uint8Array 自带 Symbol.iterator），
// 结果是拼不出完整报文、报 EmptyServerResponseError。必须包成块迭代器。
function toStream(bytes: Uint8Array): AsyncIterable<Uint8Array> {
  return (async function* () {
    yield bytes
  })()
}

export function createHttpClient(token: string) {
  return {
    async request({ url, method, headers, body }: GitHttpRequest) {
      const bodyBytes = await collectBody(body)
      const mergedHeaders: Record<string, string> = {
        'User-Agent': 'git/isomorphic-git (harmony-obsidian)',
        ...(headers || {}),
      }
      if (token) {
        mergedHeaders['Authorization'] = `Bearer ${token}`
      }

      // channel.onResult 已解过 base64，这里直接拿到解析后的对象
      const parsed = await request<RawResponse>('http', {
        url,
        method: method || 'GET',
        headers: mergedHeaders,
        bodyB64: bodyBytes ? b64FromBytes(bodyBytes) : undefined,
      })
      return {
        url: parsed.url || url,
        method: method || 'GET',
        headers: parsed.headers || {},
        body: toStream(parsed.bodyB64 ? bytesFromB64(parsed.bodyB64) : new Uint8Array(0)),
        statusCode: parsed.status,
        statusMessage: parsed.statusMessage || '',
      }
    },
  }
}

export function encodeJson(value: unknown): string {
  return b64FromJson(value)
}
