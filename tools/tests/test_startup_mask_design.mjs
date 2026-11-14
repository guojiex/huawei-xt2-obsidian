import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { readSourceFile } from './lib/source.mjs';

// v1.41 41.1–41.6：启动页品牌遮罩（品牌层 / 12 句名言 / 就绪淡出 / 常驻接线 / 无障碍隐藏）。
// v1.63：按设计稿 §4 补齐氛围层、循环动效、逐字浮现与减少动态效果终态。
// v1.64：衬线字体子集、去模糊浮现、装饰引号与极光归位等原型 CSS 的 1:1 还原。
// v1.64 修订：氛围层动效改由 onAppear 起播（ArkUI 禁止在 aboutToAppear 调用动画 API）。
const mask = readSourceFile(
  new URL('../../entry/src/main/ets/components/StartupMask.ets', import.meta.url));
const ambience = readSourceFile(
  new URL('../../entry/src/main/ets/components/StartupAmbience.ets', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const tokens = readSourceFile(
  new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const moduleJson5 = readSourceFile(
  new URL('../../entry/src/main/module.json5', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));
const colorBase = readSourceFile(
  new URL('../../entry/src/main/resources/base/element/color.json', import.meta.url));
const colorDark = readSourceFile(
  new URL('../../entry/src/main/resources/dark/element/color.json', import.meta.url));

test('brand layer renders icon, name, eyebrow, quote and cn-date footer (41.1)', () => {
  assert.match(mask, /Image\(\$r\('app\.media\.app_icon_1024'\)\)/);
  assert.match(mask, /'曜石笔记'\.split\(''\)/);
  assert.match(mask, /Text\('OBSIDIAN NOTES'\)/);
  assert.match(mask, /Text\('—— ' \+ this\.quote\.source\)/);
  assert.match(mask, /backgroundColor\(\$r\('app\.color\.bg_page'\)\)/);
  // 光晕走 brand 渐变 + Startup.haloOpacity；图标阴影复用 float_shadow
  assert.match(mask, /\$r\('app\.color\.brand'\), 0\]/);
  assert.match(mask, /\.opacity\(Startup\.haloOpacity \* this\.haloEnterOpacity \* this\.haloBreathOpacity\)/);
  assert.match(mask, /color: \$r\('app\.color\.float_shadow'\)/);
  // 页脚中文数字日期
  assert.match(mask, /function formatCnDate\(now: Date\): string \{/);
});

test('mask visuals only use tokens and Startup constants, no scattered literals (41.1)', () => {
  for (const src of [mask, ambience]) {
    const offenders = src.match(/\.fontSize\(\s*\d|\.letterSpacing\(\s*\d|\.width\(\s*\d|\.height\(\s*\d/g) ?? [];
    assert.deepEqual(offenders, [], `scattered numeric sizes: ${offenders.join(', ')}`);
  }
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
  assert.equal((mask.match(/setInterval/g) ?? []).length, 0, 'no setInterval polling (v1.65 rotation uses recursive setTimeout)');
});

test('entrance is staggered and holds until the choreography finishes, then one fade (41.3)', () => {
  // 分组错峰：六个入场时刻常量按序（品牌名 / 出处改逐字动态计算）
  const delays = ['enterIconDelay', 'enterHaloDelay', 'enterEyebrowDelay', 'enterRuleDelay',
    'enterQuoteDelay', 'enterFootDelay'];
  for (const delay of delays) {
    assert.match(tokens, new RegExp(`static readonly ${delay}: number = \\d+;`));
    assert.match(mask, new RegExp(`Startup\\.${delay}`));
  }
  assert.match(tokens, /static readonly enterDur: number = 800;/);
  // 逐字名言长度不同：出处与最短驻留按本句末字完成时刻动态顺延，入场不被提前打断
  assert.match(mask, /this\.sourceAt = Startup\.enterQuoteDelay \+ total \* Startup\.quoteCharInterval/);
  assert.match(mask, /this\.holdMs = Math\.max\(Startup\.minHold, this\.sourceAt \+ Startup\.enterDur/);
  assert.match(tokens, /static readonly minHold: number = Startup\.enterFootDelay \+ Startup\.enterDur;/);
  assert.match(mask, /Math\.max\(this\.holdMs - elapsed, 0\)/);
  assert.match(mask, /@Prop @Watch\('onReadyChange'\) ready: boolean = false;/);
  assert.match(mask, /private onReadyChange\(\): void \{/);
  assert.match(mask, /this\.clearEnterTimers\(\);/);
  assert.match(mask, /duration: Startup\.exitDur,\s*\n\s*curve: Motion\.navCurve,/);
  assert.match(mask, /onFinish: \(\): void => \{\s*\n\s*this\.maskGone = true;\s*\n\s*this\.ambienceOn = false;/);
  assert.match(tokens, /static readonly exitDur: number = Motion\.durNav;/);
  // 按分句断行 + 逐字浮现（不再整体淡入）
  assert.match(mask, /function splitQuoteLines\(text: string\): string\[\] \{/);
  assert.match(mask, /ForEach\(this\.nameChars/);
  assert.match(mask, /ForEach\(this\.quoteLineChars/);
  assert.match(mask, /private revealNameChar\(index: number\): void \{/);
  assert.match(mask, /private revealQuoteChar\(index: number\): void \{/);
});

test('Index mounts the mask persistently and keeps the old plain cover removed (41.4)', () => {
  // 旧纯色遮罩（空 Column + bg_page + 空 onClick）不再出现
  assert.doesNotMatch(index,
    /if \(!this\.workspaceInitialRenderReady\) \{\s*\n\s*Column\(\) \{\}/);
  // 常驻挂载 + ready 绑定；置位路径保持 initializeWorkspaceSession 内直接置 true
  assert.match(index, /StartupMask\(\{ ready: this\.workspaceInitialRenderReady \}\)/);
  assert.match(index, /this\.workspaceInitialRenderReady = true;/);
});

test('mask and ambience are decorative: hidden from a11y, no tracking or network (41.5)', () => {
  assert.match(mask, /\.accessibilityLevel\('no'\)/);
  assert.match(ambience, /\.accessibilityLevel\('no'\)/);
  // v1.65：冷启动仍吞掉点击；屏保模式在根节点 onClick 内分支到 exitScreenSaver。
  assert.match(mask, /\.onClick\(\(\): void => \{/);
  assert.match(mask, /if \(this\.screenSaver\) \{\s*\n\s*this\.exitScreenSaver\(\);/);
  for (const src of [mask, ambience]) {
    for (const banned of ['hilog', 'http', 'fetch', 'hiAppEvent', '@kit.NetworkKit']) {
      assert.ok(!src.includes(banned), `startup layer must not reference ${banned}`);
    }
  }
  assert.equal((ambience.match(/setInterval/g) ?? []).length, 0, 'no polling interval');
});

test('system start window stays simple: module.json5 untouched (41.6)', () => {
  assert.match(moduleJson5, /"startWindowIcon": "\$media:startIcon"/);
  assert.match(moduleJson5, /"startWindowBackground": "\$color:start_window_background"/);
  assert.ok(!moduleJson5.includes('"startWindow"'),
    'enhanced startWindow profile not introduced');
});

test('v1.63 ambience layer: three drifting aura orbs, paper grain and rising dust', () => {
  assert.match(mask, /StartupAmbience\(\{ reduceMotion: this\.reduceMotion \}\)/);
  // 极光三色（蓝 / 紫 / 绿）与三档漂移周期
  for (const color of ['brand', 'startup_aura_purple', 'success']) {
    assert.match(ambience, new RegExp(`\\$r\\('app\\.color\\.${color}'\\)`));
  }
  // 原型 filter:blur(48px) 作用于整个 .startup-aura 容器一次，不是逐团三次
  assert.equal((ambience.match(/\.blur\(Startup\.auraBlur\)/g) ?? []).length, 1);
  assert.match(ambience, /\.width\(Startup\.auraContainerSize\)/);
  assert.match(ambience, /\.position\(\{ x: Startup\.auraContainerInset, y: Startup\.auraContainerInset \}\)/);
  for (const dur of ['auraDurA', 'auraDurB', 'auraDurC']) {
    assert.match(tokens, new RegExp(`static readonly ${dur}: number = \\d+;`));
    assert.match(ambience, new RegExp(`Startup\\.${dur}`));
  }
  assert.match(ambience, /keyframeAnimateTo\(\{ iterations: -1 \}, frames\)/);
  // 原型 --cb-purple 浅 / 深值进入主题资源（绿色复用 success，与 --green 同值）
  assert.match(colorBase, /"name": "startup_aura_purple", "value": "#7A5CD6"/i);
  assert.match(colorDark, /"name": "startup_aura_purple", "value": "#A991F0"/i);
  assert.ok(prototype.includes('--cb-purple:#7a5cd6') && prototype.includes('--cb-purple:#a991f0'));
  // 纸感颗粒：ImageData 逐块随机灰度近似 SVG feTurbulence，不使用轮询或离屏混合
  assert.match(ambience, /Canvas\(this\.grainContext\)/);
  assert.match(ambience, /\.onReady\(\(\): void => \{\s*\n\s*this\.drawGrain\(\);/);
  assert.match(ambience, /ctx\.createImageData\(w, h\)/);
  assert.match(ambience, /ctx\.putImageData\(image, 0, 0\)/);
  assert.match(ambience, /Startup\.grainDarkRGB : Startup\.grainLightRGB/);
  assert.match(ambience, /Startup\.grainDarkAlpha : Startup\.grainLightAlpha/);
  assert.match(ambience, /Startup\.grainNoiseStep/);
  // 浮尘 16 粒：本地随机 + 关键帧无限上浮 + 负相位，减少动态效果时不渲染
  assert.match(tokens, /static readonly dustCount: number = 16;/);
  assert.match(ambience, /makeDustSpecs\(Startup\.dustCount\)/);
  assert.match(ambience, /delayMs: -Math\.random\(\) \* durationMs/);
  assert.match(ambience, /keyframeAnimateTo\(\{ iterations: -1, delay: this\.delayMs \}, frames\)/);
  assert.match(ambience, /if \(!this\.reduceMotion\) \{/);
  // 装饰层不拦截命中
  assert.ok((ambience.match(/\.hitTestBehavior\(HitTestMode\.None\)/g) ?? []).length >= 5);
});

test('v1.63 looping brand motion, per-character entrance and reduced-motion final state', () => {
  // 图标轻浮 / 光晕呼吸 / 高光斜扫：三段无限循环 + 退出时 duration 0 停止
  assert.equal((mask.match(/keyframeAnimateTo\(\{ iterations: -1 \}, frames\)/g) ?? []).length, 3);
  assert.match(mask, /private playIconFloat\(\): void \{/);
  assert.match(mask, /private playHaloBreath\(\): void \{/);
  assert.match(mask, /private playSheen\(\): void \{/);
  assert.match(mask, /\.clip\(true\)/);
  assert.match(mask, /\.translate\(\{ x: this\.sheenX \}\)/);
  assert.match(mask, /private stopBrandLoops\(\): void \{/);
  assert.match(mask, /animateTo\(\{ duration: 0 \}/);
  // 发丝线自中向两侧展开
  assert.match(mask, /\.scale\(\{ x: this\.ruleScaleX, y: 1 \}\)/);
  assert.match(tokens, /static readonly ruleScaleFrom: number = 0;/);
  // 逐字节奏与出处间隔来自设计稿 §4
  assert.match(tokens, /static readonly nameCharInterval: number = 120;/);
  assert.match(tokens, /static readonly quoteCharInterval: number = 45;/);
  assert.match(tokens, /static readonly sourceAfterLastChar: number = 350;/);
  // 减少动态效果：宿主可传入，终态直出、退出直接切换；偏好读取仍按 api_notes U1 不接线
  assert.match(mask, /@Prop reduceMotion: boolean = false;/);
  assert.match(mask, /private showFinalState\(\): void \{/);
  assert.match(mask, /if \(this\.reduceMotion\) \{\s*\n\s*this\.maskGone = true;/);
  assert.match(ambience, /@Prop reduceMotion: boolean = false;/);
  assert.match(ambience, /if \(this\.reduceMotion\) \{\s*\n\s*this\.auraFade = 1;/);
  assert.ok(!moduleJson5.includes('ohos.permission.FILE_ACCESS_PERSIST') ||
    !mask.includes('@kit.AssetStoreKit'), 'startup layer needs no permission or credential access');
});

test('v1.64 prototype CSS parity: serif subset, de-blur entrance, quote mark and aura placement', () => {
  // 字体：注册两档静态子集，取代在 HarmonyOS 上无效的 fontFamily('serif')
  assert.doesNotMatch(mask, /fontFamily\('serif'\)/);
  assert.match(mask, /private registerStartupSerif\(\): void \{/);
  assert.match(mask, /this\.registerStartupSerif\(\);/);
  assert.match(mask, /\.getFont\(\)\.registerFont\(\{/);
  assert.match(mask, /\$rawfile\('fonts\/StartupSerif-Regular\.ttf'\)/);
  assert.match(mask, /\$rawfile\('fonts\/StartupSerif-Semibold\.ttf'\)/);
  assert.match(mask, /familyName: Startup\.serifSemiboldFamily/);
  assert.ok((mask.match(/\.fontFamily\(Startup\.serifFamily\)/g) ?? []).length >= 3);
  assert.match(mask, /\.fontWeight\(Weight\.semibold\)/);
  assert.match(tokens, /static readonly serifFamily: string = 'StartupSerif';/);
  assert.match(tokens, /static readonly serifSemiboldFamily: string = 'StartupSerifSemibold';/);

  // 去模糊浮现：图标 + 品牌名逐字 + 名言逐字（原型 startup-in 的 filter:none）
  assert.match(mask, /\.blur\(this\.iconBlur\)/);
  assert.match(mask, /@State private iconBlur: number = Startup\.iconEnterFromBlur;/);
  assert.match(mask, /\.blur\(\(1 - this\.nameCharOpacity\[index\]\) \* Startup\.nameCharBlur\)/);
  assert.match(mask, /\.blur\(\(1 - this\.quoteCharOpacity\[/);
  for (const c of ['iconEnterFromBlur', 'nameCharBlur', 'quoteCharBlur']) {
    assert.match(tokens, new RegExp(`static readonly ${c}: number = \\d+;`));
  }
  assert.match(mask, /this\.iconBlur = 0;/);

  // 装饰引号（原型 .startup-quote::before）+ 名言 clamp 自适应字号 + 出处字距
  assert.match(mask, /Text\('“'\)/);
  assert.match(mask, /Startup\.quoteMarkOpacity/);
  assert.match(mask, /Startup\.quoteMarkSizeRatio/);
  assert.match(mask, /private quoteFontSize\(\): number \{/);
  assert.match(mask, /Startup\.quoteSizeVwRatio/);
  assert.match(mask, /Startup\.quoteMaxEm/);
  assert.match(mask, /Startup\.sourceTrackingRatio/);
  for (const c of ['quoteSizeMin', 'quoteSizeMax', 'quoteSizeVwRatio', 'quoteSizeBase',
    'quoteMaxEm', 'sourceTrackingRatio', 'quoteMarkOpacity', 'quoteMarkSizeRatio']) {
    assert.match(tokens, new RegExp(`static readonly ${c}: number = `));
  }

  // 紫色极光归位右下（right:4% / bottom:2%），第二团 scale 0.9，浮尘 X 终态回 0
  assert.match(tokens, /static readonly auraPosBX: string = '96%';/);
  assert.match(tokens, /static readonly auraPosBY: string = '98%';/);
  assert.match(ambience, /\.markAnchor\(\{ x: '100%', y: '100%' \}\)/);
  assert.match(ambience, /Startup\.auraScaleDeltaB/);
  assert.match(tokens, /static readonly auraScaleDeltaB: number = 0\.10;/);
  assert.match(tokens, /static readonly dustSwayReturnRatio: number = 0;/);
});

test('v1.64 serif subset is OFL-compliant, static and covers the startup charset', () => {
  const dir = new URL('../../entry/src/main/resources/rawfile/fonts/', import.meta.url);
  const license = readFileSync(new URL('OFL.txt', dir), 'utf8');
  assert.match(license, /SIL OPEN FONT LICENSE Version 1\.1/);
  assert.match(license, /Copyright 2012 Google Inc\./);
  assert.ok(existsSync(new URL('../../tools/generators/gen_startup_serif.mjs', import.meta.url)));

  for (const [file, weight] of [['StartupSerif-Regular.ttf', 400],
    ['StartupSerif-Semibold.ttf', 600]]) {
    const url = new URL(file, dir);
    assert.ok(existsSync(url), `missing font: ${file}`);
    const size = statSync(url).size;
    assert.ok(size > 50 * 1024 && size < 500 * 1024, `unexpected subset size: ${size}`);
    const buf = readFileSync(url);
    const count = buf.readUInt16BE(4);
    const tags = new Set();
    const offsets = new Map();
    for (let i = 0; i < count; i++) {
      const at = 12 + 16 * i;
      const tag = buf.toString('ascii', at, at + 4);
      tags.add(tag);
      offsets.set(tag, buf.readUInt32BE(at + 8));
    }
    for (const tag of ['cmap', 'glyf', 'head', 'hhea', 'hmtx', 'loca', 'maxp', 'name', 'OS/2']) {
      assert.ok(tags.has(tag), `${file}: missing ${tag}`);
    }
    assert.ok(!tags.has('fvar'), `${file}: variable axes must be pinned`);
    const os2 = offsets.get('OS/2');
    assert.equal(buf.readUInt16BE(os2 + 4), weight, `${file}: usWeightClass`);

    // 内部 family 名改写为自定义名，版权与 OFL 声明保留
    const nameAt = offsets.get('name');
    const nameCount = buf.readUInt16BE(nameAt + 2);
    const strOff = buf.readUInt16BE(nameAt + 4);
    let family = '';
    let copyright = '';
    let licenseText = '';
    for (let i = 0; i < nameCount; i++) {
      const r = nameAt + 6 + 12 * i;
      const platform = buf.readUInt16BE(r);
      const nameId = buf.readUInt16BE(r + 6);
      const len = buf.readUInt16BE(r + 8);
      const off = buf.readUInt16BE(r + 10);
      const raw = Buffer.from(buf.subarray(nameAt + strOff + off, nameAt + strOff + off + len));
      const text = platform === 3 || platform === 0 ? raw.swap16().toString('utf16le') : raw.toString('latin1');
      if (nameId === 1 && (platform === 3 || platform === 0)) family = text;
      if (nameId === 0 && platform === 3) copyright = text;
      if (nameId === 13 && platform === 3) licenseText = text;
    }
    assert.equal(family, weight === 400 ? 'StartupSerif' : 'StartupSerifSemibold');
    assert.match(copyright, /Adobe/);
    assert.match(licenseText, /Open Font License/);
  }
});

test('v1.64 fix: ambience animations start on onAppear, never in aboutToAppear', () => {
  // ArkUI 显式动画规范：aboutToAppear 中 build 未执行、内部组件未创建，动画属性无初值，
  // animateTo / animateToImmediately / keyframeAnimateTo 均不得在其中调用（api_notes U4）。
  // 品牌层走 setTimeout 异步调度（build 之后），氛围层曾全部起播在 aboutToAppear 导致背景动效不生效。
  for (const src of [ambience, mask]) {
    const lifecycle = [...src.matchAll(/aboutToAppear\(\): void \{([\s\S]*?)\n  \}/g)];
    assert.ok(lifecycle.length > 0, 'missing aboutToAppear');
    for (const [, body] of lifecycle) {
      assert.doesNotMatch(body, /\.(?:keyframe)?[Aa]nimateTo\(/,
        'animation API must not be called in aboutToAppear');
    }
  }
  // 氛围层：根节点 onAppear 起播极光淡入 + 三团漂移，一次性守卫防重复叠加循环
  assert.match(ambience, /private startAmbience\(\): void \{/);
  assert.match(ambience, /private ambienceStarted: boolean = false;/);
  assert.match(ambience, /if \(this\.ambienceStarted \|\| this\.reduceMotion\) \{/);
  assert.match(ambience, /this\.ambienceStarted = true;/);
  assert.match(ambience, /\.onAppear\(\(\): void => \{\s*this\.startAmbience\(\);/);
  assert.match(ambience, /animateTo\(\{ duration: Startup\.auraFadeDur, curve: Motion\.navCurve \}/);
  // 浮尘：每粒自己的 onAppear 起播关键帧，同样带守卫
  assert.match(ambience, /private startRise\(\): void \{/);
  assert.match(ambience, /private moteStarted: boolean = false;/);
  assert.match(ambience, /if \(this\.moteStarted\) \{/);
  assert.match(ambience, /this\.moteStarted = true;/);
  assert.match(ambience, /\.onAppear\(\(\): void => \{\s*this\.startRise\(\);/);
  assert.equal((ambience.match(/\.onAppear\(/g) ?? []).length, 2);
  // aboutToAppear 只保留数据准备与减动效静态终态
  assert.match(ambience, /this\.dustSpecs = makeDustSpecs\(Startup\.dustCount\);/);
  assert.match(ambience, /if \(this\.reduceMotion\) \{\s*this\.auraFade = 1;/);
});
