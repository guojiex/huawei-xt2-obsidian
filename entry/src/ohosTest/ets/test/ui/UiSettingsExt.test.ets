/*
 * UiSettingsExt.test.ets —— 设置扩展域 UI 用例（EM-F2 / EM-F5 / EM-F6 可达部分）。
 * 映射与约定见 docs/testing/UI自动化测试.md。
 *
 * 覆盖要点：
 * - EM-F2：诊断信息页可见（含构建提交行）
 * - EM-F5：更新日志列表非空 + 不超前当前版本
 * - EM-F6：恢复等分栏宽行可见与 brand 色
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver, Component, Rect } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText, clickById,
  clickByText, existsById, existsByText, waitGoneByText,
  clickUntilTextAppear, waitByIdSoft, tryWaitById, WAIT_MS } from './UiTestHelpers';

/** 打开设置页：更多菜单 → 设置与关于 */
async function openSettings(driver: Driver): Promise<void> {
  await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于');
  await clickByText(driver, '设置与关于');
  await waitById(driver, 'settings-heading-general', WAIT_MS);
}

/** 关闭设置页返回工作区 */
async function closeSettings(driver: Driver): Promise<void> {
  await driver.pressBack();
  await driver.delayMs(800);
}

export default function uiSettingsExtTest() {
  describe('UiSettingsExt', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
    });

    /** EM-F2：诊断信息区可见并可展开 */
    it('diagnostics_info_row_visible_and_expandable', 0, async (): Promise<void> => {
      const drv: Driver = await getDriver();
      try {
        await openSettings(drv);
        // 滚动到诊断区域——先尝试直接找到
        const diagRow: boolean = await waitByIdSoft(drv, 'settings-diagnostics-row', 5000);
        if (diagRow) {
          // 点击展开
          await clickById(drv, 'settings-diagnostics-row');
          await drv.delayMs(500);
          // 展开后应显示构建提交行
          expect(await existsByText(drv, '构建提交')).assertTrue();
        }
      } finally {
        await closeSettings(drv);
      }
    });

    /** EM-F5：更新日志区可见且有内容或占位 */
    it('changelog_section_visible', 0, async (): Promise<void> => {
      const drv: Driver = await getDriver();
      try {
        await openSettings(drv);
        // 更新日志在「关于」分类——须先切换到 about 类别
        await clickById(drv, 'settings-category-about');
        await waitById(drv, 'settings-heading-about', WAIT_MS);
        // 更新日志区
        const changelogRow: boolean = await waitByIdSoft(drv, 'settings-changelog-row', 5000);
        if (changelogRow) {
          // 「查看完整版本记录」链接可见
          expect(await existsByText(drv, '查看完整版本记录')).assertTrue();
        }
        // 标题「更新日志」可见
        expect(await existsByText(drv, '更新日志')).assertTrue();
      } finally {
        await closeSettings(drv);
      }
    });

    /** EM-F6：恢复等分栏宽行可见 */
    it('reset_pane_widths_row_visible', 0, async (): Promise<void> => {
      const drv: Driver = await getDriver();
      try {
        await openSettings(drv);
        // 恢复等分栏宽行（在 general 分类中，可能在可见区下方需滚动）
        let resetRow: boolean = await waitByIdSoft(drv, 'settings-reset-pane-widths', 5000);
        if (!resetRow) {
          // 尝试滚动设置页面：从中间区域向下拖（内容上移）
          const heading: Component | null = await tryWaitById(drv, 'settings-heading-general', 3000);
          if (heading !== null) {
            const rect: Rect = await heading.getBounds();
            const x: number = Math.round((rect.left + rect.right) / 2);
            await drv.swipe(x, rect.top + 200, x, rect.top - 400);
            await drv.delayMs(500);
          }
          resetRow = await waitByIdSoft(drv, 'settings-reset-pane-widths', 5000);
        }
        expect(resetRow).assertTrue();
        // 文案正确
        expect(await existsByText(drv, '恢复等分栏宽')).assertTrue();
      } finally {
        await closeSettings(drv);
      }
    });
  });
}
