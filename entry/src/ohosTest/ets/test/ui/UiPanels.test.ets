/*
 * UiPanels.test.ets —— 次级视图与入口冒烟：设置 / 编辑模式 / 库管理 / Git 入口隔离
 * （EM-F1、EM-C1、EM-B1、EM-K1 可达部分）。映射见 docs/testing/UI自动化测试.md。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText,
  clickById, clickByText, existsById, waitGoneById, clickUntilTextAppear } from './UiTestHelpers';

/** 从次级视图返回笔记视图：onBackPress 已覆盖（Index 2.7c） */
async function backToNoteView(driver: Driver): Promise<void> {
  await driver.pressBack();
  await waitById(driver, 'workspace-more-button');
}

export default function uiPanelsTest() {
  describe('UiPanels', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
    });

    it('settings_groups_visible_and_back', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 首用例紧随冷启动：首击可能被吞（UiTestHelpers.clickUntilTextAppear 注释），套重试保护
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
      await clickByText(driver, '设置与关于');
      // 双栏设置一次只渲染选中分类（SettingsView.CategoryContent），须逐类点击再断言 heading
      await waitById(driver, 'settings-heading-general');
      await clickById(driver, 'settings-category-data');
      await waitById(driver, 'settings-heading-data');
      await clickById(driver, 'settings-category-about');
      await waitById(driver, 'settings-heading-about');
      await backToNoteView(driver);
    });

    it('settings_editor_mode_toggle', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
      await clickByText(driver, '设置与关于');
      await waitById(driver, 'settings-heading-general');
      await clickById(driver, 'settings-editor-mode-professional');
      await driver.delayMs(500);
      await clickById(driver, 'settings-editor-mode-simple');
      await driver.delayMs(500);
      await backToNoteView(driver);
    });

    it('vault_manager_open_and_back', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await clickById(driver, 'vault-switcher-trigger');
      await clickByText(driver, '管理库…');
      await waitByText(driver, '＋ 新建笔记库');
      await backToNoteView(driver);
    });

    it('git_entry_hidden_for_non_git_vault', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 首装教程库不是 Git 库：同步入口不得出现（EM-K1 入口隔离的反向断言）
      expect(await existsById(driver, 'git-sync-button')).assertFalse();
    });
  });
}
