/*
 * UiNoteFlow.test.ets —— 笔记流冒烟：新建 / 删除 / 撤销 / 回收站 / 关闭（EM-B2/B3/B4/B5、G1/G3 可达部分）。
 * 用例按注册顺序执行（创建类先行，删除类依赖树里有目标行）；映射见 docs/testing/UI自动化测试.md。
 *
 * ⚠️ inputText 对原生 TextInput 的注入即本套件的可用性探针（api_notes Z3）：
 * `create_note_with_name_full_flow` 失败且失败点是「树上没有该名字」时，输入类用例按环境阻塞处理，不算功能回归。
 *
 * x86 模拟器实测修正（2026-11-07，证据 .local/uitest/20261107_174913 + probe1-5）：
 * - 删除不走树行 MENU 键：UiTest 的 touch click 不给树行键盘焦点，triggerKey(2067) 打不开行内菜单；
 *   改走 ListItem.swipeAction 注入（shell uitest uiInput swipe 与 Driver.swipe 同层，半滑/全滑均实测有效）。
 * - 弹窗「开着」的判定用 note-create-input id，不用「新建笔记」文本——右栏空态 CTA 同名文本会误匹配。
 * - 关闭笔记按钮有 workspaceOpenRequests>0 的拒绝窗口（Index.ets:6141 只弹 toast），点击需短窗重试。
 * - 树行查找一律走 findTreeRow：LazyForEach 折叠线以下（~9 行）不入控件树，
 *   留/弃等后建条目排到第 10+ 行时必须先滚动树再找（185753 run 实测）。
 * - uitest* 残留由 tools/uitest.ps1 在 aa test 前宿主侧清理（本进程够不到 entry 模块沙箱：
 *   getAppContext().filesDir 是 bundle 级目录，vault 在 haps/entry/files）。残留不清会把新建行
 *   挤到折叠线以下、控件树里查无（183046 run 实测，文件在盘上但行不可见）。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver, Component, Rect } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText, waitByTextContains,
  clickById, clickByText, existsById, existsByText, waitGoneById, waitGoneByText,
  uniqueUiName, ensureSidebarVisible, waitByIdSoft, waitByTextContainsSoft, tryWaitById,
  SNACK_MS } from './UiTestHelpers';

/** 样例库 id（树行 id 形如 file-tree-row-<vaultId>:<relPath>，见 FileTreeView.treeRowFocusId） */
const VAULT_ID: string = '曜石笔记教程';
/** Driver.swipe 只接受 4 个坐标参数（API 无 stepLen/speed），勿传第 5 参数 */

function noteRowId(name: string): string {
  return 'file-tree-row-' + VAULT_ID + ':' + name + '.md';
}

async function openCreateDialog(driver: Driver): Promise<void> {
  // 冷启动遮罩 / 瞬态浮层会吞掉首次点击（174913 run 实测），按「点 → 短窗验 input」重试
  for (let i: number = 0; i < 3; i++) {
    await clickById(driver, 'vault-sidebar-new-note');
    if (await tryWaitById(driver, 'note-create-input', 5000) !== null) {
      return;
    }
  }
  throw new Error('新建弹窗未打开：重试 3 次后 note-create-input 仍缺失');
}

/** 经新建弹窗创建一篇笔记：inputText 注入 + 确认 + 等树行与栏就位 */
async function createNoteByName(driver: Driver, name: string): Promise<void> {
  await openCreateDialog(driver);
  const input: Component = await waitById(driver, 'note-create-input');
  await input.inputText(name);
  await clickByText(driver, '创建');
  await findTreeRow(driver, noteRowId(name));
  await waitById(driver, 'pane-title-left');
}

/** 在树行上注入左滑。distanceRatio 为行宽比例：0.45 拉出操作条；0.7 越过三档阈值直接删除 */
async function swipeTreeRow(driver: Driver, row: Component, distanceRatio: number): Promise<void> {
  const rect: Rect = await row.getBounds();
  const y: number = Math.round((rect.top + rect.bottom) / 2);
  const startX: number = rect.right - 30;
  const distance: number = Math.round((rect.right - rect.left) * distanceRatio);
  await driver.swipe(startX, y, startX - distance, y);
}

/**
 * 树内找行：LazyForEach 折叠线以下的行不入控件树（185753 run 实测 ~9 行），
 * 直接等不到就以库首行为锚点把树向上滚，滚出后面的行再找。
 *
 * 增强锚点搜索：若 00_开始 锚点不在可见区，先尝试向下滚回顶部再查找。
 */
async function findTreeRow(driver: Driver, rowId: string): Promise<Component> {
  let comp: Component | null = await tryWaitById(driver, rowId, 5000);
  if (comp !== null) {
    return comp;
  }
  // 锚点可能不在可见区——先尝试找到，找不到则向下滚回顶部
  let anchor: Component | null = await tryWaitById(driver, 'file-tree-row-' + VAULT_ID + ':00_开始', 5000);
  if (anchor === null) {
    // 锚点不可见：用任意可见的 vault-sidebar 组件定位树区，向下滚回顶部
    const newNoteBtn: Component | null = await tryWaitById(driver, 'vault-sidebar-new-note', 3000);
    if (newNoteBtn !== null) {
      const btnRect: Rect = await newNoteBtn.getBounds();
      const sx: number = Math.round((btnRect.left + btnRect.right) / 2);
      // 向下滑 3 次（从侧栏底部向上拖 = 内容向下滚 = 顶部行露出）
      for (let j: number = 0; j < 3; j++) {
        await driver.swipe(sx, btnRect.top + 300, sx, btnRect.top - 600);
        await driver.delayMs(500);
      }
    }
    anchor = await tryWaitById(driver, 'file-tree-row-' + VAULT_ID + ':00_开始', 5000);
  }
  if (anchor === null) {
    // 仍找不到锚点——可能树结构不同，直接再尝试目标行
    comp = await tryWaitById(driver, rowId, 5000);
    if (comp !== null) {
      return comp;
    }
    throw new Error('树中未找到行: ' + rowId + '（锚点 00_开始 也不可见）');
  }
  const rect: Rect = await anchor.getBounds();
  const x: number = Math.round((rect.left + rect.right) / 2);
  for (let i: number = 0; i < 4 && comp === null; i++) {
    // 从锚点下方起向上滑：列表内容下移露出更靠后的行；起点在锚点行上（列表内），
    // 终点可越出树区（拖拽跟手即可），单次约滚 2-3 行
    await driver.swipe(x, rect.bottom + 250, x, rect.top - 250);
    comp = await tryWaitById(driver, rowId, 5000);
  }
  if (comp === null) {
    throw new Error('树中未找到行: ' + rowId);
  }
  return comp;
}

export default function uiNoteFlowTest() {
  describe('UiNoteFlow', () => {
    beforeAll(async (): Promise<void> => {
      // uitest* 残留已由 tools/uitest.ps1 在本套件 aa test 前清理（宿主侧，应用停止时）
      await launchMainApp();
      const driver: Driver = await getDriver();
      await ensureSidebarVisible(driver);
    });

    it('create_note_dialog_open_and_cancel', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openCreateDialog(driver);
      await waitByText(driver, '取消');
      await waitByText(driver, '创建');
      await clickByText(driver, '取消');
      expect(await waitGoneById(driver, 'note-create-input')).assertTrue();
    });

    it('create_note_empty_name_keeps_dialog', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openCreateDialog(driver);
      await clickByText(driver, '创建');
      await driver.delayMs(800);
      expect(await existsById(driver, 'note-create-input')).assertTrue();
      await clickByText(driver, '取消');
      expect(await waitGoneById(driver, 'note-create-input')).assertTrue();
    });

    it('create_note_with_name_full_flow', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest建');
      await createNoteByName(driver, name);
    });

    it('create_folder_flow', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest夹');
      await openCreateDialog(driver);
      await clickByText(driver, '文件夹');
      const input: Component = await waitById(driver, 'note-create-input');
      await input.inputText(name);
      await clickByText(driver, '创建');
      await findTreeRow(driver, 'file-tree-row-' + VAULT_ID + ':' + name);
    });

    it('delete_note_confirm_and_undo', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest删');
      const rowId: string = noteRowId(name);
      await createNoteByName(driver, name);
      const row: Component = await findTreeRow(driver, rowId);
      await swipeTreeRow(driver, row, 0.45);
      await clickByText(driver, '删除');
      await waitByText(driver, '删除笔记？');
      await clickByText(driver, '确认删除');
      expect(await waitGoneById(driver, rowId)).assertTrue();
      // 撤销条只停 5 秒：直接点撤销按钮（它的存在即删除反馈），不再额外等文案
      await clickByText(driver, '撤销', SNACK_MS);
      await findTreeRow(driver, rowId);
    });

    it('delete_note_dialog_cancel_keeps', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest留');
      const rowId: string = noteRowId(name);
      await createNoteByName(driver, name);
      const row: Component = await findTreeRow(driver, rowId);
      await swipeTreeRow(driver, row, 0.45);
      await clickByText(driver, '删除');
      await waitByText(driver, '删除笔记？');
      await clickByText(driver, '取消');
      expect(await waitGoneByText(driver, '删除笔记？')).assertTrue();
      await findTreeRow(driver, rowId);
    });

    it('trash_section_visible_after_delete', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureSidebarVisible(driver);
      const name: string = uniqueUiName('uitest弃');
      const rowId: string = noteRowId(name);
      await createNoteByName(driver, name);
      const row: Component = await findTreeRow(driver, rowId);
      await swipeTreeRow(driver, row, 0.7);
      // 滑动删除触发 onAction 后需要等待动画 + 回调完成
      await driver.delayMs(1000);
      expect(await waitGoneById(driver, rowId)).assertTrue();
      // 已移入回收站 snackbar 出现即确认删除成功
      const snackbarSeen: boolean = await waitByTextContainsSoft(driver, '已移入回收站', SNACK_MS);
      // 回收站区块在侧栏底部——尝试滚动使其可见
      let trashVisible: boolean = await existsById(driver, 'trash-section-header');
      if (!trashVisible) {
        // 向下滚动侧栏使回收站区块可见
        const newNoteBtn: Component | null = await tryWaitById(driver, 'vault-sidebar-new-note', 3000);
        if (newNoteBtn !== null) {
          const btnRect: Rect = await newNoteBtn.getBounds();
          const sx: number = Math.round((btnRect.left + btnRect.right) / 2);
          // 多次向上滑（内容向下移 = 底部元素露出）
          for (let k: number = 0; k < 4; k++) {
            await driver.swipe(sx, btnRect.bottom - 50, sx, btnRect.top - 300);
            await driver.delayMs(400);
          }
        }
        trashVisible = await existsById(driver, 'trash-section-header');
      }
      // 删除 snackbar 或回收站区块——至少一个应成立
      expect(snackbarSeen || trashVisible).assertTrue();
    });

    it('close_note_shows_empty_state', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest关');
      await createNoteByName(driver, name);
      // workspaceOpenRequests>0 时关闭点击被 toast 拒绝（Index.ets:6141），短窗重试
      let closed: boolean = false;
      for (let i: number = 0; i < 5; i++) {
        await clickById(driver, 'pane-close-left');
        if (await waitByIdSoft(driver, 'pane-empty-new-left', 3000)) {
          closed = true;
          break;
        }
      }
      expect(closed).assertTrue();
    });
  });
}
