/**
 * 底部手势条沉浸防线（v1.57 57.4，需求池 Y-01）。
 *
 * 背景：官方 UX 标准要求次级页面可滚动内容显示在导航条下方（qa/2026-11-13
 * 手势条问答，api_notes AE2）。落地方式：次级页面滚动容器加
 * `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])`，内容底部
 * 留白 = 既有间距 + 导航条避让高度（`navIndicatorHeightPx` 动态值，禁止硬编码）。
 *
 * 规则：
 *  1. 五个次级滚动容器（设置分类列表 / 设置内容 / 版本记录 / 库管理 / 统计）
 *     必须带 `expandSafeArea(... SafeAreaEdge.BOTTOM)`——被误删即本测试失败；
 *  2. EntryAbility 必须监听 TYPE_NAVIGATION_INDICATOR 并发布
 *     `navIndicatorHeightPx`（初始 + avoidAreaChange 两处）；
 *  3. 消费该值的视图必须同时有 `@StorageProp('navIndicatorHeightPx')` 与
 *     页面侧 `px2vp` 换算（官方口径：px2vp 在 UI 上下文才可靠）。
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
    ['components/VaultStatsView.ets', 1],
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
