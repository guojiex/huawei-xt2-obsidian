/*
 * UiShare.test.ets —— 分享域冒烟（EM-J1/J2/J3/J4 可达部分、v0.9 9.14、v1.25 长图、v1.53 PDF 能力自适应）。
 *
 * 核心回归线（2026-11-09 用户报障）：更多菜单点「分享笔记」后，应用内分享面板必须真的打开。
 * 旧用例（UiPanels.share_panel_accessible_from_more_menu）只断言菜单项可见、从不点击，
 * 面板拉不起来时测不到——本套件补齐点击穿透与全部分享预览链路。
 *
 * 关键判定约束（详见 docs/testing/UI自动化测试.md）：
 * - 面板「打开了」用弹窗独有文本（格式行「长图」）判定，不用与菜单项同名的标题「分享笔记」。
 * - 系统分享面板交接只做冒烟：无 handoff 错误文案 + 取消后应用内弹窗保留；系统面板标记尽力探测不硬断言。
 * - 长图只断言设置区与往返导航，不断言成图（渲染截图不在 UiTest 可靠断言范围）。
 */

import { describe, beforeAll, it, expect } from '@ohos/hypium';
import { Driver, ON, Component } from '@ohos.UiTest';
import { getDriver, launchMainApp, waitById, waitByText,
  clickById, clickByText, existsById, existsByText, waitGoneById,
  waitByIdSoft, waitByTextContainsSoft, clickUntilTextAppear, clickByTextUntilTextAppear,
  ensureSidebarVisible, scrollSidebarToTop, uniqueUiName } from './UiTestHelpers';

/** 首装教程库 id（uitest.ps1 清理目录同名） */
const TUTORIAL_VAULT_ID: string = '曜石笔记教程';

/** 交接失败文案前缀（UserErrorMessages handoff 档）——出现即回归 */
const HANDOFF_ERROR_FRAGMENT: string = '系统分享交接未完成';

/** 系统分享面板尽力探测标记（api_notes O1：模拟器上面板有华为分享/复制/另存为/中转站）。
 *  UiTest 对系统弹窗的可见性未核实，探测结果不做硬断言，仅冒烟取证。 */
const SYSTEM_PANEL_MARKERS: string[] = ['华为分享', '复制', '另存为', '中转站'];

/**
 * 关掉上个用例失败残留的工具弹窗（utility-dialog-close）。
 * 用例抛错时不清理现场（弹窗 autoCancel:false 残留遮罩吞点击，曾连锁搞挂后续用例，
 * 2026-11-11 首轮 3 败即此传染）；关闭可能链式再开一层（如长图预览取消重开格式面板），最多关 3 层。
 */
async function closeLeftoverDialogs(driver: Driver): Promise<void> {
  for (let i: number = 0; i < 3; i++) {
    if (!await existsById(driver, 'utility-dialog-close')) {
      return;
    }
    await clickById(driver, 'utility-dialog-close');
    const closed: boolean = await waitGoneById(driver, 'utility-dialog-close', 10000);
    if (!closed) {
      return;
    }
  }
}

/** 等教程笔记「快速上手」出现在侧栏：文件树异步加载 + 00_开始 目录可能折叠（点开重试）。
 *  树被前序套件滚离顶部时顶行不入 a11y 树（LazyForEach 折叠线；20261111_232952 全量：
 *  UiNoteFlow 滚树后本套件 9 ERROR 同签名）——探测落空先滚回顶部再探。 */
async function waitForTutorialNote(driver: Driver, probeMs: number): Promise<boolean> {
  const deadline: number = Date.now() + probeMs;
  let scrolledUp: boolean = false;
  while (Date.now() < deadline) {
    if (await existsByText(driver, '快速上手')) {
      return true;
    }
    if (await existsByText(driver, '00_开始')) {
      await clickByText(driver, '00_开始');
      await driver.delayMs(800);
      continue;
    }
    if (!scrolledUp) {
      scrolledUp = true;
      await scrollSidebarToTop(driver);
      continue;
    }
    await driver.delayMs(600);
  }
  return await existsByText(driver, '快速上手');
}

/**
 * 打开教程笔记「快速上手」（00_开始 目录下）。
 * 当前库可能不是教程库（空库探针用例建删库会把当前库切走）——先在当前库找，
 * 找不到经库切换菜单切回教程库再找。
 */
async function openTutorialNote(driver: Driver): Promise<void> {
  await closeLeftoverDialogs(driver);
  await ensureSidebarVisible(driver);
  let noteVisible: boolean = await waitForTutorialNote(driver, 8000);
  if (!noteVisible) {
    // 当前库不是教程库：切回去（非教程库时「曜石笔记教程」在菜单中唯一）
    await clickById(driver, 'vault-switcher-trigger');
    await clickByText(driver, '曜石笔记教程');
    await driver.delayMs(2000);
    noteVisible = await waitForTutorialNote(driver, 15000);
  }
  if (!noteVisible) {
    throw new Error('教程笔记「快速上手」不可见：教程库缺失或文件树未加载');
  }
  await clickByText(driver, '快速上手');
  // 等笔记在编辑器中加载（pane-title-left 出现表示笔记已打开）
  await waitByIdSoft(driver, 'pane-title-left', 5000);
  await driver.delayMs(800);
}

/**
 * 更多菜单 → 点「分享笔记」→ 等分享面板真的出现（格式行「长图」）。
 * 弹窗标题与菜单项同名（都是「分享笔记」），判定必须用弹窗独有文本。
 * 冷启动首击可能被吞（UiTestHelpers.clickUntilTextAppear 注释），整体套重试。
 */
async function openShareFormatPanel(driver: Driver): Promise<void> {
  for (let attempt: number = 0; attempt < 3; attempt++) {
    const menuOpen: boolean = await existsByText(driver, '分享笔记');
    if (!menuOpen) {
      await clickUntilTextAppear(driver, 'workspace-more-button', '分享笔记', 3, 15000);
    }
    await clickByText(driver, '分享笔记');
    // 弹窗独有文本：格式行「长图」（菜单里没有这个词条）
    const panelOpened: Component | null = await driver.waitForComponent(ON.text('长图'), 8000);
    if (panelOpened !== null) {
      return;
    }
    // 本次点击未拉开面板（吞点或 Toast「请先打开一篇笔记」）——重试
  }
  throw new Error('分享面板未打开：点击「分享笔记」后未出现格式行「长图」（openShareNoteDialog 需要 activeFilePath）');
}

/** 关闭分享面板（UtilityDialogShell ×），并确认真的关了（格式行消失） */
async function closeSharePanel(driver: Driver): Promise<void> {
  await clickById(driver, 'utility-dialog-close');
  // 用关闭按钮本身判消失：「长图」只在笔记格式面板存在，vault/文件夹范围弹窗里用它校验等于空校验
  const closed: boolean = await waitGoneById(driver, 'utility-dialog-close', 10000);
  if (!closed) {
    throw new Error('分享面板未关闭：点 × 后弹窗仍在');
  }
}

export default function uiShareTest() {
  describe('UiShare', () => {
    beforeAll(async (): Promise<void> => {
      await launchMainApp();
    });

    /** EM-J2 核心：更多菜单「分享笔记」点击穿透——应用内分享面板真的打开 */
    it('share_panel_opens_from_more_menu', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      // 笔记范围的三种基础格式行都在（PDF 行按设备能力显示，见最后一个用例）
      expect(await existsByText(driver, '长图')).assertTrue();
      expect(await existsByText(driver, 'Markdown / ZIP')).assertTrue();
      expect(await existsByText(driver, '文本')).assertTrue();
      // 描述行：面板内容按范围渲染，不是空壳
      expect(await existsByText(driver, '当前笔记及其引用的库内图片，不包含链接到的其他笔记。')).assertTrue();
      // EM-J4 反向：教程库不是 Git 库，不得出现「远端网页链接」行
      expect(await existsByText(driver, '远端网页链接')).assertFalse();
      await closeSharePanel(driver);
    });

    /** EM-J2 25.12/25.13：范围分段切换，各范围标题与格式列表正确 */
    it('share_scope_segments_switch_formats', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      // 教程笔记在 00_开始 目录下 → 三个范围分段都在
      expect(await existsByText(driver, '笔记')).assertTrue();
      expect(await existsByText(driver, '文件夹')).assertTrue();
      expect(await existsByText(driver, '知识库')).assertTrue();
      // 切到知识库：标题与 ZIP 行
      await clickByText(driver, '知识库');
      await waitByText(driver, '分享知识库');
      expect(await existsByText(driver, 'ZIP 文件')).assertTrue();
      // 切到文件夹：标题与 ZIP 行
      await clickByText(driver, '文件夹');
      await waitByText(driver, '分享文件夹');
      expect(await existsByText(driver, 'ZIP 文件')).assertTrue();
      // 切回笔记：长图行恢复
      await clickByText(driver, '笔记');
      await waitByText(driver, '分享笔记');
      expect(await existsByText(driver, '长图')).assertTrue();
      await closeSharePanel(driver);
    });

    /** v0.9 9.14：文本分享详情（可编辑说明 + 返回格式选择）可达并返回 */
    it('share_note_text_preview_roundtrip', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      await clickByText(driver, '文本');
      await waitByText(driver, '文本分享');
      expect(await existsByText(driver, '可编辑将要交接的纯文本；此处修改不会写回笔记。')).assertTrue();
      expect(await existsByText(driver, '返回格式选择')).assertTrue();
      // 返回格式选择 → 回到分享格式面板（长图行重现）
      await clickByText(driver, '返回格式选择');
      await waitByText(driver, '长图');
      await closeSharePanel(driver);
    });

    /** EM-J2（取消系统分享）：分享文本调起系统分享；取消后应用内弹窗保留、无交接失败文案 */
    it('share_text_system_handoff_cancel_keeps_dialog', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      await clickByText(driver, '文本');
      await waitByText(driver, '文本分享');
      await clickByText(driver, '分享文本');
      // 等系统分享面板交接（x86 模拟器慢）
      await driver.delayMs(4000);
      // 交接失败必须显式报错，不许静默（v0.9 9.14）——这里断言没有失败
      const handoffFailed: boolean = await waitByTextContainsSoft(driver, HANDOFF_ERROR_FRAGMENT, 1500);
      expect(handoffFailed).assertFalse();
      // 系统分享面板标记尽力探测（对 UiTest 的可见性未核实，不做硬断言）
      let systemPanelVisible: boolean = false;
      for (let i: number = 0; i < SYSTEM_PANEL_MARKERS.length; i++) {
        const markerVisible: boolean = await waitByTextContainsSoft(driver, SYSTEM_PANEL_MARKERS[i], 1500);
        if (markerVisible) {
          systemPanelVisible = true;
          break;
        }
      }
      // 取消系统分享：面板开着 → back 收起；没开 → back 走应用返回链（弹窗 autoCancel:false 不受影响）
      await driver.pressBack();
      await driver.delayMs(1500);
      // 取消不交接：文本预览弹窗保留
      expect(await existsByText(driver, '文本分享')).assertTrue();
      await clickByText(driver, '返回格式选择');
      await waitByText(driver, '长图');
      await closeSharePanel(driver);
    });

    /** EM-J2：Markdown / ZIP 文件详情（标题/分享文件/返回）可达并返回 */
    it('share_note_file_preview_roundtrip', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      await clickByText(driver, 'Markdown / ZIP');
      // 文件准备是异步的（读内容 + 本地打包），详情弹窗在准备完成后出现
      await waitByText(driver, '分享文件', 30000);
      // 标题按实际格式「Markdown 分享 / ZIP 分享」（有无本地配图决定）
      const mdTitle: boolean = await existsByText(driver, 'Markdown 分享');
      const zipTitle: boolean = await existsByText(driver, 'ZIP 分享');
      expect(mdTitle || zipTitle).assertTrue();
      expect(await existsByText(driver, '返回')).assertTrue();
      // 返回 → 重新打开分享格式面板
      await clickByText(driver, '返回');
      await waitByText(driver, '长图');
      await closeSharePanel(driver);
    });

    /** EM-J2 / v1.19 / v1.25：长图详情（宽度/外观设置区 + 返回）可达并返回；不断言成图 */
    it('share_long_image_preview_roundtrip', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      await clickByText(driver, '长图');
      await waitByText(driver, '长图分享');
      // 宽度预设与外观分段（生成在后台进行，设置区常驻可断言）
      expect(await existsByText(driver, '宽度')).assertTrue();
      expect(await existsByText(driver, '外观')).assertTrue();
      expect(await existsByText(driver, '浅色')).assertTrue();
      expect(await existsByText(driver, '深色')).assertTrue();
      expect(await existsByText(driver, '返回')).assertTrue();
      // 取消（返回）→ onCancel 重开分享格式面板
      await clickByText(driver, '返回');
      await waitByText(driver, '长图');
      await closeSharePanel(driver);
    });

    /** EM-J2：知识库范围 ZIP 详情（标题/1 个 ZIP/分享文件）可达并返回 */
    it('share_vault_zip_preview_roundtrip', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      await clickByText(driver, '知识库');
      await waitByText(driver, '分享知识库');
      await clickByText(driver, 'ZIP 文件');
      // 知识库打包是异步的（遍历 + 压缩），详情弹窗在打包完成后出现
      await waitByText(driver, 'ZIP 分享', 30000);
      expect(await existsByText(driver, '1 个 ZIP')).assertTrue();
      expect(await existsByText(driver, '分享文件')).assertTrue();
      await clickByText(driver, '返回');
      // 返回后仍在知识库范围的格式面板
      await waitByText(driver, '分享知识库');
      expect(await existsByText(driver, 'ZIP 文件')).assertTrue();
      await closeSharePanel(driver);
    });

    /** EM-J1 / v1.25 25.18：库管理「分享」入口 → 仅 ZIP 的「分享知识库」面板 */
    it('share_vault_entry_from_manager', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await closeLeftoverDialogs(driver);
      await ensureSidebarVisible(driver);
      // x86 注入抖动（2026-11-11 实测）：切换器/管理库/分享入口三跳点击均可能被单次吞掉，
      // 每跳都用「点到位才继续」重试，避免中途卡死把后续用例拖进库管理页连锁失败
      await clickUntilTextAppear(driver, 'vault-switcher-trigger', '管理库…', 3, 8000);
      await clickByTextUntilTextAppear(driver, '管理库…', '＋ 新建笔记库', 3, 8000);
      await clickUntilTextAppear(driver, 'vault-manager-share-' + TUTORIAL_VAULT_ID, '分享知识库', 3, 15000);
      expect(await existsByText(driver, 'ZIP 文件')).assertTrue();
      // 关闭后回到库管理（恢复焦点到分享按钮）
      await closeSharePanel(driver);
      await waitByText(driver, '＋ 新建笔记库');
      await driver.pressBack();
      await waitById(driver, 'workspace-more-button');
    });

    /** EM-J3 / v1.37 37.2：设置 → 数据 → 导出当前知识库复用同一分享面板 */
    it('share_export_current_vault_from_settings', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await closeLeftoverDialogs(driver);
      await clickUntilTextAppear(driver, 'workspace-more-button', '设置与关于', 3, 15000);
      await clickByText(driver, '设置与关于');
      await waitById(driver, 'settings-heading-general');
      await clickById(driver, 'settings-category-data');
      await waitById(driver, 'settings-heading-data');
      await clickUntilTextAppear(driver, 'settings-export-vault-row', '分享知识库', 3, 15000);
      expect(await existsByText(driver, 'ZIP 文件')).assertTrue();
      await closeSharePanel(driver);
      // 关闭后仍在设置数据页（导出行在）
      await waitById(driver, 'settings-export-vault-row');
      await driver.pressBack();
      await waitById(driver, 'workspace-more-button');
    });

    /** v1.53 53.3 能力自适应：有「PDF 文档」行则点入断言详情弹窗出现；无则基础三行在（优雅降级） */
    it('share_pdf_row_matches_capability', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await openTutorialNote(driver);
      await openShareFormatPanel(driver);
      const pdfRowVisible: boolean = await existsByText(driver, 'PDF 文档');
      if (pdfRowVisible) {
        await clickByText(driver, 'PDF 文档');
        // PDF 渲染是异步的：成功走文件预览（分享文件/返回），失败也走文件预览（重试生成）
        await waitByText(driver, '分享文件', 30000);
        expect(await existsByText(driver, '返回')).assertTrue();
        await clickByText(driver, '返回');
        await waitByText(driver, '长图');
      } else {
        // 不支持 PDF 的设备：基础三行必须在（优雅降级不残缺）
        expect(await existsByText(driver, '长图')).assertTrue();
        expect(await existsByText(driver, 'Markdown / ZIP')).assertTrue();
        expect(await existsByText(driver, '文本')).assertTrue();
      }
      await closeSharePanel(driver);
    });

    /** EM-J1 空库禁用：空库的分享入口禁用（新建空库探针 + 断言 + 删除清理） */
    it('share_empty_vault_entry_disabled', 0, async (): Promise<void> => {
      const driver: Driver = await getDriver();
      await closeLeftoverDialogs(driver);
      await ensureSidebarVisible(driver);
      // x86 注入抖动：切换器/管理库两跳点击均可能被单次吞掉（20261111_232952 全量 case 11
      // 实测 30s 超时即此因；case 8 同路径带重试通过）——每跳「点到位才继续」，与 case 8 同款
      await clickUntilTextAppear(driver, 'vault-switcher-trigger', '管理库…', 3, 8000);
      await clickByTextUntilTextAppear(driver, '管理库…', '＋ 新建笔记库', 3, 8000);
      await clickByText(driver, '＋ 新建笔记库');
      const vaultName: string = uniqueUiName('uitest_share_empty');
      const input: Component = await waitById(driver, 'vault-create-input');
      await input.inputText(vaultName);
      await clickByText(driver, '创建');
      // 新库出现在库管理列表（doCreateVault 会自动切换到新库）
      const shareBtn: Component = await waitById(driver, 'vault-manager-share-' + vaultName, 30000);
      expect(await shareBtn.isEnabled()).assertFalse();
      expect(await existsByText(driver, '这个库还没有笔记')).assertTrue();
      // 清理测试库（删除确认 → 确认删除 → 行消失）
      await clickById(driver, 'vault-manager-delete-' + vaultName);
      await waitByText(driver, '删除本地笔记？');
      await clickByText(driver, '确认删除');
      expect(await waitGoneById(driver, 'vault-manager-share-' + vaultName, 30000)).assertTrue();
      await driver.pressBack();
      await waitById(driver, 'workspace-more-button');
      // 删除当前库后应用会回落到列表里的另一个库（实测回落到「我的笔记」）——
      // 套件必须把当前库还原成教程库，否则污染后续全量回归的 UiLaunch/UiNoteFlow/UiSmDrawer
      // （2026-11-11 全量回归 UiNoteFlow 7 ERROR 即此因）。用 00_开始 目录可见判定切库成功。
      await clickById(driver, 'vault-switcher-trigger');
      await clickByText(driver, '曜石笔记教程');
      await waitByText(driver, '00_开始', 15000);
    });
  });
}
