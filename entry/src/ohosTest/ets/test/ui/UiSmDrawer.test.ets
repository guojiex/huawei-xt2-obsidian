/*
 * UiSmDrawer.test.ets —— 单屏文件列表交互回归（2026-11-08 用户上报：SM 抽屉点文件夹无反应）。
 *
 * 根因：doCreateNote / doCreateFolder / wiki 链接新建 / adoptExternalVaultSwitch 四处
 * 直接写 this.drawerOpen=false，drawerProgress 悬停 1 —— 抽屉视觉开着但整棵
 * .enabled(drawerOpen=false) 禁用（Index.ets 单屏分支：可见性由 drawerProgress 驱动
 * translate，可交互性由 drawerOpen 驱动 enabled）。修复为统一走 setDrawerOpen(false)。
 *
 * 控件树断言的边界（诚实记录）：失步态与正常收起态在 a11y 树里同构（抽屉/内容/遮罩
 * 三件套常驻挂载，translate 不进 bounds），本套件断言两条行为契约：
 *  1) 文件列表目录行点按必须有翻转响应（上报症状主线）；
 *  2) 抽屉里新建笔记后导航仍可复用（doCreateNote 收抽屉链路）。
 * 失步时「抽屉卡在开启视觉」无法用控件树区分，最终防线是源码修复本身。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver, Component } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, clickById, clickByText,
  existsById, waitGoneById, tryWaitById, uniqueUiName, ensureSidebarVisible,
  ensureNoteView, scrollSidebarToTop } from './UiTestHelpers';

/** 样例库 id（树行 id = file-tree-row-<vaultId>:<relPath>，见 FileTreeView.treeRowFocusId） */
const VAULT_ID: string = '曜石笔记教程';
const FOLDER_ROW_ID: string = 'file-tree-row-' + VAULT_ID + ':00_开始';
const CHILD_ROW_ID: string = 'file-tree-row-' + VAULT_ID + ':00_开始/快速上手.md';

async function folderChildVisible(driver: Driver): Promise<boolean> {
  return await existsById(driver, CHILD_ROW_ID);
}

/** 点 00_开始 目录行，子行出现或消失都算「点按有响应」 */
async function probeFolderToggle(driver: Driver): Promise<boolean> {
  const row: Component | null = await tryWaitById(driver, FOLDER_ROW_ID, 4000);
  if (row === null) {
    return false;
  }
  const before: boolean = await folderChildVisible(driver);
  await row.click();
  const deadline: number = Date.now() + 5000;
  while (Date.now() < deadline) {
    const after: boolean = await folderChildVisible(driver);
    if (after !== before) {
      return true;
    }
    await driver.delayMs(400);
  }
  return false;
}

/** 把 00_开始 复位为收起（用例间确定性收尾） */
async function collapseFolderIfExpanded(driver: Driver): Promise<void> {
  if (await folderChildVisible(driver)) {
    await clickById(driver, FOLDER_ROW_ID);
    await waitGoneById(driver, CHILD_ROW_ID, 8000);
  }
}

/**
 * 保证文件树可交互：探针失败（SM 抽屉未开 / MD 侧栏收起 / 注入被吞）时
 * toggle 汉堡重试。SM 汉堡是 setDrawerOpen(!drawerOpen)，MD 是侧栏开合，
 * 两种布局都能在少量 toggle 内到「树可点」状态。
 */
async function ensureTreeInteractive(driver: Driver): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    if (await probeFolderToggle(driver)) {
      await collapseFolderIfExpanded(driver);
      return;
    }
    // 00_开始 可能只是被前序套件滚出 LazyForEach 视口（不入 a11y 树），不是失步：
    // 20261111_232952 全量 UiNoteFlow 滚树后本套件 2 ERROR，~22s/例 = 4s 探针超时 × 4 轮
    // （点击无响应路径应为 ~9s/轮）——先滚回顶部再探，避免把滚动残留误判成失步
    await scrollSidebarToTop(driver);
    if (await probeFolderToggle(driver)) {
      await collapseFolderIfExpanded(driver);
      return;
    }
    await clickById(driver, 'workspace-navigation-button');
    await driver.delayMs(1200);
  }
  throw new Error('文件树不可交互：4 轮导航 toggle 后 00_开始 仍无展开/收起响应');
}

export default function uiSmDrawerTest() {
  describe('UiSmDrawer', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
      const driver: Driver = await getDriver();
      // 级联遏制：上个套件留在次级视图时先回笔记视图（ensureNoteView 注释）
      await ensureNoteView(driver);
      await ensureSidebarVisible(driver);
    });

    /** 回归主线：文件列表里点文件夹必须有翻转响应（用户上报症状） */
    it('folder_toggle_responds_in_navigation', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureTreeInteractive(driver);
      // 显式双向断言：再翻转一次并复位
      expect(await probeFolderToggle(driver)).assertTrue();
      await collapseFolderIfExpanded(driver);
      expect(await folderChildVisible(driver)).assertFalse();
    });

    /** 抽屉里新建笔记后导航必须仍可复用（doCreateNote 收抽屉走 setDrawerOpen 的链路） */
    it('create_note_keeps_navigation_usable', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureTreeInteractive(driver);
      // 抽屉头「+」新建：冷启动浮层会吞首次点击，按「点 → 短窗验 input」重试
      for (let i: number = 0; i < 3; i++) {
        await clickById(driver, 'vault-sidebar-new-note');
        if (await tryWaitById(driver, 'note-create-input', 5000) !== null) {
          break;
        }
      }
      const input: Component = await waitById(driver, 'note-create-input');
      const name: string = uniqueUiName('uitest抽');
      await input.inputText(name);
      await clickByText(driver, '创建');
      await waitGoneById(driver, 'note-create-input', 8000);
      // 新建后（SM 修复态抽屉自动收起）导航必须能再次到达可交互状态
      await ensureTreeInteractive(driver);
    });
  });
}
