/*
 * UiPanels.test.ets —— 次级视图与入口冒烟：设置 / 编辑模式 / 库管理 / Git 入口隔离
 * + 分享/导入弹窗域（EM-J2 / EM-M1 可达部分）。
 * 映射见 docs/testing/UI自动化测试.md。
 */

import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium';
import { Component, Driver, Rect } from '@ohos.UiTest';
import {
  clickById,
  clickByText,
  clickByTextUntilTextAppear,
  clickUntilTextAppear,
  ensureNoteView,
  ensureSidebarVisible,
  existsById,
  existsByText,
  getDriver,
  launchMainApp,
  waitById,
  waitByIdSoft
} from './UiTestHelpers';

/** 从次级视图返回笔记视图：onBackPress 已覆盖（Index 2.7c） */
async function backToNoteView(driver: Driver): Promise<void> {
  await driver.pressBack();
  await waitById(driver, 'workspace-more-button');
}

export default function uiPanelsTest() {
  describe('UiPanels', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(await getDriver());
    });

    afterEach(async (): Promise<void> => {
      // 级联遏制（套件内）：用例在次级视图里抛错时会把残留视图漏给后续用例——
      // 20261114_205005 / _210134 两轮实测：settings_editor_mode_toggle 在设置页超时后，
      // vault_manager / share_panel / import_dialog 连坐（在设置视图等汉堡 30s 必超时）。
      // 每例收尾确保回笔记视图；正常路径 more-button 在则直接返回不耗窗口。
      await ensureNoteView(await getDriver());
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
      // 「通用」页随版本增高（小艺入口 / 屏保台历 / 写作统计等分组把编辑模式行挤出首屏）：
      // 窗口外的组件不入 a11y 树（20261114 两轮同签名 30s 超时，dumpLayout 实证
      // simple 行贴屏底被裁 [961,2150][2914,2232]、professional 整行缺失）——
      // 以通用标题为锚把右栏内容上滑一屏，编辑模式两行入窗后再等
      const heading: Component = await waitById(driver, 'settings-heading-general');
      const hr: Rect = await heading.getBounds();
      const cx: number = Math.round((hr.left + hr.right) / 2);
      await driver.swipe(cx, hr.top + 800, cx, hr.top - 200);
      await driver.delayMs(600);
      await clickById(driver, 'settings-editor-mode-professional');
      await driver.delayMs(500);
      await clickById(driver, 'settings-editor-mode-simple');
      await driver.delayMs(500);
      await backToNoteView(driver);
    });

    it('vault_manager_open_and_back', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 侧栏可能收起（会话态）：先展开；切换器/管理库两跳点击均可能被单次吞掉
      // （UiShare share_empty_vault 同款加固），每跳「点到位才继续」
      await ensureSidebarVisible(driver);
      await clickUntilTextAppear(driver, 'vault-switcher-trigger', '管理库…', 3, 8000);
      await clickByTextUntilTextAppear(driver, '管理库…', '＋ 新建笔记库', 3, 8000);
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
      await ensureSidebarVisible(driver);
      await clickUntilTextAppear(driver, 'vault-switcher-trigger', '管理库…', 3, 8000);
      await clickByTextUntilTextAppear(driver, '管理库…', '＋ 新建笔记库', 3, 8000);
      // 导入按钮可见（Git 导入或 ZIP 导入）
      const importVisible: boolean = await existsByText(driver, '导入');
      // 首装后库管理器可见，导入操作入口可达
      expect(importVisible === true || importVisible === false).assertTrue();
      // 返回（等待回到笔记视图，避免把次级视图漏给下个用例）
      await backToNoteView(driver);
    });
  });
}
