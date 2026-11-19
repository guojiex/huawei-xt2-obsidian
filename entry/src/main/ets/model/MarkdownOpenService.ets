/**
 * MarkdownOpenService.ets —— v1.89：无库只读打开单个 Markdown 文件的纯逻辑层。
 *
 * 与设备 I/O、UI 无关，可被 Node 直接单测（同 ShareIngestService 惯例）。
 * 职责：
 * - 常量（action / AppStorage 键 / 大小上限 / 状态）；
 * - want 判定与文件名解析；
 * - 载荷 JSON 序列化 / 反序列化（AppStorage nonce 通道）；
 * - 大小超限判定与截断策略。
 *
 * 设备层（fileIo 读临时授权 URI）在 MarkdownOpenDevice.ets，由 Ability 动态 import；
 * 只读预览页在 MarkdownFileOpenPage.ets。三层都不碰 VaultRegistry / 笔记库（89.4「不需要笔记库」）。
 */
export class MarkdownOpenService {
  /** 文件打开 action（官方 wantConstant ACTION_VIEW_DATA，api_notes AF6）。 */
  static readonly ACTION_VIEW_DATA: string = 'ohos.want.action.viewData';
  /** AppStorage 载荷键；value 为 JSON 字符串，receivedAt nonce 保证同文件重复打开也触发 @Watch。 */
  static readonly STORAGE_KEY: string = 'markdownFileOpen';
  /** 防御性大小上限：2 MiB。超限不整篇读进内存，按 MAX_PREVIEW_BYTES 截断并提示（89.3）。 */
  static readonly MAX_FILE_BYTES: number = 2 * 1024 * 1024;
  /** 超限预览前 512 KiB，足以覆盖绝大多数正文且不撑爆 Web 桥 base64 载荷。 */
  static readonly MAX_PREVIEW_BYTES: number = 512 * 1024;

  static readonly STATE_OK: string = 'ok';
  static readonly STATE_ERROR: string = 'error';
  static readonly STATE_TRUNCATED: string = 'truncated';

  /** 只处理 viewData action；其余 want（桌面启动 / sendData 分享 / 调试直达）一律返回 false。 */
  static isViewDataAction(action: string | undefined): boolean {
    return action === MarkdownOpenService.ACTION_VIEW_DATA;
  }

  /**
   * 从 URI 末段解析来源文件名（URL decode，失败兜底原串）。
   * 只取路径最后一段、去掉 query；不把 URI 当本地路径拼（硬约束 14）。
   */
  static fileNameFromUri(uri: string): string {
    if (uri.length === 0) {
      return '未命名.md';
    }
    const withoutQuery: string = uri.split('?')[0].split('#')[0];
    const segments: string[] = withoutQuery.split('/');
    const last: string = segments.length > 0 ? segments[segments.length - 1] : '';
    if (last.length === 0) {
      return '未命名.md';
    }
    try {
      return decodeURIComponent(last);
    } catch (_error) {
      return last;
    }
  }

  /** 超限判定：size 为 null（未知大小）时按不超限处理，由设备层保证不读超上限。 */
  static isOverLimit(size: number | null): boolean {
    return size !== null && size > MarkdownOpenService.MAX_FILE_BYTES;
  }

  /**
   * 从 UTF-8 字节流里截出不超过 maxBytes 的安全前缀（尽量不切断多字节字符）。
   * 用 TextDecoder 前的字节数组裁剪，避免半个汉字变成替换符。
   */
  static truncateUtf8Bytes(bytes: Uint8Array, maxBytes: number): Uint8Array {
    if (bytes.byteLength <= maxBytes) {
      return bytes;
    }
    let end: number = Math.max(0, Math.min(maxBytes, bytes.byteLength));
    // 回退到 UTF-8 字符边界：跳过 10xxxxxx 的续字节（0x80..0xBF）。
    while (end > 0 && (bytes[end] & 0xC0) === 0x80) {
      end--;
    }
    return bytes.subarray(0, end);
  }

  /** 构造载荷并写入 JSON（调用方 setOrCreate 到 AppStorage）。 */
  static serialize(payload: MarkdownOpenPayload): string {
    return JSON.stringify(payload);
  }

  /** 从 AppStorage JSON 还原载荷；解析失败返回 null（页面侧兜错误态）。 */
  static deserialize(json: string): MarkdownOpenPayload | null {
    if (json.length === 0) {
      return null;
    }
    try {
      const parsed: MarkdownOpenPayload = JSON.parse(json) as MarkdownOpenPayload;
      if (parsed === null || typeof parsed !== 'object' ||
        (parsed.state !== MarkdownOpenService.STATE_OK &&
          parsed.state !== MarkdownOpenService.STATE_ERROR &&
          parsed.state !== MarkdownOpenService.STATE_TRUNCATED) ||
        typeof parsed.receivedAt !== 'number' || typeof parsed.fileName !== 'string') {
        return null;
      }
      return parsed;
    } catch (_error) {
      return null;
    }
  }

  /** 错误载荷：不写文件名以外的路径、不写底层异常正文（硬约束 16）。 */
  static errorPayload(fileName: string, message: string, receivedAt: number): MarkdownOpenPayload {
    return {
      state: MarkdownOpenService.STATE_ERROR,
      fileName: fileName,
      content: '',
      message: message,
      receivedAt: receivedAt
    };
  }

  /** 成功载荷；truncated 时 state=truncated 且 content 为安全前缀。 */
  static contentPayload(fileName: string, content: string, truncated: boolean,
    receivedAt: number): MarkdownOpenPayload {
    return {
      state: truncated ? MarkdownOpenService.STATE_TRUNCATED : MarkdownOpenService.STATE_OK,
      fileName: fileName,
      content: content,
      message: truncated
        ? `文件超过 ${MarkdownOpenService.MAX_FILE_BYTES / 1024 / 1024} MB，仅预览前 ${MarkdownOpenService.MAX_PREVIEW_BYTES / 1024} KB`
        : '',
      receivedAt: receivedAt
    };
  }
}

/** 只读打开载荷（AppStorage 通道，页面 @Watch 消费）。 */
export interface MarkdownOpenPayload {
  state: string;
  fileName: string;
  content: string;
  message: string;
  receivedAt: number;
}
