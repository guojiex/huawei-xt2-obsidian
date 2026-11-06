/*
 * AppUpdateCheck.ets —— 应用内检测更新（v1.17，方向 A）。
 *
 * 接口一律以 docs/harmonyos/api_notes.md V 组为准（V1 checkAppUpdate / V4 showUpdateDialog，
 * 均 @since 5.0.0(12) ≤ 24，Stage 专用，无权限要求）：
 *  - 结论只取 updateAvailable 的「有 / 无新版本」语义（V2）；不读 versionName / versionCode
 *    （V3 元服务专用字段，一律不读，不显示市场版本号、不做客户端版本比较）。
 *  - 有新版本时调系统升级弹框 showUpdateDialog 接管引导（V4），不自定义弹框、不拼市场跳转。
 *  - 失败按 V6 错误码至少区分四类：1009400003 网络、1009400004 不在前台、
 *    1009400005 未同意市场隐私协议、1009400006 限流；其余归通用失败，码值只进 hilog
 *    诊断日志，不弹原始码给用户。
 *  - 检查（checkAppUpdate）与弹框（showUpdateDialog）的抛错列表不同（V6：弹框列表不含
 *    1009400003），两个 catch 分支分开写，不共用一套错误映射。
 *
 * 冷却（D-3 已定）：5 分钟，跨会话持久化上次检查时间与结果（Preferences）。冷却值是应用内
 * 工程选择，不是官方承诺（V5：checkAppUpdate 官方限流阈值未记载，冷却期内点按不联网，
 * 直接显示上次结果）。仅由用户主动点击触发，无后台轮询、不因启动发起（D-2 / V5）。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { updateManager } from '@kit.AppGalleryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 界面阶段（对应原型关于页 updateDemoStates 的 8 态 + 系统弹框失败兜底态）。 */
export type AppUpdateUiPhase = 'idle' | 'checking' | 'available' | 'latest' |
  'network' | 'background' | 'privacy' | 'limited' | 'generic' | 'dialog_failed';

/**
 * 应用内冷却时长（D-3：5 分钟）。工程选择而非官方承诺（V5），须在真机观察。
 */
export const APP_UPDATE_COOLDOWN_MS: number = 5 * 60 * 1000;

const UPDATE_CHECK_TAG: string = 'AppUpdateCheck';

/** 冷却中点按显示的上次结果文案所需时钟（HH:MM）。 */
export function formatCheckClock(timestampMs: number): string {
  const date: Date = new Date(timestampMs);
  const hours: number = date.getHours();
  const minutes: number = date.getMinutes();
  const hoursText: string = hours < 10 ? '0' + hours.toString() : hours.toString();
  const minutesText: string = minutes < 10 ? '0' + minutes.toString() : minutes.toString();
  return hoursText + ':' + minutesText;
}

/** 冷却是否仍在生效（D-3：跨会话持久化的上次检查时间 + 5 分钟窗口）。 */
export function cooldownActive(lastCheckMs: number, nowMs: number): boolean {
  if (lastCheckMs <= 0) {
    return false;
  }
  return nowMs - lastCheckMs < APP_UPDATE_COOLDOWN_MS;
}

/**
 * V6 错误码 → 四类失败 + 通用。仅用于 checkAppUpdate 的 catch；
 * showUpdateDialog 的抛错列表不含 1009400003，弹框分支单独处理，不共用此映射。
 */
export function classifyCheckError(code: number): 'network' | 'background' | 'privacy' | 'limited' | 'generic' {
  if (code === 1009400003) {
    return 'network';
  }
  if (code === 1009400004) {
    return 'background';
  }
  if (code === 1009400005) {
    return 'privacy';
  }
  if (code === 1009400006) {
    return 'limited';
  }
  return 'generic';
}

/** 上次联网检查的结果（持久化值；available 时冷却期内点按直接再调系统弹框，不再联网检查）。 */
export type AppUpdateLastOutcome = 'latest' | 'available';

/** 冷却持久化（Preferences：'app_update_check'，键 lastCheckMs / lastOutcome）。 */
export class AppUpdateCheckStore {
  private static readonly PREF_NAME: string = 'app_update_check';
  private static readonly KEY_LAST_CHECK_MS: string = 'lastCheckMs';
  private static readonly KEY_LAST_OUTCOME: string = 'lastOutcome';
  private readonly store: preferences.Preferences | null;
  private readonly available: boolean;

  constructor(context: common.UIAbilityContext) {
    let opened: preferences.Preferences | null = null;
    let ok: boolean = false;
    try {
      opened = preferences.getPreferencesSync(context, { name: AppUpdateCheckStore.PREF_NAME });
      ok = opened !== null;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, UPDATE_CHECK_TAG, 'open store failed: %{public}d', err.code);
    }
    this.store = opened;
    this.available = ok;
  }

  isAvailable(): boolean {
    return this.available && this.store !== null;
  }

  loadLastCheckMs(): number {
    if (this.store === null) {
      return 0;
    }
    try {
      return this.store.getSync(AppUpdateCheckStore.KEY_LAST_CHECK_MS, 0) as number;
    } catch (error) {
      return 0;
    }
  }

  loadLastOutcome(): AppUpdateLastOutcome {
    if (this.store === null) {
      return 'latest';
    }
    try {
      const raw: string = this.store.getSync(AppUpdateCheckStore.KEY_LAST_OUTCOME, 'latest') as string;
      return raw === 'available' ? 'available' : 'latest';
    } catch (error) {
      return 'latest';
    }
  }

  saveOutcome(lastCheckMs: number, outcome: AppUpdateLastOutcome): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(AppUpdateCheckStore.KEY_LAST_CHECK_MS, lastCheckMs);
      this.store.putSync(AppUpdateCheckStore.KEY_LAST_OUTCOME, outcome);
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, UPDATE_CHECK_TAG, 'save outcome failed: %{public}d', err.code);
    }
  }
}

/** 一次检查动作的结果：界面阶段 + 冷却文案所需的上次检查时钟。 */
export interface AppUpdateCheckOutcome {
  phase: AppUpdateUiPhase;
  lastCheckClock: string;
}

/**
 * 执行一次检查（仅由用户主动点击触发，D-2）。
 * 流程：冷却判定（不联网）→ checkAppUpdate → 有更新则 showUpdateDialog 系统弹框接管。
 * 形参只有 context，应用侧不注入任何请求内容，笔记数据不可能进入该链路（V1）。
 */
export async function runAppUpdateCheck(context: common.UIAbilityContext,
  store: AppUpdateCheckStore): Promise<AppUpdateCheckOutcome> {
  const nowMs: number = Date.now();
  const lastCheckMs: number = store.loadLastCheckMs();
  const lastOutcome: AppUpdateLastOutcome = store.loadLastOutcome();
  // 冷却期内不联网（D-3）：上次是最新 → limited 文案；上次发现有更新 → 直接系统弹框再引导。
  if (cooldownActive(lastCheckMs, nowMs)) {
    if (lastOutcome === 'available') {
      return await showSystemUpdateDialog(context, store, lastCheckMs);
    }
    return { phase: 'limited', lastCheckClock: formatCheckClock(lastCheckMs) };
  }

  let result: updateManager.CheckUpdateResult;
  try {
    result = await updateManager.checkAppUpdate(context);
  } catch (error) {
    // 检查分支（V6 全集：401 / 1009400001–1009400007），四类分写，其余通用失败码值只进诊断日志。
    const err = error as BusinessError;
    hilog.warn(0x0000, UPDATE_CHECK_TAG, 'checkAppUpdate failed: %{public}d', err.code);
    return { phase: classifyCheckError(err.code), lastCheckClock: formatCheckClock(lastCheckMs) };
  }

  store.saveOutcome(nowMs, result.updateAvailable ===
    updateManager.UpdateAvailableCode.LATER_VERSION_EXIST ? 'available' : 'latest');

  // 只取「有 / 无新版本」语义（V2）；不读 versionName / versionCode（V3）。
  if (result.updateAvailable === updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
    return await showSystemUpdateDialog(context, store, nowMs);
  }
  // 无新版本：文案避免绝对承诺（未上架等场景无专用状态码，V6），附最近一次检查时钟。
  return { phase: 'latest', lastCheckClock: formatCheckClock(nowMs) };
}

/**
 * 系统升级弹框接管（V4）。弹框失败与弹框抛错都走兜底态：提示稍后重试或自行到
 * 应用市场操作（不能提供第三方下载路径）。此分支与检查分支分开（V6：弹框抛错
 * 列表不含 1009400003），不共用 classifyCheckError。
 */
async function showSystemUpdateDialog(context: common.UIAbilityContext, store: AppUpdateCheckStore,
  checkMs: number): Promise<AppUpdateCheckOutcome> {
  try {
    const dialogResult: updateManager.ShowUpdateResultCode = await updateManager.showUpdateDialog(context);
    if (dialogResult !== updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS) {
      hilog.warn(0x0000, UPDATE_CHECK_TAG, 'showUpdateDialog result: %{public}d', dialogResult);
      return { phase: 'dialog_failed', lastCheckClock: formatCheckClock(checkMs) };
    }
    return { phase: 'available', lastCheckClock: formatCheckClock(checkMs) };
  } catch (error) {
    const err = error as BusinessError;
    hilog.warn(0x0000, UPDATE_CHECK_TAG, 'showUpdateDialog failed: %{public}d', err.code);
    return { phase: 'dialog_failed', lastCheckClock: formatCheckClock(checkMs) };
  }
}
