/** Encode UTF-8 text as base64 for Web↔ArkTS bridge arguments. */
export function encodeUtf8ToBase64(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let binary = ''
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary)
}

/** Decode base64 bridge data as UTF-8 text. */
export function decodeBase64ToUtf8(base64: string): string {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  // ignoreBOM:true —— 无损解码（2026-11-15 BOM 误报修复）：保留开头 U+FEFF，
  // 桥接内容与 ArkTS 侧字节完全一致；等价性豁免由上层统一处理。
  return new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes)
}
