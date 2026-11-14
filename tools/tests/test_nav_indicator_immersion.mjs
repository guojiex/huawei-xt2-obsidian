/**
 * 底部手势条沉浸防线（v1.57 57.4，需求池 Y-01）。
 *
 * 背景：官方 UX 标准要求次级页面可滚动内容显示在导航条下方（qa/2026-11-13
 * 手势条问答，api_notes AE2）。落地方式：次级页面滚动容器加
 * `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])`，内容底部
 * 留白 = 既有间距 + 导航条避让高度（`navIndicatorHeightPx` 动态值，禁止硬编码）。
 *
 * 规则：
 *  1. 四个次级滚动容器（设置分类列表 / 设置内容 / 版本记录 / 库管理）
 *     必须带 `expandSafeArea(... SafeAreaEdge.BOTTOM)`——被误删即本测试失败；
 *     （v1.58 58.1 起统计改弹窗，退出次级页清单）
 *  2. EntryAbility 必须监听 TYPE_NAVIGATION_INDICATOR 并发布
 *     `navIndicatorHeightPx`（初始 + avoidAreaChange 两处）；
 *  3. 消费该值的视图必须同时有 `@StorageProp('navIndicatorHeightPx')` 与
 *     页面侧 `px2vp` 换算（官方口径：px2vp 在 UI 上下文才可靠）；
 *  4. 工作区底部表面延伸不被宿主 `.clip(true)` 裁剪（57.6，Y-02）；
 *  5. 工作区固定内容（状态条 / 钉底簇 / 连写条）offset 压进条带、滚动容器
 *     （文件树 / 章节列表）穿小白条且末条让位（57.7，Y-03）——下移量一律取
 *     `navIndicatorHeightPx` 动态值，禁止硬编码；
 *  6. onAreaChange 的 `Area.height/width` 单位是 vp：chipH / clusterH 消费处
 *     禁止再 `px2vp`（2026-11-14 真机图实测二次换算把回收站行压进两行连写条
 *     后面）；嵌入簇 offset 不得钳 0——连写条（两行卡 ~49vp）高于条带（~28vp）
 *     时差值为负，簇要上移与连写条顶相接。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const etsRoot = join(repoRoot, 'entry/src/main/ets');
const EXPAND = 'expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])';

function read(rel) {
  return readFileSync(join(etsRoot, rel), 'utf8');
}

test('次级页面滚动容器带底部 expandSafeArea', () => {
  const targets = [
    ['components/SettingsView.ets', 3], // 单屏分类列表 / 多屏侧栏 / 内容区
    ['components/ReleaseHistoryView.ets', 1],
    ['components/VaultManagerView.ets', 1],
    // v1.58 58.1 起统计改为 UtilityDialogShell 弹窗（非次级页），不再要求 expandSafeArea
  ];
  for (const [rel, minCount] of targets) {
    const src = read(rel);
    const count = src.split(EXPAND).length - 1;
    assert.ok(count >= minCount,
      `${rel} 应有 ≥${minCount} 处 ${EXPAND}，实际 ${count}（v1.57 57.1 误删即回归）`);
  }
});

test('EntryAbility 发布导航条避让高度（初始 + avoidAreaChange）', () => {
  const src = read('entryability/EntryAbility.ets');
  assert.ok(src.includes('TYPE_NAVIGATION_INDICATOR'),
    'EntryAbility 必须处理 TYPE_NAVIGATION_INDICATOR（v1.57 57.2）');
  assert.ok(src.includes("'navIndicatorHeightPx'"),
    "EntryAbility 必须发布 'navIndicatorHeightPx' 到 AppStorage");
  // 初始值（getWindowAvoidArea）与变化值（avoidAreaChange 监听内）两条路径都要在
  assert.ok(src.includes('getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)'),
    '启动时须经 getWindowAvoidArea 补发初始导航条避让高度（同 keyboardInsetPx 先例）');
});

test('消费视图必须走 StorageProp + 页面侧 px2vp', () => {
  const consumers = [
    'components/SettingsView.ets',
    'components/ReleaseHistoryView.ets',
    'components/VaultManagerView.ets',
    'components/VaultStatsView.ets',
  ];
  for (const rel of consumers) {
    const src = read(rel);
    assert.ok(src.includes("@StorageProp('navIndicatorHeightPx')"),
      `${rel} 缺 @StorageProp('navIndicatorHeightPx')`);
    assert.ok(src.includes('px2vp('),
      `${rel} 必须页面侧 px2vp 换算（官方提醒 UIAbility 早期换算可能异常）`);
    assert.ok(!/navClearanceVp[\s\S]{0,40}26/.test(src),
      `${rel} 避让高度禁止硬编码 26vp（三折叠各形态高度未记载）`);
  }
});

test('工作区底部表面延伸不被宿主裁剪（57.6，Y-02）', () => {
  const src = read('pages/Index.ets');
  // 阻断点实测（2026-11-13 探针）：工作区分支宿主（多屏 Row / 单屏 Stack）的
  // .clip(true) 会把子列 expandSafeArea 的条带延伸整体裁掉——移除后侧栏
  // bg_navigation / 内容 bg_card 立即延伸到物理下沿。防御性再加回即回归。
  assert.ok(!src.includes('.clip(true)'),
    'pages/Index.ets 工作区分支宿主不得带 .clip(true)（裁掉底部安全区延伸，v1.57 57.6）；确需局部裁剪须改为不覆盖条带的形式并同步更新本测试');
  // 底部三个表面的「背景色 + expandSafeArea」配对必须保持：
  // 导航侧栏 ×2（单屏抽屉 / 多屏侧栏）、内容列 ×1、单屏遮罩 ×1。
  const pairs = [
    ['bg_navigation', 2],
    ['bg_card', 1],
    ['mask', 1],
  ];
  for (const [color, minCount] of pairs) {
    const re = new RegExp(
      `\\.backgroundColor\\(\\$r\\('app\\.color\\.${color}'\\)\\)\\s*` +
      `\\.expandSafeArea\\(\\[SafeAreaType\\.SYSTEM\\], \\[SafeAreaEdge\\.BOTTOM\\]\\)`, 'g');
    const count = (src.match(re) || []).length;
    assert.ok(count >= minCount,
      `pages/Index.ets 底部表面 ${color} 应有 ≥${minCount} 处「背景色 + expandSafeArea(BOTTOM)」配对，实际 ${count}（v1.57 57.6 误删即回归）`);
  }
});

test('工作区可见文字压到物理下沿（57.7，Y-03）', () => {
  // 状态条：NoteWorkspaceContent 根改 Bottom Stack，Statusbar 整条 offset 进条带
  const idx = read('pages/Index.ets');
  assert.ok(idx.includes("@StorageProp('navIndicatorHeightPx')"),
    "pages/Index.ets 缺 @StorageProp('navIndicatorHeightPx')（v1.57 57.7）");
  assert.ok(idx.includes('px2vp(Math.max(0, this.navIndicatorHeightPx))'),
    'pages/Index.ets navClearanceVp() 必须页面侧 px2vp 换算（官方提醒 UIAbility 早期换算可能异常）');
  assert.ok(/Stack\(\{ alignContent: Alignment\.Bottom \}\) \{\s*\n\s*Column\(\) \{\s*\n\s*this\.Appbar\(\)/.test(idx),
    'pages/Index.ets NoteWorkspaceContent 须为 Bottom Stack{Column[Appbar, NoteBody], Statusbar}（57.7 重构被撤销即文字悬在 2152 上方）');
  assert.ok(/\.backgroundColor\(\$r\('app\.color\.bg_card'\)\)[\s\S]{0,220}?\.offset\(\{ y: this\.navClearanceVp\(\) \}\)/.test(idx),
    'pages/Index.ets Statusbar 必须带 .offset({ y: this.navClearanceVp() })（整条压进手势条条带，边界线到 2152、条底贴 2232）');

  // 文件树：钉底簇 offset 进条带 + 树 List 穿小白条 + 末条让位（Agent 引用树除外）
  const ftv = read('components/FileTreeView.ets');
  assert.ok(ftv.includes('@Prop clusterOffsetVp: number = 0;'),
    'FileTreeView 缺 @Prop clusterOffsetVp（父级算好的钉底簇下移量，抽屉/嵌入两形态不同）');
  assert.ok(ftv.includes("@StorageProp('navIndicatorHeightPx')"),
    "FileTreeView 缺 @StorageProp('navIndicatorHeightPx')");
  assert.ok(ftv.includes('.offset({ y: this.clusterOffsetVp })'),
    'FileTreeView 钉底簇必须 .offset({ y: this.clusterOffsetVp })（AE4：布局不进安全区，固定内容压条带只能靠 offset）');
  assert.ok(ftv.includes('treeBottomClearanceVp()'),
    'FileTreeView 树 List 必须按 treeBottomClearanceVp() 让位末条（滚动到头末条完整露出钉底簇上方）');
  assert.ok(!/px2vp\([^)]*this\.clusterH/.test(ftv),
    'FileTreeView clusterH 来自 onAreaChange 的 Area.height（单位 vp），再包 px2vp 即二次换算（2026-11-14 实测回归）');
  assert.ok(/private treeBottomClearanceVp\(\): number \{[\s\S]{0,160}?if \(this\.referenceOnly\)[\s\S]{0,60}?return 0;/.test(ftv),
    'FileTreeView treeBottomClearanceVp() 必须对 referenceOnly 归零（Agent 页连写条在流内、树不延伸，加了让位即 Agent 页回归）');
  assert.ok(ftv.includes('-this.clusterOffsetVp + Math.max(0, this.clusterH) + Space.s1'),
    'FileTreeView 树让位必须是 −簇offset + 簇高 + s1（expandSafeArea 只延伸渲染边界，滚动内容底止于布局区下沿 2152，公式再叠 navClearance 即重复计入条带）');
  assert.ok(ftv.includes(EXPAND),
    'FileTreeView 树 List 缺 expandSafeArea(BOTTOM)（穿小白条；referenceOnly 下底边不与安全区重合，天然 no-op）');

  // 侧栏：连写条 offset 压底 + chipH 实测回填 + 章节让位 + 给文件树传簇下移量
  const vs = read('components/VaultSidebar.ets');
  assert.ok(vs.includes("@StorageProp('navIndicatorHeightPx')"),
    "VaultSidebar 缺 @StorageProp('navIndicatorHeightPx')");
  assert.ok(vs.includes('@State chipH: number = 0;'),
    'VaultSidebar 缺 @State chipH（连写条实测高，章节/树让位与簇 offset 计算用）');
  assert.ok(vs.includes('if (this.referenceOnly && !this.asDrawer)'),
    'VaultSidebar referenceOnly 连写条必须留在流内（Agent 页维持 57.7 前现状）');
  assert.ok(vs.includes('if (!this.referenceOnly && !this.asDrawer)'),
    'VaultSidebar 工作区连写条必须走覆盖位分支');
  assert.ok(vs.includes('.offset({ y: this.navClearanceVp() })'),
    'VaultSidebar 工作区连写条必须 .offset({ y: this.navClearanceVp() }) 压进手势条条带');
  assert.ok(vs.includes('this.chipH = newArea.height'),
    'VaultSidebar 连写条高必须 onAreaChange 实测回填 chipH（禁止按 vp 估值）');
  assert.ok(!/px2vp\([^)]*this\.chipH/.test(vs),
    'VaultSidebar chipH 来自 onAreaChange 的 Area.height（单位 vp），再包 px2vp 即二次换算（2026-11-14 实测回归）');
  assert.ok(vs.includes('this.navClearanceVp() - this.chipH - Space.s1'),
    'VaultSidebar 嵌入簇 offset 必须是 避让高度 − 连写条高 − s1（连写条高于条带时为负上移；钳 0 会把回收站行压进连写条后面）');
  assert.ok(vs.includes('.padding({ left: Space.s3, right: Space.s3 })'),
    '覆盖位连写条 padding 不得带 bottom（卡片底必须贴物理下沿 2232，带 bottom 即悬空）');
  assert.ok(vs.includes('clusterOffsetVp: this.fileTreeClusterOffsetVp(),'),
    'VaultSidebar 必须给 FileTreeView 传 clusterOffsetVp（嵌入=避让高度−连写条高−s1，抽屉=全额避让高度）');
  assert.ok(vs.includes('chaptersBottomClearanceVp()'),
    'VaultSidebar 章节 List 必须按 chaptersBottomClearanceVp() 让位末条');
  assert.ok(vs.includes('this.chipH - this.navClearanceVp() + Space.s1'),
    'VaultSidebar 嵌入章节让位必须是 连写条高 − 避让高度 + s1（expandSafeArea 只延伸渲染边界，滚动内容底止于布局区下沿 2152；按 chipH 全量让位会多让一个条带高度）');
  assert.ok(vs.includes(EXPAND),
    'VaultSidebar 章节 List 缺 expandSafeArea(BOTTOM)（穿小白条）');

  // 下移量一律取 navIndicatorHeightPx 动态值：三文件条带内 offset 禁止硬编码数值
  for (const rel of ['pages/Index.ets', 'components/FileTreeView.ets', 'components/VaultSidebar.ets']) {
    assert.ok(!/\.offset\(\{ y: \d/.test(read(rel)),
      `${rel} 条带内 offset 禁止硬编码数值（各形态高度不同，须走 navIndicatorHeightPx 动态值）`);
  }
});
