/*
 * UiTestHelpers.ets —— UI 自动化测试公共辅助。
 *
 * 定位与约定见 docs/testing/UI自动化测试.md：
 * - UI 测试是质量保障资产，不占版本需求；用例只覆盖 x86 模拟器可达的冒烟子集。
 * - 等待只信控件树（waitForComponent），不信截图（api_notes L-8 白屏幻觉坑）。
 * - 默认等待 15s：x86 模拟器渲染慢；撤销条只停 5 秒，用 SNACK_MS 短超时。
 */

import { Driver, ON, Component, MatchPattern, Rect } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Want } from '@kit.AbilityKit';

/** 被测应用（AGENTS.md：包名 com.jxg.huaweiobsidian） */
const MAIN_BUNDLE: string = 'com.jxg.huaweiobsidian';
const MAIN_ABILITY: string = 'EntryAbility';

/** 默认等待：x86 模拟器整树匹配慢（实测一次成功匹配可花 ~12s），30s 才有余量 */
export const WAIT_MS: number = 30000;
/** 撤销条只停留 5 秒（Index UndoBar），等它必须用短超时 */
export const SNACK_MS: number = 4000;

let driverCache: Driver | null = null;
let nameSeq: number = 0;

export async function getDriver(): Promise<Driver> {
  if (driverCache === null) {
    driverCache = await Driver.create();
  }
  return driverCache;
}

/** 拉起主应用（已在前台时系统去重，幂等） */
export async function launchMainApp(): Promise<void> {
  const want: Want = {
    bundleName: MAIN_BUNDLE,
    abilityName: MAIN_ABILITY
  };
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility(want);
}

/** 测试数据唯一名：uitest 前缀 + 时间戳 + 序号（docs/testing 约定，不写真实笔记内容） */
export function uniqueUiName(prefix: string): string {
  nameSeq++;
  return prefix + '_' + Date.now().toString() + '_' + nameSeq.toString();
}

export async function waitById(driver: Driver, id: string, timeoutMs: number = WAIT_MS): Promise<Component> {
  // waitForComponent 超时不抛错而是返回 null（实测），必须判空转成清晰错误
  const comp: Component | null = await driver.waitForComponent(ON.id(id), timeoutMs);
  if (comp === null) {
    throw new Error('UiTest 等待超时: 未找到 id=' + id + ' (' + timeoutMs.toString() + 'ms)');
  }
  return comp;
}

/** waitById 的不抛错版（重试循环里判定进度用） */
export async function waitByIdSoft(driver: Driver, id: string, timeoutMs: number): Promise<boolean> {
  const comp: Component | null = await driver.waitForComponent(ON.id(id), timeoutMs);
  return comp !== null;
}

/** waitById 的组件版判空：超时返回 null（重试循环里拿到组件继续操作时用） */
export async function tryWaitById(driver: Driver, id: string, timeoutMs: number): Promise<Component | null> {
  return await driver.waitForComponent(ON.id(id), timeoutMs);
}

export async function waitByText(driver: Driver, txt: string, timeoutMs: number = WAIT_MS): Promise<Component> {
  const comp: Component | null = await driver.waitForComponent(ON.text(txt), timeoutMs);
  if (comp === null) {
    throw new Error('UiTest 等待超时: 未找到 text=' + txt + ' (' + timeoutMs.toString() + 'ms)');
  }
  return comp;
}

export async function waitByTextContains(driver: Driver, txt: string,
  timeoutMs: number = WAIT_MS): Promise<Component> {
  const comp: Component | null = await driver.waitForComponent(ON.text(txt, MatchPattern.CONTAINS), timeoutMs);
  if (comp === null) {
    throw new Error('UiTest 等待超时: 未找到 contains=' + txt + ' (' + timeoutMs.toString() + 'ms)');
  }
  return comp;
}

/** waitByTextContains 的不抛错版（超时返回 false） */
export async function waitByTextContainsSoft(driver: Driver, txt: string,
  timeoutMs: number = WAIT_MS): Promise<boolean> {
  const comp: Component | null = await driver.waitForComponent(ON.text(txt, MatchPattern.CONTAINS), timeoutMs);
  return comp !== null;
}

export async function clickById(driver: Driver, id: string, timeoutMs: number = WAIT_MS): Promise<void> {
  const comp: Component = await waitById(driver, id, timeoutMs);
  await comp.click();
}

export async function clickByText(driver: Driver, txt: string, timeoutMs: number = WAIT_MS): Promise<void> {
  const comp: Component = await waitByText(driver, txt, timeoutMs);
  await comp.click();
}

/** 组件当前是否存在（不存在不抛错；反向断言与轮询用） */
export async function existsById(driver: Driver, id: string): Promise<boolean> {
  try {
    await driver.assertComponentExist(ON.id(id));
    return true;
  } catch (error) {
    return false;
  }
}

export async function existsByText(driver: Driver, txt: string): Promise<boolean> {
  try {
    await driver.assertComponentExist(ON.text(txt));
    return true;
  } catch (error) {
    return false;
  }
}

/** 等某 id 的组件消失（弹窗关闭、菜单收起等）；超时返回 false */
export async function waitGoneById(driver: Driver, id: string, timeoutMs: number = WAIT_MS): Promise<boolean> {
  const deadline: number = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!await existsById(driver, id)) {
      return true;
    }
    await driver.delayMs(300);
  }
  return !await existsById(driver, id);
}

/** 等某文案的组件消失；超时返回 false */
export async function waitGoneByText(driver: Driver, txt: string, timeoutMs: number = WAIT_MS): Promise<boolean> {
  const deadline: number = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!await existsByText(driver, txt)) {
      return true;
    }
    await driver.delayMs(300);
  }
  return !await existsByText(driver, txt);
}

/**
 * 把侧栏文件树滚回顶部（顶行重新进入 LazyForEach 视口 / a11y 树）。
 * 前序套件的滚动残留会把树停在下方：顶行（00_开始/快速上手）离开 a11y 树后，
 * 依赖它的探针全部落空（20261111_232952 全量：UiNoteFlow 滚树后 UiSmDrawer 2 ERROR
 * + UiShare 9 ERROR 同签名；实验 .local/uitest/exp_d2/d3 实证滚动后顶行 0 命中）。
 * 手指向下拖 = 内容上移 = 顶行露出（与 UiNoteFlow trash 滚动注释同一套语义，
 * uitest uiInput swipe 实测校准）。侧栏不可见时锚点缺失，静默跳过（调用方负责侧栏可见性）。
 * ⚠️ 起点必须落在树行区内（按钮底 + 300）：+100 的空隙点实测完全不触发滚动
 * （exp2_e/f 对照实验，20261112——002604 run 17 ERROR 的根因）。
 * 轮数 5：单次 ~600px，5 次 3000px 覆盖满滚到底（~2500px）的最坏污染态，顶部余量只会回弹。
 */
export async function scrollSidebarToTop(driver: Driver, rounds: number = 5): Promise<void> {
  // 按钮恒可见，但匹配本身可花 2~12s（见头注）——窗口太短会把「按钮在」误判成
  // 「侧栏不在」静默跳过滚动，下游探针全部落空（005414 校准：2s 必失败、5s 实证够用）
  const btn: Component | null = await tryWaitById(driver, 'vault-sidebar-new-note', 6000);
  if (btn === null) {
    return;
  }
  const r: Rect = await btn.getBounds();
  const sx: number = Math.round((r.left + r.right) / 2);
  for (let i: number = 0; i < rounds; i++) {
    await driver.swipe(sx, r.bottom + 300, sx, r.bottom + 900);
    await driver.delayMs(400);
  }
}

/** 确保侧栏可见（依赖侧栏内控件的用例前置）：
 *  md/lg 收起态下侧栏整体隐藏（汉堡 = toggle），先点开再找；
 *  sm 单屏侧栏常驻，控件在则跳过。会话恢复出的收起态曾让侧栏用例超时（2026-11-07 实测）。 */
export async function ensureSidebarVisible(driver: Driver): Promise<void> {
  for (let i: number = 0; i < 3; i++) {
    if (await existsById(driver, 'vault-switcher-trigger')) {
      return;
    }
    await clickById(driver, 'workspace-navigation-button');
    if (await waitByIdSoft(driver, 'vault-switcher-trigger', 8000)) {
      return;
    }
  }
  await waitById(driver, 'vault-switcher-trigger');
}

/**
 * 点击 clickId 直到 text=expectText 的组件出现（最多 attempts 次）。
 * x86 模拟器实测：应用冷启动后约 1 分钟内 UiTest 的点击注入间歇性无效
 * （uinput 同坐标手动注入正常，晚于 1 分钟的用例点击也正常，2026-11-07）。
 * 点击后短期等待目标出现，未出现即视为本次点击无效，重试。
 */
export async function clickUntilTextAppear(driver: Driver, clickId: string, expectText: string,
  attempts: number = 3, attemptWaitMs: number = 8000): Promise<void> {
  let lastError: Error | null = null;
  for (let i: number = 0; i < attempts; i++) {
    try {
      await clickById(driver, clickId);
      await waitByText(driver, expectText, attemptWaitMs);
      return;
    } catch (error) {
      lastError = error as Error;
    }
  }
  throw new Error('点击 ' + clickId + ' 后未出现 text=' + expectText +
    '（重试 ' + attempts.toString() + ' 次，x86 冷启动注入不稳？）: ' + (lastError?.message ?? ''));
}

/**
 * clickByText 版的 clickUntilTextAppear：点击 text=clickText 直到 expectText 出现（最多 attempts 次）。
 * 上一次点击实际已生效但等待超时的场景下，组件可能已消失——吞掉点击异常继续等待即可自愈。
 */
export async function clickByTextUntilTextAppear(driver: Driver, clickText: string, expectText: string,
  attempts: number = 3, attemptWaitMs: number = 8000): Promise<void> {
  let lastError: Error | null = null;
  for (let i: number = 0; i < attempts; i++) {
    try {
      await clickByText(driver, clickText);
    } catch (error) {
      // 组件已不在（上一次点击实际已生效），吞掉后仅等待
    }
    try {
      await waitByText(driver, expectText, attemptWaitMs);
      return;
    } catch (error) {
      lastError = error as Error;
    }
  }
  throw new Error('点击 text=' + clickText + ' 后未出现 text=' + expectText +
    '（重试 ' + attempts.toString() + ' 次，x86 点击注入抖动？）: ' + (lastError?.message ?? ''));
}
