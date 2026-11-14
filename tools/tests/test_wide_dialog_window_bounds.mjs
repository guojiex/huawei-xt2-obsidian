import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.13：宽屏弹窗限定在应用窗口内 ——
// 原型 positionSheetDialog：宽屏 gap=--s8，顶边不高于窗口顶部 --s8、底边不低于窗口底部 --s8，
// 超出部分在弹窗内滚动；水平居中；分享面板顶部锚定（v1.25 标题不跳）；单屏半模态不变。
//
// 原生映射：
// - CustomDialog 本就渲染在应用窗口内（不会越出窗口），核心是高度约束保证上下边距 ≥ s8；
// - UtilityDialogShell 宽屏 dialogMaxHeight = windowHeightVp - s8*2（覆盖导入/同步/新建/
//   重命名/删除/快切/库操作/分享面板），单屏 0.86 不变；
// - 分享预览/设置弹窗外壳限高 windowH - s8*2（原 s6 居中后边距仅 12 < 32）；
// - 分享面板标题不跳由 v1.25 原生恒高法实现（scopeFormatAreaHeight 取各 scope 最大行数），
//   居中不跳动，无需原型式顶部锚定；
// - 回收站原生为侧栏内可展开区块（v0.2 需求 1.8），非弹窗，无窗口越界问题。
const read = (rel) => readSourceFile(new URL(rel, import.meta.url));
const shell = read('../../entry/src/main/ets/components/UtilityDialogShell.ets');
const shareFile = read('../../entry/src/main/ets/components/ShareFilePreviewDialog.ets');
const shareImage = read('../../entry/src/main/ets/components/ShareImagePreviewDialog.ets');
const shareText = read('../../entry/src/main/ets/components/ShareTextPreviewDialog.ets');
const shareImageSettings = read('../../entry/src/main/ets/components/ShareImageSettingsDialog.ets');
const shareNote = read('../../entry/src/main/ets/components/ShareNoteDialog.ets');
const index = read('../../entry/src/main/ets/pages/Index.ets');
const shareFlow = read('../../entry/src/main/ets/components/ShareFlowPanel.ets');
const proto = read('../../docs/prototype/v2/index.html');

test('32.13 原型：宽屏弹窗上下边距 gap=--s8，超出滚动', () => {
  assert.match(proto, /function positionSheetDialog\(dialog\)/);
  // gap 取 --s8（缺省 32），room 从窗口可用高中扣除上下各一个 gap
  assert.match(proto, /const gap=parseFloat\(getComputedStyle\(document\.body\)\.getPropertyValue\('--s8'\)\)\|\|32/);
  assert.match(proto, /room=Math\.max\(0,bottom0-top0-gap\*2\)/);
  // 底边不低于窗口底部 --s8：maxHeight = bottom0 - gap - top
  assert.match(proto, /dialog\.style\.maxHeight=Math\.round\(bottom0-gap-top\)\+'px'/);
  // 顶边 = top0 + gap +（分享面板锚顶 0 / 其他居中偏移）
  assert.match(proto, /const top=top0\+gap\+\(anchorTop\?0:Math\.max\(0,\(room-h\)\/2\)\)/);
});

test('32.13 原生：UtilityDialogShell 宽屏限高 = 窗口高 - 上下各 s8，单屏 0.86 不变', () => {
  assert.match(shell, /private dialogMaxHeight\(\): number \{[\s\S]*?if \(this\.singleScreen\) \{\s*return this\.windowHeightVp \* 0\.86;\s*\}/);
  assert.match(shell, /return Math\.max\(0, this\.windowHeightVp - Space\.s8 \* 2\);/);
  // 不再使用宽屏 0.8 比例（精确匹配，避免误伤单屏 0.86）
  assert.doesNotMatch(shell, /\? 0\.8 :/);
  // 超出部分弹窗内滚动：shell 内容区滚动约束仍在
  assert.match(shell, /constraintSize\(\{ maxHeight: this\.contentMaxHeight\(\) \}\)/);
});

test('32.13 原生：分享预览/设置弹窗外壳限高保证居中边距 ≥ s8', () => {
  // 25.19 重构后三个分享弹窗（图片 / 文本 / 设置）全部改用 UtilityDialogShell，
  // 限高由 shell 的 dialogMaxHeight（windowH - s8*2 / 单屏 0.86）统一保证；
  // 逐个锁定必须传 windowHeightVp，否则 shell 退回 menuMaxH 常数。
  for (const src of [shareImage, shareText, shareImageSettings]) {
    assert.match(src, /UtilityDialogShell\(\{/, '分享弹窗应使用 UtilityDialogShell 外壳');
    assert.match(src, /windowHeightVp: this\.windowHeightVp/, '必须把窗口高度传给 shell 限高');
    assert.doesNotMatch(src, /windowHeightVp - Space\.s6\)/, 's6 限高居中后边距仅 12，应替换为 s8*2');
  }
  assert.match(shareFile, /UtilityDialogShell\(\{/);
});

test('32.13 原生：分享面板标题不跳（恒高法沿用 v1.25），宽屏居中不锚顶', () => {
  // 恒高法：格式区高度取各 scope 最大行数 → 切 scope 面板总高不变，居中下标题不跳
  assert.match(shareNote, /private scopeFormatAreaHeight\(\): number \{[\s\S]*?maxRows/s);
  assert.match(shareNote, /\.height\(this\.scopeFormatAreaHeight\(\)\)/);
  // 宽屏分享面板与其他弹窗一样垂直居中（DialogAlignment.Center），不改为 Top 锚定
  //（分享域拆至 ShareFlowPanel，弹窗对齐断言读子组件）
  assert.match(shareFlow, /alignment: shareSheet \? DialogAlignment\.Bottom : DialogAlignment\.Center/);
  assert.doesNotMatch(shareFlow, /DialogAlignment\.Top/);
});

test('32.13 原生：单屏半模态不变（Bottom 贴底 + 0.86）', () => {
  assert.match(index, /alignment: syncSheet \? DialogAlignment\.Bottom : DialogAlignment\.Center/);
  assert.match(shell, /return this\.windowHeightVp \* 0\.86;/);
});
