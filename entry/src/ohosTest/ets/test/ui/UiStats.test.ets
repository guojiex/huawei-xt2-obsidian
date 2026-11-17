/*
 * UiStats.test.ets —— 写作统计 UI 用例（v1.52 / v1.58 / v1.81）。
 * 映射与约定见 docs/testing/UI自动化测试.md。
 *
 * 覆盖要点：
 * - v1.81 81.7：更多菜单「写作统计」打开独立页（stats-page），返回键恢复笔记视图；
 *   判定锚点用页面独有文案「每一天，都算数」（菜单项与页面 Appbar 标题同名）
 * - 历史案例 streak_chip_visible_in_note_sidebar 已删除（2026-11-17）：v1.67
 *   （9f3138bf）按设计移除笔记侧栏连写条，chip 不再是笔记视图的可断言锚点
 *
 * ⚠️ 设备状态自愈（20261115_001720 实锤）：statsEnabled 是持久化开关（默认开，v1.58 可关），
 * 早期手工回归拨关后残留——菜单项不渲染。v1.81 起自愈固定走设置页：
 * Toggle 无文本锚点，用 ON.type('Toggle') + 与 Text('启用写作统计') y 重叠过滤 + isChecked 判态。
 */

import { beforeAll, describe, it } from '@ohos/hypium';
import { Component, Driver, ON, Rect } from '@ohos.UiTest';
import {
  clickByText,
  clickUntilTextAppear,
  ensureNoteView,
  getDriver,
  launchMainApp,
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

/** 确认持久化的写作统计开关为开（默认开；设备残留关闭态时自愈），并回到笔记视图 */
async function ensureStatsEnabled(driver: Driver): Promise<void> {
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
}

export default function uiStatsTest() {
  describe('UiStats', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(await getDriver());
    });

    /** v1.81 81.7：更多菜单「写作统计」打开独立页，返回键恢复笔记视图（承接 v1.58 58.3/58.4 入口） */
    it('stats_page_opens_from_more_menu', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureStatsEnabled(driver);
      // 菜单项「写作统计」与页面 Appbar 标题同名——打开判定用页面根 id + 独有文案，避开同名碰撞
      await clickUntilTextAppear(driver, 'workspace-more-button', '写作统计', 3, 15000);
      await clickByText(driver, '写作统计');
      await waitById(driver, 'stats-page');
      await waitByTextContains(driver, '每一天，都算数');
      // 返回键走 returnFromVaultStats：恢复原视图与焦点，页面内容从树中消失
      await driver.pressBack();
      await waitGoneByText(driver, '每一天，都算数');
    });
  });
}
