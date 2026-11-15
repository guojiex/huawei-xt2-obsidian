/*
 * UiScreensaver.test.ets —— 屏保 / 台历 UI 冒烟用例（v1.63–v1.65）。
 * 映射与约定见 docs/testing/UI自动化测试.md。
 *
 * 覆盖要点（冒烟级，不做覆盖层内容断言）：
 * - v1.65 65.3：更多菜单「屏保 / 台历」入口可达并进入屏保
 * - v1.65 65.4：屏保中点击退出，退出后应用可交互（更多菜单可再次打开）
 * - v1.65 65.5：设置「屏保 / 台历」组（名言轮换间隔档位）可见
 *
 * 不自动化项：屏保覆盖层内容（时钟 / 名言 / 台历）不做 a11y 断言 ——
 * StartupMask 根节点 accessibilityLevel('no')（StartupMask.ets），uitest 无法读取覆盖层。
 */

import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import {
  clickByText,
  clickUntilTextAppear,
  ensureNoteView,
  getDriver,
  launchMainApp,
  waitById,
  waitByText,
  waitGoneByText
} from './UiTestHelpers';

export default function uiScreensaverTest() {
  describe('UiScreensaver', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      await ensureNoteView(await getDriver());
    });

    /** v1.65 65.3/65.4：菜单进入屏保，点击退出后应用可交互 */
    it('screensaver_entry_open_and_exit_smoke', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await clickUntilTextAppear(driver, 'workspace-more-button', '屏保 / 台历', 3, 15000);
      await clickByText(driver, '屏保 / 台历');
      // 覆盖层入场（含氛围层起播）后按 65.4 点击任意处退出；覆盖层 a11y 不可断言，仅冒烟
      await driver.delayMs(2500);
      await driver.click(1592, 1116); // 模拟器屏幕中心
      await driver.delayMs(1000);
      // 退出后应用可交互：更多菜单可再次打开（MobileMoreMenuItem onClick 收菜单）
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
      await driver.pressBack(); // autoCancel 抢序坑：收菜单用 pressBack
      expect(await waitGoneByText(driver, '设置与关于')).assertTrue();
    });

    /** v1.65 65.5：设置页「屏保 / 台历」组与名言轮换间隔档位可见 */
    it('screensaver_settings_group_visible', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
      await clickByText(driver, '设置与关于');
      await waitById(driver, 'settings-heading-general');
      // waitByText 返回 Component：抛错即失败，不包 expect(...).assertTrue()（对象恒假）
      await waitByText(driver, '屏保 / 台历');
      await waitByText(driver, '名言轮换间隔');
      await driver.pressBack();
      await waitGoneByText(driver, '名言轮换间隔');
    });
  });
}
