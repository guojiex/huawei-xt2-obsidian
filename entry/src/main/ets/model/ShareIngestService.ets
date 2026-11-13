/**
 * ShareIngestService.ets —— 接收系统分享的纯逻辑（v1.56）
 *
 * 为什么单独一层：EntryAbility 负责「拿 want → getSharedData → 转发」，Index 负责
 * 「弹确认层 → 落盘」，中间的载荷结构与「标题默认值 / 正文模板」规则是可单测的
 * 纯逻辑，放两边都会漂移。本文件**不 import 任何 SDK / UI**，保持 node 单测可用
 * （tools/tests/test_share_ingest.mjs 走 esbuild + vm，同 MarkdownInlineParser 惯例）。
 *
 * 转发机制（56.2 落码拍板）：EntryAbility → `AppStorage['incomingShare']`（JSON 字符串）
 * → Index `@StorageProp + @Watch` 消费。`receivedAt` 时间戳保证同内容两次分享也触发
 * @Watch（值变化）；消费后清空键，重复消费靠「空串守卫」挡住。
 *
 * 红线（v1.56 需求文档 56.5）：标题与内容不进埋点、不进日志；本文件不产生任何埋点。
 */

/** 分享载荷：EntryAbility 解析 SharedRecord 后的扁平结构。message 非空 = 错误载荷。 */
export interface ShareIngestPayload {
  utd: string;
  title: string;
  content: string;
  message: string;
  /** 接收时间戳（ms）；同时是同内容重复分享的 @Watch 触发 nonce。 */
  receivedAt: number;
}

/** 确认层默认草稿：标题（= 文件名，56.4）与正文模板。 */
export interface ShareIngestDraft {
  title: string;
  content: string;
}

export class ShareIngestService {
  /** UTD 穷举（56.1，module.json5 skills 里声明同一组）。 */
  static readonly UTD_TEXT: string = 'general.text';
  static readonly UTD_PLAIN_TEXT: string = 'general.plain-text';
  static readonly UTD_HYPERLINK: string = 'general.hyperlink';
  /** 分享动作名（56.1 skills / 56.2 双路径判据）。 */
  static readonly ACTION_SEND_DATA: string = 'ohos.want.action.sendData';
  /** EntryAbility → Index 的 AppStorage 键。 */
  static readonly STORAGE_KEY: string = 'incomingShare';

  static isTextLikeUtd(utd: string): boolean {
    return utd === ShareIngestService.UTD_TEXT ||
      utd === ShareIngestService.UTD_PLAIN_TEXT ||
      utd === ShareIngestService.UTD_HYPERLINK;
  }

  /** 错误载荷（解析抛错 / 无有效记录）：Index 侧 toast message，不弹确认层。 */
  static errorPayload(message: string, nowMs: number): ShareIngestPayload {
    const payload: ShareIngestPayload = {
      utd: 'error',
      title: '',
      content: '',
      message: message,
      receivedAt: nowMs
    };
    return payload;
  }

  /** JSON.parse 产物校验：字段类型全对才算合法载荷（防脏数据进 UI）。 */
  static isValidPayload(candidate: ShareIngestPayload): boolean {
    return typeof candidate.utd === 'string' && candidate.utd.length > 0 &&
      typeof candidate.title === 'string' &&
      typeof candidate.content === 'string' &&
      typeof candidate.message === 'string' &&
      typeof candidate.receivedAt === 'number';
  }

  /**
   * 确认层默认草稿（56.3）：
   * - 标题默认链：record.title 非空用之 → 链接取 URL 截 80 → 文本取正文首行
   *   （去空白，跳过空行）截 30 → 兜底「分享剪藏 yyyy-MM-dd HH:mm」；
   * - 正文模板：链接 `[title](url)`（title 与 url 相同则直接 url）；文本 content 原文。
   */
  static buildDraft(payload: ShareIngestPayload, nowMs: number): ShareIngestDraft {
    const isLink: boolean = payload.utd === ShareIngestService.UTD_HYPERLINK;
    const title: string = ShareIngestService.defaultTitle(payload, isLink, nowMs);
    let content: string = payload.content;
    if (isLink) {
      const recordTitle: string = payload.title.trim();
      if (recordTitle.length > 0 && recordTitle !== payload.content.trim()) {
        content = '[' + recordTitle + '](' + payload.content + ')';
      }
    }
    const draft: ShareIngestDraft = { title: title, content: content };
    return draft;
  }

  private static defaultTitle(payload: ShareIngestPayload, isLink: boolean, nowMs: number): string {
    const recordTitle: string = payload.title.trim();
    if (recordTitle.length > 0) {
      return recordTitle;
    }
    const content: string = payload.content.trim();
    if (content.length > 0) {
      if (isLink) {
        return ShareIngestService.clip(content, 80);
      }
      const lines: string[] = payload.content.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        if (line.length > 0) {
          return ShareIngestService.clip(line, 30);
        }
      }
    }
    return '分享剪藏 ' + ShareIngestService.formatClock(nowMs);
  }

  /** 硬截断（按 JS 字符即 UTF-16 码元；不补省略号，规则写死「截 N 字符」）。 */
  private static clip(text: string, max: number): string {
    if (text.length > max) {
      return text.substring(0, max);
    }
    return text;
  }

  /** ms → 「yyyy-MM-dd HH:mm」（兜底标题用；手工拼避免引 Intl 依赖）。 */
  private static formatClock(nowMs: number): string {
    const date: Date = new Date(nowMs);
    return ShareIngestService.pad2(date.getFullYear()) + '-' +
      ShareIngestService.pad2(date.getMonth() + 1) + '-' +
      ShareIngestService.pad2(date.getDate()) + ' ' +
      ShareIngestService.pad2(date.getHours()) + ':' +
      ShareIngestService.pad2(date.getMinutes());
  }

  private static pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }
}
