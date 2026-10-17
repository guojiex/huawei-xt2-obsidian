// 桥接层统一用 base64 传输：路径可能是中文，内容可能是二进制（packfile），
// base64 可以彻底避开 JSON / JS 字符串转义与编码问题。

const encoder = new TextEncoder()
const decoder = new TextDecoder()

export function b64FromBytes(bytes: Uint8Array): string {
  let bin = ''
  const CHUNK = 0x8000
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(bin)
}

export function bytesFromB64(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) {
    out[i] = bin.charCodeAt(i)
  }
  return out
}

export function b64FromText(text: string): string {
  return b64FromBytes(encoder.encode(text))
}

export function textFromB64(b64: string): string {
  return decoder.decode(bytesFromB64(b64))
}

export function b64FromJson(value: unknown): string {
  return b64FromText(JSON.stringify(value))
}

export function jsonFromB64<T>(b64: string): T {
  return JSON.parse(textFromB64(b64)) as T
}
