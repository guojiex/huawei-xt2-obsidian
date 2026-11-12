/*
 * UiLaunch.test.ets —— 启动与工作区冒烟（EM-A1 / EM-H1 / EM-E1 / EM-A3 可达部分）。
 * 映射与约定见 docs/testing/UI自动化测试.md。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import display from '@ohos.display';
import { getDriver, launchMainApp, waitById, waitByText, waitByTextContains,
  clickById, clickByText, existsByText, waitGoneByText, existsById, ensureSidebarVisible,
  ensureNoteView, clickUntilTextAppear, waitByIdSoft } from './UiTestHelpers';

/**
 * 关闭快切换：优先点弹窗的「×」（UtilityDialogShell onClose 直达）。
 * 不再连按 Back 兜底——x86 拆树慢时 500ms 内补按的第二次 Back 会落到
 * onBackPress 链末尾的「工作台收起侧栏」分支（Index.ets:2230-2233），
 * 把持久化的 sidebarCollapsed 改写成收起，毒化下一次冷启动（2026-11-07 实测）。
 * Back 仅在快切确实还开着时安全（命中 quickSwitchOpen 分支）；输入框聚焦时
 * Back 只清焦点（api_notes L-10）。
 */
async function closeQuickSwitcher(driver: Driver): Promise<boolean> {
  if (await existsByText(driver, '×')) {
    await clickByText(driver, '×');
    if (await waitGoneByText(driver, '快切与搜索')) {
      return true;
    }
  }
  await driver.pressBack();
  return await waitGoneByText(driver, '快切与搜索');
}

export default function uiLaunchTest() {
  describe('UiLaunch', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(await getDriver());
    });

    it('cold_launch_workspace_ready', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await waitById(driver, 'workspace-navigation-button');
      // 会话可能恢复出 md 收起态（侧栏整体隐藏），先展开再断言侧栏骨架
      await ensureSidebarVisible(driver);
      await waitById(driver, 'vault-switcher-trigger');
      await waitByTextContains(driver, '篇笔记');
    });

    it('file_tree_not_empty_fresh_install', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 空态文案在侧栏里：侧栏隐藏时断言会空真，先归一化
      await ensureSidebarVisible(driver);
      expect(await existsByText(driver, '库里还没有笔记')).assertFalse();
      expect(await existsByText(driver, '0 篇笔记')).assertFalse();
    });

    it('more_menu_opens_and_closes', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      // 冷启动初期 UiTest 点击可能无效（UiTestHelpers.clickUntilTextAppear 注释），重试直到菜单出现
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于');
      // 收起用 Back 走 bindPopup autoCancel 路径：再点「…」按钮时
      // autoCancel 的 dismiss 与按钮 onClick 的 toggle 抢序，dismiss 先到
      // 会把 onClick 翻转成 true 导致菜单重开（实测 run3 二次点击后 15s 不消失）
      await driver.pressBack();
      expect(await waitGoneByText(driver, '设置与关于')).assertTrue();
    });

    it('quick_switcher_open_and_close', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureSidebarVisible(driver);
      await clickUntilTextAppear(driver, 'vault-sidebar-search', '快切与搜索');
      expect(await closeQuickSwitcher(driver)).assertTrue();
    });

    /**
     * EM-A3 双屏形态增补（295bd23 的 UI 防线，2026-11-07）：
     * 收起目录后 nav 分栏把手必须从控件树消失——外部 .width(0) 只作用于
     * 包装节点，内部根 Stack 固定 16vp 会溢出绘制，显隐只能靠 visibility。
     * 目录把手仅存在于 md/lg 宽屏布局，单屏（<600vp）无此控件，翻转断言无意义，直通。
     */
    it('split_handle_hidden_when_sidebar_collapsed', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const screen: display.Display = display.getDefaultDisplaySync();
      const vpWidth: number = screen.width * 160 / Math.max(1, screen.densityDPI);
      if (vpWidth < 600) {
        console.info(`split_handle case skipped: window ${vpWidth}vp < 600vp`);
        return;
      }
      // 状态无关的翻转断言：无论会话恢复出展开还是收起，点汉堡都必须让把手存在性翻转。
      // 冷启动初期点击可能无效（见 UiTestHelpers），未翻转则重试点击。
      const initial: boolean = await existsById(driver, 'nav-split-handle');
      let flipped: boolean = false;
      for (let i: number = 0; i < 3 && !flipped; i++) {
        await clickById(driver, 'workspace-navigation-button');
        await driver.delayMs(1200);
        flipped = (await existsById(driver, 'nav-split-handle')) !== initial;
      }
      expect(flipped).assertTrue();
      // 复原会话状态并反向再验一次翻转
      let restored: boolean = false;
      for (let i: number = 0; i < 3 && !restored; i++) {
        await clickById(driver, 'workspace-navigation-button');
        await driver.delayMs(1200);
        restored = (await existsById(driver, 'nav-split-handle')) === initial;
      }
      expect(restored).assertTrue();
    });
  });
}
