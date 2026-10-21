/**
 * BridgeCodec.ets —— Web 桥接 base64 编解码助手。
 *
 * ⚠️ 踩坑（2026-10-18 模拟器实测）：`util.Base64Helper` 的 encodeToStringSync /
 * decodeSync 对**空输入**抛 `Parameter error. The type of Parameter must be
 * string and the length greater than 0` —— 空笔记（0 字文件）是常态，编解码必须
 * 让空串直通，否则「加载空笔记 / 保存空编辑器」整条链路断掉。
 */
import { util } from '@kit.ArkTS';

export class BridgeCodec {
  private static base64: util.Base64Helper = new util.Base64Helper();
  private static encoder: util.TextEncoder = new util.TextEncoder();

  /** UTF-8 文本 → base64；空串返回空串（Web 侧 b64decode('') === ''，语义一致） */
  static encode(text: string): string {
    if (text.length === 0) {
      return '';
    }
    return BridgeCodec.base64.encodeToStringSync(BridgeCodec.encoder.encodeInto(text));
  }

  /** base64 → UTF-8 文本；空串返回空串 */
  static decode(b64: string): string {
    if (b64.length === 0) {
      return '';
    }
    return new util.TextDecoder().decodeToString(BridgeCodec.base64.decodeSync(b64));
  }
}
