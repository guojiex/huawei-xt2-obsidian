/*
 * AppUpdateCheckDevice.ets —— 应用内检测更新的设备层（v1.17 方向 A，@kit.AppGalleryKit 调用本体）。
 *
 * 2026-11-15 冷启动优化（XT2 trace）：updateManager（@kit.AppGalleryKit）属启动期未用模块
 * （82 个之一），从 AppUpdateCheck 拆到本文件，由 SettingsView 动态 import 加载 ——
 * 用户在关于页点「检查更新」时才拉起。检查 / 弹框流程与错误映射自 AppUpdateCheck 原样搬移，
 * 行为不变；接口结论仍以 docs/harmonyos/api_notes.md V 组为准（V1 / V4，均 ≤ API 24）。
 */

import { common } from '@kit.AbilityKit';
import { updateManager } from '@kit.AppGalleryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AppUpdateCheckOutcome, AppUpdateCheckStore, AppUpdateLastOutcome,
  classifyCheckError, cooldownActive, formatCheckClock
} from './AppUpdateCheck';

const UPDATE_CHECK_TAG: string = 'AppUpdateCheck';

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
