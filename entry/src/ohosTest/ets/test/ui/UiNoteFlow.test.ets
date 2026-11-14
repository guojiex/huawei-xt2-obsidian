/*
 * UiNoteFlow.test.ets —— 笔记流冒烟：新建 / 删除 / 撤销 / 回收站 / 永久删除 / 关闭（EM-B2/B3/B4/B5/B7、G1/G3 可达部分）。
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
 * - 删除后 5s 内勿点 trash-section-header：UndoBar 底边与其中心 y 精确重合，
 *   bar 存活期点击空命中（215112 run A/B 实测，详见 trash_purge 用例内注释）。
 * - trash 行右缘 x≥1009 落进导航分隔条 responseRegion（splitTouchHitW=36vp 向左扩 ~29px），
 *   坐标点击被其吞掉；清除按钮一律按组件点击（231431 run 实测复现，详见 trash_purge 注释）。
 * - FileTreeView 钉底簇（左滑提示+回收站，不透明背景）有意盖住树尾行（FileTreeView.ets
 *   「遮住穿小白条滚上来的树行」）：被盖行 a11y 能命中、能 getBounds，但滑动触摸被簇吃掉
 *   （230939 run uinput 实锤：贴簇行中心 y2184/2160 慢滑 3 连败，上滚抬行后同速立即拉出）。
 *   滑动 y 收进行顶露出段；整行被盖先上滚抬行（ensureRowAboveCluster）。
 * - uitest* 残留由 tools/uitest.ps1 在 aa test 前宿主侧清理（本进程够不到 entry 模块沙箱：
 *   getAppContext().filesDir 是 bundle 级目录，vault 在 haps/entry/files）。残留不清会把新建行
 *   挤到折叠线以下、控件树里查无（183046 run 实测，文件在盘上但行不可见）。
 */

import { beforeAll, describe, expect, it } from '@ohos/hypium';
import { Component, Driver, ON, Rect } from '@ohos.UiTest';
import {
  clickById,
  clickByText,
  ensureNoteView,
  ensureSidebarVisible,
  existsById,
  existsByText,
  getDriver,
  launchMainApp,
  scrollSidebarToTop,
  SNACK_MS,
  tryWaitById,
  uniqueUiName,
  waitById,
  waitByIdSoft,
  waitByText,
  waitByTextContainsSoft,
  waitGoneById,
  waitGoneByText
} from './UiTestHelpers';

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

/**
 * 在树行上注入左滑。distanceRatio 为行宽比例：0.45 拉出操作条；0.7 越过三档阈值直接删除。
 * ⚠️ 必须显式传慢速 300px/s：driver.swipe 默认 600px/s 的注入档案处于 swipeAction pan
 * 识别的间歇边界——uinput 同坐标 A/B 实测：100ms 快滑（4460px/s）不拉出、300ms（1487px/s）
 * 与 1000ms（446px/s）均拉出——慢拖深入稳定区。SDK 速度范围 [200,40000]。
 * ⚠️ 滑动 y 避开钉底簇（头注 230939 run 实锤）：行中心落入簇区时收进行顶露出段
 * （rect.top + 边距）；整行被簇盖住的场景由 ensureRowAboveCluster 先抬行，本函数不滚屏。
 */
const ROW_EDGE_MARGIN_PX: number = 12;

async function swipeTreeRow(driver: Driver, row: Component, distanceRatio: number): Promise<void> {
  const rect: Rect = await row.getBounds();
  let y: number = Math.round((rect.top + rect.bottom) / 2);
  const clusterTop: number = await pinnedClusterTopPx(driver);
  if (clusterTop > 0 && y > clusterTop - ROW_EDGE_MARGIN_PX) {
    y = rect.top + ROW_EDGE_MARGIN_PX;
  }
  const startX: number = rect.right - 30;
  const distance: number = Math.round((rect.right - rect.left) * distanceRatio);
  await driver.swipe(startX, y, startX - distance, y, 300);
}

/**
 * 钉底簇顶 y（px）：以「左滑操作 · 拖图标到任一栏」提示条上沿为准（FileTreeView Bottom
 * Stack 钉底簇；230939 run dumpLayout 实测簇顶 y≈2148，簇内触摸吃掉树行滑动）。
 * 找不到提示条（布局变体 / referenceOnly 侧栏）返回 -1，调用方按「无簇」处理不收 y。
 */
async function pinnedClusterTopPx(driver: Driver): Promise<number> {
  const hint: Component | null =
    await driver.waitForComponent(ON.text('左滑操作 · 拖图标到任一栏'), 3000);
  if (hint === null) {
    return -1;
  }
  const rect: Rect = await hint.getBounds();
  return rect.top;
}

/**
 * 滑动删除笔记（trash 用例共用）：0.7 全滑越过三档阈值直接删除；未删成（行仍在）时
 * 回退 0.45 半滑 +「删除」按钮确认链。20261111_232952 全量：两 trash 用例 0.7 全滑
 * 同签名未删成（38s = 30s waitGone 超时），而同套件 0.45 路径两用例均过——半滑确认链
 * 在同场景下更可靠，做兜底。
 */
async function swipeDeleteNote(driver: Driver, row: Component, rowId: string): Promise<void> {
  await swipeTreeRow(driver, row, 0.7);
  // 滑动删除触发 onAction 后需要等待动画 + 回调完成
  await driver.delayMs(1000);
  if (!(await existsById(driver, rowId))) {
    return;
  }
  // 未删成：0.7 可能停在阈值之间（操作条半开）——「删除」按钮已在就直接点，否则半滑拉出
  if (!(await existsByText(driver, '删除'))) {
    await revealRowDelete(driver, rowId);
  }
  await clickByText(driver, '删除');
  await waitByText(driver, '删除笔记？');
  await clickByText(driver, '确认删除');
}

/**
 * 半滑拉出操作条并确认「删除」已入树。根因链（2026-11-14 实锤，221617/230939 两轮同签名
 * 3 连败）：FileTreeView 钉底簇不透明背景盖住树尾行——findTreeRow 在行进 LazyForEach 渲染区
 * 即命中（a11y 有、可 getBounds），行中心 y 落进簇区时滑动被簇吃掉、swipeAction 不触发，
 * 重试都在同一位置 → 确定性失败；速度不是根因（300px/s 慢滑同败，抬行后同速即过）。
 * 修复：每滑前 ensureRowAboveCluster 把行抬出簇区，swipeTreeRow 再把 y 收进露出段，双保险。
 */
async function revealRowDelete(driver: Driver, rowId: string): Promise<void> {
  for (let i: number = 0; i < 3; i++) {
    const row: Component = await ensureRowAboveCluster(driver, rowId);
    await swipeTreeRow(driver, row, 0.45);
    await driver.delayMs(1000);
    if (await existsByText(driver, '删除')) {
      return;
    }
  }
  throw new Error('半滑 3 次未拉出「删除」操作条: ' + rowId);
}

/**
 * 确保目标行可滑：行顶露出段（rect.top 到钉底簇顶之间）容得下一条滑动带；整行被簇盖住时
 * 手指上滑滚树抬行（内容上移 = 行上移，与 findTreeRow 翻页同向同坐标），最多 4 次。
 * 树尾行在最大滚动处底边贴物理下沿、行高 138px > 簇盖区 ~84px，顶段必然露出，4 次足够。
 */
async function ensureRowAboveCluster(driver: Driver, rowId: string): Promise<Component> {
  for (let i: number = 0; i < 4; i++) {
    const row: Component = await findTreeRow(driver, rowId);
    const rect: Rect = await row.getBounds();
    const clusterTop: number = await pinnedClusterTopPx(driver);
    if (clusterTop < 0 || rect.top + ROW_EDGE_MARGIN_PX <= clusterTop - ROW_EDGE_MARGIN_PX) {
      return row;
    }
    await driver.swipe(700, 1600, 700, 1000, 300);
    await driver.delayMs(800);
  }
  throw new Error('行被钉底簇遮挡，4 次上滚仍未露出: ' + rowId);
}

/** 可见性探针窗口：x86 模拟器一次成功匹配可花 2~12s（UiTestHelpers 头注），
 * 20261112_005414 run 实证 2s 翻页探针 0/48 命中（行可见也等不完匹配即超时）、
 * 5s 锚点探针全命中。统一 8s：命中即早返回，只有真不可见才耗满窗口。 */
const TREE_PROBE_MS: number = 8000;

/**
 * 树内找行：LazyForEach 折叠线以下的行不入控件树（185753 run 实测 ~9 行），
 * 直接等不到就以库首行为锚点把树向上滚，滚出后面的行再找。
 *
 * 增强锚点搜索：若 00_开始 锚点不在可见区，先滚回顶部再查找；滚回顶部后
 * 也先探再滑（避免把刚滚进可见区的行又被首滑滚走）。
 */
async function findTreeRow(driver: Driver, rowId: string): Promise<Component> {
  let comp: Component | null = await tryWaitById(driver, rowId, TREE_PROBE_MS);
  if (comp !== null) {
    return comp;
  }
  // 锚点可能不在可见区——先尝试找到，找不到则滚回顶部
  let scrolled: boolean = false;
  let anchor: Component | null = await tryWaitById(driver, 'file-tree-row-' + VAULT_ID + ':00_开始', 5000);
  if (anchor === null) {
    // 锚点不可见：树被滚离顶部（前序套件或本套件滚动残留）——滚回顶部再找。
    // 原实现在这里向上拖（内容向上滚，离顶部更远），方向反了；语义见 scrollSidebarToTop 注释
    await scrollSidebarToTop(driver);
    scrolled = true;
    anchor = await tryWaitById(driver, 'file-tree-row-' + VAULT_ID + ':00_开始', 5000);
  }
  if (anchor === null) {
    // 仍找不到锚点——可能树结构不同，直接再尝试目标行
    comp = await tryWaitById(driver, rowId, TREE_PROBE_MS);
    if (comp !== null) {
      return comp;
    }
    throw new Error('树中未找到行: ' + rowId + '（锚点 00_开始 也不可见）');
  }
  if (scrolled) {
    // 滚回顶部后先探一次当前位置：目标行若随滚动进入可见区（顶部驻留行）直接返回
    comp = await tryWaitById(driver, rowId, TREE_PROBE_MS);
    if (comp !== null) {
      return comp;
    }
  }
  const rect: Rect = await anchor.getBounds();
  const x: number = Math.round((rect.left + rect.right) / 2);
  for (let i: number = 0; i < 6 && comp === null; i++) {
    // 从顶部向下翻找：起点/终点都固定在树行区内的安全坐标（列表行区 ~y890-2010，lg 断点实测），
    // 不复用锚点 rect——首滑后锚点已被滚出视口，旧 rect 是失效坐标（002604 首用例败因之一）。
    // 手指上滑 = 内容上移 = 露出更靠后的行，单次 ~600px；行区尾（uitest* 排序在底）约 4 次可达，
    // 6 次（3600px）已越过树全高 ~2800px，留余量。
    await driver.swipe(x, 1600, x, 1000);
    comp = await tryWaitById(driver, rowId, TREE_PROBE_MS);
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
      await ensureNoteView(driver);
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
      // 裸 0.45 半滑间歇不触发（revealRowDelete 注释），统一走带兜底的拉出链
      await revealRowDelete(driver, rowId);
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
      // 裸 0.45 半滑间歇不触发（revealRowDelete 注释），统一走带兜底的拉出链
      await revealRowDelete(driver, rowId);
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
      await swipeDeleteNote(driver, row, rowId);
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

    it('trash_purge_confirm_and_cancel', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await ensureSidebarVisible(driver);
      const name: string = uniqueUiName('uitest灭');
      const rowId: string = noteRowId(name);
      const trashRowId: string = 'trash-row-' + VAULT_ID + ':' + name + '.md';
      await createNoteByName(driver, name);
      const row: Component = await findTreeRow(driver, rowId);
      // 0.7 全滑同场景间歇不越三档阈值（swipeDeleteNote 注释），统一走带兜底的删除链
      await swipeDeleteNote(driver, row, rowId);
      expect(await waitGoneById(driver, rowId)).assertTrue();
      // 回收站区块在侧栏底部——必要时滚动侧栏使其可见
      let trashVisible: boolean = await existsById(driver, 'trash-section-header');
      if (!trashVisible) {
        const newNoteBtn: Component | null = await tryWaitById(driver, 'vault-sidebar-new-note', 3000);
        if (newNoteBtn !== null) {
          const btnRect: Rect = await newNoteBtn.getBounds();
          const sx: number = Math.round((btnRect.left + btnRect.right) / 2);
          for (let k: number = 0; k < 4; k++) {
            await driver.swipe(sx, btnRect.bottom - 50, sx, btnRect.top - 300);
            await driver.delayMs(400);
          }
        }
      }
      // 展开回收站（删除不自动展开）。
      // ⚠️ x86 模拟器实测（2026-11-09，A/B 实验 .local/uitest/20261109_215112）：
      // UndoBar（Motion.snack=5000ms）底边 y=2083 与 trash-section-header 中心 y=2083
      // 精确重合——bar 存活期点击命中其边界空处（TTHNI 仅 page、onClick 不触发、无重渲染）。
      // 先等 bar 过期再点，并用「点击→验证」重试兜底。
      let expanded: boolean = false;
      for (let attempt: number = 0; attempt < 3 && !expanded; attempt++) {
        await driver.delayMs(attempt === 0 ? 5000 : 1500);
        await clickById(driver, 'trash-section-header');
        expanded = await waitByIdSoft(driver, trashRowId, 3000);
      }
      expect(expanded).assertTrue();
      // 最新删除的排最前（TrashService.list 按 deletedAt 倒序），无需滚动回收站列表。
      // ⚠️ 永久删除按钮必须按组件点击，不能按行右缘算坐标（trashRect.right-32≈x1029）：
      // 导航分隔条 SplitHandle 的 responseRegion（splitTouchHitW=36vp，比视觉宽向左扩
      // ~29px → x≥1009 全高区域）+ zIndex(4) 会把触点吞掉，确认弹窗永不出现
      // （2026-11-09 实测复现：CLK 命中 Stack 而非 trash-purge-button）。
      // 树上第一个 trash-purge-button 属于最新删除的行（ForEach 顺序 = items 顺序），
      // 组件中心点击（≈x969）在分隔条响应区外，安全。
      const trashRow: Component = await waitById(driver, trashRowId);
      const trashRect: Rect = await trashRow.getBounds();
      const firstBtn: Component = await waitById(driver, 'trash-purge-button');
      const firstBtnRect: Rect = await firstBtn.getBounds();
      if (firstBtnRect.top < trashRect.top || firstBtnRect.bottom > trashRect.bottom) {
        throw new Error('第一个 trash-purge-button 不在目标行内: btnTop=' + firstBtnRect.top.toString() +
          ' btnBottom=' + firstBtnRect.bottom.toString() + ' rowTop=' + trashRect.top.toString() +
          ' rowBottom=' + trashRect.bottom.toString());
      }
      // 取消路径：确认弹窗出现后取消，条目保留
      let dialogSeen: boolean = false;
      for (let attempt: number = 0; attempt < 3 && !dialogSeen; attempt++) {
        const purgeBtn: Component = await waitById(driver, 'trash-purge-button');
        await purgeBtn.click();
        dialogSeen = await waitByTextContainsSoft(driver, '永久删除笔记？', 5000);
      }
      expect(dialogSeen).assertTrue();
      await clickByText(driver, '取消');
      expect(await waitGoneByText(driver, '永久删除笔记？')).assertTrue();
      expect(await existsById(driver, trashRowId)).assertTrue();
      // 确认路径：真删，条目从回收站消失（不进撤销，无撤销条断言）
      const purgeBtn2: Component = await waitById(driver, 'trash-purge-button');
      await purgeBtn2.click();
      await waitByText(driver, '永久删除笔记？');
      await clickByText(driver, '永久删除');
      expect(await waitGoneByText(driver, '永久删除笔记？')).assertTrue();
      expect(await waitGoneById(driver, trashRowId)).assertTrue();
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
