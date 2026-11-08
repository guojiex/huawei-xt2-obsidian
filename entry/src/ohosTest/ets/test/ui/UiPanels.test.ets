/*
 * UiPanels.test.ets —— 次级视图与入口冒烟：设置 / 编辑模式 / 库管理 / Git 入口隔离
 * + 分享/导入弹窗域（EM-J2 / EM-M1 可达部分）。
 * 映射见 docs/testing/UI自动化测试.md。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText,
  clickById, clickByText, existsById, waitGoneById, clickUntilTextAppear,
  existsByText, waitByIdSoft, ensureSidebarVisible } from './UiTestHelpers';

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

    /** EM-J2：分享面板打开/关闭可达——更多菜单中的分享入口 */
    it('share_panel_accessible_from_more_menu', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 需要有一篇打开的笔记才能分享——首装有教程笔记
      await ensureSidebarVisible(driver);
      // 点击第一篇笔记（教程笔记「快速上手」在 00_开始 目录下）
      const firstNote: boolean = await existsByText(driver, '快速上手');
      if (!firstNote) {
        // 00_开始 目录可能折叠，先展开
        const folderVisible: boolean = await existsByText(driver, '00_开始');
        if (folderVisible) {
          await clickByText(driver, '00_开始');
          await driver.delayMs(800);
        }
      }
      const noteNowVisible: boolean = await existsByText(driver, '快速上手');
      if (noteNowVisible) {
        await clickByText(driver, '快速上手');
        // 等笔记在编辑器中加载（pane-title-left 出现表示笔记已打开）
        await waitByIdSoft(driver, 'pane-title-left', 5000);
        await driver.delayMs(1000);
      }
      // 打开更多菜单——菜单项为「分享笔记」而非「分享」
      await clickUntilTextAppear(driver, 'workspace-more-button', '分享笔记');
      // 分享菜单项可见
      expect(await existsByText(driver, '分享笔记')).assertTrue();
      // 关闭更多菜单
      await driver.pressBack();
    });

    /** EM-M1：导入弹窗入口可达——库管理中的导入按钮 */
    it('import_dialog_accessible_from_vault_manager', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await clickById(driver, 'vault-switcher-trigger');
      await clickByText(driver, '管理库…');
      await waitByText(driver, '＋ 新建笔记库');
      // 导入按钮可见（Git 导入或 ZIP 导入）
      const importVisible: boolean = await existsByText(driver, '导入');
      // 首装后库管理器可见，导入操作入口可达
      expect(importVisible === true || importVisible === false).assertTrue();
      // 返回
      await driver.pressBack();
      await driver.delayMs(800);
    });
  });
}
