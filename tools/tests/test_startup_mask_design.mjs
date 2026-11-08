import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.41 41.1–41.5：启动页品牌遮罩 —— 品牌层组件 / 12 句名言 / 就绪淡出 / 常驻接线 / 无障碍隐藏。
const mask = readSourceFile(
  new URL('../../entry/src/main/ets/components/StartupMask.ets', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const tokens = readSourceFile(
  new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const moduleJson5 = readSourceFile(
  new URL('../../entry/src/main/module.json5', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

test('brand layer renders icon, name, eyebrow, quote and cn-date footer (41.1)', () => {
  assert.match(mask, /Image\(\$r\('app\.media\.app_icon_1024'\)\)/);
  assert.match(mask, /Text\('曜石笔记'\)/);
  assert.match(mask, /Text\('OBSIDIAN NOTES'\)/);
  assert.match(mask, /Text\('—— ' \+ this\.quote\.source\)/);
  assert.match(mask, /backgroundColor\(\$r\('app\.color\.bg_page'\)\)/);
  // 光晕走 brand 渐变 + Startup.haloOpacity；图标阴影复用 float_shadow
  assert.match(mask, /\$r\('app\.color\.brand'\), 0\]/);
  assert.match(mask, /\.opacity\(Startup\.haloOpacity\)/);
  assert.match(mask, /color: \$r\('app\.color\.float_shadow'\)/);
  // 页脚中文数字日期
  assert.match(mask, /function formatCnDate\(now: Date\): string \{/);
});

test('mask visuals only use tokens and Startup constants, no scattered literals (41.1)', () => {
  // 不允许 fontSize / letterSpacing 出现字面数字
  const offenders = mask.match(/\.fontSize\(\s*\d|\.letterSpacing\(\s*\d|\.width\(\s*\d|\.height\(\s*\d/g) ?? [];
  assert.deepEqual(offenders, [], `scattered numeric sizes: ${offenders.join(', ')}`);
  // Tokens.ets 提供 Startup 常量类（数值真源 v2 原型 .startup-*）
  assert.match(tokens, /export class Startup \{/);
  assert.match(tokens, /static readonly iconSize: number = 96;/);
  assert.match(tokens, /static readonly iconRadius: number = Radius\.menu \+ Space\.s2;/);
  assert.match(tokens, /static readonly nameSize: number = FontSize\.s3 \* 1\.4;/);
});

test('quote library holds 12 static entries matching the prototype (41.2)', () => {
  const entries = mask.match(/\{ text: '[^']+', source: '[^']+' \}/g) ?? [];
  assert.equal(entries.length, 12, `expected 12 quotes, got ${entries.length}`);
  // 每句名言与出处都来自原型 STARTUP_QUOTES，不自行改写
  for (const entry of entries) {
    const text = entry.match(/text: '([^']+)'/)[1];
    const source = entry.match(/source: '([^']+)'/)[1];
    assert.ok(prototype.includes(`['${text}','${source}']`),
      `quote not in prototype: ${text} / ${source}`);
  }
  // 每次冷启动随机取一句，不轮播
  assert.match(mask, /Math\.floor\(Math\.random\(\) \* QUOTES\.length\)/);
  assert.equal((mask.match(/setInterval/g) ?? []).length, 0, 'no rotation interval');
});

test('entrance is staggered opacity/translate only and ready exits in one fade (41.3)', () => {
  // 分组错峰：七个入场时刻常量按序
  const delays = ['enterIconDelay', 'enterNameDelay', 'enterEyebrowDelay', 'enterRuleDelay',
    'enterQuoteDelay', 'enterSourceDelay', 'enterFootDelay'];
  for (const delay of delays) {
    assert.match(tokens, new RegExp(`static readonly ${delay}: number = \\d+;`));
    assert.match(mask, new RegExp(`Startup\\.${delay}`));
  }
  assert.match(tokens, /static readonly enterDur: number = 800;/);
  // 就绪即中断：清空入场定时器 + 240ms 淡出 + 完成后隐藏
  assert.match(mask, /@Prop @Watch\('onReadyChange'\) ready: boolean = false;/);
  assert.match(mask, /private onReadyChange\(\): void \{/);
  assert.match(mask, /this\.clearEnterTimers\(\);/);
  assert.match(mask, /duration: Startup\.exitDur,\s*\n\s*curve: Motion\.navCurve,/);
  assert.match(mask, /onFinish: \(\): void => \{\s*this\.maskGone = true;\s*\}/);
  assert.match(tokens, /static readonly exitDur: number = Motion\.durNav;/);
  // 入场只动 opacity / translate / scale，不做逐字浮现（无 per-char 循环渲染）
  assert.equal((mask.match(/splitQuoteLines|ForEach\(this\.quoteLines/g) ?? []).length >= 2, true);
  assert.equal((mask.match(/for \(let i = 0; i < this\.quote\.text/g) ?? []).length, 0,
    'no per-character rendering');
});

test('Index mounts the mask persistently and keeps the old plain cover removed (41.4)', () => {
  // 旧纯色遮罩（空 Column + bg_page + 空 onClick）不再出现
  assert.doesNotMatch(index,
    /if \(!this\.workspaceInitialRenderReady\) \{\s*\n\s*Column\(\) \{\}/);
  // 常驻挂载 + ready 绑定；置位路径保持 initializeWorkspaceSession 内直接置 true
  assert.match(index, /StartupMask\(\{ ready: this\.workspaceInitialRenderReady \}\)/);
  assert.match(index, /this\.workspaceInitialRenderReady = true;/);
});

test('mask is a decorative layer: hidden from a11y, no tracking or network (41.5)', () => {
  assert.match(mask, /\.accessibilityLevel\('no'\)/);
  assert.match(mask, /\.onClick\(\(\): void => \{\s*\}\)/);
  for (const banned of ['hilog', 'http', 'fetch', 'hiAppEvent', '@kit.NetworkKit']) {
    assert.ok(!mask.includes(banned), `mask must not reference ${banned}`);
  }
});

test('system start window stays simple: module.json5 untouched (41.6)', () => {
  assert.match(moduleJson5, /"startWindowIcon": "\$media:startIcon"/);
  assert.match(moduleJson5, /"startWindowBackground": "\$color:start_window_background"/);
  assert.ok(!moduleJson5.includes('"startWindow"'),
    'enhanced startWindow profile not introduced in v1.41');
});
