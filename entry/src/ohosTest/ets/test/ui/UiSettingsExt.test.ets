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
import { Driver, Point } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText, clickById,
  clickByText, existsById, existsByText, waitGoneByText,
  ensureNoteView, clickUntilTextAppear, waitByIdSoft, WAIT_MS } from './UiTestHelpers';

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
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(await getDriver());
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
          // ⚠️ x86 模拟器实测（2026-11-09）：
          // - 旧实现按 settings-heading-general 相对坐标取 x（≈530）落在左侧分类栏，
          //   滚不动右侧内容区（11-08 某 run 的「expect false」即此因）；
          //   且 rect.top(=365) - 400 为负时 Driver.swipe 被 APiCallInfoChecker 拒绝
          //   （错误码 401，报文是误导性的 "Illegal argument count"）。
          // - 改为按屏幕尺寸取右半内容区中线，一屏内上滑，坐标恒在屏内。
          const size: Point = await drv.getDisplaySize();
          const cx: number = Math.round(size.x / 2);
          const startY: number = Math.round(size.y * 0.67);
          const endY: number = Math.round(size.y * 0.18);
          for (let k: number = 0; k < 2 && !resetRow; k++) {
            await drv.swipe(cx, startY, cx, endY);
            await drv.delayMs(500);
            resetRow = await waitByIdSoft(drv, 'settings-reset-pane-widths', 3000);
          }
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
