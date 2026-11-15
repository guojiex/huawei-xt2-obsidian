/*
 * UiStats.test.ets —— 写作统计 UI 用例（v1.52 / v1.58）。
 * 映射与约定见 docs/testing/UI自动化测试.md。
 *
 * 覆盖要点：
 * - v1.58 58.2：侧栏连写条（vault-stats-streak-chip）在 lg 笔记视图可见
 * - v1.58 58.3/58.4：更多菜单「写作统计」入口可达，弹窗打开与关闭（副标题「只在本机统计」为弹窗独有锚点）
 *
 * ⚠️ 设备状态自愈（20261115_001720 实锤）：statsEnabled 是持久化开关（默认开，v1.58 可关），
 * 早期手工回归拨关后残留——chip 与菜单项都不渲染。套件先经设置页把开关拨回开：
 * Toggle 无文本锚点，用 ON.type('Toggle') + 与 Text('启用写作统计') y 重叠过滤 + isChecked 判态。
 */

import { beforeAll, describe, it } from '@ohos/hypium';
import { Component, Driver, ON, Rect } from '@ohos.UiTest';
import {
  clickById,
  clickByText,
  clickUntilTextAppear,
  ensureNoteView,
  ensureSidebarVisible,
  getDriver,
  launchMainApp,
  tryWaitById,
  waitById,
  waitByTextContains,
  waitGoneByText
} from './UiTestHelpers';

/** 设置页找「启用写作统计」行尾的 Toggle 开关（无文本锚点：按与标签 y 重叠过滤） */
async function findStatsToggle(driver: Driver): Promise<Component | null> {
  const label: Component | null = await driver.waitForComponent(ON.text('启用写作统计'), 3000);
  if (label === null) {
    return null;
  }
  const lr: Rect = await label.getBounds();
  const cands: Component[] = await driver.findComponents(ON.type('Toggle'));
  for (const c of cands) {
    const r: Rect = await c.getBounds();
    if (r.top < lr.bottom && r.bottom > lr.top) {
      return c;
    }
  }
  return null;
}

/** 把持久化的写作统计开关拨回开（默认开；设备残留关闭态时自愈），并回到笔记视图 */
async function ensureStatsEnabled(driver: Driver): Promise<void> {
  if (await tryWaitById(driver, 'vault-stats-streak-chip', 3000) !== null) {
    return; // 已开
  }
  await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
  await clickByText(driver, '设置与关于');
  await waitById(driver, 'settings-heading-general');
  // 统计组在 general 分类内容下方，可能要下滑设置页才可见（Scroll 渲染不裁剪，但点击需在视口内）
  let toggle: Component | null = await findStatsToggle(driver);
  for (let i: number = 0; i < 4 && toggle === null; i++) {
    await driver.swipe(1600, 1400, 1600, 800, 300);
    await driver.delayMs(600);
    toggle = await findStatsToggle(driver);
  }
  if (toggle === null) {
    throw new Error('设置页未找到「启用写作统计」开关');
  }
  if (!(await toggle.isChecked())) {
    await toggle.click();
    await driver.delayMs(800);
    if (!(await toggle.isChecked())) {
      throw new Error('写作统计开关拨开失败');
    }
  }
  await driver.pressBack();
  await waitGoneByText(driver, '启用写作统计');
  await ensureNoteView(driver);
  await waitById(driver, 'vault-stats-streak-chip');
}

export default function uiStatsTest() {
  describe('UiStats', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(await getDriver());
    });

    /** v1.58 58.2：lg 笔记视图侧栏连写条可见（statsEnabled 默认开，关闭残留自愈） */
    it('streak_chip_visible_in_note_sidebar', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureStatsEnabled(driver);
      await ensureSidebarVisible(driver);
      await waitById(driver, 'vault-stats-streak-chip');
    });

    /** v1.58 58.3/58.4：更多菜单「写作统计」打开弹窗、× 关闭 */
    it('stats_dialog_opens_from_more_menu', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureStatsEnabled(driver);
      // 菜单项「写作统计」与弹窗标题同名——弹窗独有锚点用副标题「只在本机统计」
      await clickUntilTextAppear(driver, 'workspace-more-button', '写作统计', 3, 15000);
      await clickByText(driver, '写作统计');
      await waitByTextContains(driver, '只在本机统计');
      // UtilityDialogShell 的 ×（id=utility-dialog-close，accessibilityText=关闭写作统计）
      await clickById(driver, 'utility-dialog-close');
      await waitGoneByText(driver, '写作统计');
    });
  });
}
