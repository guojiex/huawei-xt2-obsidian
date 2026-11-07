/*
 * UiNoteFlow.test.ets —— 笔记流冒烟：新建 / 删除 / 撤销 / 回收站 / 关闭（EM-B2/B3/B4/B5、G1/G3 可达部分）。
 * 用例按注册顺序执行（创建类先行，删除类依赖树里有目标行）；映射见 docs/testing/UI自动化测试.md。
 *
 * ⚠️ inputText 对原生 TextInput 的注入即本套件的可用性探针（api_notes Z3）：
 * `create_note_with_name_full_flow` 失败且失败点是「树上没有该名字」时，输入类用例按环境阻塞处理，不算功能回归。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver, Component } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText, waitByTextContains,
  clickById, clickByText, existsById, existsByText, waitGoneByText,
  uniqueUiName, SNACK_MS } from './UiTestHelpers';

/** FileTreeView.onTreeRowKey 的行内菜单键（@ohos.multimodalInput.keyCode KEYCODE_MENU） */
const KEYCODE_MENU: number = 2067;

async function openCreateDialog(driver: Driver): Promise<void> {
  await clickById(driver, 'vault-sidebar-new-note');
  await waitByText(driver, '新建笔记');
}

/** 经新建弹窗创建一篇笔记：inputText 注入 + 确认 + 等文件树与栏就位 */
async function createNoteByName(driver: Driver, name: string): Promise<void> {
  await openCreateDialog(driver);
  const input: Component = await waitById(driver, 'note-create-input');
  await input.inputText(name);
  await clickByText(driver, '创建');
  await waitByTextContains(driver, name);
  await waitById(driver, 'pane-title-left');
}

/** 点文件树行（按展示名包含匹配）使其获得焦点；随后 triggerKey(MENU) 才能打开行内菜单 */
async function focusTreeRowByName(driver: Driver, name: string): Promise<void> {
  const row: Component = await waitByTextContains(driver, name);
  await row.click();
}

/** 行内菜单 → 删除 → 确认：移入回收站（不点撤销，撤销窗口留给调用方） */
async function deleteNoteConfirmed(driver: Driver, name: string): Promise<void> {
  await focusTreeRowByName(driver, name);
  await driver.triggerKey(KEYCODE_MENU);
  await clickByText(driver, '删除');
  await waitByText(driver, '删除笔记？');
  await clickByText(driver, '确认删除');
  expect(await waitGoneByText(driver, '删除笔记？')).assertTrue();
}

export default function uiNoteFlowTest() {
  describe('UiNoteFlow', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
    });

    it('create_note_dialog_open_and_cancel', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openCreateDialog(driver);
      await waitByText(driver, '取消');
      await waitByText(driver, '创建');
      await clickByText(driver, '取消');
      expect(await waitGoneByText(driver, '新建笔记')).assertTrue();
    });

    it('create_note_empty_name_keeps_dialog', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openCreateDialog(driver);
      await clickByText(driver, '创建');
      await driver.delayMs(800);
      expect(await existsByText(driver, '新建笔记')).assertTrue();
      await clickByText(driver, '取消');
      expect(await waitGoneByText(driver, '新建笔记')).assertTrue();
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
      await waitByTextContains(driver, name);
    });

    it('delete_note_confirm_and_undo', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest删');
      await createNoteByName(driver, name);
      await deleteNoteConfirmed(driver, name);
      // 撤销条只停 5 秒：短超时抓到就立刻点
      const undoBtn: Component = await waitByText(driver, '撤销', SNACK_MS);
      await undoBtn.click();
      await waitByTextContains(driver, name);
    });

    it('delete_note_dialog_cancel_keeps', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest留');
      await createNoteByName(driver, name);
      await focusTreeRowByName(driver, name);
      await driver.triggerKey(KEYCODE_MENU);
      await clickByText(driver, '删除');
      await waitByText(driver, '删除笔记？');
      await clickByText(driver, '取消');
      expect(await waitGoneByText(driver, '删除笔记？')).assertTrue();
      await waitByTextContains(driver, name);
    });

    it('trash_section_visible_after_delete', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest弃');
      await createNoteByName(driver, name);
      await deleteNoteConfirmed(driver, name);
      // 侧栏回收站区块只在有回收内容时渲染（TrashView）
      await waitByText(driver, '回收站');
      // 撤销条放着过期，不点；该笔记留在回收站（一次性模拟器环境的可接受残留）
    });

    it('close_note_shows_empty_state', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      const name: string = uniqueUiName('uitest关');
      await createNoteByName(driver, name);
      await clickById(driver, 'pane-close-left');
      await waitById(driver, 'pane-empty-new-left');
    });
  });
}
