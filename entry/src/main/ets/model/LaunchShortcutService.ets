/**
 * LaunchShortcutService.ets —— 应用图标静态快捷方式的纯逻辑（v2.0）
 *
 * 机制（api_notes AO1 / AO3）：`shortcuts_config.json` 声明 new_note / search 两条
 * 静态快捷方式（桌面长按图标弹出，X 键编辑界面自动接入），`wants[].parameters`
 * 随 Want 到达 EntryAbility 的 onCreate / onNewWant。转发沿用 v1.56 分享链路
 * （ShareIngestService）的 AppStorage + receivedAt 时间戳 nonce 范式：
 * EntryAbility 写 `AppStorage['launchShortcut']`（JSON 字符串），Index
 * `@StorageProp + @Watch` 消费、早到由 aboutToAppear 兜底，消费后清空键防重复。
 *
 * 本文件不 import 任何 SDK / UI，保持 node 单测可用
 * （tools/tests/test_launch_shortcut.mjs 走 esbuild + vm，同 ShareIngestService 惯例）。
 *
 * 红线：不产生任何埋点；动作值不是笔记内容，可进日志。
 */

/** 快捷方式载荷：EntryAbility 解析 shortcuts want 后的转发结构。 */
export interface LaunchShortcutPayload {
  /** 动作标识（= shortcuts_config.json 的 shortcutId / wants 参数值）。 */
  action: string;
  /** 触发时间戳（ms）；同时是同动作重复点击的 @Watch 触发 nonce。 */
  receivedAt: number;
}

export class LaunchShortcutService {
  /** 动作：新建笔记（打开新建笔记对话框，与侧栏「＋」同链）。 */
  static readonly ACTION_NEW_NOTE: string = 'new_note';
  /** 动作：搜索（打开快切搜索，与侧栏搜索同链）。 */
  static readonly ACTION_SEARCH: string = 'search';
  /** shortcuts_config.json wants[].parameters 的键。 */
  static readonly WANT_PARAM_KEY: string = 'yaoshi_shortcut';
  /** EntryAbility → Index 的 AppStorage 键。 */
  static readonly STORAGE_KEY: string = 'launchShortcut';

  static isKnownAction(action: string): boolean {
    return action === LaunchShortcutService.ACTION_NEW_NOTE ||
      action === LaunchShortcutService.ACTION_SEARCH;
  }

  /**
   * 从 want.parameters 取快捷方式动作：非字符串 / 未知动作返回空串
   * （= 普通启动等非快捷方式来源，调用方零行为变化）。
   */
  static actionFromParameters(parameters: Record<string, Object> | undefined): string {
    if (parameters === undefined || parameters === null) {
      return '';
    }
    const candidate: Object | undefined = parameters[LaunchShortcutService.WANT_PARAM_KEY];
    if (typeof candidate !== 'string') {
      return '';
    }
    const action: string = candidate;
    if (!LaunchShortcutService.isKnownAction(action)) {
      return '';
    }
    return action;
  }

  static buildPayload(action: string, nowMs: number): LaunchShortcutPayload {
    const payload: LaunchShortcutPayload = { action: action, receivedAt: nowMs };
    return payload;
  }

  /** JSON.parse 产物校验：动作已知 + 时间戳为数字才算合法载荷（防脏数据进 UI）。 */
  static isValidPayload(candidate: LaunchShortcutPayload): boolean {
    return typeof candidate.action === 'string' &&
      LaunchShortcutService.isKnownAction(candidate.action) &&
      typeof candidate.receivedAt === 'number';
  }
}
